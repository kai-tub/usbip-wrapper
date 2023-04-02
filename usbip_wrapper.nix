# should differ between client/server mode
flake: { config, lib, pkgs, ... }:
let
  cfg = config.services.usbip_wrapper;
  usbip_wrapper = flake.packages.x86_64-linux.usbip_wrapper;
  port_internal = "5555";
in
{
  imports = [
  ];

  options = {
    services.usbip_wrapper = {
      enable = lib.mkEnableOption ''
        A usbip configuration wrapper
      '';

      mode = lib.mkOption {
        type = lib.types.addCheck lib.types.str (x: lib.asserts.assertOneOf "mode" x [ "host" "client" ]);
        default = "host";
        description = ''
          Set if the module should configure a usb `host`
          (a device that allows mounting of attached local USB devices)
          or a `client` that may attach a remotely hosted USB device.

          Value must be either `host` or `client`.
        '';
      };

      # could set port here
      # and usb device, I guess
      package = lib.mkOption {
        type = lib.types.package;
        default = usbip_wrapper;
        description = ''
          The usbip_wrapper package to use with the service.
        '';
      };

      usb_ids = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = ''
          The USB device(s) that should be hosted/mounted via usbip.
          Check these values with `lsusb`. For example:
        '';
        example = ''[ "0627:0001" ]'';
      };

      port = lib.mkOption {
        type = lib.types.int;
        default = 5000;
        description = ''
          The port that the usbip server/client will communicate over.
        '';
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.mode == "host") {
    # This seems to work! This is amazing!
    # I can simply add these as a dependency from within the flake
    # and continue to minimize the dependencies for the end-user flake file!
    # Nix will merge the lists during the resolving phase!
    boot.extraModulePackages = with config.boot.kernelPackages; [ usbip ];
    boot.kernelModules = [ "usbip_host" "vhci-hcd" ];
    systemd.services.usbip_server = {
      description = "Start usbip server.";
      # TODO: Re-enable after a few tests!

      requires = [ "usbip_server_timeout.timer" ];
      after = [ "usbip_server_timeout.timer" ];
      # requires
      # Stop the server when the timeout service is started,
      # which is controlled by a systemd timer unit!
      conflicts = [ "usbip_server_timeout.service" ];
      environment = {
        USBIP_TCP_PORT = "${port_internal}";
        # systemd recommends against PID files!
        # USBIP_DAEMON_PID_PATH = "/var/run/usbipd.pid";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = ''
          ${cfg.package}/bin/usbip_wrapper start-usb-hoster
        '';
        # TODO: Disable pid file if not necessary
        # TODO: Think where the unhost command should be run! 
        # just to cleanly shut down
        # or does shutting down the server take care of it?
        Restart = "no";
        # Basic Hardening
        NoNewPrivileges = "yes";
        PrivateTmp = "yes";
        # PrivateDevices = "no";
        # Limit access to only contain relevant USB devices!
        # DeviceAllow = [ "char-usb/*" "char-usb_device/*" ];
        # DevicePolicy = "closed"; # TODO: Understand this better!
        # DynamicUser = "true"; # need to explicitely create user for simpler secret management
        # ProtectSystem = "strict";
        # why at all read-only ? Whose home?
        # ProtectHome = "read-only";
        # ProtectControlGroups = "yes";
        # ProtectKernelModules = "yes";
        # ProtectKernelTunables = "yes";
        # RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6 AF_NETLINK";
        # RestrictNamespaces = "yes";
        # RestrictRealtime = "yes";
        # RestrictSUIDSGID = "yes";
        # MemoryDenyWriteExecute = "yes";
        # LockPersonality = "yes";
      };
      path = [ "${config.boot.kernelPackages.usbip}" ];
    };
    # Why host-side timeout?
    # Because I want to make the key 'locally' available again without any
    # interaction and to not keep hosting it 'forever' to my server
    # Unhosting would also be an option but then the server would be running
    # without any reason
    systemd.services.usbip_server_timeout = {
      description = "Pseudo-service that is in conflict with usbip server to stop it after timer has run out";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.coreutils}/bin/echo 'Auto-stopping USBIP server!'";
      };
    };

    systemd.timers.usbip_server_timeout = {
      timerConfig = {
        AccuracySec = 1;
        OnActiveSec = 30;
        # TODO: Write a tutorial about how this can be utilized
        # to repeatably stop the other service!
        # If not set, then it won't work!
        RemainAfterElapse = false;
      };
    };

    systemd.services.usbip_host_key = {
      description = "Host hardware token via usbip.";
      environment = {
        USBIP_TCP_PORT = "${port_internal}";
      };
      wants = [ "usbip_server_timeout.timer" ];
      bindsTo = [ "usbip_server.service" ];
      serviceConfig = {
        Type = "oneshot";
        # RemainAfterExit = "true";
        ExecStart = ''
          ${cfg.package}/bin/usbip_wrapper host -- ${builtins.concatStringsSep " " cfg.usb_ids}
        '';
        # Restart = "always";
        # Basic Hardening
        NoNewPrivileges = "yes";
        PrivateTmp = "yes";
      };
      # guarantee that the correct usbip version is used and in sync with linux kernel!
      path = [ "${config.boot.kernelPackages.usbip}" ];
    };

    # https://unix.stackexchange.com/questions/265704/start-stop-a-systemd-service-at-specific-times

    # I feel like this could also call the usbip-hoster and is then called the 'proxy' for the key
    # then I would save one config file
    systemd.services.usbip_proxy = {
      description = "A wrapper script that forwards the TCP data from a systemd controled socket to the usbip managed socket.";
      # Auto-mount the yubico usb-key if available
      wants = [ "usbip_host_key.service" ];
      # Do i need the same for the socket?
      # If usbip_server shuts down, also stop the proxy
      bindsTo = [ "usbip_server.service" ];
      after = [ "usbip_server.service" ];
      unitConfig = {
        # make the services "findable" for each other
        # but not other local services
        # TODO: Make sure this actually works and if the other ones
        # also need the same configuration!
        JoinsNamespaceOf = [ "usbip_server.service" "usbip_host_key.service" ];
      };
      serviceConfig = {
        # Sets the time before exiting when there are NO connections
        ExecStart = ''
          ${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time="1min" localhost:${port_internal}
        '';
      };
    };

    systemd.sockets.usbip_proxy = {
      enable = true;
      # Given the firewall configuration, this setting should be safe
      # and allow testing availability via localhost; also when private network
      # is set, even 'unsafe' local application shouldn't be able to see the traffic
      listenStreams = [ "5000" ];
      wantedBy = [ "sockets.target" ];
      socketConfig = {
        # Accept = true;
        # MaxConnections = 1;
      };
    };
  };
}

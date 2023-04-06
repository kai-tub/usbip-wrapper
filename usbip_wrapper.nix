# should differ between client/server mode
flake: { config, lib, pkgs, ... }:
let
  cfg = config.services.usbip_wrapper_host;
  # cfg_client = config.services.usbip_wrapper_client;
  usbip_wrapper = flake.packages.x86_64-linux.usbip_wrapper;
  port_internal = "5555";
in
{
  imports = [
  ];

  options = {
    services.usbip_wrapper_client = {
      default = { };
      description = "usbip_wrapper_client instance interface";
      # enable = lib.mkEnableOption "Global enable flag for all usbip_wrapper client instances.";
      instances = lib.mkOption {
        # attrsOf t: An attribute set of elements with the type t. 
        # The merge function zip all attribute sets into one.
        # Attribute values of the resulting attribute set are merged with the merge function of the type t.
        # submodule: https://nixos.org/manual/nixos/stable/index.html#section-option-types-submodule
        default = { };
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            enable = lib.mkEnableOption "Configure a usbip_wrapper client instance.";
            description = "An example opti";

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
                The USB device(s) that should be mounted via usbip.
                Check these values with `lsusb`.
              '';
              example = ''[ "0627:0001" ]'';
            };

            port = lib.mkOption {
              type = lib.types.int;
              default = 5000;
              description = ''
                The port that the usbip client will communicate over.
              '';
            };

            host = lib.mkOption {
              type = lib.types.str;
              description = ''
                This is the _name_ of the `host`s from the viewpoint of the **client**.
                The client takes this value and tries to connect to the host by resolving the provided value.
              '';
              default = "";
              example = ''"your-device@XXX.tailscale.net" | "192.XXX.XXX.XXX"'';
            };
          };
        });
      };
    };
    services.usbip_wrapper_host = {
      enable = lib.mkEnableOption ''
        A usbip_wrapper host configuration
      '';
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

      timeout = lib.mkOption {
        type = lib.types.str;
        description = ''
          systemd time value that defines how long the usbip server
          should live. Only used if `mode=host` otherwise the value is ignored.
          This value will NOT be checked!
          Please see https://www.freedesktop.org/software/systemd/man/systemd.time.html#
          for more information!
        '';
        default = "30s";
        example = ''30s | 1h | 2 hours | 10 seconds | 50 ms'';
      };
    };
  };

  config = lib.mkMerge [
    # Maybe required to put () around the equality check!
    (lib.mkIf
      (config.services.usbip_wrapper_client.instances != { })
      {
        # global requirement
        boot.extraModulePackages = with config.boot.kernelPackages; [ usbip ];
        boot.kernelModules = [ "vhci-hcd" ];

        systemd.services =
          # let
          # instantiateService = name: {
          #   name = "usbip_mounter@${name}";
          #   value = {
          #     enable = true;
          #   };
          # };
          # Should this still instantiate from a systemd template?
          # Feel like this isn't necessary for the first version.
          # instantiated_services = builtins.listToAttrs (builtins.map instantiateService cfg.host_names);
          # in
          lib.mapAttrs'
            (name: instance_value:
              {
                # This may be a bit misleading. I have to make clear that
                # i only build the name given the host!
                # This would again speak for using a systemd template!
                name = "usbip_mounter_${instance_value.host}";
                value = {
                  description = "Template for Remote USB mounter via usbip";
                  wants = [ "network-online.target" ];
                  after = [ "network-online.target" ];
                  # FUTURE: Think about if this is more or less clear what is going on ?
                  environment = {
                    USBIP_TCP_PORT = "${builtins.toString instance_value.port}";
                    USBIP_REMOTE_HOST = "${instance_value.host}";
                  };

                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = ''
                      ${cfg.package}/bin/usbip_wrapper mount-remote -- ${builtins.concatStringsSep " " instance_value.usb_ids}
                    '';
                  };
                  path = [ "${config.boot.kernelPackages.usbip}" ];
                };
              })
            config.services.usbip_wrapper_client.instances;
      })
    (lib.mkIf cfg.enable {

      # This seems to work! This is amazing!
      # I can simply add these as a dependency from within the flake
      # and continue to minimize the dependencies for the end-user flake file!
      # Nix will merge the lists during the resolving phase!
      boot.extraModulePackages = with config.boot.kernelPackages;
        [ usbip ];
      # boot.kernelModules = [ "usbip_host" "vhci-hcd" ];
      boot.kernelModules = [ "usbip_host" ];

      systemd.services.usbip_server_waiter = {
        description = "USBIP-Server Initialization Wait Loop";
        requires = [ "usbip_server.service" ];
        # This ensures that the service itself has printed a magic message that indicates
        # it is ready to start accepting incoming requests.
        before = [ "usbip_server.service" ];
        serviceConfig = {
          Type = "oneshot";
          # FUTURE: Avoid bash call and use socat!
          # socat EXEC:'journalctl --unit usbip_server.service --since "now" --follow' EXEC:'rg --quiet --line-buffered "started"'
          ExecStart = ''
            ${pkgs.bash}/bin/bash -c 'journalctl --unit usbip_server.service --since "now" --follow | ${pkgs.ripgrep}/bin/rg --quiet --line-buffered "listening on"'
          '';
          # Basic Hardening
          NoNewPrivileges = "yes";
          PrivateTmp = "yes";
        };
        # I assume path isn't working as the shell doesn't inherit it's execution?
        path = [ "${config.systemd.package}/lib" "${pkgs.ripgrep}/bin" "${pkgs.socat}/bin" ];
      };

      systemd.services.usbip_server = {
        description = "USBIP server with auto-shutdown";
        requires = [ "usbip_host_timeout.timer" ];
        after = [ "usbip_host_timeout.timer" ];
        # requires
        # Stop the server when the timeout service is started,
        # which is controlled by a systemd timer unit!
        conflicts = [ "usbip_host_timeout.service" ];
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
        };
        path = [ "${config.boot.kernelPackages.usbip}" ];
      };
      # Why host-side timeout?
      # Because I want to make the key 'locally' available again without any
      # interaction and to not keep hosting it 'forever' to my server
      # Unhosting would also be an option but then the server would be running
      # without any reason
      systemd.services.usbip_host_timeout = {
        description = "USBIP Server Shutdown";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${pkgs.coreutils}/bin/echo 'Auto-stopping USBIP server!'";
        };
      };

      systemd.timers.usbip_host_timeout = {
        timerConfig = {
          AccuracySec = 1;
          OnActiveSec = "${cfg.timeout}";
          # TODO: Write a tutorial about how this can be utilized
          # to repeatably stop the other service!
          # If not set, then it won't work!
          RemainAfterElapse = false;
        };
      };

      systemd.services.usbip_hoster = {
        description = "Host usb device via usbip.";
        environment = {
          USBIP_TCP_PORT = "${port_internal}";
        };
        wants = [ "usbip_host_timeout.timer" ];
        bindsTo = [ "usbip_server.service" ];
        serviceConfig = {
          Type = "oneshot";
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
        wants = [ "usbip_server.service" "usbip_hoster.service" ];
        # Do i need the same for the socket?
        # If usbip_server shuts down, also stop the proxy
        # Just to avoid confusion but usbip_hoster service would be sufficient with the bindsTo `usbip_server`
        bindsTo = [ "usbip_server.service" ];
        after = [ "usbip_server.service" "usbip_server_waiter.service" "usbip_hoster.service" ];
        unitConfig = {
          # make the services "findable" for each other
          # but not other local services
          # TODO: Make sure this actually works and if the other ones
          # also need the same configuration!
          JoinsNamespaceOf = [ "usbip_server.service" "usbip_hoster.service" ];
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
        listenStreams = [ "${builtins.toString cfg.port}" ];
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          # Accept = true;
          # MaxConnections = 1;
        };
      };
    })
  ];
}

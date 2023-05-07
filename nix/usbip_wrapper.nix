# should differ between client/server mode
flake: nu_mode: { config, lib, pkgs, ... }:
let
  cfg_host = config.services.usbip_wrapper_host;
  cfg_client = config.services.usbip_wrapper_client;
  # there is probably a smarter way to do this...
  usbip_wrapper = if nu_mode then flake.packages.x86_64-linux.usbip_wrapper_nu else flake.packages.x86_64-linuux.usbip_wrapper;
  port_internal = "5555";
in
{
  imports = [
  ];

  options =
    let
      package = lib.mkOption {
        type = lib.types.package;
        default = usbip_wrapper;
        description = ''
          The usbip_wrapper package to use with the service.
        '';
      };

      mk_opt_usb_ids = verb: lib.mkOption {
        type = lib.types.listOf lib.types.str;
        example = ''[ "0627:0001" ]'';
        description = ''
          The USB device(s) that should be ${verb} via usbip.
          Check these values with `lsusb`.
        '';
      };

      mk_opt_port = device: lib.mkOption {
        type = lib.types.int;
        default = 5000;
        description = ''
          The port that the usbip ${device} will communicate over.
        '';
      };
    in
    {
      services.usbip_wrapper_client = {
        default = { };
        # description = "usbip_wrapper_client instance interface";
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
              description = "The name of the instance will be used to generate the name of the systemd file called: usbip_mounter_<instance_value>";

              inherit package;
              usb_ids = mk_opt_usb_ids "mounted";
              port = mk_opt_port "client";

              host = lib.mkOption {
                type = lib.types.str;
                description = ''
                  This is the _name_ of the `host`s from the viewpoint of the **client**.
                  The client takes this value and tries to connect to the host by resolving the provided value.
                '';
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
        inherit package;

        usb_ids = mk_opt_usb_ids "hosted";
        port = mk_opt_port "server";

        timeout = lib.mkOption {
          type = lib.types.str;
          description = ''
            systemd time value that defines how long the usbip server
            should live.
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
      (cfg_client.instances != { })
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
          # instantiated_services = builtins.listToAttrs (builtins.map instantiateService cfg_host.host_names);
          # in
          lib.mapAttrs'
            (name: instance_value:
              {
                name = "usbip_mounter_${name}";
                value = {
                  description = "Template for Remote USB mounter via usbip";
                  wants = [ "network-online.target" ];
                  after = [ "network-online.target" ];

                  serviceConfig = {
                    Type = "oneshot";
                    ExecStart = if nu_mode then ''
                      ${cfg_host.package}/bin/usbip-wrapper-executor mount-remote \
                        --tcp-port="${builtins.toString instance_value.port}" \
                        "${instance_value.host}" \
                        ${builtins.concatStringsSep " " instance_value.usb_ids}
                    '' else ''
                      ${cfg_host.package}/bin/usbip_wrapper mount-remote \
                        --host="${instance_value.host}" \
                        --tcp-port="${builtins.toString instance_value.port}" \
                        -- ${builtins.concatStringsSep " " instance_value.usb_ids}
                    '';
                  };
                  path = [ "${config.boot.kernelPackages.usbip}" ];
                };
              })
            cfg_client.instances;
      })
    (lib.mkIf cfg_host.enable {

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
        path = [
          "${config.systemd.package}/lib"
          "${pkgs.ripgrep}/bin"
          "${pkgs.socat}/bin"
        ];
      };

      systemd.services.usbip_server = {
        description = "USBIP server with auto-shutdown";
        requires = [ "usbip_host_timeout.timer" ];
        after = [ "usbip_host_timeout.timer" ];
        # requires
        # Stop the server when the timeout service is started,
        # which is controlled by a systemd timer unit!
        conflicts = [ "usbip_host_timeout.service" ];
        serviceConfig = {
          Type = "simple";
          ExecStart = if nu_mode then ''
            ${cfg_host.package}/bin/usbip-wrapper-executor \
              start-usb-hoster \
              --tcp-port=${port_internal}
          '' else ''
            ${cfg_host.package}/bin/usbip_wrapper \
              start-usb-hoster \
              --tcp-port=${port_internal}
          '';
          # TODO: Disable pid file if not necessary
          Restart = "no";
          # Basic Hardening
          NoNewPrivileges = "yes";
          PrivateTmp = "yes";

          PrivateDevices = "no";
          # Limit access to only contain relevant USB devices!
          DeviceAllow = [ "char-usb/*" "char-usb_device/*" ];
        };
        path = [ "${config.boot.kernelPackages.usbip}" ];
      };
      # Why host-side timeout?
      # Because I want to make the key 'locally' available again without any
      # interaction and to not keep hosting it 'forever' to my server
      # Unhosting would also be an option but then the server would be running
      # without any reason
      # FUTURE: I could also consider adding a socket-based timeout for a shorter interval
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
          OnActiveSec = "${cfg_host.timeout}";
          RemainAfterElapse = false;
        };
      };

      systemd.services.usbip_hoster = {
        description = "Host usb device via usbip.";
        wants = [ "usbip_host_timeout.timer" ];
        bindsTo = [ "usbip_server.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = if nu_mode then ''
            ${cfg_host.package}/bin/usbip-wrapper-executor host \
              --tcp-port=${port_internal} \
              ${builtins.concatStringsSep " " cfg_host.usb_ids}
          '' else ''
            ${cfg_host.package}/bin/usbip_wrapper host \
              --tcp-port=${port_internal} \
              -- ${builtins.concatStringsSep " " cfg_host.usb_ids}
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
        listenStreams = [ "${builtins.toString cfg_host.port}" ];
        wantedBy = [ "sockets.target" ];
        socketConfig = {
          # Accept = true;
          # MaxConnections = 1;
        };
      };
    })
  ];
}

# should differ between client/server mode
# should also require kernel modules
flake: { config, lib, pkgs, ... }:
let
  cfg = config.services.usbip_wrapper;
  usbip_wrapper = flake.packages.x86_64-linux.usbip_wrapper;
in
{
  imports = [
  ];

  options = {
    services.usbip_wrapper = {
      enable = lib.mkEnableOption ''
        A usbip configuration wrapper
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

      port = lib.mkOption {
        type = lib.types.int;
        default = 5000;
        description = ''
          The port that the usbip server/client will communicate over.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # This seems to work! This is amazing!
    # I can simply add these as a dependency from within the flake
    # and continue to minimize the dependencies for the end-user flake file!
    # Nix will merge the lists during the resolving phase!
    boot.extraModulePackages = with config.boot.kernelPackages; [ usbip ];
    boot.kernelModules = [ "usbip_host" "vhci-hcd" ];

    systemd.services.usbip_server = {
      description = "Start usbip server.";
      # TODO: Re-enable after a few tests!

      # requires = [ "usbip_server_timeout.timer" ];
      # after = [ "usbip_server_timeout.timer" ];
      # requires
      # Stop the server when the timeout service is started,
      # which is controlled by a systemd timer unit!
      # conflicts = [ "usbip_server_timeout.service" ];
      environment = {
        USBIP_TCP_PORT = "5555";
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
      # Can this be done within the module?
      # guarantee that the correct usbip version is used and in sync with linux kernel!
      path = [ "${config.boot.kernelPackages.usbip}" ];
    };
  };
}

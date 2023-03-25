# should differ between client/server mode
# should also require kernel modules
flake: { config, lib, pkgs, ... }:
let
  cfg = config.services.usbip_wrapper;
in
{
  imports = [
  ];

  options = {
    services.usbip_wrapper = {
      enable = mkEnableOption ''
        A usbip configuration wrapper
      '';
    };
    # could set port here
    # and usb device, I guess
  };

  config = lib.mkIf cfg.enable {
    systemd.services.usbip_wrapper = {
      description = "usbip-wrapper";
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/usbip_wrapper";
      };
    };
  };
}

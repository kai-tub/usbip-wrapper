{ nixpkgs, pkgs, usbip_module, usbip_pkg, system }:
let
  lib = pkgs.lib;
  port = 5000;
  # This is a QEMU created USB device and is available
  # on all QEMU instances!
  fake_usb_id = "0627:0001";
  common_module = {
    imports = [
      # import usbip
      usbip_module
    ];

    networking.firewall.allowedTCPPorts = [ port ];
    virtualisation.graphics = false;
    environment.systemPackages = [
      usbip_pkg
    ];
  };
  base_instance = {
    enable = true;
    inherit port;
    usb_ids = [ fake_usb_id ];
  };
in
{
  # requires lib from nixpkgs for nixosSystem!
  vm = lib.makeOverridable nixpkgs.lib.nixosSystem {
    inherit system;
    modules =
      [
        # not really used in my minimal vm anymore
        usbip_module
        ({ pkgs, config, ... }: {
          system.stateVersion = "22.11";
          # This should be configurable to test different kernel version interacting with each other
          # boot.kernelPackages = pkgs.linuxPackages_latest;
          boot.kernelPackages = pkgs.linuxPackages;
          # Test that the flake doesn't break the user-defined configuration
          boot.kernelModules = [ "zfs" ];
          boot.extraModulePackages = with config.boot.kernelPackages; [ zfs ];
          environment.sessionVariables = rec {
            USBIP_TCP_PORT = "${builtins.toString port}";
            PATH = [ "${config.boot.kernelPackages.usbip}/bin" ];
          };
          environment.systemPackages = [
            pkgs.usbutils
            usbip_pkg
            pkgs.socat
            pkgs.ripgrep
          ];
        })
      ];
  };
}

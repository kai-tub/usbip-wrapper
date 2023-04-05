{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.11";
    # flake-parts.url = "github:hercules-ci/flake-parts"
  };
  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      system = "x86_64-linux";

      sharedModule = {
        virtualisation.graphics = false;
      };
      test_config = { };
    in
    rec {
      nixosModules.default = import ./usbip_wrapper.nix self;
      nixosModules.usbip_wrapper = import ./usbip_wrapper.nix self;

      # TODO: Understand how to run nixosTest!
      # Define the NixOS test using the `nixosTest` function
      # https://nix.dev/tutorials/integration-testing-using-virtual-machines
      # https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/login.nix
      packages.x86_64-linux = {
        usbip_wrapper = pkgs.rustPlatform.buildRustPackage {
          pname = "usbip-wrapper";
          version = "v0.1.0";

          src = self;

          # cargoSha256 = pkgs.lib.fakeSha256;
          cargoSha256 = "sha256-35wXNIUg01RX4qNRSYF6PXooRzqRpAkRTGuXEJd6MCs=";

          meta = with pkgs.lib; {
            description = "A simple usbip wrapper";
          };
        };
        default = packages."${system}".usbip_wrapper;
      };

      # chatgpt says:
      # nixosModules.usbip_wrapper = { ... }: { systemd.packages = [] }

      devShell.x86_64-linux =
        pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            rustc
            cargo
            rustfmt
            clippy
            rust-analyzer
            linuxKernel.packages.linux_latest_libre.usbip
          ];
          USBIP_TCP_PORT = 5000;
        };

      # check via flake --checks
      # checks.x86_64-linux.test = pkgs.nixosTest (test_config);


      nixosConfigurations =
        let
          lib = nixpkgs.lib;
        in
        {
          t = pkgs.nixosTest ({
            name = "test";
            # breaks with system! <- Maybe because I am already calling it from a system?
            # inherit system;
            nodes = {
              hoster = { config, pkgs, ... }: {
                imports = [
                  # import usbip
                  nixosModules.default
                ];

                networking.firewall.allowedTCPPorts = [ 5000 ];
                # networking.firewall.allowedUDPPorts = [ 5000 ];
                virtualisation.graphics = false;
                boot.kernelPackages = pkgs.linuxPackages_latest;
                services.usbip_wrapper = {
                  enable = true;
                  # TODO: Make these variables!
                  port = 5000;
                  usb_ids = [ "0627:0001" ];
                  host_timeout = "2";
                };
                # Make it easier to test one-self
                environment.systemPackages = [
                  pkgs.usbutils
                  packages.x86_64-linux.default
                ];
                environment.sessionVariables = rec {
                  USBIP_TCP_PORT = "5000";
                  PATH = [ "${pkgs.linuxPackages_latest.usbip}/bin" ];
                };
                # This should be configurable to test different kernel version interacting with each other
                # boot.kernelPackages = pkgs.linuxPackages_latest;
                # boot.kernelPackages = pkgs.linuxPackages;
              };
            };

            skipLint = true;

            testScript = ''
              from time import sleep
        
              start_all()
              hoster.wait_for_unit("multi-user.target")

              # Definitely also do the same test multiple times to ensure that the timer can be re-used!
              # test that the timer can be re-used multiple times!
              for _ in range(2):
                with subtest("list local"):
                  status, stdout = hoster.execute("PATH=$PATH: usbip_wrapper list-mountable --host=localhost", timeout=10)
                  assert "0627:0001" in stdout
                with subtest("test keep alive status"):
                  _, usbip_status = hoster.systemctl("is-active usbip_server")
                  assert usbip_status.strip() == "active", "Directly after accessing port the server should be active for a pre-defined time."
                # now wait until the host-time passes
                sleep(3)
                with subtest("test auto-shutdown"):
                  _, usbip_status = hoster.systemctl("is-active usbip_server")
                  assert usbip_status.strip() == "inactive", "Should automatically stop the server service after timeout time has passed"

              # TODO: Also add tests for... other parts (?) of the systemd service files?
            '';
          });
          vm = lib.makeOverridable lib.nixosSystem {
            inherit system;
            modules =
              let
                pkgs = import nixpkgs { inherit system; };
              in
              [
                # import the usbip_wrapper modules
                nixosModules.default
                ({ pkgs, config, ... }: {
                  system.stateVersion = "22.11";
                  services.usbip_wrapper = {
                    enable = true;
                    port = 5000;
                    usb_ids = [ "0627:0001" ];
                  };
                  # This should be configurable to test different kernel version interacting with each other
                  # boot.kernelPackages = pkgs.linuxPackages_latest;
                  boot.kernelPackages = pkgs.linuxPackages;
                  # Test that the flake doesn't break the user-defined configuration
                  boot.kernelModules = [ "zfs" ];
                  boot.extraModulePackages = with config.boot.kernelPackages; [ zfs ];
                  environment.sessionVariables = rec {
                    USBIP_TCP_PORT = "${builtins.toString config.services.usbip_wrapper.port}";
                    PATH = [ "${config.boot.kernelPackages.usbip}/bin" ];
                  };
                  environment.systemPackages = [
                    pkgs.usbutils
                    packages.x86_64-linux.default
                    pkgs.socat
                    pkgs.ripgrep
                  ];
                })
              ];
          };
        };
    };
}

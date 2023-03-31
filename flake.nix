{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.11";
    # flake-parts.url = "github:hercules-ci/flake-parts"
  };
  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      system = "x86_64-linux";
    in
    rec {
      nixosModules.default = import ./usbip_wrapper.nix self;
      nixosModules.usbip_wrapper = import ./usbip_wrapper.nix self;

      # Define the NixOS test configuration
      testConfig = {
        # The VM configuration
        config = {
          inherit system;
          # Include the package in the system configuration
          imports = [ nixosModules.default ];
          environment.systemPackages = [ packages."${system}".default ];
        };
      };

      # TODO: Understand how to run nixosTest!
      # Define the NixOS test using the `nixosTest` function
      # https://nix.dev/tutorials/integration-testing-using-virtual-machines
      # https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/login.nix
      testResult = nixpkgs.nixosTest {
        name = "my-test";
        system = testConfig.system;
        config = testConfig.config;
        # extraDiskImages = [ nixpkgs.nixosImage { system = testConfig.system; } ];
        # env = with testConfig; {
        #   # Export the test configuration to the VM
        #   testConfig = builtins.toJSON testConfig;
        # };
      };

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
        default = packages.x86_64-linux.usbip_wrapper;
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
      nixosConfigurations =
        let
          lib = nixpkgs.lib;
        in
        {
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
                  };
                  # This should be configurable to test different kernel version interacting with each other
                  # boot.kernelPackages = pkgs.linuxPackages_latest;
                  boot.kernelPackages = pkgs.linuxPackages;
                  # Test that the flake doesn't break the user-defined configuration
                  boot.kernelModules = [ "zfs" ];
                  boot.extraModulePackages = with config.boot.kernelPackages; [ zfs ];
                  environment.systemPackages = [
                    pkgs.usbutils
                  ];
                })
              ];
          };
        };
    };
}

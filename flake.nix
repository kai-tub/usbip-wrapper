{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.11";
    nix-filter.url = "github:numtide/nix-filter";
  };
  outputs = { self, nixpkgs, nix-filter }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      # avoid nix-filter as name as it is otherwise an infinite recursion
      filter = import nix-filter;
      system = "x86_64-linux";

      sharedModule = {
        virtualisation.graphics = false;
      };
      test_config = { };
    in
    rec {
      nixosModules.default = import ./usbip_wrapper.nix self;
      nixosModules.usbip_wrapper = import ./usbip_wrapper.nix self;

      packages.x86_64-linux =
        let
          # eval = pkgs.lib.evalModules
          #   {
          #     # no idea how to fix the error
          #     modules = [ nixosModules.default ];
          #     check = false;
          #   };
          # eval = nixosModules.default;
          # } // { _module.check = false; };
          # eval._module.check = false;
          # This is currently broken!
          # doc = pkgs.nixosOptionsDoc {
          #   options = eval.options;
          # };
          # ASK:
          # TODO: Figure out how to rewrite this as a test that I can import!
          # I have no idea how to do it correctly. I am importing it as a function
          # and then evaluating it and filtering it based on the name
          # as I need to inject the package itself into the test
          tests_f = import ./tests.nix;
        in
        rec {
          usbip_wrapper = pkgs.rustPlatform.buildRustPackage {
            pname = "usbip-wrapper";
            version = "v0.1.0";

            src = filter {
              root = ./.;
              include = [
                "src"
                ./Cargo.lock
                ./Cargo.toml
              ];
            };

            # cargoSha256 = pkgs.lib.fakeSha256;
            cargoSha256 = "sha256-35wXNIUg01RX4qNRSYF6PXooRzqRpAkRTGuXEJd6MCs=";

            meta = with pkgs.lib; {
              description = "A simple usbip wrapper";
            };
          };
          default = packages."${system}".usbip_wrapper;

          # d = pkgs.runCommand "options.md" { } ''
          #   cat ${doc.optionsCommonMark} >> $out
          # '';

          # FUTURE: Ask somebody who is smart how to do this "correctly"
          # Maybe this should be done as an 'actual' module as well?
          # I cannot figure out how to do this via import/imports
          clientUnitTest = pkgs.lib.getAttr "clientUnitTest" (tests_f {
            inherit pkgs;
            # inherit config;
            usbip_module = nixosModules.default;
            usbip_pkg = usbip_wrapper;
          });
          hostSelfTest = pkgs.lib.getAttr "hostSelfTest" (tests_f {
            inherit pkgs;
            # inherit config;
            usbip_module = nixosModules.default;
            usbip_pkg = usbip_wrapper;
          });
          integrationTest = pkgs.lib.getAttr "integrationTest" (tests_f {
            inherit pkgs;
            # inherit config;
            usbip_module = nixosModules.default;
            usbip_pkg = usbip_wrapper;
          });
        };

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

      # FUTURE: Add auto-test functionality via flake checks
      # check via flake --checks
      # checks.x86_64-linux.test = pkgs.nixosTest (test_config);

      nixosConfigurations =
        let
          lib = nixpkgs.lib;
          port = 5000;
          # This is a QEMU created USB device and is available
          # on all QEMU instances!
          fake_usb_id = "0627:0001";
          common_module = {
            imports = [
              # import usbip
              nixosModules.default
            ];

            networking.firewall.allowedTCPPorts = [ port ];
            virtualisation.graphics = false;
            environment.systemPackages = [
              # pkgs.usbutils 
              packages.x86_64-linux.default
            ];
          };
          base_instance = {
            enable = true;
            inherit port;
            usb_ids = [ fake_usb_id ];
          };
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

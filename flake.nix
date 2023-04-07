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
          # https://bmcgee.ie/posts/2023/03/til-how-to-generate-nixos-module-docs/
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

      devShells.x86_64-linux =
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

      # flake check only ensure that the deriviations can be build and doesn't actually run them

      # TODO:
      # update readme

      nixosConfigurations =
        let
          system = "x86_64-linux";
          vm_conf = import ./vm.nix {
            inherit nixpkgs;
            inherit pkgs;
            inherit system;
            usbip_module = nixosModules.default;
            usbip_pkg = packages."${system}".usbip_wrapper;
          };
        in
        {
          # only enable if required, as otherwise nix flake check fails to load this!
          # vm = vm_conf.vm;
        };

    };
}

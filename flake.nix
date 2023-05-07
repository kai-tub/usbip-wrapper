{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.11";
    nixpkgs-unstable.url = "github:nixos/nixpkgs/nixos-unstable";
    nix-filter.url = "github:numtide/nix-filter";
  };
  outputs = { self, nixpkgs, nix-filter, nixpkgs-unstable, }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      pkgs-unstable = nixpkgs-unstable.legacyPackages.x86_64-linux;
      # avoid nix-filter as name as it is otherwise an infinite recursion
      filter = nix-filter.lib;
      system = "x86_64-linux";
    in
    rec {
      nixosModules.usbip_wrapper = import ./nix/usbip_wrapper.nix self false;
      nixosModules.usbip_wrapper_nu = import ./nix/usbip_wrapper.nix self true;
      nixosModules.default = nixosModules.usbip_wrapper_nu;

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
          # FUTURE: Figure out how to rewrite this as a test that I can import!
          # I have no idea how to do it correctly. I am importing it as a function
          # and then evaluating it and filtering it based on the name
          # as I need to inject the package itself into the test
          tests_f = import ./nix/tests.nix self;
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

            meta = {
              description = "A simple usbip wrapper";
            };
          };

          # As of now, there is no easy way to call `nushell` as an _application_
          # so it is not designed to dynamically forward generic parameters/flags
          # to the underlying script. So there is currently no way to implement
          # the bash variant of $@ or $*
          usbip_wrapper_nu =
            let
              usbip_wrapper_lib = pkgs.writeTextFile {
                name = "usbip_wrapper_lib";
                text = builtins.readFile ./src/usbip_wrapper.nu;
              };
              # old variants:
              # pkgs.symlinkJoin {
              #   name = "usbip-wrapper-entrypoint";
              #   paths = [
              #     usbip_wrapper_executor
              #     pkgs-unstable.nushell
              #   ];
              # };
              #  pkgs.runCommandLocal "usbip-wrapper.nu"  {
              #   script = ./src/usbip_wrapper.nu;
              #   nativeBuildInputs = [ pkgs.makeWrapper ];
              # } ''
              #   makeWrapper $script $out/bin/usbip_wrapper.nu \
              #     --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs-unstable.nushell ] }
              # '';
            in
              pkgs.writeShellScriptBin "usbip-wrapper-executor" ''
                ${pkgs-unstable.nushell}/bin/nu -c "use ${usbip_wrapper_lib} *; usbip-wrapper ''${*}"
                # the following works with a direct call with ls but not ^ls !
                # ${pkgs-unstable.nushell}/bin/nu -c "^ls"
              '';
          
          default = packages."${system}".usbip_wrapper_nu;

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
            usbip_pkg = default;
          });
          hostSelfTest = pkgs.lib.getAttr "hostSelfTest" (tests_f {
            inherit pkgs;
            # inherit config;
            usbip_module = nixosModules.default;
            usbip_pkg = default;
          });
          integrationTest = pkgs.lib.getAttr "integrationTest" (tests_f {
            inherit pkgs;
            # inherit config;
            usbip_module = nixosModules.default;
            usbip_pkg = default;
            # usbip_module = nixosModules.usbip_wrapper;
            # usbip_pkg = packages."${system}".usbip_wrapper;
          });
        };

      # only testing nu starting from now!
      checks."${system}" = {
        clientUnitTest = packages.x86_64-linux.clientUnitTest;
        hostSelfTest = packages.x86_64-linux.hostSelfTest;
        integrationTest = packages.x86_64-linux.integrationTest;
      };

      devShells.x86_64-linux.default =
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

      # Only enable if necessary to avoid `nix flake check` errors
      # nixosConfigurations =
      #   let
      #     system = "x86_64-linux";
      #     vm_conf = import ./nix/vm.nix {
      #       inherit nixpkgs;
      #       inherit pkgs;
      #       inherit system;
      #       usbip_module = nixosModules.default;
      #       usbip_pkg = packages."${system}".usbip_wrapper_nu;
      #     };
      #   in
      #   {
      #     # only enable if required, as otherwise nix flake check fails to load this!
      #     vm = vm_conf.vm;
      #   };
    };
}

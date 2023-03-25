{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.11";
    # flake-parts.url = "github:hercules-ci/flake-parts"
  };
  outputs = { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    rec {
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
      nixosModules.default = import ./usbip_wrapper.nix self;
      nixosModules.usbip_wrapper = import ./usbip_wrapper.nix self;

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
    };
}

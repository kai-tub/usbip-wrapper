{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-22.11";
    nix-filter.url = "github:numtide/nix-filter";
    # flake-parts.url = "github:hercules-ci/flake-parts"
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

      # Define the NixOS test using the `nixosTest` function
      # https://nix.dev/tutorials/integration-testing-using-virtual-machines
      # https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/login.nix
      packages.x86_64-linux = {
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

      # check via flake --checks
      # checks.x86_64-linux.test = pkgs.nixosTest (test_config);


      nixosConfigurations =
        let
          lib = nixpkgs.lib;
        in
        {
          # This tests the entire pipeline. The wrapper, the systemd units (socket activation, timeout), mounting/unmounting, etc.
          # TODO: As this is a deriviation, it should be moved to packages and not nixosConfiguration!
          integrationTest =
            let
              port = 5000;
              # This is a QEMU created USB device and is available
              # on all QEMU instances!
              fake_usb_id = "0627:0001";
              host_timeout = 2;
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
                environment.sessionVariables = rec {
                  USBIP_TCP_PORT = "${builtins.toString port}";
                  PATH = [ "${pkgs.linuxPackages_latest.usbip}/bin" ];
                  RUST_LOG = "debug";
                };
              };
            in
            pkgs.nixosTest
              ({
                name = "full-integration-test";
                nodes =
                  let
                    hoster_base = {
                      imports = [ common_module ];
                      services.usbip_wrapper = {
                        enable = true;
                        port = port;
                        usb_ids = [ "${fake_usb_id}" ];
                        host_timeout = "${builtins.toString host_timeout}";
                      };
                    };
                    client_base = {
                      imports = [ common_module ];
                      services.usbip_wrapper = {
                        enable = true;
                        mode = "client";
                        port = port;
                        usb_ids = [ "${fake_usb_id}" ];
                        host_timeout = "${builtins.toString host_timeout}";
                      };
                    };
                  in
                  {
                    hoster_latest = { config, pkgs, ... }: {
                      imports = [ hoster_base ];
                      boot.kernelPackages = pkgs.linuxPackages_latest;
                    };
                    hoster_stable = { config, pkgs, ... }: {
                      imports = [ hoster_base ];
                      boot.kernelPackages = pkgs.linuxPackages;
                    };
                    client_latest = { config, pkgs, ... }: {
                      imports = [ client_base ];
                      boot.kernelPackages = pkgs.linuxPackages_latest;
                    };
                    client_stable = { config, pkgs, ... }: {
                      imports = [ client_base ];
                      boot.kernelPackages = pkgs.linuxPackages;
                    };
                  };

                skipLint = true;

                testScript = ''
                  from time import sleep
        
                  start_all()

                  def hoster_self_test(hoster):
                    # test entire systemctl pipeline
                    with subtest("self test hoster"):
                      print(hoster.succeed("uname -a"))
                      # Run twice to ensure that timer can be re-used/restarted
                      for _ in range(2):
                        with subtest("list local"):
                          status, stdout = hoster.execute("usbip_wrapper list-mountable --host=localhost", timeout=10)
                          assert "${fake_usb_id}" in stdout
                        with subtest("test keep alive status"):
                          _, usbip_status = hoster.systemctl("is-active usbip_server")
                          assert usbip_status.strip() == "active", "Directly after accessing port the server should be active for a pre-defined time."
                        # now wait until the host-time passes
                        sleep(int("${builtins.toString host_timeout}") + 1)
                        with subtest("test auto-shutdown"):
                          _, usbip_status = hoster.systemctl("is-active usbip_server")
                          assert usbip_status.strip() == "inactive", "Should automatically stop the server service after timeout time has passed"

                  hoster_latest.wait_for_unit("multi-user.target")
                  hoster_self_test(hoster_latest)

                  hoster_stable.wait_for_unit("multi-user.target")
                  hoster_self_test(hoster_stable)

                  def client_test(client, host_name):
                    with subtest("test client access"):
                      print(client.succeed("uname -a"))
                      client.wait_for_unit("multi-user.target")
                      with subtest(f"client can discover {host_name}"):
                        status, stdout = client.execute(f"usbip_wrapper list-mountable --host={host_name}", timeout=10)
                        assert "${fake_usb_id}" in stdout
                        client.succeed(f"usbip_wrapper mount-remote --host={host_name}", timeout=3)
                        # it takes a bit to propagate the mounting to the local USPIP interface as some time is spent mounting it
                        sleep(.5)
                        client.succeed(f"""usbip_wrapper unmount-remote""", timeout=3)
                        sleep(.5)

                  client_test(client_latest, "hoster_latest")
                  client_test(client_latest, "hoster_stable")
                  client_test(client_stable, "hoster_latest")
                  client_test(client_stable, "hoster_stable")

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

{ pkgs, usbip_module, usbip_pkg, ... }:
# Define the NixOS test using the `nixosTest` function
# https://nix.dev/tutorials/integration-testing-using-virtual-machines
# https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/login.nix
let
  lib = pkgs.lib;
  port = 5000;
  # This is a QEMU created USB device and is available
  # on all QEMU instances!
  fake_usb_id = "0627:0001";
  common_module = {
    imports = [
      # import usbip
      # nixosModules.default
      usbip_module
    ];

    networking.firewall.allowedTCPPorts = [ port ];
    virtualisation.graphics = false;
    environment.systemPackages = [
      # pkgs.usbutils 
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
  # Quickly verify that the systemd submodule interface works as expected
  # I do not do anything with the values!
  # Just boot and verify that the systemctl unit exists!
  clientUnitTest =
    let
      host = "remote_host";
    in
    pkgs.nixosTest ({
      name = "client-unit-test";
      nodes = {
        client = { config, pkgs, ... }: {
          imports = [ common_module ];
          services.usbip_wrapper_client.instances.test_instance = base_instance // {
            inherit host;
          };
        };
      };
      skipLint = false;
      # test that client systemctl file is correctly created
      testScript = ''
        start_all()
        _, out = client.systemctl("is-enabled usbip_mounter_${host}")
        print(out)
              
        # linked means that is exists but isn't depended by anyone
        assert "linked" in out, "Cannot find unit file!"
      '';
    });

  hostSelfTest =
    let
      host_timeout = "2";
    in
    pkgs.nixosTest
      ({
        name = "hoster-self-test";
        nodes =
          {
            hoster_stable = { config, pkgs, ... }: rec {
              imports = [ common_module ];
              services.usbip_wrapper_host = base_instance // {
                timeout = host_timeout;
              };
              boot.kernelPackages = pkgs.linuxPackages;
              environment.sessionVariables = {
                PATH = [ "${boot.kernelPackages.usbip}/bin" ];
              };
            };
          };

        skipLint = false;

        testScript = ''
          from time import sleep

          port = ${builtins.toString port}

          start_all()

          hoster_stable.wait_for_unit("multi-user.target")
          # Run twice to ensure that timer can be re-used/restarted
          for _ in range(2):
            status, stdout = hoster_stable.execute(f"usbip_wrapper list-mountable --host=localhost --tcp-port={port}", timeout=10)
            assert "${fake_usb_id}" in stdout
            with subtest("test keep alive status"):
              _, usbip_status = hoster_stable.systemctl("is-active usbip_server")
              assert usbip_status.strip() == "active", "Directly after accessing port the server should be active for a pre-defined time."
            # now wait until the host-time passes
            sleep(int("${host_timeout}") + 1)
            with subtest("test auto-shutdown"):
              _, usbip_status = hoster_stable.systemctl("is-active usbip_server")
              assert usbip_status.strip() == "inactive", "Should automatically stop the server service after timeout time has passed"
        '';
      });

  # This tests the entire pipeline. The wrapper, the systemd units (socket activation, timeout), mounting/unmounting, etc.
  integrationTest =
    pkgs.nixosTest
      ({
        name = "full-integration-test";
        nodes =
          let
            hoster_base = {
              imports = [ common_module ];
              services.usbip_wrapper_host = base_instance // {
                # Must be large enough to ensure that entire integration pipeline
                # works from beginning to end, as the early shutdown might happen
                # right after mounting one and before unmounting.
                timeout = "30";
              };
            };
            client_base = {
              imports = [ common_module ];
            };
          in
          {
            client_latest = { config, pkgs, ... }: rec {
              imports = [ client_base ];
              boot.kernelPackages = pkgs.linuxPackages_latest;
              # only clients manually execute usbip code
              environment.sessionVariables = {
                PATH = [ "${boot.kernelPackages.usbip}/bin" ];
              };
              # create systemd unit wi
              services.usbip_wrapper_client.instances.hoster_stable = base_instance // { host = "hoster_stable"; };
              services.usbip_wrapper_client.instances.hoster_latest = base_instance // { host = "hoster_latest"; };
            };
            client_stable = { config, pkgs, ... }: rec {
              imports = [ client_base ];
              boot.kernelPackages = pkgs.linuxPackages;
              # only clients manually execute usbip code
              environment.sessionVariables = {
                PATH = [ "${boot.kernelPackages.usbip}/bin" ];
              };
              services.usbip_wrapper_client.instances.hoster_stable = base_instance // { host = "hoster_stable"; };
              services.usbip_wrapper_client.instances.hoster_latest = base_instance // { host = "hoster_latest"; };
            };
            hoster_stable = { config, pkgs, ... }: rec {
              imports = [ hoster_base ];
              boot.kernelPackages = pkgs.linuxPackages;
            };
            hoster_latest = { config, pkgs, ... }: rec {
              imports = [ hoster_base ];
              boot.kernelPackages = pkgs.linuxPackages_latest;
            };
          };

        skipLint = false;

        testScript = ''
          from time import sleep

          port = ${builtins.toString port}
         
          start_all()

          hoster_latest.wait_for_unit("multi-user.target")
          hoster_stable.wait_for_unit("multi-user.target")

          def client_test(client, host_name):
            with subtest("test client access"):
              print(client.succeed("uname -a"))
              client.wait_for_unit("multi-user.target")
              with subtest(f"client can discover {host_name}"):
                status, stdout = client.execute(f"usbip_wrapper list-mountable --host={host_name} --tcp-port=${builtins.toString port}", timeout=10)
                assert "${fake_usb_id}" in stdout
                client.succeed(f"usbip_wrapper mount-remote --host={host_name} --tcp-port={port}", timeout=3)
                # it takes a bit to propagate the mounting to the local USPIP interface as some time is spent mounting it
                sleep(.5)
                client.succeed("usbip_wrapper unmount-remote", timeout=3)
                sleep(.5)
              with subtest("test client systemctl instances"):
                a, b = client.systemctl(f"start usbip_mounter_{host_name}")
                print(a)
                print(b)
                sleep(.5)
                client.succeed("usbip_wrapper unmount-remote", timeout=3)
                sleep(.5)

          client_test(client_latest, "hoster_latest")
          client_test(client_latest, "hoster_stable")
          client_test(client_stable, "hoster_latest")
          client_test(client_stable, "hoster_stable")
        '';
      });
}

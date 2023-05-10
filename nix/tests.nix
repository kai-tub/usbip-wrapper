# /bin/usbip-wrapper is not available!
flake: { pkgs, usbip_module, usbip_pkg, ... }:
# Define the NixOS test using the `nixosTest` function
# https://nix.dev/tutorials/integration-testing-using-virtual-machines
# https://github.com/NixOS/nixpkgs/blob/master/nixos/tests/login.nix
# Required to use custom Systemd Units for testing
# as NixOS VM's have trouble with execute that takes over stdout
# and does some job-control, see nushell notes markdown file!
let
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
    # networking.firewall.enable = false;
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
  nu_mode = flake.packages.x86_64-linux.usbip_wrapper_nu == usbip_pkg;
in
{
  # Quickly verify that the systemd submodule interface works as expected
  # I do not do anything with the values!
  # Just boot and verify that the systemctl unit exists!
  clientUnitTest =
    let
      instance = "test_instance";
      host = "remote_host";
    in
    pkgs.nixosTest ({
      name = "client-unit-test";
      nodes = {
        client = { config, pkgs, ... }: {
          imports = [ common_module ];
          services.usbip_wrapper_client.instances = {
            "${instance}" = base_instance // {
              inherit host;
            };
          };
        };
      };
      skipLint = false;
      # test that client systemctl file is correctly created
      testScript = ''
        start_all()
        _, out = client.systemctl("is-enabled usbip_mounter_${instance}")
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
              systemd.services."usbip_wrapper_list_mountable" = {
                serviceConfig = {
                  Type = "oneshot";
                  # Adding to PATH doesn't seem to work
                  # ${config.services.usbip_wrapper_host.package}/bin/usbip-wrapper-executor list mountable --tcp-port=${builtins.toString port} localhost
                  ExecStart = if nu_mode then ''
                    ${config.services.usbip_wrapper_host.package}/bin/usbip-wrapper-executor list mountable --tcp-port=${builtins.toString port} localhost | to text
                  '' else ''
                    ${config.services.usbip_wrapper_host.package}/bin/usbip_wrapper list-mountable --host=localhost --tcp-port=${builtins.toString port}
                  '';
                };
                path = [ 
                  "${config.boot.kernelPackages.usbip}"
                  # "${config.services.usbip_wrapper_host.package}"
                ];
              };
            };
          };

        skipLint = false;

        testScript =
         ''
          from time import sleep

          start_all()

          hoster_stable.wait_for_unit("multi-user.target")
          # Run twice to ensure that timer can be re-used/restarted
          for _ in range(2):
            hoster_stable.systemctl("start usbip_wrapper_list_mountable")
            out = hoster_stable.execute("journalctl -u usbip_wrapper_list_mountable --since=-2sec")[1]
            assert "${fake_usb_id}" in out
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
            usbip_wrapper_list_mountable = config: {
              serviceConfig = {
                Type = "oneshot";
                ExecStart = if nu_mode then ''
                  ${config.services.usbip_wrapper_host.package}/bin/usbip-wrapper-executor list mountable --tcp-port=${builtins.toString port} %I | to text
                '' else ''
                  ${config.services.usbip_wrapper_host.package}/bin/usbip_wrapper list-mountable --host %I --tcp-port=${builtins.toString port}
                '';
              };
              path = [ 
                "${config.boot.kernelPackages.usbip}"
              ];
            };
            usbip_wrapper_mount = config: {
              serviceConfig = {
                Type = "oneshot";
                ExecStart = if nu_mode then ''
                  ${config.services.usbip_wrapper_host.package}/bin/usbip-wrapper-executor mount-remote --tcp-port=${builtins.toString port} %I
                '' else ''
                  ${config.services.usbip_wrapper_host.package}/bin/usbip_wrapper mount-remote --host %I --tcp-port=${builtins.toString port}
                '';
              };
              path = [ 
                "${config.boot.kernelPackages.usbip}"
              ];
            };
            usbip_wrapper_unmount_remote = config: {
              serviceConfig = {
                Type = "oneshot";
                ExecStart = if nu_mode then ''
                  ${config.services.usbip_wrapper_host.package}/bin/usbip-wrapper-executor unmount-remote | to text
                '' else ''
                  ${config.services.usbip_wrapper_host.package}/bin/usbip_wrapper unmount-remote
                '';
                ExecStartPost = ''${pkgs.coreutils}/bin/sleep 1s'';
              };
              path = [ 
                "${config.boot.kernelPackages.usbip}"
              ];
            };
          in
          {
            client_latest = { config, pkgs, ... }: {
              imports = [ client_base ];
              boot.kernelPackages = pkgs.linuxPackages_latest;
              services.usbip_wrapper_client.instances.hoster_stable = base_instance // {
                host = "hoster_stable";
              };
              services.usbip_wrapper_client.instances.hoster_latest = base_instance // {
                host = "hoster_latest";
              };
              systemd.services."usbip_wrapper_list_mountable@" = usbip_wrapper_list_mountable config; 
              systemd.services."usbip_wrapper_mount@" = usbip_wrapper_mount config; 
              systemd.services.usbip_wrapper_unmount_remote = usbip_wrapper_unmount_remote config;
            };
            client_stable = { config, pkgs, ... }: {
              imports = [ client_base ];
              boot.kernelPackages = pkgs.linuxPackages;
              services.usbip_wrapper_client.instances.hoster_stable = base_instance // { host = "hoster_stable"; };
              services.usbip_wrapper_client.instances.hoster_latest = base_instance // { host = "hoster_latest"; };

              systemd.services."usbip_wrapper_list_mountable@" = usbip_wrapper_list_mountable config; 
              systemd.services."usbip_wrapper_mount@" = usbip_wrapper_mount config; 
              systemd.services.usbip_wrapper_unmount_remote = usbip_wrapper_unmount_remote config;
            };
            hoster_stable = { config, pkgs, ... }: {
              imports = [ hoster_base ];
              boot.kernelPackages = pkgs.linuxPackages;
            };
            hoster_latest = { config, pkgs, ... }: {
              imports = [ hoster_base ];
              boot.kernelPackages = pkgs.linuxPackages_latest;
            };
          };

        skipLint = false;

        testScript = ''
          start_all()

          hoster_latest.wait_for_unit("multi-user.target")
          hoster_stable.wait_for_unit("multi-user.target")

          def systemctl_start_and_exit_check(dev, unit_name, error_msg):
            """
            Start the given unit_name on the host called dev.
            Check if the unit exists and if the command succeded.
            Will only process the last event
            """
            dev.systemctl(f"start {unit_name}")
            load_state = dev.systemctl(f"show -p LoadState --value {unit_name}")[1].splitlines()[-1]
            assert "loaded" == load_state, f"Unit error: {load_state} Maybe typo?\n"
            exit_code = dev.systemctl(f"show -p Result --value {unit_name}")[1].splitlines()[-1]
            assert "success" == exit_code, f"{error_msg}\nexit-code: {exit_code}"

          def client_test(client, host_name):
            with subtest("test client access"):
              print(client.succeed("uname -a"))
              client.wait_for_unit("multi-user.target")
              with subtest(f"client can discover {host_name}"):
                client.systemctl(f"start usbip_wrapper_list_mountable@{host_name}")
                out = client.execute(f"journalctl -u usbip_wrapper_list_mountable@{host_name} --since=-0.2sec")[1]
                assert "${fake_usb_id}" in out, "USBID not found"
                systemctl_start_and_exit_check(client, f"usbip_wrapper_mount@{host_name}", "Failed to mount")
                # result = client.systemctl(f"show -p Result --value usbip_wrapper_mount@{host_name}")[1].strip()
                # assert result == "success", f"Non-zero exit code after trying to mount: {result}" 
                systemctl_start_and_exit_check(client, "usbip_wrapper_unmount_remote", "Failed to unmount")
                # client.systemctl("start usbip_wrapper_unmount_remote")
                # result = client.systemctl(f"show -p Result --value usbip_wrapper_unmount_remote@{host_name}")[1].strip()
                # assert result == "success", "Non-zero exit code after trying to unmount: {result}" 
              with subtest("test client systemctl instances"):
                systemctl_start_and_exit_check(client, f"start usbip_mounter_{host_name}", "Mouting via client systemctl failed")
                # _, out = client.systemctl(f"start usbip_mounter_{host_name}")
                systemctl_start_and_exit_check(client, "usbip_wrapper_unmount_remote", "Failed to unmount")
                # client.systemctl("start usbip_wrapper_unmount_remote")
                # result = client.systemctl(f"show -p Result --value usbip_wrapper_unmount_remote@{host_name}")[1].strip()
                # assert result == "success", "Non-zero exit code after trying to unmount: {result}" 

          client_test(client_latest, "hoster_latest")
          client_test(client_latest, "hoster_stable")
          client_test(client_stable, "hoster_latest")
          client_test(client_stable, "hoster_stable")
        '';
      });
}

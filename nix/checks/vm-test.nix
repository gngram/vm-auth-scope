{
  pkgs,
  nixosModules,
  authScope,
  authScopeGo,
}: let
  testModule = {lib, ...}: {
    imports = [nixosModules.default];

    # We need vsock loopback support
    boot.kernelModules = ["vsock_loopback"];
    environment.systemPackages = [pkgs.time authScopeGo];

    # CA Storage
    systemd.tmpfiles.rules = [
      "d /etc/auth-scope/ca 0700 root root"
      "d /var/lib/service-a 0700 root root"
      "d /var/lib/service-b 0700 root root"
      "d /var/lib/service-c 0700 root root"
    ];

    users.groups.service-a = {};
    users.groups.service-b = {};
    users.groups.service-c = {};
    users.users.service-a = {
      isSystemUser = true;
      group = "service-a";
    };
    users.users.service-b = {
      isSystemUser = true;
      group = "service-b";
    };
    users.users.service-c = {
      isSystemUser = true;
      group = "service-c";
    };

    # Use our NixOS modules to configure auth-scope
    services.auth-scope.serverPort = 900;
    services.auth-scope.agentPort = 901;
    services.auth-scope.server = {
      enable = true;
      package = authScope;
      generateKey = true;
      settings = {
        ca_cert_path = "/etc/auth-scope/ca/ca-cert.pem";
        ca_key_path = "/etc/auth-scope/ca/ca-key.pem";
        peer_port = 901;
        cert_validity_days = 365;
        vms."local-vm" = {
          vm_cid = 1;
          entities = {
            service-a.caps = [
              {
                target_vm = "local-vm";
                rpc_modules = ["auth"];
                rpc_methods = ["data.read_secure"];
                paths = [
                  {
                    path = "/api/v1/health";
                    access = ["read"];
                  }
                ];
              }
            ];
            service-b.caps = [];
            service-c.caps = [];
          };
        };
      };
    };

    systemd.services.auth-scope-agent.environment.VSOCK_HOST_CID = "1";

    services.auth-scope.agent = {
      enable = true;
      package = authScope;
      settings = {
        vm_name = "local-vm";
        server_port = 900;
        entities = [
          {
            name = "service-a";
            cert_path = "/var/lib/service-a/cert.pem";
            key_path = "/var/lib/service-a/key.pem";
            ca_path = "/var/lib/service-a/ca.pem";
            owner_uid = 0;
            owner_gid = 0;
            cert_mode = "0644";
            key_mode = "0600";
          }
          {
            name = "service-b";
            cert_path = "/var/lib/service-b/cert.pem";
            key_path = "/var/lib/service-b/key.pem";
            ca_path = "/var/lib/service-b/ca.pem";
            owner_uid = 0;
            owner_gid = 0;
            cert_mode = "0644";
            key_mode = "0600";
          }
          {
            name = "service-c";
            cert_path = "/var/lib/service-c/cert.pem";
            key_path = "/var/lib/service-c/key.pem";
            ca_path = "/var/lib/service-c/ca.pem";
            owner_uid = 0;
            owner_gid = 0;
            cert_mode = "0644";
            key_mode = "0600";
          }
        ];
      };
    };

    # Disable auto-start of the agent during the test so we can run it manually
    systemd.services.auth-scope-agent.wantedBy = lib.mkForce [];
  };
in
  pkgs.testers.runNixOSTest {
    name = "auth-scope-test";
    nodes.machine = testModule;

    testScript = ''
      machine.wait_for_unit("multi-user.target")

      # Wait for the server to be listening
      machine.wait_for_unit("auth-scope-server.service")
      machine.succeed("sleep 2") # Give it a moment to bind

      # Start the agent service via systemctl
      output = machine.succeed("systemctl start auth-scope-agent.service && journalctl -u auth-scope-agent.service")

      print(output)

      # Verify certificates were created
      with subtest("-- get certificates test --"):
          machine.succeed("ls -la /var/lib/service-a/cert.pem")
          machine.succeed("ls -la /var/lib/service-b/cert.pem")
          machine.succeed("ls -la /var/lib/service-c/cert.pem")
          print("\033[94m" + "\n-- get certificates test completed successfully --\n" + "\033[0m")

      # Evaluate service-a's capabilities using the evaluator test binary
      print("\n\n")
      with subtest("-- capability eval test(rust) --"):
          machine.succeed("auth-scope-eval-test /var/lib/service-a/cert.pem /etc/auth-scope/ca/ca-cert.pem")
          print("\033[94m" + "-- capability eval test(rust) completed successfully --" + "\033[0m")

      print("\n\n")
      with subtest("-- capability eval test(go) --"):
          machine.succeed("auth-scope-eval-test-go /var/lib/service-a/cert.pem /etc/auth-scope/ca/ca-cert.pem")
          print("\033[94m" + "-- capability eval test(go) completed successfully --" + "\033[0m")


      print("\n\n")
      with subtest("-- get status of auth scope server --"):
        status = machine.succeed("systemctl status auth-scope-server.service")
        print(status)
        print("\033[94m" + "-- status of auth scope server retrieved successfully --" + "\033[0m")

      print("\n\n")
    '';
  }

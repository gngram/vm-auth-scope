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
      secureCredentials = true;
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
            user_service = false;
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
            user_service = false;
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
            user_service = true;
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
      machine.succeed("systemctl start auth-scope-agent.service")

      # Wait for certificates to be created by the agent
      machine.wait_for_file("/var/lib/service-a/cert.pem")
      machine.wait_for_file("/var/lib/service-b/cert.pem")
      machine.wait_for_file("/var/lib/service-c/cert.pem")

      output = machine.succeed("journalctl -u auth-scope-agent.service")
      print(output)

      # Verify certificates are encrypted and not plain PEM
      with subtest("-- verify systemd credentials encryption --"):
          cert_a_content = machine.succeed("cat /var/lib/service-a/cert.pem")
          if "-----BEGIN CERTIFICATE-----" in cert_a_content:
              raise Exception("Expected cert.pem for service-a to be encrypted, but found plaintext PEM!")
          
          key_a_content = machine.succeed("cat /var/lib/service-a/key.pem")
          if "-----BEGIN PRIVATE KEY-----" in key_a_content:
              raise Exception("Expected key.pem for service-a to be encrypted, but found plaintext private key!")

          cert_c_content = machine.succeed("cat /var/lib/service-c/cert.pem")
          if "-----BEGIN CERTIFICATE-----" in cert_c_content:
              raise Exception("Expected cert.pem for service-c to be encrypted, but found plaintext PEM!")

          # Decrypt credentials using systemd-creds
          machine.succeed("systemd-creds decrypt --name=service-a /var/lib/service-a/cert.pem /tmp/decrypted_cert.pem")
          machine.succeed("systemd-creds decrypt --name=service-a /var/lib/service-a/key.pem /tmp/decrypted_key.pem")
          
          # Decrypt service-c (user service) using --user flag
          machine.succeed("systemd-creds --user decrypt --name=service-c /var/lib/service-c/cert.pem /tmp/decrypted_cert_c.pem")

          # Verify decrypted files are valid PEMs
          machine.succeed("grep -q -- '-----BEGIN CERTIFICATE-----' /tmp/decrypted_cert.pem")
          machine.succeed("grep -q -- '-----BEGIN PRIVATE KEY-----' /tmp/decrypted_key.pem")
          machine.succeed("grep -q -- '-----BEGIN CERTIFICATE-----' /tmp/decrypted_cert_c.pem")
          print("\033[94m" + "\n-- systemd credentials encryption verified successfully --\n" + "\033[0m")

      # Evaluate service-a's capabilities using the decrypted certificate
      print("\n\n")
      with subtest("-- capability eval test(rust) --"):
          machine.succeed("auth-scope-eval-test /tmp/decrypted_cert.pem /etc/auth-scope/ca/ca-cert.pem")
          print("\033[94m" + "-- capability eval test(rust) completed successfully --" + "\033[0m")

      print("\n\n")
      with subtest("-- capability eval test(go) --"):
          machine.succeed("auth-scope-eval-test-go /tmp/decrypted_cert.pem /etc/auth-scope/ca/ca-cert.pem")
          print("\033[94m" + "-- capability eval test(go) completed successfully --" + "\033[0m")


      print("\n\n")
      with subtest("-- get status of auth scope server --"):
        status = machine.succeed("systemctl status auth-scope-server.service")
        print(status)
        print("\033[94m" + "-- status of auth scope server retrieved successfully --" + "\033[0m")

      print("\n\n")
    '';
  }

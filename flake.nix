{
  description = "Auth-Scope NixOS VM Test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: {
    nixosModules.default = ./nixos;

    checks.x86_64-linux.vm-test =
      let
        pkgs = import nixpkgs { system = "x86_64-linux"; };

        authScope = pkgs.rustPlatform.buildRustPackage {
          pname = "auth-scope";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
          doCheck = false;
        };

        testModule = { pkgs, lib, ... }: {
          imports = [ self.nixosModules.default ];

          # We need vsock loopback support
          boot.kernelModules = [ "vsock_loopback" ];
          environment.systemPackages = [ pkgs.time ];

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
          users.users.service-a = { isSystemUser = true; group = "service-a"; };
          users.users.service-b = { isSystemUser = true; group = "service-b"; };
          users.users.service-c = { isSystemUser = true; group = "service-c"; };

          # Use our NixOS modules to configure auth-scope
          services.auth-scope-server = {
            enable = true;
            package = authScope;
            settings = {
              ca_cert_path = "/etc/auth-scope/ca/ca-cert.pem";
              ca_key_path = "/etc/auth-scope/ca/ca-key.pem";
              vsock_port = 900;
              cert_validity_days = 365;
              vms."1" = {
                vm_name = "local-vm";
                entities = {
                  service-a.caps = [];
                  service-b.caps = [];
                  service-c.caps = [];
                };
              };
            };
          };

          services.auth-scope-agent = {
            enable = true;
            package = authScope;
            settings = {
              vsock_host_cid = 1;
              vsock_port = 900;
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

      in pkgs.testers.runNixOSTest {
        name = "auth-scope-test";
        nodes.machine = testModule;

        testScript = ''
          machine.wait_for_unit("multi-user.target")
          
          # Wait for the server to be listening
          machine.wait_for_unit("auth-scope-server.service")
          machine.sleep(2) # Give it a moment to bind

          # Run the agent wrapped in 'time' to measure performance
          # We call the binary directly from the package since we disabled the agent service auto-start
          output = machine.succeed("env time -v auth-scope-agent --config /etc/auth-scope/agent.json 2>&1")
          
          print(output)
          
          # Verify certificates were created
          machine.succeed("ls -la /var/lib/service-a/cert.pem")
          machine.succeed("ls -la /var/lib/service-b/cert.pem")
          machine.succeed("ls -la /var/lib/service-c/cert.pem")
          
          status = machine.succeed("systemctl status auth-scope-server.service")
          print(status)
        '';
      };
  };
}

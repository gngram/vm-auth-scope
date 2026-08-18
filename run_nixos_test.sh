#!/usr/bin/env bash

set -e

WORKSPACE_DIR="/work/repositories/gngram/auth-scope"
cd $WORKSPACE_DIR

echo "=> 1. Building the Rust workspace..."
export PATH="/nix/store/788mx070y81zjlg5ipcl0cra3afviw9k-gcc-wrapper-15.2.0/bin:/nix/store/f5vajd8mhhy3rrsdz6z1m39p2p1csz5c-cargo-1.91.1/bin:/nix/store/5b2m570rjqzy9fyz9d5g5l2cljk8mvbp-rustc-1.91.1/bin:$PATH"
cargo build --release

echo "=> 2. Setting up test host configuration..."
cat << 'EOF' > test-host.json
{
  "ca_cert_path": "ca-cert.pem",
  "ca_key_path": "ca-key.pem",
  "vsock_port": 900,
  "cert_validity_days": 365,
  "vms": {
    "3": {
      "vm_name": "testvm",
      "entities": {
        "service-a": { "caps": [] },
        "service-b": { "caps": [] },
        "service-c": { "caps": [] }
      }
    }
  }
}
EOF

echo "=> 3. Initialising CA..."
sudo ./target/release/auth-scope-server --init --config test-host.json

echo "=> 4. Starting host CA server (measuring with /usr/bin/time -v)..."
# We wrap the server in time to measure its memory/cpu usage
# Output goes to server_time.txt
sudo /usr/bin/time -v -o server_time.txt ./target/release/auth-scope-server --config test-host.json > server.log 2>&1 &
SERVER_PID=$!

# Wait for server to start
sleep 2

echo "=> 5. Building NixOS VM (testvm)..."
nix build .#nixosConfigurations.testvm.config.system.build.vm

echo "=> 6. Running NixOS VM (measuring with /usr/bin/time -v)..."
# The VM is configured to auto-start auth-scope-agent via systemd.
# The agent requests certs for service-a, service-b, service-c, then exits.
# We run QEMU and wait for it to exit (or we can kill it after a bit).
# Since it's a test VM, we can pass QEMU options to auto-shutdown or we just let it boot, wait 15s, and kill it.

export QEMU_OPTS="-display none"
/usr/bin/time -v -o vm_time.txt sudo ./result/bin/run-testvm-vm &
VM_PID=$!

echo "   Waiting 15 seconds for VM to boot, agent to run, and request certs..."
sleep 15

echo "=> 7. Stopping VM and Server..."
sudo kill $VM_PID || true
sudo kill $SERVER_PID || true

echo ""
echo "======================================================"
echo "                   TEST RESULTS                       "
echo "======================================================"
echo "Host Server Metrics:"
grep -E "User time|System time|Maximum resident set size|Percent of CPU" server_time.txt || true
echo ""
echo "Guest VM Metrics (QEMU process):"
grep -E "User time|System time|Maximum resident set size|Percent of CPU" vm_time.txt || true
echo ""
echo "Host Server Logs:"
cat server.log
echo "======================================================"

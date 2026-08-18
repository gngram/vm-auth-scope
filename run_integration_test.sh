#!/usr/bin/env bash
set -e

# Make sure we are root (for vhost-vsock and 9p passthrough)
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (or use sudo) to attach /dev/vhost-vsock to QEMU."
  exec sudo "$0" "$@"
fi

WORKSPACE_DIR="$(pwd)"
echo "=> 1. Building the Rust workspace..."
# Drop privileges just for the cargo build to avoid root ownership issues if possible
if [ -n "$SUDO_USER" ]; then
    sudo -u "$SUDO_USER" cargo build --release
else
    cargo build --release
fi

echo "=> 2. Setting up test host configuration..."
mkdir -p "$WORKSPACE_DIR/tmp_agent"
cd "$WORKSPACE_DIR"

cat << EOF > test-host.json
{
  "ca_cert_path": "$WORKSPACE_DIR/tmp_agent/ca-cert.pem",
  "ca_key_path": "$WORKSPACE_DIR/tmp_agent/ca-key.pem",
  "vsock_port": 900,
  "cert_validity_days": 365,
  "vms": {
    "3": {
      "vm_name": "testvm",
      "entities": {
        "service-a": {
          "caps": [
            {
              "target_vm": "testvm",
              "target_cid": 3,
              "rpc_modules": ["auth"],
              "rpc_methods": ["data.read_secure"],
              "paths": [
                { "path": "/api/v1/health", "access": ["read"] }
              ]
            }
          ]
        },
        "service-b": { "caps": [] },
        "service-c": { "caps": [] }
      }
    }
  }
}
EOF

cat << EOF > test-agent.json
{
  "vsock_host_cid": 2,
  "vsock_port": 900,
  "entities": [
    {
      "name": "service-a",
      "cert_path": "$WORKSPACE_DIR/tmp_agent/service-a-cert.pem",
      "key_path": "$WORKSPACE_DIR/tmp_agent/service-a-key.pem",
      "ca_path": "$WORKSPACE_DIR/tmp_agent/service-a-ca.pem",
      "owner_uid": 0,
      "owner_gid": 0,
      "cert_mode": "0644",
      "key_mode": "0600"
    }
  ]
}
EOF

echo "=> 3. Initialising CA..."
./target/release/auth-scope-server --init --config test-host.json

echo "=> 4. Starting host CA server in background..."
./target/release/auth-scope-server --config test-host.json > server.log 2>&1 &
SERVER_PID=$!

sleep 2 # Let server bind

echo "=> 5. Finding Host Kernel..."
if [ -f "/run/current-system/kernel" ]; then
    KERNEL="/run/current-system/kernel"
elif [ -n "$(ls /boot/vmlinuz-* 2>/dev/null | head -n 1)" ]; then
    KERNEL=$(ls /boot/vmlinuz-* | head -n 1)
else
    echo "Could not find a suitable kernel in /boot or /run/current-system."
    kill $SERVER_PID || true
    exit 1
fi
echo "Using kernel: $KERNEL"

echo "=> 6. Creating Guest Init Script..."
cat << EOF > guest_init.sh
#!/bin/sh
# Mount essential pseudofilesystems
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev

# Setup basic networking (optional for vsock but good practice)
ip link set up dev lo || true

echo "==> [Guest] Running auth-scope-agent..."
$WORKSPACE_DIR/target/release/auth-scope-agent --config $WORKSPACE_DIR/test-agent.json

echo "==> [Guest] Evaluating generated capabilities..."
$WORKSPACE_DIR/target/release/auth-scope-eval-test \\
    $WORKSPACE_DIR/tmp_agent/service-a-cert.pem \\
    $WORKSPACE_DIR/tmp_agent/ca-cert.pem

echo "==> [Guest] Shutting down VM..."
sync
# Trigger instantaneous poweroff via sysrq to safely exit QEMU
echo 1 > /proc/sys/kernel/sysrq || true
echo o > /proc/sysrq-trigger
EOF
chmod +x guest_init.sh

echo "=> 7. Booting QEMU VM & Running Agent over vsock..."
# Run QEMU. We mount the host's root directory over 9p so the guest uses the 
# host's compiled binaries, shared libraries, and scripts without an initramfs.
qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -nographic \
    -append "console=ttyS0 root=hostshare rootfstype=9p rootflags=trans=virtio,version=9p2000.L init=$WORKSPACE_DIR/guest_init.sh rw" \
    -m 512M \
    -device vhost-vsock-pci,guest-cid=3 \
    -fsdev local,security_model=passthrough,id=fsdev0,path=/ \
    -device virtio-9p-pci,id=fs0,fsdev=fsdev0,mount_tag=hostshare

echo "=> 8. Stopping Server..."
kill $SERVER_PID || true

echo "======================================================"
echo "                   TEST RESULTS                       "
echo "======================================================"
echo "Host Server Logs:"
cat server.log
echo "======================================================"
echo "Test completed successfully!"

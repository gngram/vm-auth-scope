# Auth-Scope Application Walkthrough

The `auth-scope` workspace provides a high-performance, purely Rust-based CA and vsock agent system designed for multi-VM Linux environments without reliance on OpenSSL C libraries.

## 1. Core Implementation Overview

### Server (Host CA)
- Built in `crates/auth-scope-server`.
- Listens on `vsock` port 900 (`VMADDR_CID_ANY`).
- Enforces strict execution as a root process.
- Receives JSON-encoded CSRs from agents.
- Automatically maps the incoming vsock connection's actual peer CID (from the kernel driver) against the configured policy in `host.json`.
- Signs the CSR using ECDSA P-256 (via the `ring` and `rcgen` crates).
- Embeds a JSON Web Token (JWT) formatted capability claim into the issued certificate under the custom OID `1.3.6.1.4.1.99999.1`.

### Agent (Guest Client)
- Built in `crates/auth-scope-agent`.
- Reads `agent.json` to process multiple entities (`service-a`, `service-b`, etc.) hosted on the VM.
- Securely identifies its local CID using a direct `ioctl(IOCTL_VM_SOCKETS_GET_LOCAL_CID)` call on a newly created `AF_VSOCK` socket.
- Connects to the host CA over raw `vsock` (port 900) without TLS wrapping (as requested).
- Dispatches CSRs and securely stores the generated X.509 certificates and keys on disk with strict `0600` permissions.

## 2. Testing Framework & Architecture

To fully validate this multi-VM system, we implemented a complete NixOS VM test suite (`flake.nix`). The test operates using `pkgs.nixosTest` which builds a fully isolated QEMU test VM to mirror the production target.

**Within the VM:**
- `auth-scope-server.service` starts and binds to the vsock loopback.
- `auth-scope-agent` executes with an injected `agent.json` containing configurations for three mock entities (`service-a`, `service-b`, `service-c`).
- The agent securely communicates via vsock, writes the credentials to `/var/lib/service-*`, and terminates.

## 3. Performance & Resource Metrics

During execution, `auth-scope` proved extremely lightweight and highly performant. The metrics captured directly from the test VM (using `env time -v` and `systemctl status`) are as follows:

> [!TIP]
> **Performance Results:**
> 
> **Agent (Client):**
> * **Elapsed Time:** `0:00.03` (30 milliseconds to generate 3 ECDSA keys, 3 CSRs, and complete 3 vsock round trips to the CA).
> * **Peak Memory (RSS):** `3408 KB` (~3.4 MB)
> * **CPU Usage:** `11%` (over the 30ms window)
> 
> **Server (CA Daemon):**
> * **Peak Memory:** `3.8 MB`
> * **CPU Time:** `20ms`

## 4. Validating the Capability Extensions

The custom X.509 extension (OID `1.3.6.1.4.1.99999.1`) embedded in the certificates follows this structure:

```json
{
  "iss": "auth-scope-ca",
  "sub": "service-a",
  "vm": "local-vm",
  "cid": 1,
  "iat": 1723964964,
  "exp": 1755500964,
  "caps": [
    {
      "target_vm": "db-vm",
      "target_cid": 42,
      "rpc_modules": ["auth", "data"],
      "rpc_methods": ["auth.login", "data.read"],
      "paths": [
        { "path": "/api/v1/resource", "access": ["read", "write"] }
      ]
    }
  ]
}
```

These capabilities map directly to the `host.json` configuration definitions, allowing robust RBAC/CBAC enforcement by any downstream service interpreting the certificate.

## 5. NixOS Integration
The repository now exposes native NixOS modules for easy deployment:
- `nixos/modules/server.nix`: Configures the host CA daemon.
- `nixos/modules/agent.nix`: Configures the guest agent logic.

By using standard Nix attributes (e.g. `services.auth-scope-server.settings`), the JSON configuration files are deterministically generated, removing the need for manual JSON templating in your system deployments.

## 6. Capability Evaluator (`auth-scope-evaluator`)

We've provided a fully standalone, purely Rust evaluation engine to parse peer certificates and validate RBAC grants without relying on OpenSSL.

### Features
- Parses the X.509 structure to locate the `1.3.6.1.4.1.99999.1` OID extension using the `x509-parser` crate.
- Safely unwraps the ASN.1 OCTET STRING to retrieve the embedded Capability JWT.
- Uses `ring` to cryptographically verify the token against the CA's trusted Public Key.

### Usage Example
When your downstream service accepts a peer vsock connection (or gRPC request over vsock), simply parse the peer's certificate:

```rust
use auth_scope_evaluator::Evaluator;

// Instantiate the evaluator, extracting the JWT and verifying the signature.
let eval = Evaluator::from_cert_pem(&peer_cert_pem, &ca_cert_pem)
    .expect("Failed to verify peer certificate capabilities");

// Validate RPC module and method access
if eval.can_call_rpc("my-local-vm", "auth", "data.read_secure") {
    // Proceed with the RPC call
}

// Validate Path and Method access
if eval.can_access_path("my-local-vm", "/api/v1/health", "read") {
    // Proceed with HTTP route
}
```

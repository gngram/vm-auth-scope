# Auth-Scope: vsock Certificate Authority — Implementation Plan

## Overview

A pure-Rust (no OpenSSL/C dependency) PKI system for multi-VM Linux environments.
The **host CA** issues X.509 certificates over vsock, embedding capability claims (RBAC/CBAC) as a
custom X.509 extension encoded as a JSON Web Token (JWT)-style structure.
Each **guest VM** runs an agent that requests certificates on behalf of local entities (services/processes).

---

## User Review Required

> [!IMPORTANT]
> The following design decisions need your confirmation before coding starts.
> All open questions are listed at the bottom — please scan them before approving.

---

## Design decisions
| Scope | Implementation |
|--|--|
| Key algorithm: RSA-2048 or ECDSA P-256? |	ECDSA P-256 | 
| TLS inside vsock, or plain vsock? |	TLS (rustls) |
| Auto-renew certs, or one-shot?	| One-shot for v1 |
| CA key: plain PEM or password-protected PKCS#8?	| Plain PEM |
| Cap JWT signed by CA key or separate key? |	Same CA key |
| --init: idempotent or always-overwrite?	| Idempotent |
| Server root enforcement: policy check or just convention? |	Require root |

---

## Proposed Crate Selection (no OpenSSL / no C FFI)

| Purpose | Crate |
|---|---|
| X.509 / CSR generation | `rcgen` (pure Rust, uses *ring*) |
| Asymmetric crypto | `ring` (pure Rust crypto primitives) |
| TLS over vsock (optional mTLS) | `rustls` + `rustls-pemfile` |
| vsock transport | `tokio-vsock` (async vsock) |
| Async runtime | `tokio` |
| Serialization | `serde` + `serde_json` |
| JWT-style signing/verification | `jsonwebtoken` (pure Rust) |
| Logging | `tracing` + `tracing-subscriber` |
| Error handling | `thiserror` + `anyhow` |
| CLI | `clap` |
| Config file parsing | `serde_json` |

---

## Architecture

```
┌──────────────────────── HOST VM ────────────────────────────┐
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                  auth-scope-server                  │    │
│  │                                                     │    │
│  │  ┌──────────┐  ┌───────────┐  ┌─────────────────┐  │    │
│  │  │ vsock    │  │ CA Engine │  │ Config / Policy │  │    │
│  │  │ Listener │→ │ (rcgen)   │→ │ (host.json)     │  │    │
│  │  └──────────┘  └───────────┘  └─────────────────┘  │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  CA private key + CA cert stored in /etc/auth-scope/ca/     │
└──────────────────────────────────────────────────────────────┘
           ▲ vsock (CID=2 or VMADDR_CID_HOST, port=6666)
           │ (TLS inside vsock — server presents CA cert)
           │
┌──────────┴──────── GUEST VM (CID=N) ───────────────────────┐
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                  auth-scope-agent                   │    │
│  │                                                     │    │
│  │  ┌──────────┐  ┌────────────┐  ┌────────────────┐  │    │
│  │  │ vsock    │  │ CSR        │  │ Entity Manager │  │    │
│  │  │ Client   │→ │ Generator  │→ │ (guest.json)   │  │    │
│  │  └──────────┘  └────────────┘  └────────────────┘  │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
│  Certs written to per-entity paths with correct permissions  │
└──────────────────────────────────────────────────────────────┘
```

---

## Wire Protocol

A simple length-prefixed JSON protocol over the vsock (with TLS):

```
[4-byte big-endian length][JSON payload bytes]
```

### CertRequest (agent → server)
```json
{
  "version": 1,
  "cid": 42,
  "entity": "my-service",
  "csr_pem": "-----BEGIN CERTIFICATE REQUEST-----\n..."
}
```

### CertResponse (server → agent)
```json
{
  "status": "ok",
  "cert_pem": "-----BEGIN CERTIFICATE-----\n...",
  "ca_cert_pem": "-----BEGIN CERTIFICATE-----\n..."
}
```
or on error:
```json
{ "status": "error", "message": "CID not authorized" }
```

---

## Capability / JWT Claim Structure

Capabilities are embedded as a **custom X.509 extension** (OID `1.3.6.1.4.1.99999.1`)
whose value is a JWT signed by the CA's private key.

### JWT Header
```json
{ "alg": "RS256", "typ": "CAP" }
```

### JWT Payload
```json
{
  "iss": "auth-scope-ca",
  "sub": "my-service",
  "vm":  "vm-frontend",
  "cid": 42,
  "iat": 1700000000,
  "exp": 1731536000,
  "caps": [
    {
      "target_vm":  "vm-backend",
      "target_cid": 10,
      "rpc_modules": ["auth", "storage"],
      "rpc_methods": ["auth.login", "storage.read"],
      "paths": [
        { "path": "/api/v1/data", "access": ["read"] },
        { "path": "/api/v1/admin", "access": ["read", "write"] }
      ]
    }
  ]
}
```

---

## Configuration Schema

### Host config (`/etc/auth-scope/host.json`)
```json
{
  "ca_cert_path":   "/etc/auth-scope/ca/ca-cert.pem",
  "ca_key_path":    "/etc/auth-scope/ca/ca-key.pem",
  "vsock_port":     6666,
  "cert_validity_days": 365,
  "vms": {
    "42": {
      "vm_name": "vm-frontend",
      "entities": {
        "my-service": {
          "caps": [
            {
              "target_vm":  "vm-backend",
              "target_cid": 10,
              "rpc_modules": ["auth"],
              "rpc_methods": ["auth.login"],
              "paths": [
                { "path": "/api/v1/data", "access": ["read"] }
              ]
            }
          ]
        }
      }
    }
  }
}
```
> [!NOTE]
> CID is the primary key. Entities within a CID each get their own capability set.
> If CID is absent, the server rejects the request.

### Guest/Agent config (`/etc/auth-scope/agent.json`)
```json
{
  "server_ca_cert":  "/etc/auth-scope/ca/ca-cert.pem",
  "vsock_host_cid":  2,
  "vsock_port":      6666,
  "entities": [
    {
      "name":      "my-service",
      "cert_path": "/etc/my-service/tls/cert.pem",
      "key_path":  "/etc/my-service/tls/key.pem",
      "ca_path":   "/etc/my-service/tls/ca.pem",
      "owner_uid": 1001,
      "owner_gid": 1001,
      "cert_mode": "0640",
      "key_mode":  "0600"
    }
  ]
}
```

---

## File & Module Layout

```
auth-scope/
├── Cargo.toml               # workspace root
├── Cargo.lock
│
├── crates/
│   ├── auth-scope-proto/    # shared wire types + capability structs
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── wire.rs      # CertRequest, CertResponse
│   │       └── caps.rs      # CapClaim, Capability, PathAccess structs
│   │
│   ├── auth-scope-ca/       # CA engine (cert signing, CA key management)
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs
│   │       ├── ca.rs        # CertificateAuthority struct
│   │       ├── signing.rs   # sign_csr(), embed_caps_extension()
│   │       └── jwt.rs       # build_cap_jwt(), verify_cap_jwt()
│   │
│   ├── auth-scope-server/   # host CA daemon
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── main.rs
│   │       ├── config.rs    # HostConfig, VmEntry, EntityPolicy
│   │       ├── listener.rs  # vsock accept loop
│   │       ├── handler.rs   # per-connection request handler
│   │       └── policy.rs    # CID lookup, entity policy resolution
│   │
│   └── auth-scope-agent/    # guest agent
│       ├── Cargo.toml
│       └── src/
│           ├── main.rs
│           ├── config.rs    # AgentConfig, EntityEntry
│           ├── client.rs    # vsock connect + TLS handshake
│           ├── csr.rs       # per-entity keypair + CSR generation
│           └── store.rs     # write cert/key, set permissions
│
└── config-examples/
    ├── host.json
    └── agent.json
```

---

## Key Implementation Details

### CA Initialization (first run)
- `auth-scope-server --init` generates a self-signed CA keypair using `rcgen`
- CA key is RSA-2048 or ECDSA-P256 (configurable)
- Writes `ca-cert.pem` and `ca-key.pem` to configured paths

### TLS over vsock
- Server wraps accepted vsock stream with `rustls` (presents CA cert as server cert)
- Agent verifies server cert against known CA cert (pinned)
- Mutual TLS is optional in first version (server-side only TLS)

### Certificate Signing
1. Agent generates keypair + PKCS#10 CSR via `rcgen`
2. CSR sent to server in `CertRequest`
3. Server validates CID + entity name against `host.json`
4. Server builds capability JWT, signs with CA private key
5. Server signs CSR, embeds cap JWT in custom extension
6. Signed cert PEM returned to agent

### File Permissions (agent side)
- Agent runs as root (or with CAP_CHOWN)
- Sets `owner_uid`, `owner_gid`, `cert_mode`, `key_mode` per entity config
- Uses `std::fs` + `std::os::unix::fs::PermissionsExt`

---

## Open Questions

> [!IMPORTANT]
> **Q1 — Key algorithm**: RSA-2048 or ECDSA P-256? ECDSA is smaller and faster; RSA is more widely compatible. Which do you prefer for both the CA key and entity keys?

> [!IMPORTANT]
> **Q2 — TLS over vsock**: Should the vsock channel itself be TLS-wrapped (rustls), or is the vsock isolation considered sufficient and you want plain vsock? TLS adds mutual auth but also complexity.

> [!IMPORTANT]
> **Q3 — Certificate renewal**: Should the agent automatically renew certs before expiry (e.g. at 80% of lifetime), or is a one-shot "request and store" sufficient for v1?

> [!IMPORTANT]
> **Q4 — CA key storage**: Should the CA private key simply be a PEM file on the host filesystem, or do you want it wrapped/encrypted (e.g. password-protected PKCS#8)?

> [!IMPORTANT]
> **Q5 — JWT signing key**: Should the capability JWT be signed with the same CA key, or with a separate dedicated signing key?

> [!IMPORTANT]
> **Q6 — `auth-scope-server --init` behavior**: Should `--init` always create a fresh CA, or should it be idempotent (skip if CA already exists)?

> [!NOTE]
> **Q7 — Vsock port**: You mentioned "rooted port". vsock doesn't have privileged port semantics like TCP. Should the server require it runs as root/CAP_NET_BIND_SERVICE as a policy check, or is port number alone sufficient?

---

## Verification Plan

### Automated Tests
- Unit tests inside each crate (`cargo test --workspace`)
- CA engine: sign a CSR, parse resulting cert, verify extension is present
- Proto: serialize/deserialize round-trip for all wire types

### Manual Verification
- Run `auth-scope-server --init` on host, verify CA files created
- Start server daemon, start agent on simulated vsock (using loopback CID=1 for local testing)
- Verify cert written to entity path with correct permissions
- Parse resulting cert and verify capability JWT extension is present and valid


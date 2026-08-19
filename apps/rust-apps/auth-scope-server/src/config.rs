//! Host CA server configuration.
//!
//! Loaded from a JSON file (default: `/etc/auth-scope/host.json`).

use std::{collections::HashMap, path::PathBuf};

use serde::{Deserialize, Serialize};

use auth_scope_proto::caps::Capability;

/// Top-level host configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostConfig {
    /// Path to the CA certificate PEM file.
    pub ca_cert_path: PathBuf,
    /// Path to the CA private key PEM file.
    pub ca_key_path: PathBuf,
    /// vsock port on which to listen (should be privileged / < 1000).
    #[serde(default = "default_vsock_port")]
    pub vsock_port: u32,
    /// Default certificate validity in days (used when not overridden per-entity).
    #[serde(default = "default_validity_days")]
    pub cert_validity_days: u32,
    /// Map of vsock CID (as string) → VM entry.
    ///
    /// CID is stored as a string key because JSON object keys are always strings.
    pub vms: HashMap<String, VmEntry>,
    /// Expected peer port of the client agent.
    #[serde(default = "default_peer_port")]
    pub peer_port: u32,
    /// Optional file descriptor name to listen on.
    pub vsock_fd_name: Option<String>,
}

fn default_vsock_port() -> u32 {
    900
}

fn default_validity_days() -> u32 {
    365
}

fn default_peer_port() -> u32 {
    901
}

/// Per-VM configuration entry. CID is the primary key (stored as the map key).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct VmEntry {
    /// Human-readable VM name embedded in issued certificates.
    pub vm_name: String,
    /// Map of entity name → entity policy.
    pub entities: HashMap<String, EntityPolicy>,
}

/// Policy for a single entity (service/process) running inside a VM.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EntityPolicy {
    /// Capability grants to embed in the issued certificate.
    pub caps: Vec<Capability>,
    /// Optional per-entity validity override (days). Falls back to global setting.
    pub validity_days: Option<u32>,
}

impl HostConfig {
    /// Load and parse the config from a JSON file.
    pub fn from_file(path: &std::path::Path) -> anyhow::Result<Self> {
        let data = std::fs::read_to_string(path)?;
        let cfg: Self = serde_json::from_str(&data)?;

        if cfg.vsock_port >= 1000 {
            anyhow::bail!("vsock_port must be less than 1000, got {}", cfg.vsock_port);
        }

        Ok(cfg)
    }
}

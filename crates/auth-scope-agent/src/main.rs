//! auth-scope-agent — guest VM certificate agent.
//!
//! # Usage
//!
//! ```
//! sudo auth-scope-agent --config /etc/auth-scope/agent.json
//! ```
//!
//! The agent connects to the host CA over vsock, requests certificates for
//! every entity listed in the config, and writes the credentials to disk
//! with the configured POSIX ownership and permissions.

use std::{path::PathBuf, process};

use clap::Parser;
use tracing::{error, info};
use tracing_subscriber::{fmt, EnvFilter};

mod client;
mod config;
mod csr;
mod store;

use config::AgentConfig;

/// auth-scope guest agent — requests X.509 certificates from the host CA.
#[derive(Debug, Parser)]
#[command(
    name    = "auth-scope-agent",
    about   = "Guest agent: requests entity certificates from the auth-scope host CA",
    version
)]
struct Cli {
    /// Path to the agent JSON configuration file.
    #[arg(
        short,
        long,
        default_value = "/etc/auth-scope/agent.json",
        value_name = "FILE"
    )]
    config: PathBuf,
}

#[tokio::main]
async fn main() {
    fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    // Require root for file ownership operations.
    #[cfg(unix)]
    if unsafe { libc_getuid() } != 0 {
        error!("auth-scope-agent must run as root to set file ownership");
        process::exit(1);
    }

    let cli = Cli::parse();

    let cfg = match AgentConfig::from_file(&cli.config) {
        Ok(c) => c,
        Err(e) => {
            error!(config = %cli.config.display(), error = %e, "Failed to load config");
            process::exit(1);
        }
    };

    info!("Starting auth-scope-agent");

    if let Err(e) = client::run_agent(&cfg).await {
        error!(error = %e, "Agent encountered a fatal error");
        process::exit(1);
    }

    info!("auth-scope-agent completed successfully");
}

// ─── minimal libc shim ────────────────────────────────────────────────────────

#[cfg(unix)]
extern "C" {
    fn getuid() -> u32;
}

#[cfg(unix)]
unsafe fn libc_getuid() -> u32 {
    getuid()
}

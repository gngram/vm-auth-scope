//! vsock listener — accepts connections and spawns TLS-wrapped handlers.

use std::sync::Arc;
use std::os::unix::io::{FromRawFd, RawFd};

use tokio_vsock::{VMADDR_CID_ANY, VsockAddr, VsockListener};
use tracing::{error, info};

use auth_scope_ca::CertificateAuthority;

use crate::{config::HostConfig, handler::handle_connection};

fn get_systemd_fd(name: &str) -> Option<RawFd> {
    if let Ok(listen_pid) = std::env::var("LISTEN_PID") {
        if let Ok(pid) = listen_pid.parse::<u32>() {
            if pid != std::process::id() {
                return None;
            }
        }
    }
    
    let listen_fds = std::env::var("LISTEN_FDS").ok()?;
    let num_fds = listen_fds.parse::<usize>().ok()?;
    
    let fd_names = std::env::var("LISTEN_FDNAMES").ok()?;
    let names: Vec<&str> = fd_names.split(':').collect();
    
    for (i, &fd_name) in names.iter().enumerate() {
        if fd_name == name && i < num_fds {
            return Some((3 + i) as RawFd);
        }
    }
    
    None
}

/// Start the vsock+TLS listener loop.
///
/// Runs until the process is terminated.
pub async fn run_listener(
    config: Arc<HostConfig>,
    ca: Arc<CertificateAuthority>,
) -> anyhow::Result<()> {
    let port = config.vsock_port;
    
    let mut listener = if let Some(fd_name) = &config.vsock_fd_name {
        if let Some(fd) = get_systemd_fd(fd_name) {
            info!(fd_name, fd, "Using systemd activated socket for server");
            unsafe { VsockListener::from_raw_fd(fd) }
        } else {
            info!(port, "Systemd socket not found; binding directly to port");
            let addr = VsockAddr::new(VMADDR_CID_ANY, port);
            VsockListener::bind(addr)?
        }
    } else {
        let addr = VsockAddr::new(VMADDR_CID_ANY, port);
        VsockListener::bind(addr)?
    };

    info!(port, "auth-scope-server listening on vsock");

    loop {
        match listener.accept().await {
            Ok((stream, peer_addr)) => {
                let peer_cid = peer_addr.cid();
                let peer_port = peer_addr.port();
                info!(peer_cid, peer_port, "Accepted vsock connection");

                // Verify the peer port of the client
                if peer_port != config.peer_port {
                    error!(peer_port, expected = config.peer_port, "Rejected connection: peer port mismatch");
                    continue; // Terminate connection by dropping the stream
                }

                let config = Arc::clone(&config);
                let ca = Arc::clone(&ca);

                tokio::spawn(async move {
                    handle_connection(stream, peer_cid, config, ca).await;
                });
            }
            Err(e) => {
                error!(error = %e, "Failed to accept vsock connection");
            }
        }
    }
}

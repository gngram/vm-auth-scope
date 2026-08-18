//! vsock listener — accepts connections and spawns TLS-wrapped handlers.

use std::sync::Arc;

use tokio_vsock::{VsockAddr, VsockListener, VMADDR_CID_ANY};
use tracing::{error, info};

use auth_scope_ca::CertificateAuthority;

use crate::{
    config::HostConfig,
    handler::handle_connection,
};

/// Start the vsock+TLS listener loop.
///
/// Runs until the process is terminated.
pub async fn run_listener(
    config: Arc<HostConfig>,
    ca: Arc<CertificateAuthority>,
) -> anyhow::Result<()> {
    let port = config.vsock_port;
    let addr = VsockAddr::new(VMADDR_CID_ANY, port);
    let mut listener = VsockListener::bind(addr)?;

    info!(port, "auth-scope-server listening on vsock");

    loop {
        match listener.accept().await {
            Ok((stream, peer_addr)) => {
                let peer_cid = peer_addr.cid();
                info!(peer_cid, "Accepted vsock connection");

                let config   = Arc::clone(&config);
                let ca       = Arc::clone(&ca);

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

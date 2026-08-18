//! vsock client — connects to the host CA and requests certificates.


use tokio_vsock::{VsockAddr, VsockStream};
use tracing::{debug, info};

use auth_scope_proto::{
    codec::{recv_json, send_json},
    wire::{CertRequest, CertResponse, PROTOCOL_VERSION},
};

use anyhow::{bail, Context, Result};

use crate::{
    config::{AgentConfig, EntityEntry},
    csr::generate_csr,
    store::store_entity_credentials,
};

/// Request and store certificates for every entity in the config.
pub async fn run_agent(config: &AgentConfig) -> Result<()> {
    for entity in &config.entities {
        match request_cert(config, entity).await {
            Ok(())  => info!(entity = %entity.name, "Certificate stored successfully"),
            Err(e)  => tracing::error!(entity = %entity.name, error = %e, "Certificate request failed"),
        }
    }

    Ok(())
}

/// Request and store a certificate for a single entity.
async fn request_cert(
    config:   &AgentConfig,
    entity:   &EntityEntry,
) -> Result<()> {
    info!(entity = %entity.name, "Requesting certificate from host CA");

    // Generate a fresh keypair and CSR for this entity.
    let generated = generate_csr(&entity.name)
        .with_context(|| format!("CSR generation for entity '{}'", entity.name))?;

    // Connect to the host over vsock.
    let addr = VsockAddr::new(config.vsock_host_cid, config.vsock_port);
    debug!(cid = config.vsock_host_cid, port = config.vsock_port, "Connecting to host CA");
    let mut stream = VsockStream::connect(addr).await
        .context("vsock connect to host CA failed")?;

    // Send certificate request.
    let req = CertRequest {
        version: PROTOCOL_VERSION,
        entity:  entity.name.clone(),
        csr_pem: generated.csr_pem,
    };
    send_json(&mut stream, &req).await
        .context("sending CertRequest")?;

    // Receive response.
    let resp: CertResponse = recv_json(&mut stream).await
        .context("receiving CertResponse")?;

    match resp {
        CertResponse::Ok { cert_pem, ca_cert_pem } => {
            store_entity_credentials(entity, &cert_pem, &generated.key_pem, &ca_cert_pem)?;
        }
        CertResponse::Error { message } => {
            bail!("Server rejected request for '{}': {}", entity.name, message);
        }
    }

    Ok(())
}

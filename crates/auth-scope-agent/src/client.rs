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
    // Derive our own CID from /proc/self/cgroup or just use what kernel gives us.
    // For vsock, the kernel fills in the source CID; we read it from the bound stream.
    // We send the CID in the request — the server will cross-check against peer addr.
    let self_cid = get_local_cid().await?;
    info!(cid = self_cid, "Local vsock CID detected");

    for entity in &config.entities {
        match request_cert(config, entity, self_cid).await {
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
    self_cid: u32,
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
        cid:     self_cid,
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

/// Determine the local vsock CID by connecting to VMADDR_CID_LOCAL and reading
/// the bound address, or by reading from `/dev/vsock` attributes.
///
/// Falls back to reading from `/proc/self/net/vsock` or using CID 1 (loopback).
async fn get_local_cid() -> Result<u32> {
    // AF_VSOCK = 40 (on Linux)
    let fd = unsafe { libc::socket(40, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        tracing::warn!("socket(AF_VSOCK) failed, falling back to CID_ANY");
        return Ok(tokio_vsock::VMADDR_CID_ANY);
    }

    let mut cid: u32 = 0;
    // IOCTL_VM_SOCKETS_GET_LOCAL_CID = _IO(7, 0xb9) = 0x7b9
    let ret = unsafe { libc::ioctl(fd, 0x7b9, &mut cid) };
    unsafe { libc::close(fd) };

    if ret < 0 {
        tracing::warn!("ioctl IOCTL_VM_SOCKETS_GET_LOCAL_CID failed, falling back to CID_ANY");
        return Ok(tokio_vsock::VMADDR_CID_ANY);
    }

    Ok(cid)
}

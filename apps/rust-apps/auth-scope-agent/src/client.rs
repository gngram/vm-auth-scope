//! vsock client — connects to the host CA and requests certificates.

use std::os::unix::io::{FromRawFd, RawFd};
use libc::{connect, sockaddr, sockaddr_vm, socklen_t};

use tokio_vsock::{VsockAddr, VsockStream};
use tracing::info;

use auth_scope_proto::{
    codec::{recv_json, send_json},
    wire::{CertRequest, CertResponse, PROTOCOL_VERSION},
};

use anyhow::{Context, Result, bail};

use crate::{
    config::{AgentConfig, EntityEntry},
    csr::generate_csr,
    store::store_entity_credentials,
};

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
            std::env::remove_var("LISTEN_FDS");
            return Some((3 + i) as RawFd);
        }
    }
    
    None
}

async fn connect_raw_fd(fd: RawFd, addr: VsockAddr) -> Result<VsockStream> {
    let sockaddr = sockaddr_vm {
        svm_family: libc::AF_VSOCK as libc::sa_family_t,
        svm_reserved1: 0,
        svm_port: addr.port(),
        svm_cid: addr.cid(),
        svm_zero: [0; 4],
    };
    
    if unsafe {
        connect(
            fd,
            &sockaddr as *const _ as *const sockaddr,
            std::mem::size_of::<sockaddr_vm>() as socklen_t,
        )
    } < 0 {
        let err = std::io::Error::last_os_error();
        info!(?err, "Raw connect returned error");
        if let Some(os_err) = err.raw_os_error() {
            if os_err == libc::EINVAL {
                // If it is a listening socket, retrieve local port and bind a new socket
                let mut local_addr = libc::sockaddr_vm {
                    svm_family: 0,
                    svm_reserved1: 0,
                    svm_port: 0,
                    svm_cid: 0,
                    svm_zero: [0; 4],
                };
                let mut len = std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t;
                let local_port = unsafe {
                    if libc::getsockname(fd, &mut local_addr as *mut _ as *mut libc::sockaddr, &mut len) == 0 {
                        local_addr.svm_port
                    } else {
                        901 // fallback default
                    }
                };
                
                unsafe { libc::close(fd) };
                
                // Stop the systemd socket unit to free up the port for our dialer
                let _ = std::process::Command::new("systemctl")
                    .args(["stop", "auth-scope-agent.socket"])
                    .status();
                
                let new_socket = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
                if new_socket < 0 {
                    return Err(std::io::Error::last_os_error().into());
                }
                
                let bind_addr = libc::sockaddr_vm {
                    svm_family: libc::AF_VSOCK as libc::sa_family_t,
                    svm_reserved1: 0,
                    svm_port: local_port,
                    svm_cid: libc::VMADDR_CID_ANY,
                    svm_zero: [0; 4],
                };
                
                let optval: libc::c_int = 1;
                unsafe {
                    libc::setsockopt(
                        new_socket,
                        libc::SOL_SOCKET,
                        libc::SO_REUSEADDR,
                        &optval as *const _ as *const libc::c_void,
                        std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                    );
                }
                
                if unsafe {
                    libc::bind(
                        new_socket,
                        &bind_addr as *const _ as *const libc::sockaddr,
                        std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t,
                    )
                } < 0 {
                    let bind_err = std::io::Error::last_os_error();
                    unsafe { libc::close(new_socket) };
                    return Err(anyhow::anyhow!("fallback bind to client port {} failed: {}", local_port, bind_err));
                }
                
                if unsafe {
                    connect(
                        new_socket,
                        &sockaddr as *const _ as *const sockaddr,
                        std::mem::size_of::<sockaddr_vm>() as socklen_t,
                    )
                } < 0 {
                    let conn_err = std::io::Error::last_os_error();
                    unsafe { libc::close(new_socket) };
                    return Err(anyhow::anyhow!("fallback connect failed: {}", conn_err));
                }
                
                let stream = unsafe { vsock::VsockStream::from_raw_fd(new_socket) };
                let stream = VsockStream::new(stream)?;
                return Ok(stream);
            }
        }
        return Err(anyhow::anyhow!("connect failed: {}", err));
    }
    
    let stream = unsafe { vsock::VsockStream::from_raw_fd(fd) };
    let stream = VsockStream::new(stream)?;
    Ok(stream)
}

async fn connect_with_local_port(host_cid: u32, port: u32, local_port: u32) -> Result<VsockStream> {
    let socket = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if socket < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    
    // Bind to the local port
    let local_addr = libc::sockaddr_vm {
        svm_family: libc::AF_VSOCK as libc::sa_family_t,
        svm_reserved1: 0,
        svm_port: local_port,
        svm_cid: libc::VMADDR_CID_ANY,
        svm_zero: [0; 4],
    };
    
    let optval: libc::c_int = 1;
    unsafe {
        libc::setsockopt(
            socket,
            libc::SOL_SOCKET,
            libc::SO_REUSEADDR,
            &optval as *const _ as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }

    if unsafe {
        libc::bind(
            socket,
            &local_addr as *const _ as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t,
        )
    } < 0 {
        let err = std::io::Error::last_os_error();
        let _ = unsafe { libc::close(socket) };
        return Err(anyhow::anyhow!("bind to client port {} failed: {}", local_port, err));
    }
    
    connect_raw_fd(socket, VsockAddr::new(host_cid, port)).await
}

/// Request and store certificates for every entity in the config.
pub async fn run_agent(config: &AgentConfig) -> Result<()> {
    for entity in &config.entities {
        match request_cert(config, entity).await {
            Ok(()) => info!(entity = %entity.name, "Certificate stored successfully"),
            Err(e) => {
                tracing::error!(entity = %entity.name, error = ?e, "Certificate request failed")
            }
        }
    }

    Ok(())
}

/// Request and store a certificate for a single entity.
async fn request_cert(config: &AgentConfig, entity: &EntityEntry) -> Result<()> {
    info!(entity = %entity.name, "Requesting certificate from host CA");

    // Generate a fresh keypair and CSR for this entity.
    let generated = generate_csr(&entity.name)
        .with_context(|| format!("CSR generation for entity '{}'", entity.name))?;

    // Connect to the host over vsock.
    let mut stream = if let Some(fd_name) = &config.vsock_fd_name {
        if let Some(fd) = get_systemd_fd(fd_name) {
            info!(fd_name, fd, "Using systemd activated socket for client");
            connect_raw_fd(fd, VsockAddr::new(config.vsock_host_cid, config.vsock_port))
                .await
                .context("vsock connect using systemd fd failed")?
        } else {
            connect_with_local_port(config.vsock_host_cid, config.vsock_port, config.client_port)
                .await
                .context("vsock connect with local port failed")?
        }
    } else {
        connect_with_local_port(config.vsock_host_cid, config.vsock_port, config.client_port)
            .await
            .context("vsock connect with local port failed")?
    };

    // Send certificate request.
    let req = CertRequest {
        version: PROTOCOL_VERSION,
        entity: entity.name.clone(),
        csr_pem: generated.csr_pem,
    };
    send_json(&mut stream, &req)
        .await
        .context("sending CertRequest")?;

    // Receive response.
    let resp: CertResponse = recv_json(&mut stream)
        .await
        .context("receiving CertResponse")?;

    match resp {
        CertResponse::Ok {
            cert_pem,
            ca_cert_pem,
        } => {
            store_entity_credentials(entity, &cert_pem, &generated.key_pem, &ca_cert_pem)?;
        }
        CertResponse::Error { message } => {
            bail!("Server rejected request for '{}': {}", entity.name, message);
        }
    }

    Ok(())
}

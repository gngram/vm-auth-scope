//! Write certificate, key, and CA cert to disk with correct ownership and permissions.

use std::{
    fs,
    os::unix::fs::{PermissionsExt, chown},
    path::Path,
};

use anyhow::{Context, Result};
use tracing::info;

use crate::config::EntityEntry;

/// Write the issued certificate, private key, and CA cert for `entity`.
///
/// Creates parent directories automatically.
/// Sets POSIX ownership (uid/gid) and permission modes.
pub fn store_entity_credentials(
    entity: &EntityEntry,
    cert_pem: &str,
    key_pem: &str,
    ca_pem: &str,
    secure_credentials: bool,
) -> Result<()> {
    if secure_credentials {
        encrypt_and_write_file(
            &entity.cert_path,
            cert_pem.as_bytes(),
            &entity.cert_mode,
            entity.owner_uid,
            entity.owner_gid,
            &entity.name,
            entity.user_service,
        )
        .with_context(|| format!("encrypting and writing cert to {}", entity.cert_path.display()))?;

        encrypt_and_write_file(
            &entity.key_path,
            key_pem.as_bytes(),
            &entity.key_mode,
            entity.owner_uid,
            entity.owner_gid,
            &entity.name,
            entity.user_service,
        )
        .with_context(|| format!("encrypting and writing key to {}", entity.key_path.display()))?;
    } else {
        write_file(
            &entity.cert_path,
            cert_pem.as_bytes(),
            &entity.cert_mode,
            entity.owner_uid,
            entity.owner_gid,
        )
        .with_context(|| format!("writing cert to {}", entity.cert_path.display()))?;

        write_file(
            &entity.key_path,
            key_pem.as_bytes(),
            &entity.key_mode,
            entity.owner_uid,
            entity.owner_gid,
        )
        .with_context(|| format!("writing key to {}", entity.key_path.display()))?;
    }

    write_file(
        &entity.ca_path,
        ca_pem.as_bytes(),
        &entity.cert_mode,
        entity.owner_uid,
        entity.owner_gid,
    )
    .with_context(|| format!("writing CA cert to {}", entity.ca_path.display()))?;

    info!(
        entity = %entity.name,
        cert   = %entity.cert_path.display(),
        key    = %entity.key_path.display(),
        secure = secure_credentials,
        "Credentials stored"
    );

    Ok(())
}

// ─── internals ────────────────────────────────────────────────────────────────

/// Write `data` to `path`, creating parent dirs, then set permissions + ownership.
fn write_file(path: &Path, data: &[u8], mode_str: &str, uid: u32, gid: u32) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating directory {}", parent.display()))?;
    }

    fs::write(path, data).with_context(|| format!("writing {}", path.display()))?;

    // Set permissions.
    let mode =
        parse_octal_mode(mode_str).with_context(|| format!("parsing mode '{}'", mode_str))?;
    let perms = fs::Permissions::from_mode(mode);
    fs::set_permissions(path, perms)
        .with_context(|| format!("setting permissions on {}", path.display()))?;

    // Set ownership.
    chown(path, Some(uid), Some(gid))
        .with_context(|| format!("chown {}:{} on {}", uid, gid, path.display()))?;

    Ok(())
}

/// Encrypt data using systemd-creds and write it to `path`.
fn encrypt_and_write_file(
    path: &Path,
    data: &[u8],
    mode_str: &str,
    uid: u32,
    gid: u32,
    entity_name: &str,
    is_user_service: bool,
) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("creating directory {}", parent.display()))?;
    }

    use std::io::Write;
    use std::process::{Command, Stdio};

    let mut cmd = Command::new("systemd-creds");
    if is_user_service {
        cmd.arg("--user");
    }
    cmd.arg(format!("--name={}", entity_name));
    cmd.arg("encrypt");
    cmd.arg("-"); // read from stdin
    cmd.arg(path); // write directly to the output path

    cmd.stdin(Stdio::piped());
    cmd.stdout(Stdio::inherit());
    cmd.stderr(Stdio::piped());

    let mut child = cmd.spawn().context("spawning systemd-creds")?;

    {
        let mut stdin = child.stdin.take().context("getting stdin of systemd-creds")?;
        stdin.write_all(data).context("writing data to systemd-creds stdin")?;
    }

    let output = child.wait_with_output().context("waiting for systemd-creds")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!(
            "systemd-creds failed with exit code {:?}: {}",
            output.status.code(),
            stderr.trim()
        );
    }

    // Set permissions.
    let mode = parse_octal_mode(mode_str).with_context(|| format!("parsing mode '{}'", mode_str))?;
    let perms = fs::Permissions::from_mode(mode);
    fs::set_permissions(path, perms)
        .with_context(|| format!("setting permissions on {}", path.display()))?;

    // Set ownership.
    chown(path, Some(uid), Some(gid))
        .with_context(|| format!("chown {}:{} on {}", uid, gid, path.display()))?;

    Ok(())
}

/// Parse an octal string like "0640" or "640" into a u32 mode.
fn parse_octal_mode(s: &str) -> Result<u32> {
    let trimmed = s.trim_start_matches('0');
    let trimmed = if trimmed.is_empty() { "0" } else { trimmed };
    u32::from_str_radix(trimmed, 8).with_context(|| format!("'{}' is not a valid octal mode", s))
}

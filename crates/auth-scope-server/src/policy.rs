//! Policy resolution: CID + entity → capability list.

use auth_scope_proto::caps::Capability;

use crate::config::HostConfig;

/// Result of a policy lookup.
#[derive(Debug)]
pub struct PolicyDecision {
    pub vm_name: String,
    pub caps: Vec<Capability>,
    pub validity_days: u32,
}

/// Look up whether `cid`/`entity` is authorised and retrieve capabilities.
///
/// Returns `None` if the CID is not in the config (reject the request).
/// Returns `None` if the entity is not registered for that CID.
pub fn resolve(
    config: &HostConfig,
    cid: u32,
    entity: &str,
) -> Option<PolicyDecision> {
    let vm_entry = config.vms.get(&cid.to_string())?;
    let policy   = vm_entry.entities.get(entity)?;

    Some(PolicyDecision {
        vm_name:      vm_entry.vm_name.clone(),
        caps:         policy.caps.clone(),
        validity_days: policy
            .validity_days
            .unwrap_or(config.cert_validity_days),
    })
}

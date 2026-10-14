//! Explicit ACP writer operations, separate from Codex process eviction.

use pocket_codex_host_svc::acp::session_control::SessionControl;

use super::*;

/// The displayed ownership snapshot that a session operation acts on.
pub struct SessionControlDto {
    /// Exact original session id.
    pub session_id: String,
    /// Host incarnation, captured before user confirmation.
    pub host_id: String,
    /// Agent generation, captured before user confirmation.
    pub generation: u64,
    /// Persisted source identity required by acquire.
    pub source_generation: Option<String>,
    /// Provider whose release rules apply.
    pub provider: String,
    /// Ownership/availability reason.
    pub status: String,
    /// The existing writer can serve this controller.
    pub can_continue: bool,
    /// This host can close its idle writer.
    pub can_release: bool,
    /// A freshly checked original-session acquisition is available.
    pub can_acquire: bool,
}

impl From<SessionControl> for SessionControlDto {
    fn from(v: SessionControl) -> Self {
        Self {
            session_id: v.session_id,
            host_id: v.host_id,
            generation: v.generation,
            source_generation: v.source_generation,
            provider: v.provider,
            status: v.status,
            can_continue: v.can_continue,
            can_release: v.can_release,
            can_acquire: v.can_acquire,
        }
    }
}

impl From<SessionControlDto> for SessionControl {
    fn from(v: SessionControlDto) -> Self {
        Self {
            session_id: v.session_id,
            host_id: v.host_id,
            generation: v.generation,
            source_generation: v.source_generation,
            provider: v.provider,
            status: v.status,
            can_continue: v.can_continue,
            can_release: v.can_release,
            can_acquire: v.can_acquire,
        }
    }
}

/// Read available operations without restoring, stopping or claiming a session.
pub fn app_acp_session_control(
    service_key: String,
    thread_id: String,
) -> Result<SessionControlDto> {
    Ok(crate::engine::acp::session_control(&service_key, &thread_id)?.into())
}

/// Apply the operation explicitly confirmed against this displayed snapshot.
/// `action` is `continue`, `release` or `acquire`; a replaced host is refused.
pub fn app_acp_control_session(
    service_key: String,
    snapshot: SessionControlDto,
    action: String,
) -> Result<()> {
    crate::engine::acp::control_session(&service_key, snapshot.into(), &action)
}

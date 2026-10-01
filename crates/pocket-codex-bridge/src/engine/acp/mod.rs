//! Controller side of the generic ACP provider (TRD §4.4.2). Compiled on every
//! platform; the hosting half (`serve_acp`, `acp_manage`) is desktop only.

use pocket_codex_core::acp::pcx::AuthState;

/// Result of starting (or reusing) an ACP host, surfaced to the UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpServeReport {
    /// Device id the services registered under.
    pub device: String,
    /// Instance name.
    pub name: String,
    /// `pcx:<device>:acp:<name>`.
    pub service_key: String,
    /// Loopback WebSocket address of the hub.
    pub listen_addr: String,
    /// `pcx:<device>:meta:<name>`.
    pub meta_service_key: String,
    /// Agent id.
    pub agent_id: String,
    /// Agent display name.
    pub agent_name: String,
    /// Installed agent version (empty for custom agents).
    pub agent_version: String,
    /// Authentication state after the first detection.
    pub auth: AuthState,
    /// An existing host was reused.
    pub reused: bool,
}

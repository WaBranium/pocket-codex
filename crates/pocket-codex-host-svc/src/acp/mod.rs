//! Host-side ACP hub (TRD §4.2): the only ACP client of one agent process,
//! multiplexing its sessions to many controllers over `_pcx`-extended ACP.
//!
//! Desktop only; the module is not compiled for Android or iOS.

mod auth;
mod error;
mod fs;
mod hub;
mod inbound;
mod launch;
mod ops;
mod peer;
mod pending;
mod process;
mod session;
#[cfg(any(test, feature = "acp-testing"))]
pub mod testing;

pub use auth::{GatewayAuth, TerminalLaunch, TerminalLauncher};
pub use error::AcpError;
pub use hub::{AcpHub, ConnId, HubConnection, HubInfo, HubOptions, LaunchProvider};
pub use launch::{AgentConnector, AgentIo, ChildHandle, LaunchSpec, ProcessConnector};
pub use peer::{Inbound, PeerExit, MAX_LINE_BYTES};

//! Concrete reader dispatch shared by local browsing and hosted ACP views.
use anyhow::Result;
use serde_json::Value;

use super::{ClaudeHistory, NativePage};

/// An explicitly selected native source. No variant admits or resumes sessions.
pub enum NativeHistory {
    /// Official read-only Claude SDK with optional verified native ownership.
    Claude(std::sync::Arc<ClaudeHistory>),
    /// Existing OpenCode database, available on desktop hosts only.
    #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
    OpenCode(super::OpenCodeHistory),
}

impl NativeHistory {
    /// Stable projection identity used by history reconciliation.
    pub fn provider(&self) -> &'static str {
        match self {
            Self::Claude(_) => "claude/native-v1",
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => "opencode/native-v1",
        }
    }
    /// List one source-scoped inventory page.
    pub async fn list_sessions(&self, cursor: Option<&str>, limit: usize) -> Result<Value> {
        match self {
            Self::Claude(reader) => reader.list_sessions(cursor, limit).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(reader) => reader.list_sessions(cursor, limit).await,
        }
    }
    /// Read the source revision without starting a runtime.
    pub async fn revision(&self, session: &str) -> Result<Value> {
        match self {
            Self::Claude(reader) => reader.revision(session).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(reader) => reader.revision(session).await,
        }
    }
    /// Read a bounded window, without acquiring write permission.
    pub async fn read_page(
        &self,
        session: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<NativePage> {
        match self {
            Self::Claude(reader) => reader.read_page(session, before, limit).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(reader) => reader.read_page(session, before, limit).await,
        }
    }
    /// Read one explicit native turn.
    pub async fn read_turn(&self, session: &str, turn: &str) -> Result<NativePage> {
        match self {
            Self::Claude(reader) => reader.read_turn(session, turn).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(reader) => reader.read_turn(session, turn).await,
        }
    }
    /// Reading a file or database never proves that an external writer is idle.
    pub async fn liveness(&self, session: &str) -> crate::sessions::SessionLiveness {
        match self {
            Self::Claude(reader) => reader.liveness(session).await,
            #[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
            Self::OpenCode(_) => super::ownership::unknown(session),
        }
    }
}

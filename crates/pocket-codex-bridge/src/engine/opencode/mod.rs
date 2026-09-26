//! OpenCode session state, independent of the Codex JSON-RPC controller.

use std::{collections::HashMap, sync::Arc};

use anyhow::{ensure, Context, Result};
use once_cell::sync::OnceCell;
use pocket_codex_host_svc::opencode::{
    Message, OpenCodeClient, OpenCodeEventStream, PermissionReply, PermissionRequest, PromptInput,
    QuestionRequest,
};
use tokio::sync::Mutex;

/// An authoritative native message window for the selected session.
#[derive(Clone, Debug)]
pub struct Snapshot {
    /// Upstream session identity.
    pub session_id: String,
    /// Native messages, ordered from oldest to newest.
    pub messages: Vec<Message>,
    /// Cursor for the next earlier page, when available.
    pub next_cursor: Option<String>,
    /// Monotonic local view revision.
    pub revision: u64,
    /// Authoritative upstream execution state: idle, busy, or retry.
    pub status: String,
    /// Live permission requests for this session only.
    pub permissions: Vec<PermissionRequest>,
    /// Live question requests for this session only.
    pub questions: Vec<QuestionRequest>,
}

#[derive(Default)]
struct State {
    selection: u64,
    snapshot: Option<Snapshot>,
}

struct ConnectionEntry {
    controller: Arc<OpenCodeController>,
    relay_key: Option<String>,
    event_tasks: Vec<tokio::task::JoinHandle<()>>,
}

static CONNECTIONS: OnceCell<std::sync::Mutex<HashMap<String, ConnectionEntry>>> = OnceCell::new();

fn connections() -> &'static std::sync::Mutex<HashMap<String, ConnectionEntry>> {
    CONNECTIONS.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

fn lock_connections() -> std::sync::MutexGuard<'static, HashMap<String, ConnectionEntry>> {
    match connections().lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            tracing::warn!("OpenCode connection registry lock was poisoned; recovering state");
            poisoned.into_inner()
        },
    }
}

/// One connection's selected conversation and bounded history.
pub struct OpenCodeController {
    client: OpenCodeClient,
    state: Mutex<State>,
}

impl OpenCodeController {
    /// Construct a read-only controller without taking ownership of the server.
    pub fn new(client: OpenCodeClient) -> Self {
        Self {
            client,
            state: Mutex::new(State::default()),
        }
    }

    /// List sessions in the selected directory, bounded by the upstream API.
    pub async fn sessions(
        &self,
        search: Option<&str>,
    ) -> Result<Vec<pocket_codex_host_svc::opencode::Session>> {
        Ok(self.client.sessions(search).await?)
    }

    /// Create an empty session and select it without sending a prompt.
    pub async fn create(&self, title: Option<&str>) -> Result<Snapshot> {
        let session = self.client.create(title).await?;
        self.open_session(&session.id).await
    }

    /// Return the currently selected session ID, if any.
    pub async fn selected_session(&self) -> Option<String> {
        self.state
            .lock()
            .await
            .snapshot
            .as_ref()
            .map(|snapshot| snapshot.session_id.clone())
    }

    /// Select a session and read its bounded tail. A newer selection wins over
    /// any response already in flight for the previous session.
    pub async fn open_session(&self, session_id: &str) -> Result<Snapshot> {
        let selection = {
            let mut state = self.state.lock().await;
            state.selection += 1;
            state.selection
        };
        let page = self.client.history(session_id, 20, None).await?;
        let statuses = self.client.status().await?;
        let status = match statuses.get(session_id) {
            Some(status) => status["type"]
                .as_str()
                .context("invalid OpenCode execution status")?,
            None => "idle",
        };
        ensure!(
            matches!(status, "idle" | "busy" | "retry"),
            "unsupported OpenCode execution status"
        );
        let permissions = self
            .client
            .permissions()
            .await?
            .into_iter()
            .filter(|request| request.session_id == session_id)
            .collect();
        let questions = self
            .client
            .questions()
            .await?
            .into_iter()
            .filter(|request| request.session_id == session_id)
            .collect();
        let mut state = self.state.lock().await;
        ensure!(state.selection == selection, "OpenCode session selection changed");
        let snapshot = Snapshot {
            session_id: session_id.into(),
            messages: page.messages,
            next_cursor: page.next_cursor,
            revision: selection,
            status: status.into(),
            permissions,
            questions,
        };
        state.snapshot = Some(snapshot.clone());
        Ok(snapshot)
    }

    /// Read the last accepted snapshot without contacting the upstream server.
    pub async fn snapshot(&self) -> Result<Snapshot> {
        self.state
            .lock()
            .await
            .snapshot
            .clone()
            .context("no OpenCode session selected")
    }

    /// Prepend one earlier page. Failed reads retain the last confirmed cursor
    /// so only an explicit retry can advance it.
    pub async fn older(&self, session_id: &str) -> Result<Snapshot> {
        let (selection, retained) = {
            let state = self.state.lock().await;
            (
                state.selection,
                state
                    .snapshot
                    .clone()
                    .context("no OpenCode session selected")?,
            )
        };
        ensure!(retained.session_id == session_id, "OpenCode session selection changed");
        let Some(cursor) = retained.next_cursor.as_deref() else { return Ok(retained) };
        let page = self.client.history(session_id, 20, Some(cursor)).await?;
        ensure!(
            page.next_cursor.as_deref() != Some(cursor),
            "OpenCode history cursor did not advance"
        );
        let mut state = self.state.lock().await;
        ensure!(state.selection == selection, "OpenCode session selection changed");
        let current = state
            .snapshot
            .as_mut()
            .context("no OpenCode session selected")?;
        if current.next_cursor != retained.next_cursor {
            return Ok(current.clone());
        }
        let mut messages: Vec<_> = page
            .messages
            .into_iter()
            .filter(|message| {
                !current
                    .messages
                    .iter()
                    .any(|existing| existing.info.id == message.info.id)
            })
            .collect();
        messages.extend(current.messages.iter().cloned());
        current.messages = messages;
        current.next_cursor = page.next_cursor;
        current.revision += 1;
        Ok(current.clone())
    }

    /// Submit a text continuation for the selected session.
    ///
    /// OpenCode's `204` response means only that the request was accepted. A
    /// transport failure is returned as an error and callers must reconcile
    /// history before offering a retry; this method never retries implicitly.
    pub async fn send(&self, session_id: &str, text: &str) -> Result<()> {
        let selected = self.state.lock().await.snapshot.clone();
        ensure!(
            selected
                .as_ref()
                .is_some_and(|snapshot| snapshot.session_id == session_id),
            "OpenCode session is not selected"
        );
        self.client
            .prompt(session_id, &PromptInput::text(text, None))
            .await?;
        Ok(())
    }

    /// Answer one currently pending permission request.
    pub async fn reply_permission(
        &self,
        request_id: &str,
        reply: PermissionReply,
        message: Option<&str>,
    ) -> Result<()> {
        self.client
            .reply_permission(request_id, reply, message)
            .await?;
        self.refresh_interactions().await
    }

    /// Answer one currently pending question request in the upstream order.
    pub async fn reply_question(&self, request_id: &str, answers: Vec<Vec<String>>) -> Result<()> {
        self.client.reply_question(request_id, answers).await?;
        self.refresh_interactions().await
    }

    /// Reject one currently pending question request.
    pub async fn reject_question(&self, request_id: &str) -> Result<()> {
        self.client.reject_question(request_id).await?;
        self.refresh_interactions().await
    }

    /// Abort execution for the selected session without stopping OpenCode.
    pub async fn abort(&self, session_id: &str) -> Result<()> {
        let selected = self.state.lock().await.snapshot.clone();
        ensure!(
            selected
                .as_ref()
                .is_some_and(|snapshot| snapshot.session_id == session_id),
            "OpenCode session is not selected"
        );
        self.client.abort(session_id).await?;
        Ok(())
    }

    /// Subscribe to the scoped upstream SSE stream.
    ///
    /// The stream is owned by the caller. Dropping it only closes this
    /// controller's HTTP connection and does not abort the OpenCode session.
    pub async fn events(&self) -> Result<OpenCodeEventStream> {
        Ok(self.client.events().await?)
    }

    async fn refresh_interactions(&self) -> Result<()> {
        let (session_id, revision) = {
            let state = self.state.lock().await;
            let snapshot = state
                .snapshot
                .as_ref()
                .context("no OpenCode session selected")?;
            (snapshot.session_id.clone(), snapshot.revision)
        };
        let permissions = self
            .client
            .permissions()
            .await?
            .into_iter()
            .filter(|request| request.session_id == session_id)
            .collect();
        let questions = self
            .client
            .questions()
            .await?
            .into_iter()
            .filter(|request| request.session_id == session_id)
            .collect();
        let mut state = self.state.lock().await;
        if let Some(snapshot) = state.snapshot.as_mut() {
            if snapshot.session_id == session_id && snapshot.revision == revision {
                snapshot.permissions = permissions;
                snapshot.questions = questions;
                snapshot.revision += 1;
            }
        }
        Ok(())
    }
}

/// Register an in-memory controller and return an opaque connection ID.
pub fn register(client: OpenCodeClient, relay_key: Option<String>) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    lock_connections().insert(id.clone(), ConnectionEntry {
        controller: Arc::new(OpenCodeController::new(client)),
        relay_key,
        event_tasks: Vec::new(),
    });
    id
}

/// Attach an SSE task to a connection so disconnect can release it.
pub fn track_event_task(id: &str, task: tokio::task::JoinHandle<()>) -> bool {
    let mut connections = lock_connections();
    let Some(entry) = connections.get_mut(id) else {
        task.abort();
        return false;
    };
    entry.event_tasks.push(task);
    true
}

/// Get a live controller by connection ID.
pub fn get(id: &str) -> Result<Arc<OpenCodeController>> {
    lock_connections()
        .get(id)
        .map(|entry| Arc::clone(&entry.controller))
        .context("OpenCode connection not found")
}

/// Remove a controller without touching the external OpenCode process.
pub fn disconnect(id: &str) {
    if let Some(entry) = lock_connections().remove(id) {
        for task in entry.event_tasks {
            task.abort();
        }
        if let Some(key) = entry.relay_key {
            crate::engine::runtime::unsubscribe_service(&key);
        }
    }
}

#[cfg(test)]
mod tests;

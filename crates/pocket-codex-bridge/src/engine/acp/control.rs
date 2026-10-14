//! Explicit writer transfer bound to the snapshot the user confirmed.

use anyhow::ensure;
use pocket_codex_host_svc::acp::session_control::SessionControl;

use super::*;

pub fn session_control(service_key: &str, session: &str) -> Result<SessionControl> {
    let link = conn(service_key)?;
    let identity = link.identity();
    let view = block(link.client.session_control(session, &identity))?;
    ensure!(
        view.session_id == session
            && view.host_id == identity.host_id.as_deref().unwrap_or("")
            && Some(view.generation) == identity.generation,
        "session control identity changed"
    );
    link.commit(&identity, |_| ()).ok_or_else(ops::superseded)?;
    Ok(view)
}

pub fn control_session(service_key: &str, view: SessionControl, action: &str) -> Result<()> {
    let link = conn(service_key)?;
    control_on_link(&link, view, action)
}

pub(super) fn control_on_link(link: &Link, view: SessionControl, action: &str) -> Result<()> {
    let expected = Identity {
        host_id: Some(view.host_id),
        generation: Some(view.generation),
    };
    link.commit(&expected, |_| ()).ok_or_else(ops::superseded)?;
    let session = &view.session_id;
    let body = match action {
        "acquire" if view.can_acquire => block(
            link.client.acquire_session(
                session,
                view.source_generation
                    .as_deref()
                    .context("missing native source generation")?,
                &expected,
            ),
        )?,
        "release" if view.can_release => block(link.client.release_session(session, &expected))?,
        "continue" if view.can_continue => {
            block(link.client.open_session(session, Some(&expected)))?
        },
        _ => bail!("this operation is not available; refresh session controls"),
    };
    ensure!(
        body["sessionId"].as_str() == Some(session),
        "session control returned another session"
    );
    ops::accept_history(link, &expected, &body, |shared| {
        if action == "release" {
            shared.sessions.remove(session);
        } else {
            shared.sessions.insert(session.to_owned(), body.clone());
        }
    })?;
    Ok(())
}

//! Native transcript follow consumes a stream permit, never a writer lease.

use super::*;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct FollowQuery {
    session_id: String,
    host_id: String,
    generation: u64,
}

pub(super) async fn status(
    State(state): State<ApiState>,
    Query(query): Query<FollowQuery>,
) -> Result<Json<Value>, ApiError> {
    if query.host_id != state.host.host_id() {
        return Err(ApiError(HostError::Stale));
    }
    let body = state
        .host
        .native_status(&query.session_id)
        .await
        .map_err(ApiError)?;
    if body["generation"].as_u64() != Some(query.generation) {
        return Err(ApiError(HostError::Stale));
    }
    Ok(Json(body))
}

pub(super) async fn follow(
    State(state): State<ApiState>,
    Query(query): Query<FollowQuery>,
) -> Response {
    if query.host_id != state.host.host_id() || query.session_id.len() > 1024 {
        return ApiError(HostError::Stale).into_response();
    }
    let Ok(permit) = state.streams.clone().try_acquire_owned() else {
        return (StatusCode::SERVICE_UNAVAILABLE, "too many event streams").into_response();
    };
    let (tx, rx) = mpsc::channel::<std::result::Result<Event, Infallible>>(4);
    tokio::spawn(async move {
        let _permit = permit;
        loop {
            let result = tokio::select! {
                () = tx.closed() => return,
                result = state.host.native_status(&query.session_id) => result,
            };
            let body = match result {
                Ok(body) if body["generation"].as_u64() == Some(query.generation) => body,
                _ => return,
            };
            // Heartbeats let the receiver release a disposed view even when
            // the transcript is unchanged. Only revisions trigger a re-read.
            if tx
                .send(Ok(Event::default().data(body.to_string())))
                .await
                .is_err()
            {
                return;
            }
            tokio::select! {
                () = tx.closed() => return,
                () = tokio::time::sleep(std::time::Duration::from_secs(2)) => {},
            }
        }
    });
    Sse::new(ReceiverStream::new(rx)).into_response()
}

//! Rewrite caller path slices, methods, queries and bodies for native V2.

use reqwest::Method;
use serde_json::{json, Value};

use super::{prompt, string, ClientError, Dialect};

pub(in super::super) struct Request {
    pub method: Method,
    pub path: Vec<String>,
    pub query: Vec<(String, String)>,
    pub body: Option<Value>,
}

impl Request {
    fn new(method: Method, path: &[&str], body: Option<Value>) -> Self {
        Self {
            method,
            path: std::iter::once("api")
                .chain(path.iter().copied())
                .map(str::to_owned)
                .collect(),
            query: Vec::new(),
            body,
        }
    }
}

pub(in super::super) struct Prepared {
    pub request: Request,
    pub preflights: Vec<(&'static str, Request)>,
}

pub(in super::super) fn prepare(
    dialect: &Dialect,
    method: Method,
    path: &[&str],
    directory: Option<&str>,
    query: &[(&str, &str)],
    body: Option<Value>,
) -> Result<Prepared, ClientError> {
    let mut request = Request::new(method.clone(), path, body);
    let mut preflights = Vec::new();
    let mut directory_key = None;
    match (method.as_str(), path) {
        ("GET", ["global", "health"]) => {
            request = Request::new(method, &["info"], None);
        },
        ("GET", ["global", "event"] | ["event"]) => {
            request = Request::new(method, &["event"], None);
        },
        ("GET", ["experimental", "session"] | ["session"]) => {
            request = Request::new(method, &["session"], None);
            directory_key = Some("directory");
        },
        ("GET", ["session", "status"]) => {
            request = Request::new(method, &["session", "active"], None);
        },
        ("POST", ["session"]) => {
            let mut location = json!({});
            if let Some(directory) = directory {
                location["directory"] = directory.into();
            }
            request.body = Some(json!({"location": location}));
        },
        ("GET", ["provider"] | ["model"] | ["model", "default"] | ["agent"] | ["command"]) => {
            directory_key = Some("location[directory]");
        },
        ("GET", ["permission"] | ["question"]) => {
            let target: &[&str] =
                if path[0] == "permission" { &["permission", "request"] } else { &["form"] };
            request = Request::new(method, target, None);
            directory_key = Some("location[directory]");
        },
        ("POST", ["session", session, action @ ("prompt_async" | "command")]) => {
            let input = request.body.as_ref().ok_or(ClientError::InvalidResponse)?;
            let command = *action == "command";
            let prompt = prompt::prepare(input, command)?;
            for (kind, body) in [("model", prompt.model), ("agent", prompt.agent)] {
                if let Some(body) = body {
                    preflights.push((
                        kind,
                        Request::new(Method::POST, &["session", session, kind], Some(body)),
                    ));
                }
            }
            request = Request::new(
                method,
                &["session", session, if command { "command" } else { "prompt" }],
                Some(prompt.body),
            );
        },
        ("POST", ["session", session, "abort"]) => {
            request = Request::new(method, &["session", session, "interrupt"], request.body);
        },
        ("POST", ["permission", id, "reply"]) => {
            let ids = dialect.ids()?;
            let session = &ids
                .permissions
                .get(*id)
                .ok_or(ClientError::PendingRequestUnavailable)?
                .value;
            let body = request.body.as_ref().ok_or(ClientError::InvalidResponse)?;
            let decision = string(body, "reply")?;
            request = Request::new(
                method,
                &["session", session, "permission", id, "reply"],
                Some(json!({"decision": decision})),
            );
        },
        ("POST", ["question", id, action @ ("reply" | "reject")]) => {
            let ids = dialect.ids()?;
            let form = &ids
                .forms
                .get(*id)
                .ok_or(ClientError::PendingRequestUnavailable)?
                .value;
            request = if *action == "reject" {
                Request::new(Method::DELETE, &["session", &form.session, "form", id], None)
            } else {
                let body = request.body.as_ref().ok_or(ClientError::InvalidResponse)?;
                Request::new(
                    method,
                    &["session", &form.session, "form", id, "reply"],
                    Some(form.answer(body)?),
                )
            };
        },
        _ => {},
    }
    for &(key, value) in query {
        if matches!(key, "directory" | "location[directory]") {
            continue;
        }
        let key = if matches!(path, ["session", _, "message"]) && key == "before" {
            "cursor"
        } else {
            key
        };
        request.query.push((key.into(), value.into()));
    }
    if let (Some(key), Some(directory)) = (directory_key, directory) {
        request.query.push((key.into(), directory.into()));
    }
    Ok(Prepared {
        request,
        preflights,
    })
}

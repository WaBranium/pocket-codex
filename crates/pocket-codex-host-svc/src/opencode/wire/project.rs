//! Project V2 JSON into the existing host, catalog and history shapes.

use std::collections::BTreeMap;

use serde_json::{json, Map, Value};

use super::{data, rows, string, ClientError, Dialect, Field, Form, Pending};

pub(in super::super) fn project(
    dialect: &Dialect,
    path: &[&str],
    directory: Option<&str>,
    value: Value,
) -> Result<Value, ClientError> {
    match path {
        ["global", "health"] => Ok(json!({"healthy": true, "version": string(&value, "version")?})),
        ["session"] | ["experimental", "session"] if value.get("cursor").is_some() || value["data"].is_array() => {
            rows(&value)?.iter().map(session).collect::<Result<Vec<_>, _>>().map(Value::Array)
        },
        ["session", "status"] => {
            let active = data(&value)?.as_object().ok_or(ClientError::InvalidResponse)?;
            Ok(Value::Object(active.keys().map(|id| (id.clone(), json!({"type": "busy"}))).collect()))
        },
        ["session"] | ["session", _] => session(data(&value)?),
        ["provider"] => catalog(&value),
        ["agent"] => rows(&value)?.iter().map(|agent| {
            let name = agent["id"].as_str().or_else(|| agent["name"].as_str())
                .ok_or(ClientError::InvalidResponse)?;
            Ok(json!({"name": name, "description": agent["description"], "hidden": agent["hidden"], "mode": agent["mode"]}))
        }).collect::<Result<Vec<_>, _>>().map(Value::Array),
        ["command"] => rows(&value)?.iter().map(|command| {
            Ok(json!({"name": string(command, "name")?, "description": command["description"],
                "source": command["source"], "hints": command["hints"]}))
        }).collect::<Result<Vec<_>, _>>().map(Value::Array),
        ["permission"] => permissions(dialect, directory, &value),
        ["question"] => forms(dialect, directory, &value),
        ["session", session, "message"] => rows(&value)?.iter().rev()
            .map(|item| message(item, session)).collect::<Result<Vec<_>, _>>().map(Value::Array),
        ["session", _, "abort"] => value["interrupted"].as_bool()
            .map(Value::Bool).ok_or(ClientError::InvalidResponse),
        ["session", _, "prompt_async" | "command"] | ["permission" | "question", _, _] if value.is_null() => Ok(json!({})),
        _ => Ok(value),
    }
}

pub(in super::super) fn next_cursor(value: &Value) -> Result<Option<String>, ClientError> {
    match value.pointer("/cursor/next") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(cursor)) if cursor.len() <= 4096 => Ok(Some(cursor.clone())),
        _ => Err(ClientError::InvalidResponse),
    }
}

fn session(value: &Value) -> Result<Value, ClientError> {
    Ok(json!({
        "id": string(value, "id")?,
        "directory": string(&value["location"], "directory")?,
        "title": value["title"].as_str().unwrap_or_default(),
        "parentID": value["parentID"],
        "time": value["time"],
    }))
}

fn catalog(value: &Value) -> Result<Value, ClientError> {
    let mut models = BTreeMap::<String, Map<String, Value>>::new();
    for model in rows(&value["models"])? {
        if model["status"] == "deprecated" || model["enabled"] == false {
            continue;
        }
        let provider = string(model, "providerID")?;
        let id = string(model, "id")?;
        let variants = model["variants"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|variant| Ok((string(variant, "id")?.to_owned(), json!({}))))
            .collect::<Result<Map<_, _>, ClientError>>()?;
        let image = model["capabilities"]["input"]
            .as_array()
            .is_some_and(|input| input.iter().any(|kind| kind == "image"));
        models.entry(provider.into()).or_default().insert(
            id.into(),
            json!({
                "id": id, "name": model["name"], "variants": variants,
                "capabilities": {"input": {"image": image}},
            }),
        );
    }
    let mut all = Vec::new();
    let mut connected = Vec::new();
    for provider in rows(&value["providers"])? {
        let id = string(provider, "id")?;
        if provider["activation"] != "disabled" {
            connected.push(id);
        }
        all.push(json!({"id": id, "name": provider["name"], "models": models.remove(id).unwrap_or_default()}));
    }
    let mut default = Map::new();
    let model = data(&value["default"])?;
    if !model.is_null() {
        default.insert(string(model, "providerID")?.into(), string(model, "id")?.into());
    }
    Ok(json!({"all": all, "connected": connected, "default": default}))
}

fn permissions(
    dialect: &Dialect,
    directory: Option<&str>,
    value: &Value,
) -> Result<Value, ClientError> {
    let mut projected = Vec::new();
    let mut pending = BTreeMap::new();
    for permission in rows(value)? {
        let id = string(permission, "id")?;
        let session = string(permission, "sessionID")?;
        projected.push(json!({"id": id, "sessionID": session,
            "permission": permission["action"], "patterns": permission["resources"],
            "always": permission.get("save").cloned().unwrap_or_else(|| json!([]))}));
        pending.insert(id.into(), Pending {
            directory: directory.map(str::to_owned),
            value: session.to_owned(),
        });
    }
    let mut ids = dialect.ids()?;
    ids.permissions
        .retain(|_, pending| directory.is_some() && pending.directory.as_deref() != directory);
    ids.permissions.extend(pending);
    Ok(Value::Array(projected))
}

fn forms(dialect: &Dialect, directory: Option<&str>, value: &Value) -> Result<Value, ClientError> {
    let mut projected = Vec::new();
    let mut pending = BTreeMap::new();
    for form in rows(value)? {
        let id = string(form, "id")?;
        let session = string(form, "sessionID")?;
        let fields = form["fields"]
            .as_array()
            .ok_or(ClientError::InvalidResponse)?;
        let choices = fields
            .iter()
            .map(choice)
            .collect::<Option<Vec<_>>>()
            .filter(|fields| !fields.is_empty());
        let questions = match &choices {
            Some(choices) => fields.iter().zip(choices).map(|(field, choice)| {
                json!({
                    "question": field["description"].as_str().or_else(|| field["title"].as_str()).unwrap_or(&choice.key),
                    "header": field["title"].as_str().unwrap_or(&choice.key),
                    "multiple": choice.multiple, "custom": false,
                    "options": field["options"].as_array().into_iter().flatten().map(|option| {
                        json!({"label": option["label"], "description": option["description"]})
                    }).collect::<Vec<_>>()
                })
            }).collect::<Vec<_>>(),
            None => vec![json!({"question": "This OpenCode form cannot be answered here. Reject it to continue.",
                "header": form["title"].as_str().unwrap_or("OpenCode form"),
                "multiple": false, "custom": true, "options": []})],
        };
        projected.push(json!({"id": id, "sessionID": session, "questions": questions}));
        pending.insert(id.into(), Pending {
            directory: directory.map(str::to_owned),
            value: Form {
                session: session.into(),
                fields: choices,
            },
        });
    }
    let mut ids = dialect.ids()?;
    ids.forms
        .retain(|_, pending| directory.is_some() && pending.directory.as_deref() != directory);
    ids.forms.extend(pending);
    Ok(Value::Array(projected))
}

fn choice(field: &Value) -> Option<Field> {
    let multiple = match field["type"].as_str()? {
        "multiselect" => true,
        "string" => false,
        _ => return None,
    };
    let options = field["options"]
        .as_array()?
        .iter()
        .map(|option| Some((option["label"].as_str()?.to_owned(), option.get("value")?.clone())))
        .collect::<Option<Vec<_>>>()?;
    Some(Field {
        key: field["key"].as_str()?.into(),
        multiple,
        options,
    })
}

fn message(value: &Value, session: &str) -> Result<Value, ClientError> {
    let id = string(value, "id")?;
    let kind = string(value, "type")?;
    let mut info = json!({"id": id, "sessionID": session, "role": if kind == "user" { "user" } else { "assistant" }, "time": value["time"]});
    for key in ["agent", "parentID", "finish", "cost", "tokens", "error"] {
        if let Some(value) = value.get(key) {
            info[key] = value.clone();
        }
    }
    if let Some(model) = value.get("model") {
        let mut model = model.clone();
        if let Some(id) = model.get("id").cloned() {
            model["modelID"] = id;
        }
        info["model"] = model;
    }
    let mut parts = Vec::new();
    match kind {
        "user" => {
            parts.push(part(
                &json!({"type": "text", "text": string(value, "text")?}),
                session,
                id,
                0,
            )?);
            for file in value["files"].as_array().into_iter().flatten() {
                if file["uri"].is_string() {
                    parts.push(file_part(file, session, id, parts.len()));
                }
            }
        },
        "assistant" => {
            let content = value["content"]
                .as_array()
                .ok_or(ClientError::InvalidResponse)?;
            for (index, content) in content.iter().enumerate() {
                parts.push(part(content, session, id, index)?);
            }
        },
        "file" if value["uri"].is_string() => parts.push(file_part(value, session, id, 0)),
        _ => parts.push(part(&json!({"type": "text", "text": kind}), session, id, 0)?),
    }
    Ok(json!({"info": info, "parts": parts}))
}

fn part(value: &Value, session: &str, message: &str, index: usize) -> Result<Value, ClientError> {
    let kind = string(value, "type")?;
    if kind == "file" && value["uri"].is_string() {
        return Ok(file_part(value, session, message, index));
    }
    let mut part = identity(value, session, message, index);
    match kind {
        "text" | "reasoning" => {
            part["type"] = kind.into();
            part["text"] = string(value, "text")?.into();
            part["time"] = time(&value["time"]);
        },
        "tool" => {
            part["type"] = "tool".into();
            part["callID"] = part["id"].clone();
            part["tool"] = string(value, "name")?.into();
            part["state"] = tool_state(value, session, message, index);
        },
        _ => {
            part["type"] = "text".into();
            part["text"] = kind.into();
        },
    }
    Ok(part)
}

fn identity(value: &Value, session: &str, message: &str, index: usize) -> Value {
    let id = value["id"]
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| format!("{message}:part:{index}"));
    json!({"id": id, "sessionID": session, "messageID": message})
}

fn file_part(value: &Value, session: &str, message: &str, index: usize) -> Value {
    let mut part = identity(value, session, message, index);
    part["type"] = "file".into();
    part["url"] = value["uri"].clone();
    part["mime"] = value["mime"].clone();
    part["filename"] = value["name"].clone();
    part
}

fn time(value: &Value) -> Value {
    let mut result = json!({});
    if let Some(start) = value.get("ran").or_else(|| value.get("created")) {
        result["start"] = start.clone();
    }
    if let Some(end) = value.get("completed") {
        result["end"] = end.clone();
    }
    result
}

fn tool_state(value: &Value, session: &str, message: &str, index: usize) -> Value {
    let state = &value["state"];
    let status =
        if state["status"] == "streaming" { json!("pending") } else { state["status"].clone() };
    let content = state["content"].as_array();
    let output = content
        .into_iter()
        .flatten()
        .filter(|part| part["type"] == "text")
        .filter_map(|part| part["text"].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    let mut projected = json!({"status": status, "input": state["input"],
        "title": state["title"], "output": output, "time": time(&value["time"])});
    if let Some(error) = state.get("error") {
        projected["error"] = error["message"]
            .as_str()
            .map(Value::from)
            .unwrap_or_else(|| error.clone());
    }
    let attachment_message = format!("{message}:tool:{index}");
    projected["attachments"] = Value::Array(
        content
            .into_iter()
            .flatten()
            .filter(|part| part["type"] == "file")
            .chain(state["attachments"].as_array().into_iter().flatten())
            .filter(|file| file["uri"].is_string())
            .enumerate()
            .map(|(index, file)| file_part(file, session, &attachment_message, index))
            .collect(),
    );
    projected
}

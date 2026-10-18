//! Pure prompt, command and selection body translations.

use serde_json::{json, Value};

use super::{string, ClientError};

pub(super) struct Prompt {
    pub body: Value,
    pub model: Option<Value>,
    pub agent: Option<Value>,
}

pub(super) fn prepare(body: &Value, command: bool) -> Result<Prompt, ClientError> {
    let parts = body["parts"]
        .as_array()
        .ok_or(ClientError::InvalidResponse)?;
    if parts.iter().any(|part| part["type"] == "file") {
        return Err(ClientError::UnsupportedAttachment);
    }
    let mut translated = if command {
        json!({
            "name": string(body, "command")?,
            "text": string(body, "arguments")?,
            "files": parts.iter().filter(|part| part["type"] == "file").collect::<Vec<_>>()
        })
    } else {
        let text = parts
            .iter()
            .filter(|part| part["type"] == "text")
            .map(|part| string(part, "text"))
            .collect::<Result<Vec<_>, _>>()?
            .join("\n");
        json!({"text": text})
    };
    if let Some(id) = body.get("messageID").filter(|_| !command) {
        translated["id"] = id.clone();
    }
    let model = body
        .get("model")
        .filter(|value| !value.is_null())
        .map(|model| {
            let (provider, id) = if let Some(key) = model.as_str() {
                key.split_once('/').ok_or(ClientError::InvalidResponse)?
            } else {
                (string(model, "providerID")?, string(model, "modelID")?)
            };
            let mut model = json!({"id": id, "providerID": provider});
            if let Some(variant) = body.get("variant").filter(|value| !value.is_null()) {
                model["variant"] = variant.clone();
            }
            Ok::<_, ClientError>(json!({"model": model}))
        })
        .transpose()?;
    let agent = body
        .get("agent")
        .filter(|value| !value.is_null())
        .map(|agent| json!({"agent": agent}));
    Ok(Prompt {
        body: translated,
        model,
        agent,
    })
}

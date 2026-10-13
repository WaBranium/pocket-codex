//! Public transcript content only; native reasoning and provider metadata stay
//! private.

use serde_json::Value;

use crate::acp::fold::{Item, ItemKind, Tool, Turn};

pub(super) struct Message {
    pub id: String,
    pub kind: String,
    pub data: Value,
}

pub(super) fn clip(text: &str, max: usize) -> (String, bool) {
    if text.len() <= max {
        return (text.into(), false);
    }
    let mut end = max;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    (format!("{}\n[… truncated]", &text[..end]), true)
}

fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or_default().to_owned()
}

fn item(id: String, kind: ItemKind, text: &str) -> Item {
    let (text, truncated) = clip(text, 128 * 1024);
    Item {
        id,
        kind,
        title: String::new(),
        text,
        images: vec![],
        tool: None,
        plan: None,
        message_id: None,
        truncated,
        text_full: truncated,
        omitted: vec![],
    }
}

fn omit(item: &mut Item, reason: &str) {
    item.truncated = true;
    if !item.omitted.iter().any(|known| known == reason) {
        item.omitted.push(reason.into());
    }
}

fn files(item: &mut Item, values: &Value) {
    for file in values.as_array().into_iter().flatten() {
        let url = file["url"].as_str().unwrap_or_default();
        if [
            "data:image/png;base64,",
            "data:image/jpeg;base64,",
            "data:image/gif;base64,",
            "data:image/webp;base64,",
        ]
        .iter()
        .any(|prefix| url.starts_with(prefix))
            && url.len() <= 512 * 1024
            && item.images.len() < 4
        {
            item.images.push(url.into());
        } else {
            // File paths and remote URLs are not automatic read authority.
            omit(item, "attachments");
        }
    }
}

fn tool(id: String, block: &Value) -> Item {
    let state = &block["state"];
    let mut result = item(id.clone(), ItemKind::ToolCall, "");
    let mut output = String::new();
    for part in state["content"].as_array().into_iter().flatten() {
        if part["type"] == "text" {
            if !output.is_empty() {
                output.push('\n');
            }
            output.push_str(&text(part, "text"));
        } else {
            omit(&mut result, "tool content");
        }
    }
    if state["status"] == "error" {
        output.push_str(&text(&state["error"], "message"));
    }
    let (output, cut) = clip(&output, 128 * 1024);
    result.text = output;
    if cut {
        omit(&mut result, "tool output");
    }
    result.title = clip(&text(block, "name"), 4096).0;
    let input = &state["input"];
    let input = if input.to_string().len() <= 64 * 1024 {
        Some(input.clone())
    } else {
        omit(&mut result, "input");
        None
    };
    files(&mut result, &state["attachments"]);
    result.tool = Some(Tool {
        call_id: text(block, "id"),
        kind: "other".into(),
        status: match state["status"].as_str() {
            Some("completed") => "completed",
            Some("error") => "failed",
            Some("running") => "in_progress",
            _ => "pending",
        }
        .into(),
        name: Some(result.title.clone()),
        raw_input: input,
        ..Tool::default()
    });
    result
}

fn project(message: &Message) -> Vec<Item> {
    let id = format!("opencode:{}", message.id);
    let data = &message.data;
    if data.is_null() {
        let mut result =
            item(id, ItemKind::AgentMessage, "[Message exceeds the local reader limit]");
        omit(&mut result, "content");
        return vec![result];
    }
    match message.kind.as_str() {
        "user" => {
            let mut result = item(id, ItemKind::UserMessage, &text(data, "text"));
            files(&mut result, &data["files"]);
            if data["omitted"] == true {
                omit(&mut result, "unsupported content");
            }
            vec![result]
        },
        "assistant" => {
            let mut items = Vec::new();
            for (index, part) in data["content"].as_array().into_iter().flatten().enumerate() {
                let part_id = format!("{id}:{index}");
                match part["type"].as_str() {
                    Some("text") => {
                        items.push(item(part_id, ItemKind::AgentMessage, &text(part, "text")))
                    },
                    Some("tool") => items.push(tool(part_id, part)),
                    Some("reasoning") => {},
                    _ => {
                        let mut notice = item(part_id, ItemKind::AgentMessage, "");
                        omit(&mut notice, "unsupported content");
                        items.push(notice);
                    },
                }
            }
            if data["files"]
                .as_array()
                .is_some_and(|files| !files.is_empty())
            {
                let mut attachments = item(format!("{id}:files"), ItemKind::AgentMessage, "");
                files(&mut attachments, &data["files"]);
                items.push(attachments);
            }
            if let Some(error) = data["error"]["message"].as_str() {
                items.push(item(format!("{id}:error"), ItemKind::AgentMessage, error));
            }
            items
        },
        "shell" => {
            let mut result = item(id.clone(), ItemKind::ToolCall, &text(data, "output"));
            result.title = clip(&text(data, "command"), 4096).0;
            result.tool = Some(Tool {
                call_id: text(data, "callID"),
                kind: "execute".into(),
                status: if data["time"]["completed"].is_null() {
                    "in_progress"
                } else {
                    "completed"
                }
                .into(),
                ..Tool::default()
            });
            vec![result]
        },
        "compaction" => vec![item(id, ItemKind::AgentMessage, "[Earlier context compacted]")],
        "system" | "synthetic" => vec![],
        "agent-switched" | "model-switched" => vec![],
        _ => {
            let mut result = item(id, ItemKind::AgentMessage, "");
            omit(&mut result, "unsupported message");
            vec![result]
        },
    }
}

pub(super) fn turns(messages: Vec<Message>) -> (Vec<Turn>, bool) {
    let mut turns: Vec<Turn> = Vec::new();
    let mut truncated = false;
    for message in messages {
        let items = project(&message);
        if message.kind == "user" || (turns.is_empty() && !items.is_empty()) {
            turns.push(Turn {
                id: format!("native:{}", message.id),
                items: vec![],
                outcome: None,
                replayed: true,
                next_item: 0,
                omitted: 0,
            });
        }
        if let Some(turn) = turns.last_mut() {
            for item in items {
                truncated |= item.truncated;
                if turn.items.len() < 4000 {
                    turn.items.push(item);
                } else {
                    turn.omitted += 1;
                    truncated = true;
                }
            }
        }
    }
    (turns, truncated)
}

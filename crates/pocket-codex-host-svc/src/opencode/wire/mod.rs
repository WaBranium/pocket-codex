//! Native V2 dialect at the existing client's request/response boundary.

mod project;
mod prompt;
mod route;

use std::{
    collections::BTreeMap,
    sync::{Arc, Mutex, MutexGuard},
};

pub(super) use project::{next_cursor, project};
pub(super) use route::{prepare, Prepared, Request};
use serde_json::{json, Map, Value};

use super::client::ClientError;

#[derive(Clone, Default)]
pub(super) struct Dialect {
    pub v2: bool,
    ids: Arc<Mutex<Ids>>,
}

impl Dialect {
    fn ids(&self) -> Result<MutexGuard<'_, Ids>, ClientError> {
        self.ids.lock().map_err(|_| ClientError::InvalidResponse)
    }
}

#[derive(Default)]
struct Ids {
    permissions: BTreeMap<String, Pending<String>>,
    forms: BTreeMap<String, Pending<Form>>,
}

struct Pending<T> {
    directory: Option<String>,
    value: T,
}

struct Form {
    session: String,
    fields: Option<Vec<Field>>,
}

struct Field {
    key: String,
    multiple: bool,
    options: Vec<(String, Value)>,
}

impl Form {
    fn answer(&self, body: &Value) -> Result<Value, ClientError> {
        let fields = self.fields.as_ref().ok_or(ClientError::UnsupportedForm)?;
        let answers = body["answers"]
            .as_array()
            .ok_or(ClientError::InvalidResponse)?;
        if fields.len() != answers.len() {
            return Err(ClientError::UnsupportedForm);
        }
        let mut answer = Map::new();
        for (field, labels) in fields.iter().zip(answers) {
            let labels = labels.as_array().ok_or(ClientError::UnsupportedForm)?;
            let values = labels
                .iter()
                .map(|label| {
                    field
                        .options
                        .iter()
                        .find(|(name, _)| label.as_str() == Some(name.as_str()))
                        .map(|(_, value)| value.clone())
                        .ok_or(ClientError::UnsupportedForm)
                })
                .collect::<Result<Vec<_>, _>>()?;
            let value = if field.multiple {
                Value::Array(values)
            } else if values.len() == 1 {
                values
                    .into_iter()
                    .next()
                    .ok_or(ClientError::UnsupportedForm)?
            } else {
                return Err(ClientError::UnsupportedForm);
            };
            answer.insert(field.key.clone(), value);
        }
        Ok(json!({"answer": answer}))
    }
}

fn string<'a>(value: &'a Value, key: &str) -> Result<&'a str, ClientError> {
    value[key].as_str().ok_or(ClientError::InvalidResponse)
}

fn data(value: &Value) -> Result<&Value, ClientError> {
    value.get("data").ok_or(ClientError::InvalidResponse)
}

fn rows(value: &Value) -> Result<&Vec<Value>, ClientError> {
    data(value)?.as_array().ok_or(ClientError::InvalidResponse)
}

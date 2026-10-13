//! Default model catalog for the OpenCode preset.
//!
//! OpenCode only offers the models its configuration (or the models.dev
//! database) declares, so a gateway provider configured with a `baseURL`
//! and key would otherwise show just the handful of models typed into its
//! config. For the `opencode` profile the host loads a small server plugin
//! (`opencode_catalog.mjs`) through one of OpenCode's own config layers. Its
//! `config` hook — which OpenCode runs before it builds providers from the
//! merged configuration — lists each such provider's `<baseURL>/models` and
//! adds the undeclared chat models, so every listed model reaches OpenCode's
//! own ACP `model` option.
//!
//! The layer only names the plugin (and where to write its report); it holds
//! no configuration, and no OpenCode file is modified. It goes into
//! `OPENCODE_CONFIG_CONTENT` (merged last), or — when the host's environment
//! already sets that — into a generated file named by `OPENCODE_CONFIG`
//! (merged after the global config). The user's own layer is passed on
//! untouched, and plugin lists from all layers are combined by OpenCode.
//! When both are set, or `OPENCODE_PURE` or the `--pure` argument disables
//! plugins, the catalog is reported unavailable with that reason and the
//! plugin file's URL, so it can be added to the user's own config instead.
//! The arguments are passed on verbatim either way.
//!
//! An instance's own provider (see `super::provider`) shares this layer but
//! is stricter: it must be the inline, last-merged layer (a user
//! `OPENCODE_CONFIG_CONTENT` refuses the launch), and its text may hold no
//! `{env:` / `{file:` directive, which OpenCode would expand in the raw text.
//!
//! The catalog's provider URL and key never pass through Pocket-Codex: the
//! plugin runs inside OpenCode and reads the configuration OpenCode resolved.
//! Its report holds only provider ids, counts and fixed reason codes, and is
//! validated again here before it is shown.

use std::{
    ffi::{OsStr, OsString},
    io::{Read, Write},
    path::{Path, PathBuf},
};

use serde::Deserialize;

use super::spec::AgentSpec;

/// The OpenCode environment variable holding an inline configuration layer.
pub const CONFIG_CONTENT_VAR: &str = "OPENCODE_CONFIG_CONTENT";
/// The OpenCode environment variable naming an extra configuration file.
pub const CONFIG_FILE_VAR: &str = "OPENCODE_CONFIG";
/// The OpenCode environment variable that disables plugins.
pub const PURE_VAR: &str = "OPENCODE_PURE";

/// The plugin's source.
pub const PLUGIN_SOURCE: &str = include_str!("opencode_catalog.mjs");

const PLUGIN_FILE: &str = "model-catalog-v1.mjs";
const PROFILE: &str = "opencode";
const MAX_REPORT_BYTES: u64 = 256 * 1024;
const MAX_PROVIDERS: usize = 64;
const MAX_PROVIDER_ID: usize = 128;

/// Why the catalog could not be attached to a launch.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unavailable {
    /// `OPENCODE_PURE` or the `--pure` argument disables every plugin.
    PluginsDisabled,
    /// `OPENCODE_CONFIG` and `OPENCODE_CONFIG_CONTENT` are both the user's.
    ConfigTaken,
    /// The plugin or its layer could not be written.
    Install,
}

impl Unavailable {
    /// Stable reason code.
    pub fn code(self) -> &'static str {
        match self {
            Self::PluginsDisabled => "plugins-disabled",
            Self::ConfigTaken => "config-env-taken",
            Self::Install => "install-failed",
        }
    }
}

/// The catalog attached to one agent: its launch environment and report.
/// Dropping it removes the files written for this launch (the shared
/// plugin file stays).
#[derive(Debug)]
pub struct Launch {
    env: Vec<(OsString, OsString)>,
    owned: Vec<PathBuf>,
    report: Option<PathBuf>,
    plugin: Option<String>,
    unavailable: Option<Unavailable>,
    /// Whether the layer carries an instance's own provider, whose route the
    /// plugin then enforces and reports.
    route: bool,
}

impl Drop for Launch {
    fn drop(&mut self) {
        for path in &self.owned {
            let _ = std::fs::remove_file(path);
        }
    }
}

/// What the catalog reported, safe to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CatalogStatus {
    /// `waiting` (no session opened yet), `reported` or `unavailable`.
    pub state: &'static str,
    /// Why it is unavailable.
    pub reason: Option<&'static str>,
    /// The plugin's `file://` URL, for adding it to a config by hand.
    pub plugin: Option<String>,
    /// One entry per listed provider, by id.
    pub providers: Vec<ProviderListing>,
    /// Whether OpenCode selected the instance's own provider; `None` without
    /// one.
    pub route: Option<RouteStatus>,
}

/// How the plugin's `config` hook left the instance's own provider in the
/// merged configuration (every layer, managed ones included) of each project
/// OpenCode loaded. The hook runs before OpenCode builds its providers from
/// that configuration, puts the host's route back where another layer
/// changed it and pins the supplied key in memory, ahead of a key stored for
/// the same id; it covers only what that hook sees (a plugin whose hook runs
/// later, or another plugin's provider loader, is outside it).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RouteStatus {
    /// `waiting` (no project configuration loaded yet), `selected` (nothing
    /// had to change), `enforced` (some setting was reset), `refused` (the
    /// key was missing in the agent's process, so no provider was left
    /// usable), `overridden` (an older plugin only reported it), or
    /// `unverified` (the plugin cannot run).
    pub state: &'static str,
    /// For `enforced` / `overridden`: what was reset or found (`model`,
    /// `small-model`, `agent-model`, `enabled-providers`,
    /// `disabled-providers`, `provider`, `missing`); for `refused`, `key`;
    /// for `unverified`, why ([`Unavailable::code`]).
    pub reasons: Vec<String>,
    /// The project directories this covers, as the plugin's input named
    /// them (not verified against OpenCode's source; empty when the report
    /// did not name them).
    pub projects: Vec<String>,
}

/// One provider's listing outcome.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderListing {
    /// The provider id from the OpenCode config.
    pub id: String,
    /// `complete`, `partial` (bounded), `failed` (nothing added) or
    /// `skipped`.
    pub status: String,
    /// Reason code (`http-401`, `timeout`, `model-limit`, …).
    pub reason: Option<String>,
    /// Chat models listed.
    pub listed: u32,
    /// Models added (listed and not already declared).
    pub added: u32,
    /// Entries left out for an explicit non-chat type.
    pub excluded: u32,
    /// Ids OpenCode cannot hold, left out.
    pub unsafe_ids: u32,
    /// Where the credential came from: `config`, `env`, `headers` or `none`.
    pub key_source: String,
}

/// Attach the catalog to a launch of `spec`, writing below `state_dir`.
/// `None` for agents other than OpenCode.
pub fn launch(spec: &AgentSpec, state_dir: &Path) -> Option<Launch> {
    // Without an extra layer `attach` never fails: every problem is an
    // unavailable catalog.
    attach(spec, state_dir, |name| std::env::var_os(OsStr::new(name)), None)
        .ok()
        .flatten()
}

/// Why an instance's own configuration layer could not be attached.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LayerError {
    /// `OPENCODE_CONFIG` and `OPENCODE_CONFIG_CONTENT` are both the user's.
    Taken,
    /// The generated layer file could not be written.
    Write,
    /// `OPENCODE_CONFIG_CONTENT` is the user's: the provider layer would not
    /// be the last one, so a project configuration could select another
    /// model or provider.
    ContentTaken,
    /// The layer text holds a substitution directive OpenCode would expand
    /// (`{env:`, `{file:`).
    Unsafe,
}

impl std::fmt::Display for LayerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Taken => {
                "this environment already sets both OPENCODE_CONFIG and OPENCODE_CONFIG_CONTENT, \
                 so the provider cannot be added; use the existing configuration or unset one of \
                 them"
            },
            Self::Write => "the provider configuration layer could not be written",
            Self::ContentTaken => {
                "this environment already sets OPENCODE_CONFIG_CONTENT, so the provider would not \
                 be OpenCode's last configuration layer; use the existing configuration or unset it"
            },
            Self::Unsafe => {
                "the provider configuration contains `{env:` or `{file:`, which OpenCode would \
                 expand; remove it from the base URL or model"
            },
        })
    }
}

impl std::error::Error for LayerError {}

/// [`launch`] with `extra` — the instance's own provider configuration (see
/// `super::provider`) — merged into the same layer. The provider layer goes
/// in even when plugins are disabled; when it cannot be placed at all, the
/// launch fails instead of starting without it.
pub fn launch_with(
    spec: &AgentSpec,
    state_dir: &Path,
    extra: serde_json::Map<String, serde_json::Value>,
) -> Result<Option<Launch>, LayerError> {
    attach(spec, state_dir, |name| std::env::var_os(OsStr::new(name)), Some(extra))
}

fn is_set(value: Option<OsString>) -> bool {
    value.is_some_and(|v| !v.is_empty())
}

/// Effect's boolean config parser, as OpenCode reads `OPENCODE_PURE`.
fn is_true(value: Option<OsString>) -> bool {
    value.and_then(|v| v.into_string().ok()).is_some_and(|v| {
        matches!(v.to_ascii_lowercase().as_str(), "true" | "yes" | "on" | "1" | "y")
    })
}

/// Whether `args` turn on OpenCode's global boolean `--pure` option, which
/// then sets `OPENCODE_PURE=1` for the process. This mirrors its yargs
/// parser: the last of `--pure`, `--pure true|false`, `--pure=<value>`
/// (true only for exactly `true`) and `--no-pure` wins, and nothing after a
/// `--` terminator is an option. A dash-led token is never another option's
/// value, so a bare `--pure` is always the flag; text that merely contains
/// `--pure` (`--cwd=/x/--pure`, `/x/--pure`) is not.
fn pure_flag(args: &[String]) -> bool {
    let mut pure = false;
    let mut args = args.iter().map(String::as_str).peekable();
    while let Some(arg) = args.next() {
        match arg {
            "--" => break,
            "--no-pure" => pure = false,
            "--pure" => {
                // A following literal `true` / `false` is the flag's value.
                pure = args.next_if(|next| matches!(*next, "true" | "false")) != Some("false");
            },
            _ => {
                if let Some(value) = arg.strip_prefix("--pure=") {
                    pure = value == "true";
                }
            },
        }
    }
    pure
}

/// The catalog (and `extra`, the instance's provider layer) for a launch of
/// `spec`. With no `extra` this never fails; a provider layer that cannot
/// be placed fails the launch.
fn attach(
    spec: &AgentSpec,
    state_dir: &Path,
    env: impl Fn(&str) -> Option<OsString>,
    extra: Option<serde_json::Map<String, serde_json::Value>>,
) -> Result<Option<Launch>, LayerError> {
    if spec.profile_id != PROFILE {
        return Ok(None);
    }
    let mut launch = Launch {
        env: Vec::new(),
        owned: Vec::new(),
        report: None,
        plugin: None,
        unavailable: None,
        route: false,
    };
    let mut layer = extra.unwrap_or_default();
    let provider = !layer.is_empty();
    launch.route = provider;
    // What the plugin puts back into OpenCode's merged configuration: the
    // provider id, its default model and its exact definition (which holds
    // no key: only the name of the child variable that carries it).
    let route = provider.then(|| {
        let own = layer
            .get("provider")
            .and_then(serde_json::Value::as_object)
            .and_then(|p| p.iter().next());
        serde_json::json!({
            "provider": own.map(|(id, _)| id),
            "model": layer.get("model"),
            "definition": own.map(|(_, definition)| definition),
        })
    });
    let content_free = !is_set(env(CONFIG_CONTENT_VAR));
    let file_free = !is_set(env(CONFIG_FILE_VAR));
    let dir = state_dir.join("opencode");
    let reports = dir.join("reports");
    let id = uuid::Uuid::new_v4();
    let plugin = install(&dir)
        .ok()
        .and_then(|file| url::Url::from_file_path(file).ok());
    match plugin {
        None => {
            tracing::warn!("OpenCode model catalog plugin unavailable");
            launch.unavailable = Some(Unavailable::Install);
        },
        Some(plugin) => {
            launch.plugin = Some(plugin.to_string());
            // `--no-pure` only leaves the variable alone; it never clears it.
            if is_true(env(PURE_VAR)) || pure_flag(&spec.args) {
                launch.unavailable = Some(Unavailable::PluginsDisabled);
            } else if !content_free && !file_free {
                launch.unavailable = Some(Unavailable::ConfigTaken);
            } else if std::fs::create_dir_all(&reports).is_err() {
                launch.unavailable = Some(Unavailable::Install);
            } else {
                let report = reports.join(format!("{id}.json"));
                let mut options = serde_json::json!({ "report": report.to_string_lossy() });
                if let Some(route) = route {
                    options["route"] = route;
                }
                layer.insert("plugin".into(), serde_json::json!([[plugin.as_str(), options]]));
                launch.owned.push(report.clone());
                launch.report = Some(report);
            }
        },
    }
    if layer.is_empty() {
        return Ok(Some(launch));
    }
    let text = serde_json::Value::Object(layer).to_string();
    if provider {
        // OpenCode substitutes these directives in the raw layer text
        // before parsing it (`config/variable.ts`), so none may appear.
        if has_directive(&text) {
            return Err(LayerError::Unsafe);
        }
        // Only the inline layer is merged after project configurations.
        if !content_free {
            return Err(if file_free { LayerError::ContentTaken } else { LayerError::Taken });
        }
    }
    if content_free {
        launch.env.push((CONFIG_CONTENT_VAR.into(), text.into()));
    } else if file_free {
        let file = reports.join(format!("{id}.config.json"));
        let written =
            std::fs::create_dir_all(&reports).and_then(|()| write_atomic(&file, text.as_bytes()));
        if written.is_err() {
            if provider {
                return Err(LayerError::Write);
            }
            launch.report = None;
            launch.unavailable = Some(Unavailable::Install);
            return Ok(Some(launch));
        }
        launch.owned.push(file.clone());
        launch
            .env
            .push((CONFIG_FILE_VAR.into(), file.into_os_string()));
    } else {
        // Only a provider layer gets here (the catalog alone was reported
        // `config-env-taken` above).
        return Err(LayerError::Taken);
    }
    Ok(Some(launch))
}

/// Whether `text` holds an OpenCode substitution directive.
fn has_directive(text: &str) -> bool {
    text.contains("{env:") || text.contains("{file:")
}

impl Launch {
    /// Child-only environment for the agent.
    pub fn env(&self) -> Vec<(OsString, OsString)> {
        self.env.clone()
    }

    /// The latest report (re-read on every call; it is small and bounded).
    pub fn status(&self) -> CatalogStatus {
        let mut status = CatalogStatus {
            state: "waiting",
            reason: None,
            plugin: self.plugin.clone(),
            providers: Vec::new(),
            route: self.route.then(|| RouteStatus {
                state: "waiting",
                reasons: Vec::new(),
                projects: Vec::new(),
            }),
        };
        if let Some(unavailable) = self.unavailable {
            status.state = "unavailable";
            status.reason = Some(unavailable.code());
            if let Some(route) = &mut status.route {
                route.state = "unverified";
                route.reasons = vec![unavailable.code().to_string()];
            }
            return status;
        }
        if let Some((providers, route)) = self.report.as_deref().and_then(read_report) {
            status.state = "reported";
            status.providers = providers;
            if let (Some(shown), Some(reported)) = (&mut status.route, route) {
                *shown = reported;
            }
        }
        status
    }
}

#[derive(Deserialize)]
struct RawReport {
    version: u32,
    providers: Vec<RawListing>,
    /// An older plugin's one launch-wide verdict.
    #[serde(default)]
    route: Option<RawRoute>,
    /// One verdict per project directory.
    #[serde(default)]
    routes: Vec<RawRoute>,
}

#[derive(Deserialize)]
struct RawRoute {
    state: String,
    reasons: Vec<String>,
    #[serde(default)]
    directory: Option<String>,
}

/// Reasons a route verdict may give, in display order.
const ROUTE_REASONS: [&str; 8] = [
    "key",
    "model",
    "small-model",
    "agent-model",
    "enabled-providers",
    "disabled-providers",
    "provider",
    "missing",
];

/// Most project directories one report names.
const MAX_ROUTE_PROJECTS: usize = 32;

/// A reported verdict, kept only when well formed.
fn route_of(raw: &RawRoute) -> Option<&'static str> {
    let state = match raw.state.as_str() {
        "selected" if raw.reasons.is_empty() => "selected",
        "enforced" if !raw.reasons.is_empty() => "enforced",
        "overridden" if !raw.reasons.is_empty() => "overridden",
        "refused" if raw.reasons == ["key"] => "refused",
        _ => return None,
    };
    let known = raw.reasons.len() <= ROUTE_REASONS.len()
        && raw
            .reasons
            .iter()
            .all(|r| ROUTE_REASONS.contains(&r.as_str()));
    let directory = raw
        .directory
        .as_deref()
        .is_none_or(|d| d.chars().count() <= 4096 && !d.chars().any(char::is_control));
    (known && directory).then_some(state)
}

/// The verdicts of every project in one: `refused` when any project was
/// refused, else `enforced` when any setting was reset anywhere, the reasons
/// of all of them. `None` when any is not well formed (nothing in such a
/// report is trusted) or there is none.
fn routes_of(raw: &[RawRoute]) -> Option<RouteStatus> {
    if raw.is_empty() || raw.len() > MAX_ROUTE_PROJECTS {
        return None;
    }
    let states = raw.iter().map(route_of).collect::<Option<Vec<_>>>()?;
    let state = ["refused", "enforced", "overridden"]
        .into_iter()
        .find(|s| states.contains(s))
        .unwrap_or("selected");
    let reasons = ROUTE_REASONS
        .iter()
        .filter(|reason| raw.iter().any(|r| r.reasons.iter().any(|x| x == *reason)))
        .map(|reason| reason.to_string())
        .collect();
    Some(RouteStatus {
        state,
        reasons,
        projects: raw.iter().filter_map(|r| r.directory.clone()).collect(),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawListing {
    id: String,
    status: String,
    reason: Option<String>,
    listed: u32,
    added: u32,
    excluded: u32,
    #[serde(rename = "unsafe")]
    unsafe_ids: u32,
    key_source: String,
}

fn code(text: &str) -> bool {
    !text.is_empty()
        && text.len() <= 32
        && text
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// A report written by the plugin, keeping only well-formed entries.
fn read_report(path: &Path) -> Option<(Vec<ProviderListing>, Option<RouteStatus>)> {
    let mut text = String::new();
    std::fs::File::open(path)
        .ok()?
        .take(MAX_REPORT_BYTES + 1)
        .read_to_string(&mut text)
        .ok()?;
    if text.len() as u64 > MAX_REPORT_BYTES {
        return None;
    }
    let raw: RawReport = serde_json::from_str(&text).ok()?;
    if raw.version != 1 {
        return None;
    }
    let route = match raw.routes.is_empty() {
        true => raw
            .route
            .as_ref()
            .and_then(|r| routes_of(std::slice::from_ref(r))),
        false => routes_of(&raw.routes),
    };
    let providers = raw
        .providers
        .into_iter()
        .filter(|p| {
            !p.id.is_empty()
                && p.id.chars().count() <= MAX_PROVIDER_ID
                && !p.id.chars().any(char::is_control)
                && matches!(p.status.as_str(), "complete" | "partial" | "failed" | "skipped")
                && p.reason.as_deref().is_none_or(code)
                && matches!(p.key_source.as_str(), "config" | "env" | "headers" | "none")
        })
        .take(MAX_PROVIDERS)
        .map(|p| ProviderListing {
            id: p.id,
            status: p.status,
            reason: p.reason,
            listed: p.listed,
            added: p.added,
            excluded: p.excluded,
            unsafe_ids: p.unsafe_ids,
            key_source: p.key_source,
        })
        .collect();
    Some((providers, route))
}

/// Replace `file` with `bytes` atomically.
fn write_atomic(file: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let dir = file.parent().unwrap_or(Path::new("."));
    let name = file
        .file_name()
        .unwrap_or(OsStr::new("file"))
        .to_string_lossy();
    let staging = dir.join(format!(".{name}.{}", uuid::Uuid::new_v4()));
    let written = std::fs::File::create(&staging)
        .and_then(|mut out| {
            out.write_all(bytes)?;
            out.sync_all()
        })
        .and_then(|()| std::fs::rename(&staging, file));
    if written.is_err() {
        let _ = std::fs::remove_file(&staging);
    }
    written
}

/// Write the plugin to `dir` unless an identical copy is already there.
fn install(dir: &Path) -> std::io::Result<PathBuf> {
    let file = dir.join(PLUGIN_FILE);
    if std::fs::read(&file).is_ok_and(|current| current == PLUGIN_SOURCE.as_bytes()) {
        return Ok(file);
    }
    std::fs::create_dir_all(dir)?;
    write_atomic(&file, PLUGIN_SOURCE.as_bytes())?;
    Ok(file)
}

#[cfg(test)]
#[path = "catalog_tests.rs"]
mod tests;

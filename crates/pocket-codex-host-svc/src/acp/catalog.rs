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
//! When both are set, or `OPENCODE_PURE` disables plugins, the catalog is
//! reported unavailable with that reason and the plugin file's URL, so it
//! can be added to the user's own config instead.
//!
//! The provider URL and key never pass through Pocket-Codex: the plugin runs
//! inside OpenCode and reads the configuration OpenCode resolved. Its report
//! holds only provider ids, counts and fixed reason codes, and is validated
//! again here before it is shown.

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
    /// `OPENCODE_PURE` disables every plugin.
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
    attach(spec, state_dir, |name| std::env::var_os(OsStr::new(name)))
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

fn attach(
    spec: &AgentSpec,
    state_dir: &Path,
    env: impl Fn(&str) -> Option<OsString>,
) -> Option<Launch> {
    if spec.profile_id != PROFILE {
        return None;
    }
    let mut launch = Launch {
        env: Vec::new(),
        owned: Vec::new(),
        report: None,
        plugin: None,
        unavailable: None,
    };
    let dir = state_dir.join("opencode");
    let plugin = install(&dir)
        .ok()
        .and_then(|file| url::Url::from_file_path(file).ok());
    let Some(plugin) = plugin else {
        tracing::warn!("OpenCode model catalog plugin unavailable");
        launch.unavailable = Some(Unavailable::Install);
        return Some(launch);
    };
    launch.plugin = Some(plugin.to_string());
    if is_true(env(PURE_VAR)) {
        launch.unavailable = Some(Unavailable::PluginsDisabled);
        return Some(launch);
    }
    let content_free = !is_set(env(CONFIG_CONTENT_VAR));
    if !content_free && is_set(env(CONFIG_FILE_VAR)) {
        launch.unavailable = Some(Unavailable::ConfigTaken);
        return Some(launch);
    }
    let reports = dir.join("reports");
    let id = uuid::Uuid::new_v4();
    let report = reports.join(format!("{id}.json"));
    let layer = serde_json::json!({
        "plugin": [[plugin.as_str(), { "report": report.to_string_lossy() }]],
    })
    .to_string();
    if std::fs::create_dir_all(&reports).is_err() {
        launch.unavailable = Some(Unavailable::Install);
        return Some(launch);
    }
    launch.owned.push(report.clone());
    launch.report = Some(report);
    if content_free {
        launch.env.push((CONFIG_CONTENT_VAR.into(), layer.into()));
    } else {
        let file = reports.join(format!("{id}.config.json"));
        if write_atomic(&file, layer.as_bytes()).is_err() {
            launch.report = None;
            launch.unavailable = Some(Unavailable::Install);
            return Some(launch);
        }
        launch.owned.push(file.clone());
        launch
            .env
            .push((CONFIG_FILE_VAR.into(), file.into_os_string()));
    }
    Some(launch)
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
        };
        if let Some(unavailable) = self.unavailable {
            status.state = "unavailable";
            status.reason = Some(unavailable.code());
            return status;
        }
        if let Some(providers) = self.report.as_deref().and_then(read_report) {
            status.state = "reported";
            status.providers = providers;
        }
        status
    }
}

#[derive(Deserialize)]
struct RawReport {
    version: u32,
    providers: Vec<RawListing>,
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
fn read_report(path: &Path) -> Option<Vec<ProviderListing>> {
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
    Some(providers)
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
mod tests {
    use std::collections::HashMap;

    use super::*;

    fn spec(profile: &str) -> AgentSpec {
        AgentSpec {
            profile_id: profile.into(),
            display_name: "Agent".into(),
            program: "opencode".into(),
            args: vec!["acp".into()],
        }
    }

    fn with_env(dir: &Path, profile: &str, vars: &[(&str, &str)]) -> Option<Launch> {
        let vars: HashMap<String, OsString> = vars
            .iter()
            .map(|(k, v)| (k.to_string(), OsString::from(v)))
            .collect();
        attach(&spec(profile), dir, |name| vars.get(name).cloned())
    }

    fn var<'a>(launch: &'a Launch, name: &str) -> Option<&'a OsString> {
        launch.env.iter().find(|(k, _)| k == name).map(|(_, v)| v)
    }

    /// The plugin spec of a layer: its file URL and report path.
    fn plugin_of(layer: &str) -> (String, PathBuf) {
        let layer: serde_json::Value = serde_json::from_str(layer).expect("json");
        assert_eq!(layer.as_object().map(|o| o.len()), Some(1), "only the plugin");
        let entry = &layer["plugin"][0];
        let url = entry[0].as_str().expect("url").to_string();
        let report = PathBuf::from(entry[1]["report"].as_str().expect("report"));
        (url, report)
    }

    #[test]
    fn a_free_environment_gets_an_inline_layer_naming_the_plugin() {
        let dir = tempfile::tempdir().expect("tempdir");
        let launch = with_env(dir.path(), "opencode", &[]).expect("opencode");
        assert_eq!(launch.env.len(), 1);
        let layer = var(&launch, CONFIG_CONTENT_VAR).expect("inline layer");
        let (url, report) = plugin_of(layer.to_str().expect("utf8"));
        let file = url::Url::parse(&url)
            .expect("url")
            .to_file_path()
            .expect("path");
        assert_eq!(std::fs::read_to_string(file).expect("plugin"), PLUGIN_SOURCE);
        assert!(report.starts_with(dir.path().join("opencode/reports")));
        let status = launch.status();
        assert_eq!(status.state, "waiting");
        assert_eq!(status.plugin.as_deref(), Some(url.as_str()));
    }

    #[test]
    fn a_users_inline_layer_is_kept_and_the_plugin_goes_into_a_file_layer() {
        let dir = tempfile::tempdir().expect("tempdir");
        let mine = r#"{"provider":{"gw":{"options":{"baseURL":"{env:GW_URL}"}}}}"#;
        let launch =
            with_env(dir.path(), "opencode", &[(CONFIG_CONTENT_VAR, mine)]).expect("opencode");
        assert!(var(&launch, CONFIG_CONTENT_VAR).is_none(), "passed on untouched");
        let file = PathBuf::from(var(&launch, CONFIG_FILE_VAR).expect("file layer"));
        let (_, report) = plugin_of(&std::fs::read_to_string(&file).expect("layer"));
        assert!(report.starts_with(dir.path().join("opencode/reports")));
        assert_eq!(launch.status().state, "waiting");
        // Empty values count as unset, as OpenCode reads them.
        let empty =
            with_env(dir.path(), "opencode", &[(CONFIG_CONTENT_VAR, ""), (CONFIG_FILE_VAR, "")])
                .expect("opencode");
        assert!(var(&empty, CONFIG_CONTENT_VAR).is_some());
    }

    #[test]
    fn both_layers_taken_or_plugins_disabled_is_reported_with_the_manual_path() {
        let dir = tempfile::tempdir().expect("tempdir");
        let taken = with_env(dir.path(), "opencode", &[
            (CONFIG_CONTENT_VAR, "{}"),
            (CONFIG_FILE_VAR, "/elsewhere/opencode.json"),
        ])
        .expect("opencode");
        assert!(taken.env.is_empty());
        let status = taken.status();
        assert_eq!((status.state, status.reason), ("unavailable", Some("config-env-taken")));
        assert!(status.plugin.is_some_and(|url| url.starts_with("file://")));
        for value in ["1", "true", "YES", "on"] {
            let pure = with_env(dir.path(), "opencode", &[(PURE_VAR, value)]).expect("opencode");
            assert!(pure.env.is_empty());
            assert_eq!(pure.status().reason, Some("plugins-disabled"));
        }
        let not_pure = with_env(dir.path(), "opencode", &[(PURE_VAR, "false")]).expect("opencode");
        assert_eq!(not_pure.env.len(), 1);
    }

    #[test]
    fn other_agents_get_nothing() {
        let dir = tempfile::tempdir().expect("tempdir");
        assert!(with_env(dir.path(), "claude", &[]).is_none());
        assert!(with_env(dir.path(), "custom-1", &[]).is_none());
        assert!(!dir.path().join("opencode").exists(), "nothing written");
    }

    #[test]
    fn a_stale_plugin_is_replaced_and_an_unwritable_dir_is_reported() {
        let dir = tempfile::tempdir().expect("tempdir");
        let target = dir.path().join("opencode");
        std::fs::create_dir_all(&target).expect("dir");
        std::fs::write(target.join(PLUGIN_FILE), "old").expect("write");
        assert_eq!(
            with_env(dir.path(), "opencode", &[])
                .expect("opencode")
                .env
                .len(),
            1
        );
        assert_eq!(std::fs::read_to_string(target.join(PLUGIN_FILE)).expect("read"), PLUGIN_SOURCE);
        let blocked = dir.path().join("blocked");
        std::fs::write(&blocked, "").expect("write");
        let launch = with_env(&blocked, "opencode", &[]).expect("opencode");
        assert!(launch.env.is_empty());
        assert_eq!(launch.status().reason, Some("install-failed"));
    }

    fn report_path(launch: &Launch) -> PathBuf {
        launch.report.clone().expect("report path")
    }

    #[test]
    fn reports_are_validated_before_they_are_shown() {
        let dir = tempfile::tempdir().expect("tempdir");
        let launch = with_env(dir.path(), "opencode", &[]).expect("opencode");
        let entry = |id: &str, status: &str, reason: serde_json::Value, key: &str| {
            serde_json::json!({
                "id": id, "status": status, "reason": reason, "listed": 83,
                "added": 81, "excluded": 1, "unsafe": 0, "keySource": key,
            })
        };
        let report = serde_json::json!({
            "version": 1,
            "providers": [
                entry("gw", "complete", serde_json::Value::Null, "config"),
                entry("partial-gw", "partial", "model-limit".into(), "env"),
                entry("header-gw", "failed", "http-401".into(), "headers"),
                entry("bad-status", "great", serde_json::Value::Null, "config"),
                entry("bad-reason", "failed", "https://gw.example/v1 401".into(), "none"),
                entry("bad\nid", "failed", "timeout".into(), "none"),
                entry("bad-key", "failed", "timeout".into(), "sk-secret"),
            ],
        });
        std::fs::write(report_path(&launch), report.to_string()).expect("write");
        let status = launch.status();
        assert_eq!(status.state, "reported");
        let ids: Vec<_> = status.providers.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, ["gw", "partial-gw", "header-gw"]);
        assert_eq!(status.providers[0].listed, 83);
        assert_eq!(status.providers[0].added, 81);
        assert_eq!(status.providers[1].reason.as_deref(), Some("model-limit"));

        for bad in [
            serde_json::json!({ "version": 2, "providers": [] }).to_string(),
            "not json".to_string(),
            " ".repeat(MAX_REPORT_BYTES as usize + 1),
        ] {
            std::fs::write(report_path(&launch), bad).expect("write");
            assert_eq!(launch.status().state, "waiting");
        }
    }

    #[test]
    fn each_launch_has_its_own_report_and_cleans_up_after_itself() {
        let dir = tempfile::tempdir().expect("tempdir");
        let first =
            with_env(dir.path(), "opencode", &[(CONFIG_CONTENT_VAR, "{}")]).expect("opencode");
        let second = with_env(dir.path(), "opencode", &[]).expect("opencode");
        std::fs::write(report_path(&first), r#"{"version":1,"providers":[]}"#).expect("write");
        assert_ne!(report_path(&first), report_path(&second));
        assert_eq!(second.status().state, "waiting", "no report carried over");
        let layer = PathBuf::from(var(&first, CONFIG_FILE_VAR).expect("file layer"));
        let report = report_path(&first);
        drop(first);
        assert!(!layer.exists() && !report.exists());
        assert!(dir.path().join("opencode").join(PLUGIN_FILE).exists(), "shared plugin stays");
    }
}

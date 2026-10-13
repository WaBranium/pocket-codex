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

fn attach_to(spec: &AgentSpec, dir: &Path, vars: &[(&str, &str)]) -> Option<Launch> {
    let vars: HashMap<String, OsString> = vars
        .iter()
        .map(|(k, v)| (k.to_string(), OsString::from(v)))
        .collect();
    attach(spec, dir, |name| vars.get(name).cloned(), None).expect("no layer never fails")
}

/// [`attach_to`] with a provider layer.
fn with_provider(
    dir: &Path,
    args: &[&str],
    vars: &[(&str, &str)],
) -> Result<Option<Launch>, LayerError> {
    let vars: HashMap<String, OsString> = vars
        .iter()
        .map(|(k, v)| (k.to_string(), OsString::from(v)))
        .collect();
    let spec = AgentSpec {
        args: args.iter().map(|a| a.to_string()).collect(),
        ..spec("opencode")
    };
    let mut extra = serde_json::Map::new();
    extra.insert("model".into(), "pocket-codex/m1".into());
    extra.insert("provider".into(), serde_json::json!({ "pocket-codex": {} }));
    attach(&spec, dir, |name| vars.get(name).cloned(), Some(extra))
}

#[test]
fn the_own_provider_route_is_reported_as_opencode_resolved_it() {
    let dir = tempfile::tempdir().expect("tempdir");
    let launch = with_provider(dir.path(), &["acp"], &[])
        .expect("ok")
        .expect("opencode");
    let layer = layer_of(&launch);
    let route = &layer["plugin"][0][1]["route"];
    assert_eq!(route["provider"], "pocket-codex");
    assert_eq!(route["model"], "pocket-codex/m1");
    assert_eq!(route["definition"], serde_json::json!({}), "the layer's own definition");
    let waiting = launch.status().route.expect("route");
    assert_eq!(waiting.state, "waiting");

    let write = |report: serde_json::Value| {
        std::fs::write(report_path(&launch), report.to_string()).expect("write");
        launch.status().route.expect("route")
    };
    let projects = |routes: serde_json::Value| {
        write(serde_json::json!({ "version": 1, "providers": [], "routes": routes }))
    };
    // Per project: one that needed nothing, one whose layers were reset.
    let both = projects(serde_json::json!([
        { "directory": "/work/a", "state": "selected", "reasons": [] },
        { "directory": "/work/b", "state": "enforced", "reasons": ["provider", "model"] },
    ]));
    assert_eq!(both.state, "enforced");
    assert_eq!(both.reasons, ["model", "provider"], "display order");
    assert_eq!(both.projects, ["/work/a", "/work/b"]);
    let only = projects(serde_json::json!([
        { "directory": "/work/a", "state": "selected", "reasons": [] },
    ]));
    assert_eq!((only.state, only.projects.len()), ("selected", 1));
    // A project whose key was missing outranks every other verdict.
    let refused = projects(serde_json::json!([
        { "directory": "/work/a", "state": "enforced", "reasons": ["model"] },
        { "directory": "/work/b", "state": "refused", "reasons": ["key"] },
    ]));
    assert_eq!(refused.state, "refused");
    assert_eq!(refused.reasons, ["key", "model"]);
    for bad in [
        serde_json::json!({ "state": "refused", "reasons": [] }),
        serde_json::json!({ "state": "refused", "reasons": ["model"] }),
    ] {
        assert_eq!(projects(serde_json::json!([bad])).state, "waiting");
    }
    // An older plugin's single verdict is still read.
    let legacy = write(serde_json::json!({
        "version": 1, "providers": [],
        "route": { "state": "overridden", "reasons": ["model", "enabled-providers"] },
    }));
    assert_eq!(legacy.state, "overridden");
    assert_eq!(legacy.reasons, ["model", "enabled-providers"]);
    assert!(legacy.projects.is_empty());
    // Anything else is not trusted: it stays waiting.
    for bad in [
        serde_json::json!({ "state": "selected", "reasons": ["model"] }),
        serde_json::json!({ "state": "enforced", "reasons": [] }),
        serde_json::json!({ "state": "enforced", "reasons": ["https://gw/v1"] }),
        serde_json::json!({ "state": "fine", "reasons": [] }),
        serde_json::json!({ "directory": "/a\nb", "state": "selected", "reasons": [] }),
    ] {
        let ok = serde_json::json!({ "directory": "/work/a", "state": "selected", "reasons": [] });
        assert_eq!(projects(serde_json::json!([ok, bad])).state, "waiting");
    }

    // Without the plugin nothing can check it: unverified, never selected.
    let pure = with_provider(dir.path(), &["acp", "--pure"], &[])
        .expect("ok")
        .expect("opencode");
    let unverified = pure.status().route.expect("route");
    assert_eq!(unverified.state, "unverified");
    assert_eq!(unverified.reasons, ["plugins-disabled"]);
    // The catalog alone has no route.
    let catalog = with_env(dir.path(), "opencode", &[]).expect("opencode");
    assert!(catalog.status().route.is_none());
}

fn layer_of(launch: &Launch) -> serde_json::Value {
    let text = match var(launch, CONFIG_CONTENT_VAR) {
        Some(inline) => inline.to_string_lossy().into_owned(),
        None => std::fs::read_to_string(var(launch, CONFIG_FILE_VAR).expect("file layer"))
            .expect("layer file"),
    };
    serde_json::from_str(&text).expect("json")
}

#[test]
fn a_provider_layer_shares_the_catalog_layer() {
    let dir = tempfile::tempdir().expect("tempdir");
    let launch = with_provider(dir.path(), &["acp"], &[])
        .expect("ok")
        .expect("opencode");
    let layer = layer_of(&launch);
    assert_eq!(layer["model"], "pocket-codex/m1");
    assert!(layer["plugin"].is_array(), "the catalog plugin too");
    assert_eq!(launch.env.len(), 1, "one layer");
}

#[test]
fn a_provider_layer_is_kept_without_plugins_and_refused_after_a_user_inline_layer() {
    let dir = tempfile::tempdir().expect("tempdir");
    let pure = with_provider(dir.path(), &["acp", "--pure"], &[])
        .expect("ok")
        .expect("opencode");
    let layer = layer_of(&pure);
    assert_eq!(layer["model"], "pocket-codex/m1");
    assert!(layer.get("plugin").is_none(), "no plugin under --pure");
    assert_eq!(pure.status().reason, Some("plugins-disabled"));
    // The user's inline layer would be merged after ours: refused, so a
    // project configuration can never silently select another model.
    let mine = with_provider(dir.path(), &["acp"], &[(CONFIG_CONTENT_VAR, "{}")]);
    assert_eq!(mine.err(), Some(LayerError::ContentTaken));
}

#[test]
fn a_provider_layer_with_a_substitution_directive_is_refused() {
    let dir = tempfile::tempdir().expect("tempdir");
    let spec = spec("opencode");
    for value in ["{env:HOME}", "x{file:/etc/passwd}"] {
        let mut extra = serde_json::Map::new();
        extra.insert("model".into(), value.into());
        let refused = attach(&spec, dir.path(), |_| None, Some(extra));
        assert_eq!(refused.err(), Some(LayerError::Unsafe), "{value}");
    }
}

#[test]
fn a_provider_layer_that_cannot_be_placed_fails_the_launch() {
    let dir = tempfile::tempdir().expect("tempdir");
    let taken = [(CONFIG_CONTENT_VAR, "{}"), (CONFIG_FILE_VAR, "/elsewhere/opencode.json")];
    assert_eq!(with_provider(dir.path(), &["acp"], &taken).err(), Some(LayerError::Taken));
    // Without a provider, the same environment only reports the catalog.
    let catalog = with_env(dir.path(), "opencode", &taken).expect("opencode");
    assert_eq!(catalog.status().reason, Some("config-env-taken"));
}

fn with_env(dir: &Path, profile: &str, vars: &[(&str, &str)]) -> Option<Launch> {
    attach_to(&spec(profile), dir, vars)
}

/// An OpenCode launch with `args` after the program.
fn with_args(dir: &Path, args: &[&str], vars: &[(&str, &str)]) -> Launch {
    let spec = AgentSpec {
        args: args.iter().map(|a| a.to_string()).collect(),
        ..spec("opencode")
    };
    attach_to(&spec, dir, vars).expect("opencode")
}

fn plugins_disabled(launch: &Launch) -> bool {
    let status = launch.status();
    let disabled = (status.state, status.reason) == ("unavailable", Some("plugins-disabled"));
    if disabled {
        assert!(launch.env.is_empty(), "nothing injected");
        assert!(launch.report.is_none(), "no report awaited");
        assert!(status.plugin.is_some_and(|url| url.starts_with("file://")));
    } else {
        assert_eq!(launch.env.len(), 1, "the layer is injected");
        assert_eq!(status.state, "waiting");
    }
    disabled
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
    let launch = with_env(dir.path(), "opencode", &[(CONFIG_CONTENT_VAR, mine)]).expect("opencode");
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
fn a_pure_argument_disables_the_catalog_as_opencode_parses_it() {
    let dir = tempfile::tempdir().expect("tempdir");
    let disabled: &[&[&str]] = &[
        &["acp", "--pure"],
        &["--pure", "acp"],
        &["acp", "--pure", "--cwd", "/p"],
        &["acp", "--cwd", "/p", "--pure"],
        &["acp", "--pure", "true"],
        &["acp", "--pure=true"],
        &["acp", "--no-pure", "--pure"],
        &["acp", "--pure=false", "--pure"],
        // A dash-led token is never the previous option's value.
        &["acp", "--cwd", "--pure"],
        &["acp", "--cors", "a", "--pure"],
    ];
    for args in disabled {
        assert!(plugins_disabled(&with_args(dir.path(), args, &[])), "{args:?}");
    }
    let attached: &[&[&str]] = &[
        &["acp"],
        &["acp", "--pure", "false"],
        &["acp", "--pure=false"],
        // yargs takes a boolean `=` value as true only when it is `true`.
        &["acp", "--pure=1"],
        &["acp", "--no-pure"],
        &["acp", "--pure", "--no-pure"],
        &["acp", "--pure", "false", "--cwd", "/p"],
        // Operands after the terminator, and values that contain the text.
        &["acp", "--", "--pure"],
        &["acp", "--cwd=/x/--pure"],
        &["acp", "--cwd", "/x/--pure"],
    ];
    for args in attached {
        assert!(!plugins_disabled(&with_args(dir.path(), args, &[])), "{args:?}");
    }
}

#[test]
fn the_pure_argument_and_variable_each_disable_the_catalog() {
    let dir = tempfile::tempdir().expect("tempdir");
    let on = [(PURE_VAR, "1")];
    let off = [(PURE_VAR, "false")];
    assert!(plugins_disabled(&with_args(dir.path(), &["acp", "--pure"], &off)));
    // `--no-pure` does not clear an inherited `OPENCODE_PURE`.
    assert!(plugins_disabled(&with_args(dir.path(), &["acp", "--no-pure"], &on)));
    assert!(plugins_disabled(&with_args(dir.path(), &["acp", "--pure=false"], &on)));
    // Disabled plugins are reported before a taken config layer.
    let taken = [(CONFIG_CONTENT_VAR, "{}"), (CONFIG_FILE_VAR, "/elsewhere/opencode.json")];
    assert!(plugins_disabled(&with_args(dir.path(), &["acp", "--pure"], &taken)));
    // A user's inline layer still gets the file layer without `--pure`.
    let mine = with_args(dir.path(), &["acp", "--no-pure"], &[(CONFIG_CONTENT_VAR, "{}")]);
    assert!(var(&mine, CONFIG_FILE_VAR).is_some());
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
    let first = with_env(dir.path(), "opencode", &[(CONFIG_CONTENT_VAR, "{}")]).expect("opencode");
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

//! An ACP agent's own model provider, for the agents whose actual
//! configuration mechanism is known. ACP itself has no provider schema, so
//! every other agent keeps its own configuration.
//!
//! - **OpenCode** reads providers from its config layers. The instance's
//!   provider goes into the host's inline layer (see [`super::catalog`]) under
//!   an id of the instance and its saved authority generation
//!   ([`opencode_provider_id`]). The generation is random and changes with the
//!   service, which makes an accidental match unlikely; nothing prevents
//!   another layer or a login stored with `opencode auth login` from naming the
//!   same id once it is known. The catalog plugin's `config` hook therefore
//!   installs exactly the host's definition, pins the supplied key in memory as
//!   `options.apiKey` (which OpenCode's SDK options take before the
//!   stored-login `provider.key`), refuses the route when that key is missing,
//!   and resets `model` and the provider filters (`enabled_providers` /
//!   `disabled_providers`), reporting what it reset (see
//!   [`super::catalog::RouteStatus`]). Another plugin's own provider or auth
//!   loader for the same id, and a later plugin's hook, stay outside it.
//!   Without the plugin (`--pure`) the route is reported unverified. Its AI SDK
//!   package matches the protocol (`@ai-sdk/openai` for Responses,
//!   `@ai-sdk/anthropic` for Messages, `@ai-sdk/openai-compatible` for Chat
//!   Completions). The key is never written into the layer, not even as an
//!   `{env:…}` reference: OpenCode expands those into the raw text before
//!   parsing it, so a key holding a quote or a `{file:…}` directive would
//!   rewrite the configuration (`config/variable.ts`). Instead the provider's
//!   `env` names one child-only variable, which OpenCode reads as the provider
//!   key (`provider/provider.ts`, "load env"). A default model is required and
//!   selected, or OpenCode's own `model` (another provider) would stay active.
//! - **The Claude adapter** passes its process environment to Claude Code
//!   (`claude-agent-acp` 0.89.1 `dist/acp-agent.js`, the query's `env` is
//!   `{...process.env, ...options.env, …}`), but Claude Code applies the `env`
//!   of user and project `settings.json` after it. So the route also goes into
//!   each session's programmatic settings tier
//!   (`_meta.claudeCode.options.settings`, see
//!   [`AcpProviderLaunch::session_meta`]), the tier the adapter itself uses for
//!   its own provider routes. Anthropic Messages only, with a required key (no
//!   sign-in of the user's may reach another endpoint): `ANTHROPIC_BASE_URL`
//!   and `ANTHROPIC_API_KEY`, the other routing variables reset the way the
//!   adapter's own `createEnvForProvider` resets them (including
//!   `ANTHROPIC_CUSTOM_HEADERS`, so no inherited credential header reaches the
//!   new provider), and `apiKeyHelper` cleared.

use std::ffi::OsString;

use pocket_codex_core::provider::{ApiProtocol, ProviderEndpoint};
use serde_json::{json, Map, Value};

use super::{claude, spec::AgentSpec};

/// Prefix of the OpenCode provider id of an instance's own provider.
pub const OPENCODE_PROVIDER_ID: &str = "pocket-codex";

/// The child environment variable holding the key OpenCode's provider names
/// in its `env`.
pub const OPENCODE_KEY_VAR: &str = "POCKET_CODEX_PROVIDER_KEY";

const OPENCODE_PROFILE: &str = "opencode";

/// The OpenCode provider id of `instance`'s own provider under the saved
/// `authority` generation: the prefix, the instance name in hex and the
/// generation's letters, digits and dashes (never a `/`, which separates a
/// model id).
pub fn opencode_provider_id(instance: &str, authority: &str) -> String {
    let mut id = String::with_capacity(
        OPENCODE_PROVIDER_ID.len() + 2 + instance.len() * 2 + authority.len(),
    );
    id.push_str(OPENCODE_PROVIDER_ID);
    id.push('-');
    for byte in instance.bytes() {
        id.push_str(&format!("{byte:02x}"));
    }
    id.push('-');
    id.extend(
        authority
            .chars()
            .filter(|c| c.is_ascii_alphanumeric() || *c == '-')
            .map(|c| c.to_ascii_lowercase()),
    );
    id
}

/// What an agent's launch gets for its provider.
#[derive(Clone, Default)]
pub struct AcpProviderLaunch {
    /// OpenCode: the keys to merge into the host's config layer.
    pub layer: Option<Map<String, Value>>,
    /// Child-only environment (it may hold the key).
    pub env: Vec<(OsString, OsString)>,
    /// Claude: `_meta` merged into every `session/new`, `session/load` and
    /// `session/resume` request (it holds the key; it travels only on the
    /// agent's own stdio pipe).
    pub session_meta: Option<Map<String, Value>>,
}

impl std::fmt::Debug for AcpProviderLaunch {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The environment and the session `_meta` may hold the key: only
        // names are shown.
        let names: Vec<_> = self.env.iter().map(|(k, _)| k).collect();
        f.debug_struct("AcpProviderLaunch")
            .field("layer", &self.layer)
            .field("env", &names)
            .field("session_meta", &self.session_meta.as_ref().map(|_| "[redacted]"))
            .finish()
    }
}

/// Why an agent cannot use a provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderError {
    /// This agent has no known provider mechanism.
    Unsupported,
    /// This agent cannot speak this protocol.
    Protocol(ApiProtocol),
    /// This agent needs a default model to select the provider.
    ModelRequired,
    /// This agent needs a key (it would otherwise send its own sign-in).
    KeyRequired,
    /// The base URL or model holds text the agent would expand or reject.
    Unsafe,
}

impl std::fmt::Display for ProviderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported => f.write_str(
                "this agent has no supported provider configuration; it uses its own configuration",
            ),
            Self::Protocol(protocol) => {
                write!(f, "this agent cannot use a `{protocol}` provider; choose another agent")
            },
            Self::ModelRequired => f.write_str(
                "this agent needs the provider's default model, or it keeps using its own model",
            ),
            Self::KeyRequired => f.write_str(
                "this agent needs the provider's key, or it would send its own sign-in to the \
                 provider",
            ),
            Self::Unsafe => f.write_str(
                "the base URL or model contains `{`, `}`, `$` or a control character, which the \
                 agent would expand; remove it",
            ),
        }
    }
}

impl std::error::Error for ProviderError {}

/// The protocols `spec`'s agent can use with an instance provider; empty
/// for agents without a known mechanism.
pub fn supported_protocols(spec: &AgentSpec) -> &'static [ApiProtocol] {
    if spec.profile_id == OPENCODE_PROFILE {
        &ApiProtocol::ALL
    } else if spec.profile_id == claude::PROFILE_ID {
        // The Claude preset, with its bare adapter or an explicit path to it.
        &[ApiProtocol::AnthropicMessages]
    } else {
        &[]
    }
}

/// What a custom provider of `spec`'s agent must name: (a default model,
/// a key). OpenCode needs the model, or the user's own default model of
/// another provider stays selected; Claude needs the key, or its own
/// sign-in would be sent to the gateway.
pub fn requirements(spec: &AgentSpec) -> (bool, bool) {
    (spec.profile_id == OPENCODE_PROFILE, spec.profile_id == claude::PROFILE_ID)
}

/// Whether `value` holds substitution syntax (`{env:}`, `${VAR}`) or a
/// control character.
fn unsafe_text(value: &str) -> bool {
    value
        .chars()
        .any(|c| matches!(c, '{' | '}' | '$') || c.is_control())
}

/// The provider launch of `spec` for `endpoint`, for the host `instance`
/// (its canonical name) under its saved `authority` generation.
pub fn launch(
    spec: &AgentSpec,
    endpoint: &ProviderEndpoint,
    instance: &str,
    authority: &str,
) -> Result<AcpProviderLaunch, ProviderError> {
    let supported = supported_protocols(spec);
    if supported.is_empty() {
        return Err(ProviderError::Unsupported);
    }
    if !supported.contains(&endpoint.protocol) {
        return Err(ProviderError::Protocol(endpoint.protocol));
    }
    let model = endpoint.model.as_deref().filter(|m| !m.is_empty());
    if unsafe_text(&endpoint.base_url) || model.is_some_and(unsafe_text) {
        return Err(ProviderError::Unsafe);
    }
    let key = endpoint
        .key
        .as_ref()
        .map(|k| k.expose())
        .filter(|k| !k.is_empty());
    if spec.profile_id == OPENCODE_PROFILE {
        let model = model.ok_or(ProviderError::ModelRequired)?;
        return Ok(opencode(endpoint, model, key, &opencode_provider_id(instance, authority)));
    }
    let key = key.ok_or(ProviderError::KeyRequired)?;
    Ok(claude_route(endpoint, model, key))
}

fn opencode(
    endpoint: &ProviderEndpoint,
    model: &str,
    key: Option<&str>,
    id: &str,
) -> AcpProviderLaunch {
    let npm = match endpoint.protocol {
        ApiProtocol::Responses => "@ai-sdk/openai",
        ApiProtocol::AnthropicMessages => "@ai-sdk/anthropic",
        ApiProtocol::ChatCompletions => "@ai-sdk/openai-compatible",
    };
    let mut env = Vec::new();
    let names: Vec<&str> = match key {
        Some(key) => {
            env.push((OsString::from(OPENCODE_KEY_VAR), OsString::from(key)));
            vec![OPENCODE_KEY_VAR]
        },
        // An explicit empty list: no variable of the user's names this
        // provider's key.
        None => Vec::new(),
    };
    let provider = json!({
        "npm": npm,
        "name": "Pocket-Codex provider",
        "env": names,
        "options": { "baseURL": endpoint.base_url },
        // Declared, so it is offered even without a `/models` listing.
        "models": { model: {} },
    });
    let mut layer = Map::new();
    layer.insert("model".into(), Value::String(format!("{id}/{model}")));
    layer.insert("provider".into(), json!({ id: provider }));
    AcpProviderLaunch {
        layer: Some(layer),
        env,
        session_meta: None,
    }
}

fn claude_route(endpoint: &ProviderEndpoint, model: Option<&str>, key: &str) -> AcpProviderLaunch {
    let mut route: Vec<(&str, &str)> = vec![
        // The routing reset of the adapter's own provider override.
        ("ANTHROPIC_AUTH_TOKEN", ""),
        ("ANTHROPIC_BEDROCK_BASE_URL", ""),
        ("ANTHROPIC_VERTEX_BASE_URL", ""),
        ("ANTHROPIC_VERTEX_PROJECT_ID", ""),
        ("CLAUDE_CODE_USE_BEDROCK", "0"),
        ("CLAUDE_CODE_USE_VERTEX", "0"),
        ("CLAUDE_CODE_OAUTH_TOKEN", ""),
        // Inherited headers may carry another account's credential.
        ("ANTHROPIC_CUSTOM_HEADERS", ""),
        ("ANTHROPIC_BASE_URL", endpoint.base_url.as_str()),
        ("ANTHROPIC_API_KEY", key),
    ];
    if let Some(model) = model {
        route.push(("ANTHROPIC_MODEL", model));
    }
    let env = route
        .iter()
        .map(|(k, v)| (OsString::from(k), OsString::from(v)))
        .collect();
    let values: Map<String, Value> = route
        .iter()
        .map(|(k, v)| ((*k).to_string(), Value::String((*v).to_string())))
        .collect();
    let options = json!({
        "env": values,
        "settings": { "apiKeyHelper": "", "env": values },
    });
    let mut meta = Map::new();
    meta.insert("claudeCode".into(), json!({ "options": options }));
    AcpProviderLaunch {
        layer: None,
        env,
        session_meta: Some(meta),
    }
}

#[cfg(test)]
mod tests {
    use pocket_codex_core::provider::Secret;

    use super::*;

    fn spec(profile: &str, program: &str) -> AgentSpec {
        AgentSpec {
            profile_id: profile.into(),
            display_name: "Agent".into(),
            program: program.into(),
            args: vec!["acp".into()],
        }
    }

    fn endpoint(protocol: ApiProtocol) -> ProviderEndpoint {
        ProviderEndpoint {
            protocol,
            base_url: "https://gw.example.com/v1".into(),
            key: Some(Secret::new("sk-acp")),
            model: Some("m1".into()),
        }
    }

    const INSTANCE: &str = "oc";
    const AUTHORITY: &str = "0f1e2d3c-AAAA-4bbb-8ccc-123456789abc";

    fn provider_id() -> String {
        opencode_provider_id(INSTANCE, AUTHORITY)
    }

    fn launch(
        spec: &AgentSpec,
        endpoint: &ProviderEndpoint,
        instance: &str,
    ) -> Result<AcpProviderLaunch, ProviderError> {
        super::launch(spec, endpoint, instance, AUTHORITY)
    }

    #[test]
    fn opencode_gets_the_matching_sdk_package_and_an_env_name_only() {
        let opencode = spec("opencode", "opencode");
        assert_eq!(provider_id(), "pocket-codex-6f63-0f1e2d3c-aaaa-4bbb-8ccc-123456789abc");
        for (protocol, npm) in [
            (ApiProtocol::Responses, "@ai-sdk/openai"),
            (ApiProtocol::AnthropicMessages, "@ai-sdk/anthropic"),
            (ApiProtocol::ChatCompletions, "@ai-sdk/openai-compatible"),
        ] {
            let launch = launch(&opencode, &endpoint(protocol), INSTANCE).expect("supported");
            let layer = Value::Object(launch.layer.clone().expect("layer"));
            let provider = &layer["provider"][provider_id()];
            assert_eq!(provider["npm"], npm);
            assert_eq!(provider["options"]["baseURL"], "https://gw.example.com/v1");
            assert!(provider["options"].get("apiKey").is_none(), "no key template");
            assert_eq!(provider["env"], json!([OPENCODE_KEY_VAR]));
            assert!(provider["models"]["m1"].is_object());
            assert_eq!(layer["model"], format!("{}/m1", provider_id()));
            assert!(!layer.to_string().contains("sk-acp"), "no secret in the layer");
            assert!(!layer.to_string().contains("{env:"), "no substitution directive");
            assert_eq!(launch.env, [(OsString::from(OPENCODE_KEY_VAR), OsString::from("sk-acp"))]);
            assert!(launch.session_meta.is_none());
            assert!(!format!("{launch:?}").contains("sk-acp"));
        }
    }

    #[test]
    fn keys_that_look_like_configuration_never_reach_the_layer() {
        let opencode = spec("opencode", "opencode");
        for raw in ["a\"b", "back\\slash", "line\nbreak", "{file:/etc/passwd}", "{env:HOME}"] {
            let mut tricky = endpoint(ApiProtocol::Responses);
            tricky.key = Some(Secret::new(raw));
            let launch = launch(&opencode, &tricky, INSTANCE).expect("any key text is data");
            let text = Value::Object(launch.layer.clone().expect("layer")).to_string();
            assert!(!text.contains(raw), "{raw:?} stays out of the layer");
            assert_eq!(launch.env[0].1, OsString::from(raw), "only the child env holds it");
        }
    }

    #[test]
    fn opencode_needs_a_default_model_and_no_substitution_syntax() {
        let opencode = spec("opencode", "opencode");
        let mut no_model = endpoint(ApiProtocol::Responses);
        no_model.model = None;
        assert_eq!(
            launch(&opencode, &no_model, INSTANCE).err(),
            Some(ProviderError::ModelRequired)
        );
        assert_eq!(requirements(&opencode), (true, false));
        for (url, model) in [
            ("https://gw.example.com/${HOME}", "m1"),
            ("https://gw.example.com/v1", "{env:HOME}"),
            ("https://gw.example.com/v1", "m}1"),
            ("https://gw.example.com/v1", "m\n1"),
        ] {
            let mut bad = endpoint(ApiProtocol::Responses);
            bad.base_url = url.into();
            bad.model = Some(model.into());
            assert_eq!(launch(&opencode, &bad, INSTANCE).err(), Some(ProviderError::Unsafe));
        }
    }

    #[test]
    fn each_instance_has_its_own_opencode_provider() {
        let opencode = spec("opencode", "opencode");
        let one = launch(&opencode, &endpoint(ApiProtocol::Responses), "one").expect("one");
        let two = launch(&opencode, &endpoint(ApiProtocol::Responses), "two").expect("two");
        assert_ne!(one.layer, two.layer);
        assert!(!opencode_provider_id("a/b", "x/y").contains('/'));
    }

    #[test]
    fn a_users_provider_of_the_old_per_name_id_never_merges_into_ours() {
        // A user table (or `opencode auth` entry) under the name-only id a
        // host would have used before cannot be our provider: the id also
        // carries the random authority generation, and moves with it.
        let opencode = spec("opencode", "opencode");
        let ours = launch(&opencode, &endpoint(ApiProtocol::Responses), INSTANCE).expect("ok");
        let layer = Value::Object(ours.layer.expect("layer"));
        let ids: Vec<&String> = layer["provider"]
            .as_object()
            .expect("providers")
            .keys()
            .collect();
        assert_eq!(ids, [&provider_id()]);
        assert_ne!(provider_id(), format!("{OPENCODE_PROVIDER_ID}-6f63"));
        let moved = super::launch(&opencode, &endpoint(ApiProtocol::Responses), INSTANCE, "b2")
            .expect("ok");
        let moved = Value::Object(moved.layer.expect("layer"));
        assert!(moved["provider"].get(provider_id()).is_none(), "a new generation, a new id");
    }

    #[test]
    fn claude_takes_anthropic_messages_through_env_and_session_settings() {
        let claude = spec(claude::PROFILE_ID, claude::ADAPTER_BIN);
        let launch = launch(&claude, &endpoint(ApiProtocol::AnthropicMessages), "cl").expect("ok");
        assert!(launch.layer.is_none());
        let get = |name: &str| {
            launch
                .env
                .iter()
                .find(|(k, _)| k == name)
                .map(|(_, v)| v.to_string_lossy().into_owned())
        };
        assert_eq!(get("ANTHROPIC_BASE_URL").as_deref(), Some("https://gw.example.com/v1"));
        assert_eq!(get("ANTHROPIC_API_KEY").as_deref(), Some("sk-acp"));
        assert_eq!(get("ANTHROPIC_AUTH_TOKEN").as_deref(), Some(""));
        assert_eq!(get("CLAUDE_CODE_USE_BEDROCK").as_deref(), Some("0"));
        // An inherited dummy credential header is replaced, not passed on.
        assert_eq!(get("ANTHROPIC_CUSTOM_HEADERS").as_deref(), Some(""));
        assert_eq!(get("ANTHROPIC_MODEL").as_deref(), Some("m1"));
        let meta = Value::Object(launch.session_meta.clone().expect("session meta"));
        let options = &meta["claudeCode"]["options"];
        let settings = &options["settings"];
        assert_eq!(settings["apiKeyHelper"], "");
        assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], "https://gw.example.com/v1");
        assert_eq!(settings["env"]["ANTHROPIC_API_KEY"], "sk-acp");
        assert_eq!(settings["env"]["CLAUDE_CODE_OAUTH_TOKEN"], "");
        assert_eq!(settings["env"]["ANTHROPIC_CUSTOM_HEADERS"], "");
        assert_eq!(options["env"], settings["env"]);
        assert!(!format!("{launch:?}").contains("sk-acp"), "meta is redacted too");
        for protocol in [ApiProtocol::Responses, ApiProtocol::ChatCompletions] {
            assert_eq!(
                super::launch(&claude, &endpoint(protocol), "cl", AUTHORITY).err(),
                Some(ProviderError::Protocol(protocol))
            );
        }
    }

    #[test]
    fn claude_refuses_a_keyless_provider() {
        let claude = spec(claude::PROFILE_ID, claude::ADAPTER_BIN);
        for key in [None, Some(Secret::new(""))] {
            let mut keyless = endpoint(ApiProtocol::AnthropicMessages);
            keyless.key = key;
            assert_eq!(launch(&claude, &keyless, "cl").err(), Some(ProviderError::KeyRequired));
        }
    }

    #[test]
    fn other_agents_have_no_provider_mechanism() {
        for other in [spec("custom-x-1234", "my-agent"), spec("custom-claude-1", "claude")] {
            assert!(supported_protocols(&other).is_empty());
            assert_eq!(
                launch(&other, &endpoint(ApiProtocol::Responses), INSTANCE).err(),
                Some(ProviderError::Unsupported)
            );
        }
    }

    #[test]
    fn a_keyless_opencode_provider_names_no_variable() {
        let mut keyless = endpoint(ApiProtocol::ChatCompletions);
        keyless.key = None;
        let launch = launch(&spec("opencode", "opencode"), &keyless, INSTANCE).expect("ok");
        let layer = Value::Object(launch.layer.expect("layer"));
        let provider = &layer["provider"][provider_id()];
        assert!(provider["options"].get("apiKey").is_none());
        assert_eq!(provider["env"], json!([]));
        assert!(launch.env.is_empty());
    }
}

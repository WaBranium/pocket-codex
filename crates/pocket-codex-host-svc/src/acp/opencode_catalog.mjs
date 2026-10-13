// Pocket-Codex model catalog for OpenCode (`opencode acp`).
//
// Loaded as an OpenCode server plugin through a config layer the host adds
// (see `catalog.rs`). Its `config` hook runs after OpenCode has merged and
// substituted every config layer and before providers are built from
// `cfg.provider`, so models added here appear in OpenCode's own model list
// and therefore in its ACP `model` config option.
//
// For every enabled config provider with an explicit `options.baseURL`, the
// hook lists `<baseURL>/models` with the provider's own key and headers and
// adds each listed chat model the configuration does not already declare.
// Declared models (including `disabled` ones), `whitelist` / `blacklist`,
// `enabled_providers` / `disabled_providers` and ids stay authoritative; no
// capability (reasoning, effort variants, limits) is inferred.
//
// A listing is all or nothing: a failed request, a malformed or oversized
// page, or a broken cursor adds nothing. A listing that is well formed but
// larger than the bounds, or that contains ids OpenCode cannot represent,
// adds what it can and is reported `partial`.
// Every outcome is written, without URL, key, headers or response text, to
// the report file named in the plugin options; the host shows it. Nothing
// is printed (stdout is the ACP channel) and nothing is cached.
//
// When the options name the instance's own provider (`route`), the hook
// first puts that route back into the merged configuration (`enforce`):
// OpenCode reads `cfg.provider`, `enabled_providers` and `disabled_providers`
// only after every plugin's `config` hook ran (provider.ts, "load plugins
// first so config() hook runs before reading cfg.provider"), and `model`,
// `small_model` and agent models whenever it picks one. The provider's
// credential is pinned in memory as `options.apiKey` (the supplied key, read
// from the child-only variable its `env` names, or empty without one): the
// SDK options take `options.apiKey` before `provider.key`, the field a key
// stored with `opencode auth login` for the same id overwrites (provider.ts
// "load apikeys", and `resolveSDK`), and config options are applied last
// ("load config - re-apply"). A route whose key is missing in this process is
// refused: no provider stays usable. The key is never written anywhere (not
// into a layer, the report or arguments). The report says what had to be
// reset, per project directory as the plugin input names it (the pinned
// public source has no plugin loader, so that name is not verified). Outside
// this hook's reach: another plugin's own provider or auth loader for the
// same id (its options other than the key), and a later plugin's `config`
// hook.

const PROVIDER_TIMEOUT_MS = 8000
const TOTAL_TIMEOUT_MS = 15000
const CONCURRENCY = 4
const MAX_PROVIDERS = 32
const MAX_PAGES = 20
const MAX_MODELS = 2000
const MAX_BODY_BYTES = 4 * 1024 * 1024
// Project verdicts kept in one report (the host reads at most this many).
const MAX_ROUTES = 32

// Listing `type`s that name a chat model. `chat` is what OpenAI-compatible
// gateways report, `model` is the Anthropic API's object type. Any other
// explicit type (embedding, image, …) is not offered; a missing type is.
const CHAT_TYPES = new Set(["chat", "model"])

// Whether OpenCode can hold `id` as a model key. Its provider build looks
// every configured model up with `parsed.models[id]` on an ordinary object
// and reads `.api.id` from a hit (provider.ts). Any name an ordinary object
// inherits (`__proto__`, `constructor`, `toString`, …) resolves to that
// inherited value instead of `undefined`, so OpenCode would fail to build
// the provider. Such ids are left out and counted; the listing is then not
// complete.
function representable(id) {
  return !(id in Object.prototype)
}

class ListingError extends Error {
  constructor(reason) {
    super(reason)
    this.reason = reason
  }
}

function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function isAnthropic(provider) {
  return typeof provider.npm === "string" && provider.npm.includes("anthropic")
}

/** The listing URL for a configured base URL, or undefined. */
export function listUrl(baseURL) {
  if (typeof baseURL !== "string") return undefined
  let url
  try {
    url = new URL(baseURL)
  } catch {
    return undefined
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return undefined
  url.pathname = url.pathname.replace(/\/+$/, "") + "/models"
  url.search = ""
  url.hash = ""
  return url
}

/** Request headers: the provider's configured headers plus its key. */
export function requestHeaders(provider, key) {
  const headers = { accept: "application/json" }
  const configured = provider.options?.headers
  if (isRecord(configured)) {
    for (const [name, value] of Object.entries(configured)) {
      if (typeof value === "string") headers[name.toLowerCase()] = value
    }
  }
  if (isAnthropic(provider)) {
    if (key) headers["x-api-key"] = key
    headers["anthropic-version"] ??= "2023-06-01"
  } else if (key) {
    headers.authorization = `Bearer ${key}`
  }
  return headers
}

/**
 * One listing page: chat models (`{id, name?}`), entries left out, and the
 * next cursor (`undefined` on the last page). Throws on a malformed page.
 */
export function parsePage(body) {
  if (!isRecord(body) || !Array.isArray(body.data)) throw new ListingError("malformed")
  const models = []
  let excluded = 0
  let unsafe = 0
  for (const entry of body.data) {
    if (!isRecord(entry) || typeof entry.id !== "string" || !entry.id) throw new ListingError("malformed")
    if (!representable(entry.id)) {
      unsafe++
      continue
    }
    if (entry.type !== undefined && !CHAT_TYPES.has(entry.type)) {
      excluded++
      continue
    }
    const label = [entry.display_name, entry.name].find((v) => typeof v === "string" && v.trim())
    models.push(label && label !== entry.id ? { id: entry.id, name: label } : { id: entry.id })
  }
  if (body.has_more !== true) return { models, excluded, unsafe, next: undefined }
  const last = body.data.at(-1)
  const next = typeof body.last_id === "string" && body.last_id ? body.last_id : last?.id
  if (typeof next !== "string" || !next) throw new ListingError("cursor-missing")
  return { models, excluded, unsafe, next }
}

/** The response body as text, refusing more than `limit` bytes. */
export async function readBounded(response, signal, limit = MAX_BODY_BYTES) {
  const reader = response.body?.getReader?.()
  if (!reader) throw new ListingError("malformed")
  const abort = () => reader.cancel().catch(() => {})
  signal.addEventListener("abort", abort, { once: true })
  try {
    const decoder = new TextDecoder()
    let text = ""
    let total = 0
    for (;;) {
      if (signal.aborted) throw new ListingError("timeout")
      const { done, value } = await reader.read()
      if (signal.aborted) throw new ListingError("timeout")
      if (done) return text + decoder.decode()
      total += value.byteLength
      if (total > limit) {
        await reader.cancel().catch(() => {})
        throw new ListingError("too-large")
      }
      text += decoder.decode(value, { stream: true })
    }
  } finally {
    signal.removeEventListener("abort", abort)
  }
}

/** A signal aborted by `parent` or after `ms`, and its cleanup. */
function deadline(parent, ms) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), ms)
  const follow = () => controller.abort()
  if (parent.aborted) controller.abort()
  else parent.addEventListener("abort", follow, { once: true })
  return {
    signal: controller.signal,
    done() {
      clearTimeout(timer)
      parent.removeEventListener("abort", follow)
    },
  }
}

/**
 * List every chat model of `provider`. Resolves to
 * `{status, reason, models, listed, excluded, unsafe}`; `models` is empty
 * unless the status is `complete` or `partial`. Unrepresentable ids make an
 * otherwise complete listing `partial` (`unsafe-id`).
 */
export async function discover(provider, key, fetchImpl, parent, limits = {}) {
  const maxPages = limits.maxPages ?? MAX_PAGES
  const maxModels = limits.maxModels ?? MAX_MODELS
  const maxBytes = limits.maxBytes ?? MAX_BODY_BYTES
  const base = listUrl(provider.options?.baseURL)
  const { signal, done } = deadline(parent, limits.timeoutMs ?? PROVIDER_TIMEOUT_MS)
  const found = []
  const seen = new Set()
  const cursors = new Set()
  let excluded = 0
  let unsafe = 0
  let cursor
  try {
    for (let page = 0; ; page++) {
      if (page >= maxPages) return result("partial", "page-limit")
      if (signal.aborted) throw new ListingError("timeout")
      const url = new URL(base)
      if (cursor) url.searchParams.set("after_id", cursor)
      let response
      try {
        response = await fetchImpl(url, { method: "GET", headers: requestHeaders(provider, key), signal, redirect: "error" })
      } catch {
        throw new ListingError(signal.aborted ? "timeout" : "network")
      }
      if (!response.ok) {
        await response.body?.cancel?.().catch(() => {})
        throw new ListingError(`http-${response.status}`)
      }
      let body
      const text = await readBounded(response, signal, maxBytes)
      try {
        body = JSON.parse(text)
      } catch {
        throw new ListingError("malformed")
      }
      const parsed = parsePage(body)
      excluded += parsed.excluded
      unsafe += parsed.unsafe
      for (const model of parsed.models) {
        if (seen.has(model.id)) continue
        if (found.length >= maxModels) return result("partial", "model-limit")
        seen.add(model.id)
        found.push(model)
      }
      if (parsed.next === undefined) return unsafe ? result("partial", "unsafe-id") : result("complete", null)
      if (cursors.has(parsed.next)) throw new ListingError("cursor-repeat")
      cursors.add(parsed.next)
      cursor = parsed.next
    }
  } catch (error) {
    const reason = error instanceof ListingError ? error.reason : "error"
    return { status: "failed", reason, models: [], listed: 0, excluded: 0, unsafe: 0 }
  } finally {
    done()
  }

  function result(status, reason) {
    return { status, reason, models: found, listed: found.length, excluded, unsafe }
  }
}

/**
 * Providers to list: enabled, with an explicit base URL, and their key.
 * `keySource` says where the credential came from: the configured `apiKey`,
 * a provider env variable, only the configured request headers, or nothing.
 */
export function candidates(cfg, env) {
  if (!isRecord(cfg.provider)) return []
  const disabled = new Set(Array.isArray(cfg.disabled_providers) ? cfg.disabled_providers : [])
  const enabled = Array.isArray(cfg.enabled_providers) ? new Set(cfg.enabled_providers) : undefined
  const out = []
  for (const [id, provider] of Object.entries(cfg.provider)) {
    if (!isRecord(provider) || disabled.has(id) || (enabled && !enabled.has(id))) continue
    if (!listUrl(provider.options?.baseURL)) continue
    const configured = typeof provider.options?.apiKey === "string" && provider.options.apiKey
    const fromEnv = Array.isArray(provider.env) ? provider.env.map((name) => env[name]).find(Boolean) : undefined
    const headers = provider.options?.headers
    const withHeaders = isRecord(headers) && Object.values(headers).some((v) => typeof v === "string" && v)
    out.push({
      id,
      provider,
      key: configured || fromEnv || undefined,
      keySource: configured ? "config" : fromEnv ? "env" : withHeaders ? "headers" : "none",
    })
  }
  return out
}

/** Add listed models the configuration does not declare; the count added. */
export function merge(provider, models) {
  if (!isRecord(provider.models)) provider.models = {}
  const declared = new Set(Object.keys(provider.models))
  for (const model of Object.values(provider.models)) {
    if (isRecord(model) && typeof model.id === "string") declared.add(model.id)
  }
  let added = 0
  for (const model of models) {
    if (declared.has(model.id) || !representable(model.id)) continue
    Object.defineProperty(provider.models, model.id, {
      value: model.name ? { name: model.name } : {},
      enumerable: true,
      writable: true,
      configurable: true,
    })
    added++
  }
  return added
}

async function inBatches(items, size, run) {
  for (let i = 0; i < items.length; i += size) {
    await Promise.all(items.slice(i, i + size).map(run))
  }
}

/** Extend `cfg` in place and describe what happened. Never throws. */
export async function apply(cfg, env, fetchImpl, limits = {}) {
  const report = { version: 1, providers: [] }
  if (!isRecord(cfg)) return report
  const all = candidates(cfg, env)
  const listed = all.slice(0, MAX_PROVIDERS)
  const total = deadline(new AbortController().signal, limits.totalTimeoutMs ?? TOTAL_TIMEOUT_MS)
  try {
    await inBatches(listed, CONCURRENCY, async ({ id, provider, key, keySource }) => {
      const outcome = await discover(provider, key, fetchImpl, total.signal, limits)
      const added = merge(provider, outcome.models)
      report.providers.push({
        id,
        status: outcome.status,
        reason: outcome.reason,
        listed: outcome.listed,
        added,
        excluded: outcome.excluded,
        unsafe: outcome.unsafe,
        keySource,
      })
    })
  } finally {
    total.done()
  }
  for (const { id, keySource } of all.slice(MAX_PROVIDERS)) {
    report.providers.push({ id, status: "skipped", reason: "provider-limit", listed: 0, added: 0, excluded: 0, unsafe: 0, keySource })
  }
  report.providers.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))
  return report
}

/** `value` as JSON with sorted keys, so merged objects compare by content. */
function canonical(value) {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`
  if (isRecord(value)) {
    const keys = Object.keys(value).sort()
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(",")}}`
  }
  return JSON.stringify(value) ?? "null"
}

function own(provider, model) {
  return typeof model === "string" && model.startsWith(`${provider}/`)
}

/**
 * Put the instance's own route (`route`: `{provider, model, definition}`
 * from the host's layer) back into the merged configuration `cfg`, in place:
 * the default and small model, every agent or mode model naming another
 * provider, the provider entry itself (exactly the host's definition, so no
 * other layer's endpoint, key, headers or per-model route remains, with its
 * credential pinned as `options.apiKey` from `env`, see the header), and the
 * provider lists (only this provider enabled, it not disabled). Answers
 * `{state, reasons}`: `selected` when nothing had to change, `enforced` with
 * what was reset, `refused` (`key`) when the definition names a key variable
 * `env` does not hold — the entry is then removed, so no provider is usable.
 * Undefined without a well-formed route or configuration.
 */
export function enforce(cfg, route, env = {}) {
  if (!isRecord(route) || typeof route.provider !== "string" || !own(route.provider, route.model)) return undefined
  if (!isRecord(route.definition) || !isRecord(cfg)) return undefined
  const id = route.provider
  const names = route.definition.env ?? []
  const variable = Array.isArray(names) && names.length === 1 ? names[0] : undefined
  const keyed = !(Array.isArray(names) && names.length === 0)
  const key = typeof variable === "string" && typeof env[variable] === "string" ? env[variable] : ""
  const reasons = []
  if (cfg.model !== route.model) {
    cfg.model = route.model
    reasons.push("model")
  }
  if (cfg.small_model !== undefined && !own(id, cfg.small_model)) {
    cfg.small_model = route.model
    reasons.push("small-model")
  }
  for (const group of [cfg.agent, cfg.mode]) {
    if (!isRecord(group)) continue
    for (const agent of Object.values(group)) {
      if (!isRecord(agent) || agent.model === undefined || own(id, agent.model)) continue
      agent.model = route.model
      if (!reasons.includes("agent-model")) reasons.push("agent-model")
    }
  }
  const enabled = cfg.enabled_providers
  if (enabled !== undefined && !(Array.isArray(enabled) && enabled.length === 1 && enabled[0] === id)) {
    reasons.push("enabled-providers")
  }
  // Only this provider: one OpenCode found through env variables or a
  // stored login could otherwise serve a model chosen in a session.
  cfg.enabled_providers = [id]
  if (Array.isArray(cfg.disabled_providers) && cfg.disabled_providers.includes(id)) {
    cfg.disabled_providers = cfg.disabled_providers.filter((p) => p !== id)
    reasons.push("disabled-providers")
  }
  if (!isRecord(cfg.provider)) cfg.provider = {}
  if (keyed && !key) {
    // Without its key the provider would fall back to another credential:
    // only it is enabled, and it is gone, so nothing can be prompted.
    delete cfg.provider[id]
    return { state: "refused", reasons: ["key"] }
  }
  const current = Object.hasOwn(cfg.provider, id) ? cfg.provider[id] : undefined
  if (current === undefined) reasons.push("missing")
  else if (canonical(current) !== canonical(route.definition)) reasons.push("provider")
  const definition = structuredClone(route.definition)
  definition.options = { ...(isRecord(definition.options) ? definition.options : {}), apiKey: key }
  Object.defineProperty(cfg.provider, id, {
    value: definition,
    enumerable: true,
    writable: true,
    configurable: true,
  })
  return { state: reasons.length ? "enforced" : "selected", reasons }
}

// Each project's verdict, by the directory OpenCode loaded it for; one
// OpenCode process loads the plugin once and runs `server` per project.
const routes = new Map()
let staged = 0

/** Replace the report file atomically. Failures are ignored. */
export async function writeReport(path, report) {
  if (typeof path !== "string" || !path) return
  try {
    const fs = await import("node:fs/promises")
    const staging = `${path}.${process.pid}.${Date.now()}.${staged++}.tmp`
    await fs.writeFile(staging, JSON.stringify(report), { mode: 0o600 })
    await fs.rename(staging, path)
  } catch {
    // The host then shows the catalog as not yet reported.
  }
}

export default {
  id: "pocket-codex.model-catalog",
  server: async (input, options) => ({
    config: async (cfg) => {
      const route = enforce(cfg, options?.route, process.env)
      const report = await apply(cfg, process.env, fetch)
      if (route) {
        const named = input?.directory
        // What the host accepts: a bounded name without control characters.
        const directory =
          typeof named === "string" && named.length <= 4096 && !/\p{Cc}/u.test(named) ? named : undefined
        routes.delete(directory ?? "")
        routes.set(directory ?? "", { ...(directory === undefined ? {} : { directory }), ...route })
        if (routes.size > MAX_ROUTES) routes.delete(routes.keys().next().value)
        report.routes = [...routes.values()]
      }
      await writeReport(options?.report, report)
    },
  }),
}

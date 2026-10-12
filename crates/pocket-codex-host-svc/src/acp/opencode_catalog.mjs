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

const PROVIDER_TIMEOUT_MS = 8000
const TOTAL_TIMEOUT_MS = 15000
const CONCURRENCY = 4
const MAX_PROVIDERS = 32
const MAX_PAGES = 20
const MAX_MODELS = 2000
const MAX_BODY_BYTES = 4 * 1024 * 1024

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

/** Replace the report file atomically. Failures are ignored. */
export async function writeReport(path, report) {
  if (typeof path !== "string" || !path) return
  try {
    const fs = await import("node:fs/promises")
    const staging = `${path}.${process.pid}.${Date.now()}.tmp`
    await fs.writeFile(staging, JSON.stringify(report), { mode: 0o600 })
    await fs.rename(staging, path)
  } catch {
    // The host then shows the catalog as not yet reported.
  }
}

export default {
  id: "pocket-codex.model-catalog",
  server: async (_input, options) => ({
    config: async (cfg) => {
      const report = await apply(cfg, process.env, fetch)
      await writeReport(options?.report, report)
    },
  }),
}

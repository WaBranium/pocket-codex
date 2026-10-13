// Boundary tests for the OpenCode catalog plugin (`node --test`, Node 18+),
// run by `tests/opencode_catalog.rs`. A fake `fetch` stands in for the
// gateway and answers with real `Response` objects; no network is used.
import assert from "node:assert/strict"
import { mkdtemp, readFile, readdir } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { test } from "node:test"

import plugin, {
  apply,
  candidates,
  discover,
  listUrl,
  merge,
  parsePage,
  readBounded,
  enforce,
} from "../src/acp/opencode_catalog.mjs"

const json = (body, status = 200) => new Response(JSON.stringify(body), { status })

/** A gateway serving `pages` keyed by the `after_id` cursor ("" first). */
function gateway(pages, { status = 200 } = {}) {
  const calls = []
  const fetchImpl = async (url, init) => {
    calls.push({ url: String(url), headers: init.headers, method: init.method, redirect: init.redirect })
    const body = pages[url.searchParams.get("after_id") ?? ""]
    return body === undefined ? json({ error: "nope" }, 404) : json(body, status)
  }
  return { fetchImpl, calls }
}

const config = (provider, extra = {}) => ({ provider: { gw: provider }, ...extra })
const base = { options: { baseURL: "https://gw.example/v1" } }
const chat = (n, prefix = "m") => Array.from({ length: n }, (_, i) => ({ id: `${prefix}-${i}`, type: "chat" }))
const only = (report) => {
  assert.equal(report.providers.length, 1)
  return report.providers[0]
}

test("a complete listing adds every chat model with its id verbatim", async () => {
  const { fetchImpl, calls } = gateway({
    "": {
      object: "list",
      data: [
        { id: "vendor-a/model-one", display_name: "Model One", type: "chat" },
        { id: "model-two-thinking", type: "chat" },
        { id: "model-three-high", display_name: "model-three-high" },
      ],
    },
  })
  const cfg = config({ npm: "@ai-sdk/anthropic", options: { baseURL: "https://gw.example/v1/", apiKey: "k-1" } })
  const row = only(await apply(cfg, {}, fetchImpl))
  assert.deepEqual(cfg.provider.gw.models, {
    "vendor-a/model-one": { name: "Model One" },
    "model-two-thinking": {},
    "model-three-high": {},
  })
  assert.deepEqual(row, { id: "gw", status: "complete", reason: null, listed: 3, added: 3, excluded: 0, unsafe: 0, keySource: "config" })
  assert.equal(calls.length, 1)
  assert.equal(calls[0].url, "https://gw.example/v1/models")
  assert.equal(calls[0].method, "GET")
  assert.equal(calls[0].redirect, "error")
  assert.equal(calls[0].headers["x-api-key"], "k-1")
  assert.equal(calls[0].headers["anthropic-version"], "2023-06-01")
  assert.equal(calls[0].headers.authorization, undefined)
})

test("83 chat entries of the gateway shape are all added", async () => {
  const data = Array.from({ length: 83 }, (_, i) => ({
    id: `model-${i}`, display_name: `Model ${i}`, max_tokens: 64000, created: 1, object: "model", owned_by: "x", type: "chat",
  }))
  const { fetchImpl } = gateway({ "": { object: "list", data } })
  const cfg = config({ ...base })
  const row = only(await apply(cfg, {}, fetchImpl))
  assert.equal(Object.keys(cfg.provider.gw.models).length, 83)
  assert.equal(row.status, "complete")
  // Nothing is inferred from a listing: no limits, reasoning or variants.
  assert.deepEqual(cfg.provider.gw.models["model-7"], { name: "Model 7" })
})

test("explicit non-chat types are left out and counted", async () => {
  const { fetchImpl } = gateway({
    "": { data: [{ id: "a", type: "chat" }, { id: "b", type: "embedding" }, { id: "c", type: "model" }, { id: "d" }, { id: "e", type: "image" }] },
  })
  const cfg = config({ ...base })
  const row = only(await apply(cfg, {}, fetchImpl))
  assert.deepEqual(Object.keys(cfg.provider.gw.models), ["a", "c", "d"])
  assert.equal(row.excluded, 2)
  assert.equal(row.status, "complete")
})

test("inherited object keys are left out and the listing is not complete", async () => {
  const inherited = ["__proto__", "constructor", "toString", "hasOwnProperty", "valueOf"]
  const { fetchImpl } = gateway({ "": { data: [...inherited.map((id) => ({ id, type: "chat" })), { id: "kept", type: "chat" }] } })
  const cfg = config({ ...base })
  const row = only(await apply(cfg, {}, fetchImpl))
  const models = cfg.provider.gw.models
  assert.deepEqual(Object.keys(models), ["kept"])
  assert.equal(Object.getPrototypeOf(models), Object.prototype, "prototype untouched")
  assert.deepEqual(
    { status: row.status, reason: row.reason, unsafe: row.unsafe, listed: row.listed, added: row.added },
    { status: "partial", reason: "unsafe-id", unsafe: inherited.length, listed: 1, added: 1 },
  )
  // The downstream contract: OpenCode looks each added id up on a separate
  // ordinary object and reads `.api.id` (provider.ts). Every kept id must
  // miss; every excluded id would hit an inherited value and throw there.
  const parsed = {}
  for (const id of Object.keys(models)) {
    assert.equal(parsed[id], undefined, id)
    parsed[id] = { api: { id } }
  }
  for (const id of inherited) {
    assert.notEqual(({})[id], undefined, id)
    assert.throws(() => ({})[id].api.id, TypeError, id)
  }
  const direct = {}
  assert.equal(merge(direct, inherited.map((id) => ({ id })).concat([{ id: "opaque/name", name: "Opaque" }])), 1)
  assert.deepEqual(Object.keys(direct.models), ["opaque/name"])
})

test("more models than the bound: the bounded prefix is added and reported partial", async () => {
  const { fetchImpl } = gateway({ "": { data: chat(2001) } })
  const cfg = config({ ...base })
  const row = only(await apply(cfg, {}, fetchImpl))
  assert.equal(Object.keys(cfg.provider.gw.models).length, 2000)
  assert.deepEqual({ status: row.status, reason: row.reason, listed: row.listed }, { status: "partial", reason: "model-limit", listed: 2000 })
})

test("more pages than the bound is reported partial", async () => {
  const pages = { "": { data: [{ id: "p0" }], has_more: true, last_id: "p0" } }
  for (let i = 0; i < 30; i++) pages[`p${i}`] = { data: [{ id: `p${i + 1}` }], has_more: true, last_id: `p${i + 1}` }
  const { fetchImpl, calls } = gateway(pages)
  const outcome = await discover(base, undefined, fetchImpl, new AbortController().signal, { maxPages: 3 })
  assert.deepEqual({ status: outcome.status, reason: outcome.reason, listed: outcome.listed }, { status: "partial", reason: "page-limit", listed: 3 })
  assert.equal(calls.length, 3)
})

test("pagination follows the cursor; a repeated or missing cursor fails and adds nothing", async () => {
  const ok = gateway({ "": { data: [{ id: "p1" }], has_more: true, last_id: "p1" }, p1: { data: [{ id: "p2" }], has_more: false } })
  const cfg = config({ ...base })
  assert.equal(only(await apply(cfg, {}, ok.fetchImpl)).status, "complete")
  assert.deepEqual(Object.keys(cfg.provider.gw.models), ["p1", "p2"])
  assert.equal(ok.calls[1].url, "https://gw.example/v1/models?after_id=p1")

  const cases = {
    "cursor-repeat": { "": { data: [{ id: "p1" }], has_more: true, last_id: "p1" }, p1: { data: [{ id: "p2" }], has_more: true, last_id: "p1" } },
    "cursor-missing": { "": { data: [], has_more: true } },
  }
  for (const [reason, pages] of Object.entries(cases)) {
    const cfg = config({ ...base, models: { keep: {} } })
    const row = only(await apply(cfg, {}, gateway(pages).fetchImpl))
    assert.deepEqual({ status: row.status, reason: row.reason, added: row.added }, { status: "failed", reason, added: 0 })
    assert.deepEqual(cfg.provider.gw.models, { keep: {} }, reason)
  }
})

test("a failure on a later page adds nothing from earlier pages", async () => {
  const cfg = config({ ...base, models: { keep: {} } })
  const row = only(await apply(cfg, {}, gateway({ "": { data: [{ id: "p1" }], has_more: true, last_id: "p1" } }).fetchImpl))
  assert.deepEqual({ status: row.status, reason: row.reason }, { status: "failed", reason: "http-404" })
  assert.deepEqual(cfg.provider.gw.models, { keep: {} })
})

test("failures are reported with a fixed reason and leave the provider as configured", async () => {
  const cases = [
    ["http-401", gateway({ "": { data: [{ id: "x" }] } }, { status: 401 }).fetchImpl],
    ["malformed", gateway({ "": { unexpected: true } }).fetchImpl],
    ["malformed", gateway({ "": { data: [{ id: "ok" }, { nope: 1 }] } }).fetchImpl],
    ["malformed", async () => new Response("not json")],
    ["network", async () => { throw new Error("offline https://gw.example/v1 k-secret") }],
  ]
  for (const [reason, fetchImpl] of cases) {
    const cfg = config({ options: { baseURL: "https://gw.example/v1", apiKey: "k-secret" }, models: { keep: {} } })
    const report = await apply(cfg, {}, fetchImpl)
    const row = only(report)
    assert.deepEqual({ status: row.status, reason: row.reason, added: row.added }, { status: "failed", reason, added: 0 })
    assert.deepEqual(cfg.provider.gw.models, { keep: {} })
    const text = JSON.stringify(report)
    assert.ok(!text.includes("k-secret") && !text.includes("gw.example"), "nothing sensitive reported")
  }
})

/** A body that yields `chunk` forever, recording whether it was cancelled. */
function endless(chunk) {
  const state = { reads: 0, cancelled: false }
  const body = new ReadableStream({
    pull(controller) {
      state.reads++
      controller.enqueue(new TextEncoder().encode(chunk))
    },
    cancel() {
      state.cancelled = true
    },
  })
  return { state, response: new Response(body) }
}

test("an oversized body is cut off while streaming and cancelled", async () => {
  const { state, response } = endless("x".repeat(1024))
  await assert.rejects(readBounded(response, new AbortController().signal, 8 * 1024), { reason: "too-large" })
  assert.ok(state.cancelled, "the stream was cancelled")
  assert.ok(state.reads <= 12, `bounded reads (${state.reads})`)

  const cfg = config({ ...base, models: { keep: {} } })
  const outcome = await discover(cfg.provider.gw, undefined, async () => endless('{"data":[').response, new AbortController().signal, { maxBytes: 4096 })
  assert.deepEqual({ status: outcome.status, reason: outcome.reason }, { status: "failed", reason: "too-large" })
})

test("the whole discovery is bounded in time, including a stalled body", async () => {
  const stalled = async () => new Response(new ReadableStream({ pull: () => new Promise(() => {}) }))
  const started = Date.now()
  const cfg = config({ ...base, models: { keep: {} } })
  const row = only(await apply(cfg, {}, stalled, { timeoutMs: 50, totalTimeoutMs: 1000 }))
  assert.deepEqual({ status: row.status, reason: row.reason }, { status: "failed", reason: "timeout" })
  assert.ok(Date.now() - started < 1000)
  assert.deepEqual(cfg.provider.gw.models, { keep: {} })

  const hanging = (_url, init) => new Promise((_, reject) => init.signal.addEventListener("abort", () => reject(new Error("aborted"))))
  const many = { provider: Object.fromEntries(Array.from({ length: 6 }, (_, i) => [`p${i}`, { ...base }])) }
  const report = await apply(many, {}, hanging, { timeoutMs: 5000, totalTimeoutMs: 50 })
  assert.equal(report.providers.length, 6)
  assert.ok(report.providers.every((p) => p.status === "failed" && p.reason === "timeout"))
})

test("a partial listing reports what was listed and what was added apart", async () => {
  const { fetchImpl } = gateway({ "": { data: chat(5) } })
  const cfg = config({ ...base, models: { "m-0": { name: "Declared" } } })
  const row = only(await apply(cfg, {}, fetchImpl, { maxModels: 3 }))
  assert.deepEqual(
    { status: row.status, reason: row.reason, listed: row.listed, added: row.added },
    { status: "partial", reason: "model-limit", listed: 3, added: 2 },
  )
  assert.deepEqual(Object.keys(cfg.provider.gw.models), ["m-0", "m-1", "m-2"])
  assert.deepEqual(cfg.provider.gw.models["m-0"], { name: "Declared" })
})

test("declared models, disabled ones, aliases and filters stay authoritative", async () => {
  const { fetchImpl } = gateway({ "": { data: [{ id: "a", display_name: "A" }, { id: "b" }, { id: "real-c" }, { id: "d" }] } })
  const declared = { a: { name: "Mine", limit: { context: 1, output: 1 } }, b: { disabled: true }, alias: { id: "real-c" } }
  const cfg = config({ ...base, models: declared, whitelist: ["a", "d"] })
  const row = only(await apply(cfg, {}, fetchImpl))
  assert.deepEqual(cfg.provider.gw.models, { ...declared, d: {} })
  assert.deepEqual({ listed: row.listed, added: row.added }, { listed: 4, added: 1 })
  assert.deepEqual(cfg.provider.gw.whitelist, ["a", "d"], "filters are left for OpenCode to apply")
})

test("keys: config, then the provider env variables, else none; bearer for non-Anthropic", async () => {
  const { fetchImpl, calls } = gateway({ "": { data: [{ id: "x" }] } })
  const cfg = {
    provider: {
      one: { options: { baseURL: "https://one.example/v1", apiKey: "k-one", headers: { "X-Tenant": "t" } } },
      two: { env: ["TWO_KEY"], options: { baseURL: "https://two.example/v1" } },
      three: { env: ["UNSET"], options: { baseURL: "https://three.example/v1" } },
    },
  }
  const report = await apply(cfg, { TWO_KEY: "k-two" }, fetchImpl)
  const byHost = Object.fromEntries(calls.map((c) => [new URL(c.url).host, c.headers]))
  assert.equal(byHost["one.example"].authorization, "Bearer k-one")
  assert.equal(byHost["one.example"]["x-tenant"], "t")
  assert.equal(byHost["two.example"].authorization, "Bearer k-two")
  assert.equal(byHost["three.example"].authorization, undefined)
  assert.deepEqual(report.providers.map((p) => [p.id, p.keySource]), [["one", "config"], ["three", "none"], ["two", "env"]])
})

test("configured headers are a credential source even without a key", async () => {
  const { fetchImpl, calls } = gateway({ "": { data: [{ id: "x" }] } }, { status: 401 })
  const row = only(await apply(config({ options: { baseURL: "https://gw.example/v1", headers: { Authorization: "secret-value" } } }), {}, fetchImpl))
  assert.equal(calls[0].headers.authorization, "secret-value")
  assert.deepEqual({ status: row.status, reason: row.reason, keySource: row.keySource }, { status: "failed", reason: "http-401", keySource: "headers" })
  assert.equal(JSON.stringify(row).includes("secret-value"), false)
})

test("a key only in OpenCode's auth store is not visible: refused listing says so", async () => {
  // The config hook sees config and env only; `opencode auth login` keys are
  // applied by OpenCode later, after the hook (provider.ts).
  const { fetchImpl } = gateway({ "": { data: [{ id: "x" }] } }, { status: 401 })
  const row = only(await apply(config({ ...base }), {}, fetchImpl))
  assert.deepEqual({ status: row.status, reason: row.reason, keySource: row.keySource }, { status: "failed", reason: "http-401", keySource: "none" })
})

test("every apply lists with the configuration it is given; nothing carries over", async () => {
  const first = gateway({ "": { data: [{ id: "old" }] } })
  const cfgA = config({ options: { baseURL: "https://a.example/v1", apiKey: "k-a" } })
  await apply(cfgA, {}, first.fetchImpl)
  const second = gateway({ "": { data: [{ id: "new" }] } })
  const cfgB = config({ options: { baseURL: "https://b.example/v1", apiKey: "k-b" } })
  await apply(cfgB, {}, second.fetchImpl)
  assert.deepEqual(Object.keys(cfgB.provider.gw.models), ["new"])
  assert.equal(second.calls[0].url, "https://b.example/v1/models")
  assert.equal(second.calls[0].headers.authorization, "Bearer k-b")
})

test("provider filters decide which providers are listed", () => {
  const p = { options: { baseURL: "https://gw.example/v1" } }
  const both = { provider: { a: p, b: p, c: { options: {} }, d: { options: { baseURL: "file:///x" } } } }
  assert.deepEqual(candidates(both, {}).map((c) => c.id), ["a", "b"])
  assert.deepEqual(candidates({ ...both, disabled_providers: ["a"] }, {}).map((c) => c.id), ["b"])
  assert.deepEqual(candidates({ ...both, enabled_providers: ["a"] }, {}).map((c) => c.id), ["a"])
})

test("helpers reject unusable input", () => {
  assert.equal(listUrl("ftp://gw.example"), undefined)
  assert.equal(listUrl("not a url"), undefined)
  assert.equal(listUrl("https://gw.example/v1?x=1").href, "https://gw.example/v1/models")
  assert.throws(() => parsePage({ data: "nope" }), { reason: "malformed" })
  assert.throws(() => parsePage({ data: [{ id: "" }] }), { reason: "malformed" })
})

test("the plugin writes a sanitized report to the path in its options", async () => {
  assert.equal(plugin.id, "pocket-codex.model-catalog")
  const dir = await mkdtemp(join(tmpdir(), "pcx-catalog-"))
  const report = join(dir, "report.json")
  const hooks = await plugin.server({}, { report })
  assert.equal(typeof hooks.config, "function")
  // No listable provider: no request, an empty report.
  await hooks.config({ provider: { plain: {} } })
  assert.deepEqual(JSON.parse(await readFile(report, "utf8")), { version: 1, providers: [] })
  assert.deepEqual(await readdir(dir), ["report.json"], "no staging file left")
})

const ID = "pocket-codex-6f63-a1"
const KEY_VAR = "PCX_KEY_6F63"
// Dummy keys only.
const SUPPLIED = "sk-dummy-supplied-0123"
const STORED = "sk-dummy-stored-4567"
const ENV = { [KEY_VAR]: SUPPLIED }
const definition = () => ({
  npm: "@ai-sdk/openai-compatible",
  name: "Pocket-Codex provider",
  env: [KEY_VAR],
  options: { baseURL: "https://gw.example/v1" },
  models: { m1: {} },
})
/** The definition as `enforce` installs it: the supplied key pinned. */
const pinned = (key = SUPPLIED) => {
  const d = definition()
  d.options.apiKey = key
  return d
}
const route = () => ({ provider: ID, model: `${ID}/m1`, definition: definition() })
const merged = () => ({ model: `${ID}/m1`, provider: { [ID]: definition() } })

test("a configuration already on the host's route is left as it is, its key pinned", () => {
  const cfg = merged()
  assert.deepEqual(enforce(cfg, route(), ENV), { state: "selected", reasons: [] })
  assert.deepEqual(cfg.provider[ID], pinned())
  assert.deepEqual(cfg.enabled_providers, [ID], "only the host's provider")
  // Keys merged in another order are the same definition.
  const reordered = merged()
  reordered.provider[ID] = { models: { m1: {} }, options: { baseURL: "https://gw.example/v1" }, env: [KEY_VAR], name: "Pocket-Codex provider", npm: "@ai-sdk/openai-compatible" }
  assert.equal(enforce(reordered, route(), ENV).state, "selected")
})

test("another layer redefining the same provider id is replaced by the host's definition", () => {
  const cfg = merged()
  // A project or managed layer merged into the same id: its own endpoint,
  // key, headers and a per-model route.
  Object.assign(cfg.provider[ID].options, { baseURL: "https://other.example/v1", apiKey: "sk-dummy-other", headers: { "x-route": "b" } })
  cfg.provider[ID].models.m1 = { provider: { api: "https://elsewhere.example" }, headers: { a: "b" }, options: { x: 1 } }
  cfg.provider[ID].env = ["OTHER_KEY"]
  assert.deepEqual(enforce(cfg, route(), ENV), { state: "enforced", reasons: ["provider"] })
  assert.deepEqual(cfg.provider[ID], pinned(), "exactly the host's definition")
  // The definition is a copy: a later merge cannot change the route's own.
  const r = route()
  const again = merged()
  enforce(again, r, ENV)
  again.provider[ID].options.baseURL = "https://x.example"
  assert.equal(r.definition.options.baseURL, "https://gw.example/v1")
  assert.equal(r.definition.options.apiKey, undefined, "the route itself never holds the key")
})

test("provider lists, default, small and agent models are put back", () => {
  const cfg = {
    ...merged(),
    model: "anthropic/claude",
    small_model: "openai/gpt-nano",
    enabled_providers: ["anthropic", ID],
    disabled_providers: ["x", ID],
    agent: { build: { model: "anthropic/claude" }, plan: { model: `${ID}/m1` }, review: {} },
    mode: { fast: { model: "openai/gpt" } },
  }
  assert.deepEqual(enforce(cfg, route(), ENV), {
    state: "enforced",
    reasons: ["model", "small-model", "agent-model", "enabled-providers", "disabled-providers"],
  })
  assert.equal(cfg.model, `${ID}/m1`)
  assert.equal(cfg.small_model, `${ID}/m1`)
  assert.deepEqual([cfg.agent.build.model, cfg.agent.plan.model, cfg.mode.fast.model], [`${ID}/m1`, `${ID}/m1`, `${ID}/m1`])
  assert.equal(cfg.agent.review.model, undefined, "an agent without a model keeps the default")
  assert.deepEqual(cfg.enabled_providers, [ID])
  assert.deepEqual(cfg.disabled_providers, ["x"])
  // An own small model is kept.
  const small = { ...merged(), small_model: `${ID}/m1` }
  assert.equal(enforce(small, route(), ENV).state, "selected")
})

test("a missing provider entry is restored", () => {
  const cfg = { model: `${ID}/m1` }
  assert.deepEqual(enforce(cfg, route(), ENV), { state: "enforced", reasons: ["missing"] })
  assert.deepEqual(cfg.provider[ID], pinned())
  // An inherited name is not an entry.
  const r = { provider: "toString", model: "toString/m", definition: {} }
  assert.deepEqual(enforce({ model: "toString/m", provider: {} }, r).reasons, ["missing"])
})

test("a keyed route whose key is missing in the agent leaves no usable provider", () => {
  for (const env of [{}, { [KEY_VAR]: "" }]) {
    const cfg = { ...merged(), enabled_providers: ["anthropic"] }
    assert.deepEqual(enforce(cfg, route(), env), { state: "refused", reasons: ["key"] })
    assert.equal(Object.hasOwn(cfg.provider, ID), false, "the provider is removed")
    assert.deepEqual(cfg.enabled_providers, [ID], "and nothing else is enabled")
    assert.equal(cfg.model, `${ID}/m1`)
  }
})

test("without a route nothing is changed (inherited configuration)", () => {
  const cfg = { model: "anthropic/claude", provider: { anthropic: { options: { apiKey: "k" } } } }
  const before = JSON.stringify(cfg)
  assert.equal(enforce(cfg, undefined, ENV), undefined)
  assert.equal(enforce(cfg, { provider: ID, model: "other/m1", definition: {} }, ENV), undefined, "model of another provider")
  assert.equal(enforce(cfg, { provider: ID, model: `${ID}/m1` }, ENV), undefined, "no definition")
  assert.equal(JSON.stringify(cfg), before)
})

// remeda `mergeDeep`, as OpenCode uses it: plain objects merge recursively,
// the second argument wins, anything else is replaced.
function mergeDeep(a, b) {
  const out = { ...a }
  for (const [k, v] of Object.entries(b)) {
    const plain = (x) => x !== null && typeof x === "object" && !Array.isArray(x)
    out[k] = plain(v) && plain(out[k]) ? mergeDeep(out[k], v) : v
  }
  return out
}

/**
 * The SDK options OpenCode 1.18.35 builds for `providerID` from the merged
 * configuration `cfg` (after every `config` hook), the process environment
 * `envs` and stored logins `auths`, following the pinned
 * packages/opencode/src/provider/provider.ts step by step: config providers
 * into the database (1533-1543), "load env" (1634-1644), "load apikeys" —
 * a stored `api` login merged by id AFTER the env key (1647-1657), "load
 * config - re-apply" (1699-1706), the provider filter (1722-1727), and
 * `resolveSDK` (1788 `{...provider.options}`, 1832 `apiKey` from
 * `provider.key` only when undefined). models.dev entries, plugin auth
 * loaders and custom loaders are left out: none exists for this random id.
 */
function sdkOptions(cfg, envs, auths, providerID) {
  const database = {}
  for (const [id, p] of Object.entries(cfg.provider ?? {})) {
    database[id] = { id, env: p.env ?? [], options: mergeDeep({}, p.options ?? {}), source: "config", models: p.models ?? {} }
  }
  const disabled = new Set(cfg.disabled_providers ?? [])
  const enabled = cfg.enabled_providers ? new Set(cfg.enabled_providers) : null
  const providers = {}
  const mergeProvider = (id, patch) => {
    if (providers[id]) providers[id] = mergeDeep(providers[id], patch)
    else if (database[id]) providers[id] = mergeDeep(database[id], patch)
  }
  for (const [id, p] of Object.entries(database)) {
    if (disabled.has(id)) continue
    const apiKey = p.env.map((item) => envs[item]).find(Boolean)
    if (!apiKey) continue
    mergeProvider(id, { source: "env", key: p.env.length === 1 ? apiKey : undefined })
  }
  for (const [id, stored] of Object.entries(auths)) {
    if (disabled.has(id)) continue
    if (stored.type === "api") mergeProvider(id, { source: "api", key: stored.key })
  }
  for (const [id, p] of Object.entries(cfg.provider ?? {})) {
    const partial = { source: "config" }
    if (p.env) partial.env = p.env
    if (p.name) partial.name = p.name
    if (p.options) partial.options = p.options
    mergeProvider(id, partial)
  }
  for (const id of Object.keys(providers)) {
    if ((enabled && !enabled.has(id)) || disabled.has(id)) delete providers[id]
  }
  const provider = providers[providerID]
  if (!provider) return { providers: Object.keys(providers) }
  const options = { ...provider.options }
  if (options["apiKey"] === undefined && provider.key) options["apiKey"] = provider.key
  return { providers: Object.keys(providers), options }
}

test("a key stored for the same id never reaches the SDK: the supplied key does", () => {
  const auths = { [ID]: { type: "api", key: STORED }, anthropic: { type: "api", key: "sk-dummy-other" } }
  // Without the pin (the hook's earlier behaviour), the stored login wins:
  // this is what the fixture must be able to show.
  const unpinned = merged()
  const before = sdkOptions(unpinned, ENV, auths, ID)
  assert.equal(before.options.apiKey, STORED, "the stored login overwrote the env key")

  const cfg = { ...merged(), model: "anthropic/claude", provider: { ...merged().provider, anthropic: {} } }
  cfg.provider[ID].options.headers = { authorization: "Bearer sk-dummy-other" }
  assert.equal(enforce(cfg, route(), ENV).state, "enforced")
  const after = sdkOptions(cfg, ENV, auths, ID)
  assert.deepEqual(after.providers, [ID], "only the host's provider is usable")
  assert.equal(after.options.apiKey, SUPPLIED, "the supplied key")
  assert.equal(after.options.baseURL, "https://gw.example/v1", "the chosen endpoint")
  assert.equal(after.options.headers, undefined, "no other layer's headers")
  assert.equal(cfg.model, `${ID}/m1`, "the chosen model")

  // A route without a key sends none: neither the stored login nor an
  // SDK's own environment fallback (an empty key is defined).
  const keyless = { provider: ID, model: `${ID}/m1`, definition: { ...definition(), env: [] } }
  const open = merged()
  enforce(open, keyless, {})
  assert.equal(sdkOptions(open, {}, auths, ID).options.apiKey, "")

  // A refused route leaves nothing to build an SDK for.
  const refused = merged()
  enforce(refused, route(), {})
  assert.deepEqual(sdkOptions(refused, {}, auths, ID), { providers: [] })
})

test("the report never holds the supplied key", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pcx-key-"))
  const report = join(dir, "report.json")
  const variable = "PCX_TEST_KEY_6F63"
  process.env[variable] = SUPPLIED
  try {
    const keyed = { provider: ID, model: `${ID}/m1`, definition: { npm: "@ai-sdk/openai-compatible", env: [variable], options: {}, models: { m1: {} } } }
    const hooks = await plugin.server({ directory: "/work/k" }, { report, route: keyed })
    const cfg = { model: `${ID}/m1`, provider: {} }
    await hooks.config(cfg)
    assert.equal(cfg.provider[ID].options.apiKey, SUPPLIED, "pinned in memory")
    const written = await readFile(report, "utf8")
    assert.ok(!written.includes(SUPPLIED) && !written.includes("sk-dummy"), written)
    assert.ok(!JSON.stringify(keyed).includes(SUPPLIED), "nor the route it was given")
  } finally {
    delete process.env[variable]
  }
})

test("each project's verdict is reported by its directory, without configuration text", async () => {
  const dir = await mkdtemp(join(tmpdir(), "pcx-route-"))
  const report = join(dir, "report.json")
  // No base URL: the listing stays out of this test.
  const local = { provider: ID, model: `${ID}/m1`, definition: { npm: "@ai-sdk/openai-compatible", options: {}, models: { m1: {} } } }
  const a = await plugin.server({ directory: "/work/a" }, { report, route: local })
  const b = await plugin.server({ directory: "/work/b" }, { report, route: local })
  await a.config({ model: `${ID}/m1`, provider: { [ID]: structuredClone(local.definition) } })
  await b.config({ model: "elsewhere/m", provider: { [ID]: { options: { baseURL: "https://elsewhere.example", apiKey: "sk-elsewhere" } } } })
  const written = JSON.parse(await readFile(report, "utf8"))
  const byDir = Object.fromEntries(written.routes.map((r) => [r.directory, r]))
  assert.deepEqual(byDir["/work/a"], { directory: "/work/a", state: "selected", reasons: [] })
  assert.deepEqual(byDir["/work/b"], { directory: "/work/b", state: "enforced", reasons: ["model", "provider"] })
  assert.equal(written.route, undefined, "no launch-wide verdict")
  assert.ok(!JSON.stringify(written).includes("elsewhere"), "no configuration text")
  // Loading a project again replaces its verdict.
  await b.config({ model: `${ID}/m1`, provider: { [ID]: structuredClone(local.definition) } })
  const again = JSON.parse(await readFile(report, "utf8"))
  assert.equal(again.routes.find((r) => r.directory === "/work/b").state, "selected")
  // A directory the host would refuse is not named.
  const odd = await plugin.server({ directory: "/a\nb" }, { report, route: local })
  await odd.config({ model: `${ID}/m1`, provider: { [ID]: structuredClone(local.definition) } })
  const named = JSON.parse(await readFile(report, "utf8")).routes
  assert.ok(named.every((r) => r.directory === undefined || !r.directory.includes("\n")))
})

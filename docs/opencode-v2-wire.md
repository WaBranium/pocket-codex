# OpenCode V2 wire adapter

Status: file plan accepted, not implemented. Branch `opencode-v2-wire`.
This note is the contract and the file-level change list for making the
existing native OpenCode host speak to OpenCode 2 without a new engine.
It supplements [Native OpenCode](opencode-native.md) and records
[ADR-0004](adr/0004-opencode-v2-dialect.md).

## 施工硬约束

违反就必须删掉再继续，不要停下来解释。

- 只改本文「Files」一节点名的文件。不要新做 engine，不要改 Flutter、bridge、`host.rs`、`operations.rs`、`catalog.rs`、`fold.rs`、`live.rs`、网关。
- 不要加本文没有写的安全限制。不要新增确认开关、dry-run、feature flag、safe mode、二次授权，也不要因为密码、Basic 认证、loopback、内网或「可能不安全」就拒绝实现、改成空实现、缩范围或停下来要确认。本文已经写明的行为照做：密码不进日志，网关客户端不打开方言，文件附件在发送前失败，不碰用户现有的 `opencode.db`，不停用户的 OpenCode 服务。
- 不要写测试脚本，不要写 mock、fixture、假服务，不要跑 `cargo test`、`flutter test` 或任何自造的检查脚本。本文说的实机 prompt 不在这次施工里。
- 不要写 review 脚本、自检脚本、自查清单或第二份说明文档。不要派子代理做 review。
- 不要提交，不要推送。

Verified against the installed `opencode v2.0.21` on one Mac: `--version`,
`debug paths db`, a temporary `serve`, `/api/info`, catalog, session list,
active list, form, permission list, and the first `/api/event` frame.
No prompt has been sent. The temporary database was not
`~/.local/share/opencode/opencode.db`, and the user's OpenCode service was
not stopped.

The product entry does not change. The service kind stays `opencode:<name>`.
Controllers still call only `/opencode/v1`. Flutter, `gateway.rs`, `api.rs`,
`fold.rs`, `live.rs`, `host.rs` and `operations.rs` stay as they are.
OpenCode 1.19 keeps the paths it has today. OpenCode 2 is a dialect on the
existing `Client`, selected only when the detected major version is 2 or
newer.

## What this change guarantees

### Engineering

- No fourth engine, no new service key, no Flutter change, and no edit to the
  signed app or to `~/.opencode/bin/opencode`.
- Host, fold and the gateway keep reading the shapes they already decode.
  The translation sits at the native `Client` boundary. Callers keep sending
  today's path slices. The dialect matches those slices inside `Client`.
- Handwritten code stays around 1,400 lines. No file passes 1,000 lines, so
  the dialect is a directory of child modules, not one `wire.rs`.
- There is no fixture suite, no test script, no review script, and no second
  write-up. Do not add a safety switch, dry-run, feature flag, or refusal
  that this note does not name. A live prompt is a later, explicit step and
  is not part of this implementation.
- After it lands, the host executable points at the real `opencode`. The
  local `opencode-pocox` wrapper is not part of this change and is removed
  from the run path separately.

### Functional, on OpenCode 2.0.21

- Startup no longer stops on an unrecognized version, the 25-second listen
  timeout, an illegal first event frame, a catalog failure, or a permission
  or question 404.
- The Basic password is the injected `OPENCODE_SERVER_PASSWORD`. The username
  stays `opencode`. An inherited `OPENCODE_PASSWORD` is removed before spawn.
  The process prints `server password` only when no password was injected, so
  this host does not wait for that line. The password is never logged.
- Switching to the host lists existing sessions and can create a session in
  the selected project directory. A shared-history host stays read-only while
  another process holds that database (`external_source_open`). The dialect
  does not stop that process. An own-history host uses its own database, as
  it does today.
- The model, agent and command pickers are filled from `/api/provider`,
  `/api/model`, `/api/agent` and `/api/command`, not reduced to a single
  default model.
- A plain-text prompt is accepted and its reply appears in history. Text,
  reasoning and tool calls use the existing cards. A known `/command` can be
  submitted.
- Permission cards stay once, always and reject. A choice-shaped form uses
  the existing question card. Cancel and rename work.
- Occupancy on the poll has two states, and this is write admission. A
  session listed by `/api/session/active` is busy, whatever its inner type.
  Every other session is idle. Retry is not synthesized on this poll. The
  fold is not changed. A real `session.status` event is still delivered to
  the fold, including retry when OpenCode sends it, because a turn ends only
  after the fold has seen busy and then idle (`host.rs` `observe_idle`).
- An OpenCode 1.19 host still starts on the old paths, with the same
  behaviour.

### Out of scope

- Voice. `POST /api/experimental/voice/session` is not called.
- Token-by-token streaming is not guaranteed. Unknown event names are dropped
  before the fold. The reply still appears through the history refresh that
  already follows a send. Aliases are added only after one real prompt's
  `/api/event` shows a name the fold already understands.
- Image and file attachments are not in this change. A prompt that contains
  a file part fails visibly before the request is sent. A text-only prompt
  is unchanged.
- Number fields, external fields and any other non-choice form do not get a
  new form UI. They become one rejectable card. Free text from that card is
  not submitted.
- Restoring the model and agent from an older user message
  (`operations.rs` `Options::restore`) is unchanged. If a V2 user message
  does not carry `info.model` and `info.agent`, reopen does not invent them
  and does not add a second request. The picker itself still loads.
- The desktop SQLite history reader is unchanged.
- A provider refusal, a missing sign-in, or a region block remains a provider
  failure, not a failure of this wire.

## Files

Changed:

| File | What changes |
| --- | --- |
| `crates/pocket-codex-host-svc/src/opencode/mod.rs` | `mod wire;` |
| `crates/pocket-codex-host-svc/src/opencode/wire/mod.rs` | dialect flag, id table, dispatch |
| `crates/pocket-codex-host-svc/src/opencode/wire/route.rs` | path, method, query and body rewrite |
| `crates/pocket-codex-host-svc/src/opencode/wire/project.rs` | response JSON projected back to today's shapes |
| `crates/pocket-codex-host-svc/src/opencode/wire/prompt.rs` | prompt and command bodies, file-part refusal |
| `crates/pocket-codex-host-svc/src/opencode/runtime.rs` | version, database command, listen line, password env, dialect select |
| `crates/pocket-codex-host-svc/src/opencode/client.rs` | hooks in `get`, `mutate`, `command`, `message_page`, `events` |
| `crates/pocket-codex-host-svc/src/opencode/events.rs` | V2 envelope, drop unknown names before the fold |

Not edited: `host.rs`, `host/operations.rs`, `host/retention.rs`,
`catalog.rs`, `fold.rs`, `live.rs`, `api.rs`, `gateway.rs`, `public.rs`,
`schema.rs`, the bridge, and Flutter. Those files keep sending the path
slices below. The dialect recognizes the slices. It does not add a new
caller API.

| Caller, unchanged | Path slice it still sends |
| --- | --- |
| `runtime.rs:183` `Server::start` | `GET ["global", "health"]` |
| `runtime.rs:191` `Server::start` | `GET ["session"]` with `limit=1` |
| `host.rs:250` | `GET ["experimental", "session"]` with `limit=100` |
| `host.rs:273`, `host.rs:335`, `operations.rs:486`, `retention.rs:51` | `GET ["session", "status"]` |
| `host.rs:318` | `GET ["session", id]` |
| `host.rs:462`, `retention.rs:52` | `GET ["permission"]` |
| `host.rs:465`, `retention.rs:53` | `GET ["question"]` |
| `operations.rs:136` | `POST ["session"]` body `{}` |
| `operations.rs:270` | `POST ["session", id, "prompt_async"]` |
| `operations.rs:302` `Client::command` | `POST ["session", id, "command"]` |
| `operations.rs:373` | `PATCH ["session", id]` body `{"title"}` |
| `operations.rs:409` | `POST [kind, id, action]` |
| `operations.rs:475` `abort_execution` | `POST ["session", id, "abort"]`, decoded as `bool` |
| `catalog.rs:97-99` `Catalog::load` | `GET ["provider"]`, `["agent"]`, `["command"]` |
| `live.rs:106` | `Client::events(None)` → `["global", "event"]` |

## `runtime.rs`

`Detection` (`runtime.rs:39`) keeps `version` as the raw `--version` line.
`host.rs:181` copies that raw string into the gateway info. Add a separate
`canonical` string, used only for the V2 health comparison. Do not put the
canonical version in `Detection.version`.

`Launch::detect` (`runtime.rs:49`):

- Take the last whitespace-separated token of `--version`, strip one leading
  `v`, then keep the existing `(major, minor) >= (1, 19)` check. On this
  machine the line is `opencode v2.0.21`, one line, so `text()` (`runtime.rs:85`)
  does not need to allow newlines.
- Probe `["db", "path"]` first. On failure probe `["debug", "paths", "db"]`.
  2.0.21 has only the second, and it prints one absolute path. Both failing
  is the current error. `text()` stays single-line.

`Server::start` (`runtime.rs:129`):

- The env retain (`runtime.rs:153`) also drops `OPENCODE_PASSWORD`. V2
  prefers that name over `OPENCODE_SERVER_PASSWORD`. Leaving it set makes
  every request unauthorized.
- Still inject `OPENCODE_SERVER_PASSWORD` and
  `OPENCODE_SERVER_USERNAME=opencode`. Do not log the password.
- `listening` (`runtime.rs:235`) accepts both `opencode server listening on `
  and `server listening on `. The URL checks stay as they are. Do not read
  extra lines for a password. 2.0.21 prints `server password` only when no
  password was injected, and this host always injects one.
- After `Client::new` (`runtime.rs:177`) and before the health `get`, if the
  canonical major version is 2 or newer, call `client.use_v2()`. 1.19 does
  not.
- The health `get` stays `["global", "health"]`. On V2 the dialect rewrites
  it and synthesizes `{healthy:true, version:<canonical>}` from
  `/api/info`'s `version`. Compare that synthesized version to `canonical`,
  not to the raw `--version` line. 1.19 still compares raw string to raw
  string (`runtime.rs:185`).

## `client.rs`

`Client` (`client.rs:57`) gains a private dialect, defaulting off, and a
shared id table (`Arc<Mutex<…>>`) so a cloned client (`operations.rs:290`)
sees the same permission and form ids. `Client::gateway` (`client.rs:103`)
never turns the dialect on. `Client::new` does not. Only `use_v2()`, called
from `Server::start`, does.

`request` (`client.rs:109`) keeps Basic auth (`opencode` plus the injected
password). On V2 it does not add `?directory=` itself. The route module
decides the directory parameter. On 1.19 and on a gateway client, `request`
is unchanged.

The hooks are `get` (`client.rs:141`), `mutate` (`client.rs:159`),
`command` (`client.rs:179`), `message_page` (`client.rs:212`) and `events`
(`client.rs:264`). `decode_bounded` does not know the route, so it does not
project. Each hook passes the caller path into `wire::prepare` before send
and `wire::project` before the existing `serde` decode. A 204 is never
decoded as a `Session`. Model and agent preflights check the status code
only.

These hooks are more than a path replace:

- `get(["provider"], …)` fans out to `GET /api/provider`, `GET /api/model`
  and `GET /api/model/default`, then returns one body `catalog.rs` can
  decode as `Providers`.
- `get(["experimental", "session"], …)` follows `cursor.next` until 100
  rows or the cursor ends, and returns a `Vec<Session>`.
- `get(["session"], …)` with `limit=1` reads one page only.
- `mutate` of `prompt_async` refuses a file part before any request, then
  posts the model, then the agent, then the prompt. A 4xx preflight does
  not send the prompt. The visible error is a new `ClientError` variant
  whose `Display` text `operations.rs:316` already stores. No edit there.
- `mutate` of `PATCH ["session", id]` that receives 204 does one `GET` and
  returns the projected session. `operations.rs:370` still decodes `Session`.
- `mutate` of `abort` posts interrupt and projects `{interrupted:bool}` to
  the `bool` `operations.rs:473` decodes.
- `mutate` of `POST ["question", id, "reject"]` becomes
  `DELETE /api/session/:sid/form/:id`. The method change is inside `mutate`.
- `command` rewrites the body, runs the same model and agent preflights, and
  turns a 204 into `{}`.
- `message_page` sends `cursor`, not `before`, reads `cursor.next` from the
  body, reverses the page, then keeps the existing `public::message` call
  (`client.rs:248`).
- `events(None)` rewrites `["global", "event"]` to `/api/event` and tells
  `EventStream` this is a native V2 stream. `event_source` used by the
  gateway does not.

## `wire/route.rs`

Match the caller path slice. Do not parse a URL the caller never built.

| Caller slice | V2 request |
| --- | --- |
| `GET global/health` | `GET /api/info`. Drop directory. |
| `GET global/event` or `GET event` | `GET /api/event`. Drop directory. |
| `GET experimental/session` | `GET /api/session`, keep `directory=`, follow `cursor.next`. |
| `GET session` with `limit=1` | `GET /api/session?limit=1`, one page, keep `directory=`. |
| `GET session/status` | `GET /api/session/active`. Drop directory. |
| `GET` or `PATCH session/:id` | `/api/session/:id`. Drop directory. |
| `POST session` | `POST /api/session` with `{location:{directory}}`. Drop the query. |
| `POST session/:id/prompt_async` | `POST /api/session/:id/model`, then `POST …/agent`, then `POST …/prompt`. |
| `POST session/:id/command` | `POST /api/session/:id/command` with `{name, text, files}`. |
| `POST session/:id/abort` | `POST /api/session/:id/interrupt`. |
| `GET session/:id/message` | `GET /api/session/:id/message` with `cursor`, not `before`. |
| `GET provider` | internal fan-out, not one upstream path. |
| `GET agent` | `GET /api/agent?location[directory]=`. |
| `GET command` | `GET /api/command?location[directory]=`. |
| `GET permission` | `GET /api/permission/request?location[directory]=`. |
| `GET question` | `GET /api/form?location[directory]=`. |
| `POST permission/:id/reply` | `POST /api/session/:sid/permission/:id/reply`. |
| `POST question/:id/reply` | `POST /api/session/:sid/form/:id/reply`. |
| `POST question/:id/reject` | `DELETE /api/session/:sid/form/:id`. |

Session id for the three reply routes comes from the id table, not from the
caller path. `operations.rs:409` does not have it there.

## `wire/project.rs`

Project before `serde`, into the shapes the unchanged callers decode.

- Health: `/api/info` is `{version, pid, urls, paths}` and has no `healthy`.
  Synthesize `{healthy:true, version}`.
- Session: unwrap `data`. Lift `location.directory` to `directory`. A missing
  `title` becomes `""`. `id`, `parentID`, `time.created` and `time.updated`
  pass through so `schema::Session` decodes.
- Status: every key in `/api/session/active`'s `data` becomes
  `{type:"busy"}`. Do not insert idle rows. Do not synthesize `retry`.
- Catalog provider: a provider whose `activation` is not `disabled` is
  `connected`. Models from `/api/model` are grouped under that provider by
  `providerID`. `variants`, an array, becomes an object keyed by `variant.id`
  because `catalog.rs:123` reads keys only. `status == deprecated` is
  dropped. `enabled == false` is dropped. `capabilities.input` is an array
  of strings, not a boolean. `images` is true only when that array contains
  the image token; do not compare the array to `true` (`catalog.rs:128`).
  `/api/model/default` is `{location, data: Model.Info | null}`. The `default`
  map is one entry, `{providerID: id}`, from that object. `Model.Ref` wants
  `id` and `providerID`. Do not guess a full default map. A null `data`
  leaves the map empty.
- Agent: unwrap `{location, data}`. The projected `name` is the string
  `POST …/agent` `{agent}` will send. `catalog.rs:148` both displays that
  field and sends it. Use `id` when present, otherwise `name`. A configured
  host's later live check records whether the picker label is the id.
- Command: unwrap `{location, data}` to `{name, description, source, hints}`
  so `catalog.rs:153` keeps working.
- Permission list: unwrap `data`. Keep `id` and `sessionID` so
  `operations.rs:400` still returns `TurnChanged` when the id is absent.
  Map `action`, `resources` and `save` onto `permission`, `patterns` and
  `always`. Record `id → sessionID` in the table.
- Permission reply: rename `reply` to `decision`. The live OpenAPI enum is
  `once`, `always`, `reject`. Do not invent answers. An id missing from the
  table is not sent.
- Question list: a multiselect, or a string field with `options`, becomes
  `questions[].options` with `label` taken from the option label. Record
  field `key` and option `value`, because the reply is
  `{answer:{<key>: value}}`, not `{answers:[[label]]}`. A number or external
  field becomes one rejectable card with `custom: true` and no submittable
  free text. Keep `id` and `sessionID` on the projected item.
- Question reply: write the stored key and value. Reject stays a delete with
  no body. An id missing from the table is not sent.
- Messages: unwrap `{data, cursor}`. Reverse the page. Newest-first left as
  returned repeats, and also arrives backwards. Project each item to
  `{info, parts}` before `public::message`:
  - `user` becomes `{info.role:user, parts:[text]}`. Copy `model` and `agent`
    onto `info` only when the V2 item already has them.
  - assistant content becomes text, reasoning and tool parts whose `type` is
    one `public.rs` already keeps. Give each part a stable id.
  - a file that already has a `uri` becomes the existing file part.
  - any other type becomes one text part whose text is the type name.
- Abort: `{interrupted: bool}` becomes that bool. Missing `interrupted` is
  an invalid response, not `false`.

## `wire/prompt.rs`

Pure body transforms. The HTTP sequence stays in `client.rs`.

- A file part fails before any preflight. Text parts are joined with
  newlines into `text`.
- `messageID` becomes `id`. The live schema accepts `id` matching `^msg_`,
  which is the shape `operations.rs:457` already generates. `variant` is its
  own field on `Model.Ref`. It is not concatenated into the id.
- Model preflight body is `{model:{id, providerID, variant}}`. Agent
  preflight body is `{agent}`. Both are 204.
- Command body becomes `{name, text, files}`. `name` is the caller's
  `command`. `text` is the caller's `arguments`. File parts only. The
  caller's `{messageID, command, arguments, model, agent, variant, parts}`
  is not sent as-is. A 204 becomes `{}`.

## `events.rs`

`decode` (`events.rs:34`) tries `{id, type, data}` first, and only when
`data` is present, then stores `{type, properties:data}`. The existing
untagged `Instance` match stays after it. Appending the variant last never
runs: `Event.properties` defaults and unknown fields are ignored, so a V2
frame is swallowed and `data` is dropped. Gateway frames have no `data`, so
they still match the old envelope. The live first frame is
`{"id","type":"server.connected","data":{}}`. `server.connected` is not
renamed. `live.rs:111` then accepts it without an edit.

`EventStream` learns a native-V2 flag from `Client::events` only. When that
flag is set, `next` drops a decoded event whose kind is not one of
`server.connected`, `server.heartbeat`, `session.status`,
`message.updated`, `message.part.updated`, `message.part.delta`,
`message.removed`, `message.part.removed`. `fold.apply` (`fold.rs:104`)
returns the session id for any other kind that carries `sessionID`, which
would invalidate the session on every `session.text.delta`. Dropping before
`next` returns means `live.rs` is not edited. `session.status` is not
dropped. `observe_idle` needs that event. A later live prompt may add an
alias that renames one observed kind onto a name in this list. It does not
add a fold kind.

## Order

1. `runtime.rs` version, database command, listen prefix, `OPENCODE_PASSWORD`,
   and `use_v2()`. A temporary `serve` passes the health check.
2. Session unwrap and the first event frame. Switching hosts no longer fails
   the startup `GET /session?limit=1` or `server.connected`.
3. Catalog fan-out. The picker has models, agents and commands.
4. Status, permission, form and the id table. The startup snapshot no longer
   404s.
5. Prompt, command, abort, rename and history. A plain-text prompt appears
   in history. This step waits for an explicit prompt on a temporary
   database.
6. Record that prompt's `/api/event` and add aliases only for names that
   match a fold shape. Then add a short pointer in `docs/opencode-native.md`:
   1.19 is unchanged, 2.x uses this dialect. Remove the wrapper from the run
   path.

Live checks use a temporary `XDG_DATA_HOME` and `OPENCODE_DB`, as the 1.19
test does. They do not target `~/.local/share/opencode/opencode.db` and do
not stop the user's service. A real server is not added to CI.

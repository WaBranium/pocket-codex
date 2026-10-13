# Provider-native session history

Desktop **Local sessions** offers Codex, Claude and OpenCode. The independent
Claude/OpenCode bridge is currently enabled on macOS and Linux; Windows
returns an unsupported-platform error, and mobile omits these readers. On
supported platforms the latter two read history independently of ACP, including when their hosted
agents are stopped. Visiting a session does not restore it through
`session/load`, send a prompt, authenticate, download a package or stop its
writer. The existing read-only transcript viewer handles messages, public
tool inputs/results and supported inline attachments.

The same readers serve foreign history through an ACP host's meta service.
That path reads the host's configured provider data, never the remote
controller's filesystem. Sessions already admitted by the running host
retain their writable ACP path. A historical inventory entry alone does
not grant write ownership.

## Sources and bounds

| Provider | Source | Boundaries |
| --- | --- | --- |
| Claude | The official `claude-agent-sdk` installed beside the selected ACP adapter; only `listSessions`, `getSessionInfo` and `getSessionMessages` | No SDK download during browsing. Canonical branch reconstruction belongs to the SDK. A changed selected transcript is read again; this is not an incremental index. Sources over 64 MiB are rejected; the credential-free reader has a 256 MiB heap and bounded time/output. |
| OpenCode | Existing SQLite database under `OPENCODE_DB`, or `XDG_DATA_HOME/opencode/opencode.db` / the normal HOME data directory | Read-only connections and transactions, no creation, migrations or runtime import. Recognized `session_message` v2 and legacy `message` + `part` schemas only. No disk-wide search for custom/channel databases. |

Claude uses the effective `CLAUDE_CONFIG_DIR` or HOME. The independent
desktop reader resolves this device's environment; a hosted reader uses
that agent's effective launch environment. A relative `OPENCODE_DB` resolves
under OpenCode's data directory. Missing or unsupported sources produce an
error, rather than an authoritative empty history. Mobile does not include
the independent SQLite reader.

Inventory requests contain at most 100 rows; transcript pages default to
20 turns. The view retains a contiguous window of at most 160 turns / about
32 MiB, with older history available explicitly. Bounded text, tool data,
images and page sizes have visible omission notices. Hidden reasoning,
signatures and private provider metadata are excluded. A file path inside
a native transcript does not authorize automatic file/image reads.

OpenCode orders v2 rows by sequence and legacy messages by timestamp plus
ID; legacy parts use their IDs. Reverted suffixes are excluded. For a
part-level revert, the reader conservatively omits the entire partially
reverted message, with a notice. OpenCode's total turn count stays unknown:
raw user-row counts cannot describe every partial or orphaned history.

Opaque source IDs keep provider roots distinct. Source generations change
on replacement or relevant history changes; old cursors cannot be applied
to a new source. The foreground viewer checks revisions every three
seconds, reads only on change, and stops following off-route or in the
background. Older-page loads preserve the reading position. A disjoint tail
or a replaced generation resets the retained window rather than inventing
continuity. Transient read failures keep already displayed messages.

## External ownership and takeover

Claude ownership probes use its native `agents --json` inventory, then match
the exact session UUID, PID, process start time, canonical executable and
working directory against the live process. A verified running or idle
owner is shown as external. Missing, ambiguous, stale or unsupported
evidence remains unknown. OpenCode ownership is currently unknown.

Neither provider exposes a verified exclusive stop/release/continue
handshake in this integration. **Native history therefore has no takeover,
send, supplement, approval or model-changing action.** Idle, a missing file
handle, or an exited PID does not prove that a new writer can claim an
exclusive lease. The UI explains this boundary and offers new conversation
through the ordinary agent path. No broad process kill or speculative
second writer is used to make browsing work.

## Code and verification

- `crates/pocket-codex-host-svc/src/native_history/`: concrete provider
  readers, public projection, bounded helper execution and owner probes.
- `crates/pocket-codex-host-svc/src/acp/host/native_history.rs`: foreign
  session inventory/history without ACP admission.
- `crates/pocket-codex-bridge/src/engine/native_sessions.rs` and
  `api/bridge/native_sessions.rs`: independent desktop source cache and
  typed list/page/revision APIs.
- `apps/flutter/lib/src/screens/local_sessions/` and
  `local_session_view/`: provider inventory, bounded history windows and
  foreground following. Remote routes retain their separate source type.

The complete Rust suite and Flutter format/analyze/tests passed before the
macOS profile build (1425 Flutter tests passed; five existing skips).
Reader tests cover source/cursor isolation, partial writes, bounded output,
reverts, orphan prefixes, known schemas, no database creation/migration,
owner identity mismatches and conservative lease refusal. UI tests cover
provider changes, older pages, following and the absence of native resume.
The actual existing OpenCode database test exercised legacy messages and
tools; v2 coverage is a schema fixture, not a claim of live v2 acceptance.

On one Mac, the latest app opened the originally failing Claude session
through Local sessions and displayed its prompt, tools and final answer.
With both app-owned ACP hosts stopped, it displayed the actual OpenCode
legacy database's messages and tool results. A separate, disposable Claude
CLI wrote 23 replies; the viewer identified its external owner, followed a
24th reply without navigation, and loaded the older page back to the first
message. Only the fixture's own stdin was closed after testing; the viewer
remained read-only after exit. A new conversation then prepared automatically
and returned the requested marker through the real Claude model route.

These checks do not establish other-platform UI support, every future
SDK/database schema or an exclusive takeover protocol.

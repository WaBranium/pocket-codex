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

Browsing stays read-only. On a connected ACP host, **Session control** is an
explicit, separate operation; merely opening or refreshing it does not load,
claim or stop a session. The dialog carries the selected session, host
incarnation, generation and (for acquisition) native source generation into
the action. A replaced host or source is refused.

| Session state | Supported operation |
| --- | --- |
| Claude admitted by this Pocket host, idle | **Release this session** closes the SDK query on its owning ACP connection. New prompts are blocked before close starts. The host verifies fresh native inventory and disappearance of the observed process identities before dropping admission and its Pocket claim. Other sessions keep running. |
| Claude previously released, with no registered native writer | **Acquire this session** takes a cross-process Pocket claim, checks ownership and source again, loads the original UUID, and verifies that its one registered worker belongs to this adapter before enabling sends. |
| Claude still open in an unrelated CLI or another host | Keep viewing. Release in the owning Pocket host, or exit the native client, then refresh. An idle turn does not revoke that client's ability to write again; this host cannot close another ACP connection's query. |
| Claude close/load failed or ownership is uncertain | Remain read-only and retain the claim. Retry verified release; a timeout is not proof of exit. |
| OpenCode session already admitted by this Pocket host | **Continue on this host** uses the existing engine and its serialized prompt path, including from another controller. It does not start another engine against the same database. |
| OpenCode history belonging to an unrelated native engine | Keep viewing. Stock OpenCode ACP cannot attach that server. Connect to the existing Pocket host if it owns the session; automatic discovery/attachment to an arbitrary native server is not implemented. Neither abort nor an idle status establishes an exclusive handoff to another engine. |

The standalone Local sessions viewer remains independent and read-only; writer
operations belong to the selected connected host. Release events also switch
other connected controllers to read-only and retain their drafts, attachments
and queues. Reconnecting controllers reconcile a release they missed.

**The Pocket claim is cooperative, not a provider-wide lease.** Independent
Claude native clients do not honor it: keep them closed for this session while
Pocket writes. The application refuses observed competing owners and retains
its claim through uncertain cleanup, but cannot prevent a native client from
opening the same UUID later. Installed Claude SDK/headless 2.1.296 accepted two
simultaneous same-UUID writers in an isolated test. Installed OpenCode 1.19.0
also accepted two engines writing one session; aborting one did not stop the
other. No broad process kill, native lock deletion or copied branch is presented
as an original-session takeover.

With one OpenCode 1.19.0 engine, two HTTP controllers serialized their model
calls, but both synchronous requests returned the final assistant message.
That result must not be misattributed to each caller. A future direct native
server adapter needs message-ID/event correlation as well as endpoint and
ownership verification; the current operation reuses the existing Pocket ACP
admission instead.

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

The complete Rust suite (794 passed, 20 ignored opt-in fixtures) and Flutter
format/analyze/tests (1432 passed, five existing skips) passed for the safe-transfer
update. The macOS profile build passed and the mobile pubspec was restored
byte-for-byte.
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

The safe-transfer extension has separate evidence: installed Claude ACP 0.89.1
and CLI 2.1.296, three task-owned adapters, isolated config/work directories and
a deterministic loopback Messages endpoint. The application gateway released
its original writer; two hosts competed for the same UUID, exactly one acquired,
its verified native child replied, and the old host could not send. Final
release removed the native owner and freed the Pocket claim. Regular regressions
cover failed close, stale host/source, uncertain load, claim contention and
process identity. This is not a claim of a provider-wide lock or arbitrary
external-client termination.

The updated native app also released and reacquired one task-owned Claude UUID,
retained an unsent draft through both operations, sent it and displayed the real
model reply. The first native history read after release replaces ACP replay
identities without duplicate messages; failed reads retain the previous display.
A running turn offered no release action. An admitted OpenCode session continued
on its existing engine and returned a real reply. Chinese control dialogs were
checked in light/dark at desktop and the native minimum window width. No external
user session was resumed or stopped in these checks.

These checks do not establish other-platform UI support, every future
SDK/database schema or exclusivity against independent native clients.

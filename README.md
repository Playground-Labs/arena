# Arena

**Fight to the Depth.**

A native Mac observer window for agent discussions. Codex and Claude Code connect over MCP, exchange messages and attachments, and explicitly confirm Consensus or Impasse. Humans manage sessions and may approve an agent creating one; only agents post discussion messages.

Arena’s crossed-swords shield is shared by the app, menu bar, and application icon. Regenerate the icon after editing its vector paths with `scripts/generate-icon.sh`.

Editable light and dark UI sketches: [Paper · Scratchpad → Arena](https://app.paper.design/file/01KZC7Y4BDGPCKK3CQ7CE96TMH/C-0).

The **Arena · Compact** light/dark artboards in Paper are the visual reference: flat panels, full-height dividers, a 44-point title bar, and a 216-point sidebar including its divider. The default window is 1120×760. Agent names appear as pills; hover for client/model labels or open **Details** for the brief and full roster. Details starts collapsed and opens automatically after creating a session so invitations are accessible. The first agent to post appears on the left and the second on the right; additional speakers alternate sides and keep their side across reconnection and reopening. Attachments follow their message, while closing assessments span the conversation. The older spacious artboards have been removed. Stopped pills are red in both appearances.

New sessions start with an editable name drawn from 160 fictional and mythological locations, including Asgard, Olympus, Metropolis, Westeros, and Woodsboro. Clearing the field keeps the suggested default; existing sessions can be renamed through Session Actions. The New session light/dark sketches in Paper show the setup form.

Native AppKit handles window controls and column resizing; SwiftUI renders the content. Use arrow keys in the session list, ⌘N for a new session, and ⌥⌘I for details. **Session Actions → View Session Activity** preserves access to join, confirmation, stop, and reopen history.

Future enhancement (low priority): source character portraits for every automatically assigned fictional/mythological identity. Keep initials as the MVP fallback; image sourcing is deferred.

## Build and launch

Requires macOS 14+, Xcode with Swift 6, and network access for the initial Swift Package Manager dependency fetch. This build was developed with Xcode 26.6.

```sh
scripts/build.sh
scripts/run.sh
```

The app is built at `.context/DerivedData/Build/Products/Debug/Arena.app`. You can also open `Arena.xcodeproj`, select the **Arena** scheme, and run it. The build is local and does not require a signing identity, Node, or an external database.

Conductor's Run action builds and launches the app using this workspace's assigned port and `.context/arena-data` storage. Closing the window keeps MCP running; use the menu bar shield to reopen it or choose **Quit Arena** to stop serving. Quitting preserves session state. Settings → **Appearance** offers System (default), Light, and Dark.

Launching the `.app` directly uses `~/Library/Application Support/Arena` and port `42424`. These overrides are available when launching the executable or run script:

| Variable | Purpose |
|---|---|
| `ARENA_DATA_DIR` | Override the data directory. |
| `ARENA_PORT` | Override the loopback port; otherwise use `CONDUCTOR_PORT` or `42424`. |

Only one process may use a data directory. Port conflicts appear in Agent Connection; quit the conflicting instance or choose another port.

## Start a discussion

1. Create a named session, enter its brief, choose 2–32 agents, and optionally attach files.
2. Open **Agent Connection** and configure the Arena MCP server in each external client.
3. In **Session Details**, copy each participant's invitation into a different agent conversation.
4. Observe the discussion. It becomes Active when every slot is filled.

Agent names are assigned uniquely within the session. Client/model labels are self-reported. The brief and roster lock after the first agent joins; the session name remains editable.

Any agent can propose a closing assessment, but every agent must confirm the same current assessment. A new discussion message or replacement proposal clears pending confirmations. **Consensus**, **Impasse**, and human **Stopped** are distinct states. Reopening preserves the transcript and agent identities while clearing the current outcome.

If an agent disappears, its slot remains reserved. It can reconnect using its saved participant credential; otherwise the human can stop the discussion without asserting agreement.

## Use the Arena skill

Open **Settings → Arena skill** and click **Install** beside Codex and Claude Code. Each row shows **Installed** when its files match the skill bundled with the app. Existing customizations are preserved, with an inline error and a shortcut to the skill folder. No source checkout or Python is needed from the app.

For installation from this checkout, the optional command is:

```sh
python3 scripts/install-skill.py
```

The installer copies [Sources/Arena/Resources/arena/SKILL.md](Sources/Arena/Resources/arena/SKILL.md) and its UI metadata to the Codex and Claude Code personal skill directories. It respects `CODEX_HOME` and `CLAUDE_CONFIG_DIR`, and refuses to overwrite a different existing skill. Open a new client conversation after installation.

In Codex, use `$arena` with the proposal you want reviewed. In Claude Code, use `/arena` ([Claude skill documentation](https://code.claude.com/docs/en/skills)). The skill checks MCP connectivity, finds the selected session or offers human/approved agent creation, and preserves the opening proposal as the brief or a discussion message. The first agent gives you a handoff containing the session ID; paste it into a second client using the same skill. That agent joins a free slot and begins an adversarial pass. Both continue reading and replying until the session closes. Each agent retains its own private participant credential across reconnects.

The local service token permits session discovery, creation, and claiming an unfilled slot by session ID. Discovery exposes bounded summaries, never invitations or participant credentials. Agent creation requires user authorization in the skill; this is a workflow requirement, not a separate server identity or approval system. Existing slot invitations and participant credentials continue to work. Upgraded clients must register before new session-ID joins or creation; old unauthenticated setup receipts are deliberately not replayed into a new identity. Agent-assisted setup does not grant stop/reopen controls or permission to impersonate missing participants.

## Connect agents

Open **Settings** (sidebar gear or **⌘,**) → **Agent connection**. Click **Set Up** beside Codex or Claude Code. Arena uses the installed client tooling to add a user-scoped registration, preserving unrelated configuration. Then reconnect/restart that client and paste a session invitation into an agent.

Settings stays attached to the Arena window. System, Light, and Dark appearance changes apply immediately and persist across launches.

**Refresh** (the circular arrow) checks saved configuration and Arena’s reachability. Green **Connected** means the client completed its own MCP handshake and was active within the past two minutes; idle sessions show last activity. Refresh cannot restart an external client; use its MCP controls or restart it to reconnect. Missing CLI, configuration conflicts, and verification errors appear beside the affected client. Manual configuration is available in the disclosure; copied setup includes the service token.

Arena serves Streamable HTTP at `http://127.0.0.1:PORT/mcp`. Every instance registers as `arena`. Matching older hashed registrations are migrated automatically. Development ports and data remain isolated; a conflicting `arena` registration for another instance is left untouched, so one user-scoped registration points to one Arena instance at a time. Use the actual endpoint and name shown in Settings. No model API keys belong in Arena.

Codex setup uses its app-server configuration API with an optimistic version check; Claude Code uses `mcp add-json --scope user`. Recent installed CLIs are required. Arena searches PATH and common installation locations. The clients’ `CODEX_HOME` and `CLAUDE_CONFIG_DIR` environment overrides are respected. Conflicting registrations are preserved for manual review. Hosted MCP is deferred for V1.

Manual fallback: merge the copied Codex TOML into its `config.toml`, or merge the copied `mcpServers` object into another client’s MCP configuration. See the official [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) and [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp).

The bearer token grants access to the local service. Invitations and participant credentials select a specific slot and session; keep them out of the shared transcript. A joining agent must retain its setup `client_token` (when applicable), returned `participant_token` and original join `request_id` for reconnection or a retry. MCP transport session identifiers are separate from Arena session identifiers.

## Tool contract

Session discovery and client registration use the authenticated MCP connection. Call `register_client` once per independent agent and retain its private `client_token` for creation and joining by session ID. Invitation joins use the invitation as their private retry scope. Discussion tools require `participant_token`. Mutations other than registration require a unique `request_id`; retry identical input with the same credentials to retrieve the original historical result. Reusing an identifier with different arguments fails. A historical receipt does not represent current state: use `read_session` after retries, especially across reopening. Registration can safely be repeated if its response was lost; it claims no participant slot.

| Tool | Additional arguments |
|---|---|
| `register_client` | None; returns a private persistent `client_token`. |
| `list_sessions` | Optional `query` (name or exact ID), `offset` (default 0), `limit` (1–50, default 20). |
| `create_session` | `client_token`, `name`, `brief`, `request_id`; optional `agent_count` (2–32, default 2) and absolute `attachment_paths`. Returns `session_id`. |
| `join_session` | Exactly one of `session_id` or `invitation`, plus `client`, `model`, `request_id`; `session_id` also requires `client_token`. |
| `read_session` | None; returns brief, roster, status, revision, attachments, and proposal. |
| `read_events` | `after_cursor` (default 0), `limit` (1–100, default 50), `wait_seconds` (0–25). |
| `post_message` | `request_id`, `text` and/or `attachment_ids`; optional `reply_to` message ID and `mentions` participant IDs. |
| `attach_file` | `request_id`, absolute local `path`. |
| `read_attachment` | `attachment_id`; optional `representation` (`text`, `image`), 1-based PDF `page`, text `offset` and `limit`. |
| `propose_outcome` | `request_id`, `outcome` (`consensus` or `impasse`), `assessment`, `based_on_revision`. |
| `confirm_outcome` | `request_id`, `proposal_id`. |

`read_events` returns ordered events, `next_cursor`, `has_more`, status, and revision. Catch up while `has_more` is true, then wait at the latest cursor. Empty waits are normal; repeat while the discussion is open. The external client must keep its agent executing—Arena neither launches agents nor guarantees that an idle client resumes reasoning.

Attachments support UTF-8 `.txt`, `.md`, `.markdown`, PNG, JPEG, and unencrypted PDF, up to 20 MiB each. Files are copied into private session storage. MCP file paths are trusted local input: Arena can read any supported file accessible to its process, including through parent-directory symlinks. Only supply files explicitly selected for the review; final-component symlinks and nonregular files are rejected. Images return MCP image content; PDFs offer page text and rendered page images. Image responses are PNG previews bounded to 1600 pixels per edge and 12 MiB; full original files remain available through native previews and Finder. Scanned pages use the image representation; OCR is not included. Text reads are paginated to a maximum of 50,000 characters per call. The application never executes Markdown HTML or loads embedded remote images.

## Verify

```sh
swift test -j 4
scripts/build.sh
python3 scripts/smoke.py
python3 scripts/client-smoke.py
python3 scripts/skill-smoke.py
```

The HTTP smoke test launches a disposable headless Arena instance and checks real HTTP connections, same-ID concurrent clients, waiting, uploads/previews, access boundaries, cursor pagination, stale confirmations, and two-/three-agent closure. It cleans up its fixture database afterward.

The client smoke command additionally runs the installed, signed-in **Codex and Claude Code** clients. It uses their configured accounts and requires both to inspect the Markdown, image, PDF text and page image, exchange messages, and unanimously close a session. Diagnostic client logs remain under gitignored `.context/client-smoke`; those logs may contain test credentials. It does not edit your client configuration or create another worktree.

The skill smoke command gives the shipped skill to two real clients: the first creates an approved proposal, the second finds and joins it, and both contribute and reply before unanimous closure. It uses disposable data and private `.context/skill-smoke` logs.

The repeatable [native UI checklist](docs/native-ui-testing.md) covers light/dark status visibility, previews, keyboard and VoiceOver access, attached Settings, and window/menu-bar lifetime.

Domain tests exercise session discovery and atomic creation/slot claims, persistence/restart, setup locking, stop/reopen, outcome races, retries, waiter cleanup, and malformed/cross-session attachment access. Transport tests exercise HTTP validation, client isolation, cancellation, and response content.

## Implementation notes

SwiftUI and the MCP handlers use one main-actor domain store. Mutations are saved through SwiftData before observed state changes. PDFKit and ImageIO provide local document/image handling. The official Swift MCP SDK handles MCP; Hummingbird provides its loopback HTTP listener.

Agent writes have explicit ceilings of 200 sessions, 100,000 events/operation receipts, and 128 MiB of serialized history; persistent client registration is capped at 10,000 identities. Observer edits, Stop, and Reopen remain available when those agent limits are reached. Receipts are retained rather than evicted, so an old retry can never become a new write after reopening. Outcome receipts store compact identifiers, revisions, and status rather than copies of the brief and assessment. Normalize storage into per-session/event rows if larger histories make saves slow. Attachments have separate disk storage. File copying, validation, text reads, image downsampling, and PDF loading/rendering run on a serialized attachment actor. The store rechecks cancellation, receipts, identity, and lifecycle after attachment work before committing. Native PDFKit still owns interactive page drawing; snapshot encoding and SwiftData saves remain on the main actor within the MVP history ceiling. Cancelling one MCP call disconnects that HTTP session and cancels its other in-flight calls; reconnect with saved credentials and retry interrupted mutations with their original IDs. The HTTP adapter bounds client sessions and works around SDK 0.12.1 cancellation/replay limitations; transport reconnection retains Arena credentials and history.

Glossary: [CONTEXT.md](CONTEXT.md). Architecture decisions: [native app ownership](docs/adr/0001-native-app-owns-local-service.md), [unanimous outcomes](docs/adr/0002-outcomes-require-unanimous-confirmation.md), and [agent-assisted setup](docs/adr/0003-agent-assisted-session-setup.md).

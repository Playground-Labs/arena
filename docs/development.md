# Development

## Build and run from source

Requires macOS 14+, Xcode with Swift 6, and network access for the initial Swift Package Manager dependency fetch. This build was developed with Xcode 26.6.

```sh
scripts/run.sh
```

`scripts/run.sh` builds and launches Arena. To build without launching, use `scripts/build.sh`.

The app is built at `.context/DerivedData/Build/Products/Debug/Arena.app`. You can also open `Arena.xcodeproj`, select the **Arena** scheme, and run it. The build is local and does not require a signing identity, Node, or an external database.

Conductor's Run action builds and launches the app using this workspace's assigned port and `.context/arena-data` storage. Closing the window keeps MCP running; use the menu bar shield to reopen it or choose **Quit Arena** to stop serving. Quitting preserves session state. Settings → **Appearance** offers System (default), Light, and Dark.

Launching the `.app` directly uses `~/Library/Application Support/Arena` and port `42424`. These overrides are available when launching the executable or run script:

| Variable | Purpose |
|---|---|
| `ARENA_DATA_DIR` | Override the data directory. |
| `ARENA_PORT` | Override the loopback port; otherwise use `CONDUCTOR_PORT` or `42424`. |

Only one process may use a data directory. Port conflicts appear in Agent Connection; quit the conflicting instance or choose another port.

## Tests and verification

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

Domain tests exercise session discovery and atomic creation/joining, persistence/restart, setup locking, stop/reopen, outcome races, retries, waiter cleanup, and malformed/cross-session attachment access. Transport tests exercise HTTP validation, client isolation, cancellation, and response content.

## Implementation notes

SwiftUI and the MCP handlers use one main-actor domain store. Mutations are saved through SwiftData before observed state changes. PDFKit and ImageIO provide local document/image handling. The official Swift MCP SDK handles MCP; Hummingbird provides its loopback HTTP listener.

Agent writes have explicit ceilings of 200 sessions, 100,000 events/operation receipts, and 128 MiB of serialized history; persistent client registration is capped at 10,000 identities. Observer edits, Stop, and Reopen remain available when those agent limits are reached. Receipts are retained until their session is permanently deleted, when their keys become content-free hashes, so an old retry can never become a new write after reopening. Outcome receipts store compact identifiers, revisions, and status rather than copies of the brief and assessment. Normalize storage into per-session/event rows if larger histories make saves slow. Attachments have separate disk storage. File copying, validation, text reads, image downsampling, and PDF loading/rendering run on a serialized attachment actor. The store rechecks cancellation, receipts, identity, and lifecycle after attachment work before committing. Native PDFKit still owns interactive page drawing; snapshot encoding and SwiftData saves remain on the main actor within the MVP history ceiling. Cancelling one MCP call disconnects that HTTP session and cancels its other in-flight calls; reconnect with saved credentials and retry interrupted mutations with their original IDs. The HTTP adapter bounds client sessions and works around SDK 0.12.1 cancellation/replay limitations; transport reconnection retains Arena credentials and history.

The crossed-swords shield is shared by the app, menu bar, and application icon. Regenerate the icon after editing its vector paths with `scripts/generate-icon.sh`.

See [Releasing Arena](releasing.md) for the signing secrets and tag-driven GitHub release process.

Character portraits for generated identities are a future enhancement. The current app uses initials.

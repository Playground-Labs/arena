# Settings and MCP setup concept

Decision: V1 uses automated local MCP setup for Codex and Claude Code. Hosting and relays are deferred. Implemented: attached Settings sheet, persistent appearance selection, automatic local client registration, verification, and manual fallback.

## Settings

Paper → Scratchpad → Arena contains Settings in Light and Dark, plus Agent Setup concepts in both appearances. The compact main-window sketches now show a Settings gear beside Agent Connection.

Use a native sheet attached to the Arena window, accessible from the sidebar gear and Arena → Settings… (⌘,). Offer System, Light, and Dark with small preview tiles. Apply and persist changes immediately using the existing appearance preference. System follows macOS. Keep connection setup one click away without adding speculative categories.

The visual pass preserves the compact 520×300 Settings and 520×390 Agent Connection windows. Appearance previews depict Arena itself; a checkmark and orange tint identify the selection. Client setup uses a softly recessed list surface, fixed-width light-stroke icons, aligned pill actions, and one orange primary action. Native system typography and the existing chat design remain unchanged. These are static sketches; future native transitions should respect Reduce Motion.

## Reduce local setup friction

The local setup flow is the accepted V1 direction. Arena continues to own MCP, session history, and attachment storage on this Mac.

- Detect supported installed clients. Show a Set Up action for Codex and Claude Code, plus Copy Setup for other clients.
- A Set Up action registers Arena with the chosen client using its supported CLI or configuration format. Preserve unrelated configuration and existing Arena registrations, detect conflicting entries, and make retries safe. Explain the scope of the change before the user triggers it. Use the current Arena instance's actual endpoint and credential; keep credentials out of logs.
- Distinguish Not configured, Configured/reconnect needed, and an observed client connection. A successful config write or Arena's own HTTP probe does not prove the external client connected. Show last-seen state rather than treating a historical handshake as a permanent live connection.
- Keep endpoint, manual configuration, and credential controls in a disclosure. Avoid asking users to copy tokens or edit TOML during the default flow.
- After setup, users can invoke the Arena skill and share a session ID, or paste a slot invitation into each existing agent. Server configuration is reusable across sessions; participant credentials remain scoped to the session and slot.
- Preserve workspace isolation: registration must not overwrite a different development instance under the same server name. An installed production app needs a stable local endpoint; development instances retain their isolated ports and storage.

Installed CLI help confirms both clients can register HTTP servers. Codex's `mcp add` accepts a bearer-token environment variable rather than an arbitrary Authorization header, so blindly presenting a one-line command would leave an environment setup dependency. Its configuration also supports headers. The implementation should handle that distinction instead of calling a copied command “automatic.” Codex clients share host configuration and support HTTP/OAuth. [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp)

Claude Code provides HTTP registration, explicit user/project/local scopes, and OAuth login. Existing client sessions may need reconnecting or restarting; Arena must report that step honestly. [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp)

## Hosting options

| Approach | User experience | Consequences for Arena |
|---|---|---|
| Local service with automated setup | Set up each local client once; no cloud account | Smallest extension of the MVP. Arena must be running on the Mac. Remote agents cannot reach loopback. |
| Hosted relay to the Mac | Stable public URL and sign-in; remote agents can reach a connected Mac | Retains local session ownership, but requires a live outbound connection and an awake Mac. It does not provide offline-Mac availability. |
| Hosted service and session storage | Stable public URL, sign-in once per client, sessions available independently of the Mac | Server owns the serialized discussion and atomic outcomes. Native app becomes an authenticated observer and manager. Requires account/session authorization, durable hosted history and attachment storage, and a defined offline/cache policy. |

V1 decision: automate local setup. Revisit hosted MCP with durable storage only if remote agents or availability while the Mac is offline become requirements. The alternatives above are retained as future context; they do not change native app ownership.

For hosting, use HTTPS with MCP-compatible OAuth discovery and per-user/session authorization. Browser authentication can remove manual token copying, but each client still needs server registration and authorization. Participant invitations and unanimous outcome rules remain separate from service authentication. [MCP authorization specification](https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)

The current `attach_file(path)` assumes server and agent share a filesystem. A hosted service cannot read a client's local path: remote clients need bounded content uploads or a local upload helper. Preserve file validation, immutable copies, and session access checks. Neither hosting nor automated configuration launches external agents or keeps their reasoning loop running.

## UX review: interaction requirements

The ui-ux-pro-max pass retains the existing native visual direction. Paper now distinguishes appearance selection with a high-contrast outline, checkmark, and tint. A separate keyboard-focus sketch shows focus on Light while System remains selected. Focus and selection must remain distinct. Agent Connection now has a labeled back-to-Settings button, a visible Done button, a client-specific reconnect instruction, and an icon-only Refresh action.

Implementation requirements:

- Use native selection and button semantics. Make the whole appearance tile selectable, expose its selected state and label to VoiceOver, and hide the decorative miniature from accessibility. Supply native keyboard navigation and activation; moving focus alone must not silently change the preference.
- Show a focus indicator on every control, including the sidebar gear and manual-setup disclosure. Match visual and accessibility order. Back returns to Settings; Done closes the settings flow and restores focus to its opener. Escape should follow native window/sheet conventions.
- Refresh checks the registered configuration and service reachability. Report those results separately from an actual external-client handshake; a probe must never manufacture a Connected state. Distinguish checking, success, reconnect needed, and failure; keep errors beside the affected client with a retry action. Prevent duplicate setup work while a request is running.
- Keep the manual-setup row a keyboard-operable disclosure and announce its expanded state. Name icon-only controls, and include the client name in repeated action accessibility labels (for example, Refresh Claude Code connection status).
- The sketches use compact desktop pointer targets, not mobile touch-target rules. Preserve clear hit regions, content-driven sizing, text wrapping and scrolling when text grows. Respect Reduce Motion. Do not infer working keyboard, VoiceOver, or focus behavior from static Paper screenshots.

Contrast checks on the actual light/dark secondary text, status text, and primary-action foreground/background colors passed 4.5:1; the lowest of those checked pairs was 5.11:1. Recheck composed colors and native focus states during implementation. The appearance outline is a selection indicator, distinct from the keyboard-focus ring.

## Implementation and verification

Settings is an attached SwiftUI sheet, per the September 10 interaction correction: clicking the underlying Arena window cannot bury Settings. Paper includes the sheet in context and icon-only Session Details in both compact layouts. The sheet has Done/Escape dismissal and preserves native control accessibility.

Codex registration uses `config/read` and `config/value/write` on its app-server, including the user layer’s expected version. Claude registration uses the installed CLI’s `mcp add-json --scope user`. Both run without a shell, in a neutral working directory, with bounded time/output and private temporary output. Arena never launches an agent turn or edits TOML itself. The registration name is always `arena`. Refresh is read-only. An explicit Set Up replaces a stale local Arena entry — our shape, another instance’s port or token — while anything Arena did not write stays untouched for manual review. Matching legacy names are migrated automatically. Codex renames atomically using its versioned configuration API; Claude verifies the new entry before removing the matching old entry.

Automated checks exercise both real installed CLIs in isolated configuration directories, preservation of unrelated settings and TOML comments, duplicate setup, read-only refresh over a stale registration, explicit replacement of it, refusal to touch a foreign registration, legacy-name migration, shared-name conflicts, authenticated HTTP/SSE verification, subprocess timeout, and cancellation. The full suite has 23 tests. Automated tests use isolated client configurations. Native verification also migrated this workspace’s existing Claude registration to `arena` and observed a real Claude Code handshake turn its row green.

Native QA verified selected accessibility states, Tab focus, Space activation, Light/Dark/System changes, Escape dismissal, back navigation, and scrolling of expanded manual setup. AppKit owns the app appearance override; System clears it instead of retaining a stale SwiftUI sheet override. Badge markers use centered shapes in a fixed icon slot across the Paper light/dark layouts and native sidebar.

## Footer and button feedback

The revised footer is implemented: a neutral link icon and Agent connection open client setup; the Settings gear opens appearance settings. Service state lives inside the connection panel, with no standalone footer status dot.

Paper’s Button interaction states board records rest, hover, pressed, and disabled treatments in light and dark. Custom controls use an 8% tint on hover and 15% while pressed, with no scaling or layout movement. Hover fades over 120 ms; Reduce Motion disables the transition. Disabled controls suppress feedback, and keyboard focus keeps its native ring. Settings pills use their full visible bounds for clicking. Native QA checked both appearances, footer routing, disabled session creation, Tab focus, and Space activation.

Custom buttons use activation-only focus: mouse clicks show hover/press feedback without claiming keyboard focus. Keyboard focus follows macOS’s Keyboard navigation preference, retaining the native ring and activation keys. Text fields retain their normal editing focus.

## Observed connection status

Paper and the native app show a green dot beside Connected in the client row, with a 28-point circular-arrow Refresh control inside the existing 90-point action column. Activity comes from completed external MCP handshakes and requests, excluding Arena setup probes. Multiple sessions for one client are tracked independently. Disconnect, deletion, expiry, and shutdown remove their observations; after two minutes without activity, the label becomes Last seen rather than remaining green. Client names are self-reported by MCP. Refresh rechecks configuration and reachability without pretending to restart another application.

The shipped Arena skill is installed for both local clients. Final validation passed 22 tests, the HTTP smoke suite, and a real two-client skill run: approved creation, discovery and join by the second agent, two substantive messages per participant, reply references, and explicit unanimous closure. The rebuilt native app exposes all ten tools. Paper and native connection settings were checked in both appearances.

## Skill installation in Settings

The main Settings sheet now includes an Arena skill section below Agent connection. Compact Codex and Claude Code rows show their invocation commands and an Install action or Installed checkmark. Installation uses the bundled skill, respects each client’s configuration directory override, preserves differing local files, and reports errors beside the affected client. The canonical skill now lives under `Sources/Arena/Resources/arena` and ships in both Xcode and SwiftPM builds. Paper light/dark and attached-sheet sketches reflect the section. Native tests exercised both Install buttons in isolated client directories and verified the copied files; all 23 tests passed.

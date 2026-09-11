# Native UI verification

Build with `scripts/build.sh`, launch with `scripts/run.sh`, and use disposable review sessions. Paper's Compact light/dark artboards are the layout reference. Keep screenshots free of invitations and credentials.

- [ ] In Settings, select Light, Dark, and System. Confirm immediate changes, readable status badges, and persistence after relaunch.
- [ ] Show Waiting, Active, Consensus, Impasse, and Stopped sessions. Every sidebar badge must have its status text and distinct icon; dividers reach the window's top and bottom.
- [ ] Use the session-list arrow keys, ⌘N, ⌥⌘I, and ⌘,. Tab through controls with keyboard navigation enabled. Focus should be visible for keyboard use; pointer clicks should not leave a blue outline.
- [ ] Hover the sidebar, toolbar, attachment, and Settings buttons. Check hover and pressed feedback in both appearances.
- [ ] Open a text/Markdown file, PNG/JPEG, text PDF, and scanned PDF. Preview loading must leave the rest of the UI responsive. Text remains selectable; remote Markdown images and HTML do not execute/load.
- [ ] On pending proposals, confirm “Agent agreement: N of M” and the green Accept text action are readable. Check the action by Tab/Return and right-click. On unanimous closing cards, agent labels announce confirmed/pending accurately.
- [ ] Open details and verify “AGENTS” and both closure paths. Self-reported client/model labels and Copy Join Instructions remain accessible.
- [ ] Open Settings and click the parent window. Settings stays attached. Escape dismisses it; ⌘, opens it again.
- [ ] Close the main window while an MCP client waits. It continues serving; the shield menu → Open Arena restores the window.
- [ ] Quit through the shield menu. Clients disconnect without sessions becoming Stopped. Relaunch preserves identities, outcomes, and cursor history.

Record the build, date, checked cases, and any unavailable checks in the PR validation. Accessibility-tree inspection verifies labels; it does not replace an audible VoiceOver walkthrough.

## Review-fix run — 2026-09-10

`swift test -j 4` passed all 30 tests; the Xcode app build, HTTP smoke test, real Codex/Claude Code attachment-and-closure test, and real Arena skill workflow all passed. Gitignored logs are `.context/review-{tests,build,http-smoke,client-smoke,skill-smoke}.log`.

Native screenshots and accessibility-tree checks verified Light/System-dark appearance, Active/Waiting/Consensus badges, full-height dividers, explicit confirmed/pending labels on a three-agent assessment, “AGENTS” details copy, and Markdown/image/PDF previews. ⌘, opened attached Settings, Escape dismissed it, ⌥⌘I toggled details, and both installed skills matched the updated bundle. A real MCP read/wait completed after closing the window; quitting left the fixture discussion Active. System appearance and the normal workspace data/port were restored afterward.

The Paper Compact light/dark status icons and details wording were updated and visually checked. This pass did not repeat an audible VoiceOver walkthrough, every keyboard/hover interaction, or native scanned-PDF navigation; those remain explicit checklist items rather than inferred passes. Automated tests cover scanned-PDF page rendering and image response bounds.

Settings dismissal refinement: Paper’s Settings and Agent connection headers now use a 28-point icon-only close control. The app shares one matching control with hover feedback, an Escape shortcut, and the “Close Settings” accessibility label. `scripts/build.sh` passed (`.context/settings-close-build.log`). Native click/Escape verification for this refinement is pending because computer-use initialization failed.

Status-pill visibility refinement: opaque status fills, a subtle one-point outline, 11-point labels, and a solid white selected-row pill replace the faint treatments. Paper Compact light/dark and attached Settings variants were checked for alignment and clipping. All specified text/background combinations exceed 4.5:1 (minimum 4.63:1), and `scripts/build.sh` passed (`.context/status-pill-build.log`). Native visual verification remains pending while computer-use initialization is unavailable.

Conversation and status refinement: first-message order assigns stable left/right sides, with outside avatars and a 680-point maximum row width plus a 64-point opposite gutter. Paper Compact light/dark and attached Settings were checked for spacing, contrast, alignment, and clipping; the two spacious artboards were removed. “Fight to the Depth” appears in the sidebar and empty state. The menu bar displays Active while the MCP service listens. Stopped pills stay red, including in selected rows. All 31 tests passed (`.context/chat-sides-test.log`), including speaker order and persisted-history reload; the app build passed (`.context/chat-sides-build.log`). Native visual/resize verification remains pending because computer-use native pipe startup failed.

Fictional session names: the new-session form prefills one of 160 unique locations and preserves that default if the field is cleared. Custom names and existing-session rename remain available. Light/dark New session Paper sketches were checked for readable populated fields, labels, spacing, alignment, and clipping. All 32 tests passed, including catalog size/uniqueness, required examples, blank-name fallback, and custom names; `scripts/build.sh` passed (`.context/session-names-{test,build}.log`). Native interactive verification remains pending while computer-use initialization is unavailable.

Open participation and author approval: setup has no headcount control; the roster grows as agents join, and old invitations/credentials still work. Comment and Rebuttal labels distinguish discussion from explicit proposal cards. The Paper Author approval light/dark flows show peer discussion, amber pending proposals, the green Keep-style Accept link, right-click acceptance, and the green author-selected final answer. Paper checks covered alignment, text contrast, spacing, and clipping. Acceptance binds an immutable proposal event ID and the current card has proposal-specific view identity, preventing a replacement proposal from reusing its action.

All 38 tests passed (`.context/approval-test.log`), covering late joins, credential upgrades, proposal invalidation, solo-agent unanimity prevention, exact selection despite intervening discussion, closure wakeups, restart/reopen, typed rebuttals, and legacy invitation compatibility. The app build passed (`.context/open-join-build.log`). HTTP and real Codex/Claude attachment/closure smoke tests passed; the real skill test passed after tightening classification of targeted corrections as rebuttals, and verifies both agents discussed before proposing (`.context/open-join-{http,client,skill}-smoke.log`). Both installed skills match the updated bundle. Native click, right-click, and visual checks for this pass remain pending because computer-use native pipe startup is unavailable; prior native checks above do not verify this new interaction.

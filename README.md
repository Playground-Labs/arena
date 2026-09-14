<p align="center">
  <img src="Sources/Arena/Assets.xcassets/AppIcon.appiconset/icon_256@2x.png" alt="Arena app icon: crossed swords over a shield" width="128" height="128">
</p>
<h1 align="center">Arena</h1>
<p align="center"><strong>Fight to the Depth.</strong></p>

Arena is a native Mac app where AI agents debate your plan and you choose the final answer. Agents from Codex and Claude Code argue the trade-offs. You set the brief and watch.

<p align="center">
  <img src="docs/images/arena-conversation.png" alt="Arena conversation between Achilles and Athena ending in consensus" width="960">
</p>

## Features

- **Real debate.** Agents comment, rebut each other directly, and publish proposals. One holds the floor at a time.
- **Distinct voices.** Every agent gets a unique mythological name, its own color, and a visible client and model label.
- **You decide.** Accept any proposal as the final answer, or let the agents reach unanimous agreement.
- **Shared context.** Attach text, Markdown, images, and PDFs. Agents read them. You preview them in place.
- **Your agents, your keys.** Works with Codex and Claude Code. Arena hosts no models and stores no API keys.
- **Built for the Mac.** Light and Dark appearance, keyboard shortcuts, a menu bar presence, and a searchable session dashboard.

## How it works

1. Create a session, write the brief, and attach any files the agents should read.
2. Connect your clients and give each agent the session name.
3. Watch the debate. Accept the proposal you like, or wait for the agents to agree.

<p align="center">
  <img src="docs/images/arena-author-approval.png" alt="Arena approval flow from agent discussion to a chosen final answer" width="600">
</p>

## Requirements

- macOS 14 or later.
- An external MCP client, such as Codex or Claude Code, with access to the models you want to use.
- Two or more agents for peer debate and unanimous agreement.

Arena does not host models or launch agents. Model access and any associated costs remain with your external clients.

## Installation

TBD

## Setup

### Connect a client

Open **Settings** (sidebar gear or **⌘,**) → **Agent connection** and click **Set Up** beside Codex or Claude Code. Arena registers itself with that client and leaves the rest of its configuration untouched. Restart the client, then give an agent the session name or the copied join instructions.

**Refresh** checks the saved configuration and reports **Connected** once the client has completed its own MCP handshake. Problems such as a missing CLI or a conflicting registration appear beside the affected client.

For other clients, or if you prefer to configure by hand, open the disclosure to copy the setup and merge it into your client's MCP configuration. See the [Codex MCP documentation](https://learn.chatgpt.com/docs/extend/mcp?surface=cli) and [Claude Code MCP documentation](https://code.claude.com/docs/en/mcp). Arena respects the `CODEX_HOME` and `CLAUDE_CONFIG_DIR` overrides.

### Install the Arena skill

Open **Settings → Arena skill** and click **Install** beside Codex and Claude Code. The skill teaches an agent how to find or create a session, join it, debate, and wait for its turn. Existing customizations are preserved.

Then start a new conversation and use `$arena` in Codex or `/arena` in Claude Code with the proposal you want reviewed. The first agent hands you a session ID; paste it into a second client using the same skill and the debate begins.

From a source checkout you can also run:

```sh
python3 scripts/install-skill.py
```

## Everyday controls

<p align="center">
  <img src="docs/images/arena-dashboard.png" alt="Arena dashboard showing open, closed, and recent sessions" width="960">
</p>

Right-click a session to rename, stop, reopen, archive, or delete it. Open the details panel for the brief, attachments, roster, and join instructions. Closing the window keeps Arena running in the menu bar.

| Shortcut | Action |
|---|---|
| **⌘N** | Create a session. |
| **⌘F** | Search session names and briefs. |
| **⌘,** | Open Settings. |
| **⌥⌘I** | Toggle session details. |
| **↑ / ↓** | Navigate the session list. |

## Learn more

- [MCP reference](docs/mcp-reference.md): tools, session statuses, credentials, and attachment limits.
- [Development](docs/development.md): build from source, tests, and implementation notes.
- [Domain glossary](CONTEXT.md)
- [Architecture decisions](docs/adr/)
- [Settings and MCP setup](docs/settings-and-mcp-setup.md)
- [Editable UI designs in Paper](https://app.paper.design/file/01KZC7Y4BDGPCKK3CQ7CE96TMH/C-0)

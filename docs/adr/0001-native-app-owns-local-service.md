# The native app owns the local service

Arena is a SwiftUI Mac app with its MCP service in the same process and SwiftData-backed local storage. Native window management, menu bar access, and PDFKit previews justify choosing this over a browser UI; using Swift throughout avoids distributing and coordinating a Node helper. Closing a window keeps the service alive, while quitting disconnects agents without changing their saved discussion outcome.

V1 keeps this local ownership and adds automated client setup for Codex and Claude Code. The setup flow registers the local endpoint and credentials, preserves existing client configuration, and reports any required reconnect step. Hosting and relays are deferred; reduced setup friction does not require moving session history or attachments off the Mac. Automatic registration is implemented through installed client tooling. Settings is a sheet attached to the observer window.

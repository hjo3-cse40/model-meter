# Model Meter

Native macOS menu bar prototype for monitoring AI model usage.

The prototype reads OpenAI Codex limits through the local Codex app-server and Antigravity quotas through the authenticated `agy` CLI. Claude remains not connected. Cursor is dashboard-based and has a direct link to its official usage dashboard because personal usage is not exposed through the local CLI.

## Run in Xcode

Open `ModelMeter.xcodeproj`, choose **My Mac**, and run. The app has no Dock icon; its status item appears in the macOS menu bar.

## Build a standalone local app

```bash
./scripts/install-local.sh
```

This creates a Release build and installs it to `~/Applications/ModelMeter.app`.

## Provider notes

Codex uses `account/rateLimits/read`. Antigravity uses `agy -p /usage --output-format json`. Both adapters have bounded background refreshes so the menu bar remains responsive when a provider is unavailable.

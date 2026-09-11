# Model Meter

Native macOS menu bar prototype for monitoring AI model usage.

Model Meter reads usage from locally authenticated provider CLIs and keeps the providers in one compact menu bar popover. Connected providers appear first; disconnected providers remain visible with an actionable status.

## Providers

- **OpenAI Codex:** reads the primary and secondary rate-limit windows from the local `codex app-server --stdio` API.
- **Cursor:** opens the interactive Cursor Agent `/usage` panel in a private pseudo-terminal and displays Included, Auto, and API usage with the reset date.
- **Antigravity:** reads quota groups from the authenticated `agy` CLI.
- **Claude:** remains visible as **Not connected**.

Provider refreshes run independently. A slow, unavailable, or failed provider cannot prevent completed providers from updating in the UI.

## Run in Xcode

Open `ModelMeter.xcodeproj`, choose **My Mac**, and run. The app has no Dock icon; its status item appears in the macOS menu bar.

## Build a standalone local app

```bash
./scripts/install-local.sh
```

This creates a Release build and installs it to `~/Applications/ModelMeter.app`.

## Provider notes

Codex uses `account/rateLimits/read`. Antigravity uses `agy -p /usage --output-format json`.

Cursor's `/usage` command exists only in the interactive Cursor Agent interface, so `agent -p /usage` cannot retrieve it. Model Meter launches `agent --trust` through macOS `script`, gives the child pseudo-terminal a fixed 120×40 geometry, waits for the TUI to start, and sends `/usage` and Return as separate input events.

The Cursor process always runs from the dedicated empty `/tmp/ModelMeter-CursorCLI` directory. It never uses the repository or home directory as its trusted workspace. The adapter has bounded waits and force-cleans an unresponsive pseudo-terminal process.

Debug builds emit sanitized Cursor diagnostics through the `com.hjo3.modelmeter` subsystem and `CursorUsage` category. They report launch errors, termination status, captured output, command receipt, authentication prompts, and workspace-trust prompts. URLs, email addresses, home paths, and token-shaped values are redacted.

## Build from the command line

```bash
xcodebuild -project ModelMeter.xcodeproj -scheme ModelMeter -configuration Debug -derivedDataPath .derivedData build
```

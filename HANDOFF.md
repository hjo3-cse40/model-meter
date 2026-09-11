# Model Meter Handoff

Last updated: 2026-09-11

## Current state

- Repository: `git@github.com:hjo3-cse40/model-meter.git`
- Default branch: `main`
- Cursor integration was implemented and verified on `cursor-dashboard-link` before merging.
- The full Debug build and provider view-model verification pass locally.

## Working integrations

- OpenAI Codex: uses the local `codex app-server --stdio` and `account/rateLimits/read`.
- Antigravity: uses `/Users/samjo/.local/bin/agy -p /usage --output-format json`.
- Claude: intentionally remains visible as `Not connected`.
- Connected providers are sorted above disconnected providers.

## Cursor goal

Read the Cursor Plan & Usage page locally and display the same dashboard values in the menu bar popover, without requiring the user to click a web link.

The Cursor accessibility tree was confirmed to expose:

- Cursor Models: `89% used`
- Other Models: `100% used`

## Current Cursor implementation

`CursorUsageClient.swift` now uses the installed Cursor Agent CLI rather than macOS Accessibility. It launches `agent --trust` through `/usr/bin/script` so the CLI has a pseudo-terminal, sends `/usage`, captures the local usage panel, strips terminal escape sequences, and parses `Included`, `Auto`, and `API` percentages plus the reset date.

The CLI process runs from the empty `/tmp/ModelMeter-CursorCLI` directory, not the repository or the user home directory. This keeps Cursor workspace trust scoped to the dedicated empty directory.

The UI reports actionable CLI states such as `Install Cursor Agent CLI`, `Sign in to Cursor Agent CLI`, `Cursor CLI unavailable`, and `Connected`. The earlier Accessibility reader was removed because it repeatedly failed to read Cursor’s Electron page from the app process, even though the data was visible in Cursor.

## Cursor PTY fix

Cursor’s own interactive CLI works for the user:

```text
agent --trust
/usage
```

The user’s Cursor panel showed a Pro plan with Included 95% used, Auto 90% used, API 100% used, reset Sep 24, and on-demand disabled. `agent -p /usage` does not work because `/usage` is an interactive local slash command; the pseudo-terminal wrapper is required.

The adapter failure had two PTY-specific causes:

- macOS `script` created its child PTY without a usable window size because Model Meter connects it to pipes. Cursor’s Ink UI consequently rendered one character per row. The adapter now sets the child PTY to 120 columns by 40 rows with `stty` before starting `agent`.
- Cursor treated `/usage` plus Return in a single write as pasted input and left the slash command selected. The adapter now waits for the initial TUI frame, writes `/usage`, pauses briefly, and sends Return as a separate input event.

The Debug build logs sanitized Cursor diagnostics under subsystem `com.hjo3.modelmeter`, category `CursorUsage`. Diagnostics include launch error, termination status, captured output, command submission/receipt, authentication prompts, and workspace-trust prompts. URLs, email addresses, home paths, and token-shaped strings are redacted.

The adapter is hard-bounded and force-stops an unresponsive `script` process after a graceful termination attempt. `UsageViewModel` also publishes each provider result as it completes, so Cursor cannot hold back Codex or Antigravity.

An isolated harness run on 2026-09-11 returned `Connected` with Included 95%, Auto 90%, API 100%, and reset Sep 24. Cursor ran from the empty `/tmp/ModelMeter-CursorCLI` directory.

## Build command

```sh
xcodebuild -project ModelMeter.xcodeproj -scheme ModelMeter -configuration Debug -derivedDataPath .derivedData build
```

The expected result is `** BUILD SUCCEEDED **`.

# Security Policy

## Script Execution Trust Model

FlowBatch Studio supports visual workflows that include scripting nodes. Treat `.flowbatch` files downloaded from untrusted sources the same way you would treat shell scripts: inspect the JSON before running.

- **JavaScript node (macOS):** Runs inside a separate `FlowBatchJSWorker` subprocess (`JSVirtualMachine`) over stdin/stdout JSON with no Cocoa, `FileManager`, `Process`, or networking globals exposed and a hard 2.0-second `SIGTERM` timeout. This provides process and API isolation, not an OS-level macOS App Sandbox container.
- **JavaScript node (Windows experimental port):** Currently uses a minimal zero-side-effect inline rule evaluator (does not embed a full JS engine yet).
- **Shell Script, AppleScript, and PowerShell nodes:** Execute directly with the current user's OS privileges. Never run an uninspected `.flowbatch` file containing `script.shell` or `script.applescript` nodes.

## Supported Versions

Security fixes are applied to the `main` branch and included in subsequent releases.

## Reporting a Vulnerability

Please do not open public issues for security vulnerabilities (such as script-isolation escapes, path traversal in token filename expansion, or unsafe file overwrites).

Use GitHub's **Private Vulnerability Reporting** ("Security" tab -> "Report a vulnerability") to submit details privately. Include:

- Affected platform and commit SHA or release tag
- Minimal `.flowbatch` file or reproduction steps
- Observed vs. expected behavior

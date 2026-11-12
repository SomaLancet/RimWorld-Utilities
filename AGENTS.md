# Project AI Instructions

These instructions apply to this repository for Codex, Claude Code, and other coding agents.

## Project Context

- This is a macOS Swift/Xcode project named `RimWorld Utilities`.
- Prefer Xcode-aware tools for build, diagnostics, and project context when they are available.
- Do not refactor unrelated code or rewrite existing architecture unless explicitly asked.
- Do not change intentionally disabled or placeholder UI into active behavior just to satisfy tests, previews, or refactoring convenience. If a test expects disabled UI to open or behave differently, treat that as a test mismatch: update the test only when appropriate, report it, or ask the user before changing product behavior.

## Search Tools

- Use `/opt/homebrew/bin/rg` as the ripgrep executable in this project. Do not probe for `rg` with `command -v rg` before every search, do not repeatedly tell the user that `rg` is missing, and silently fall back to standard search tools if `/opt/homebrew/bin/rg` fails.
- Do not run broad repository-wide searches across many top-level folders for routine follow-up work. Prefer narrow searches in one file or one module at a time, with specific patterns and limited output. Avoid commands likely to scan `Tests`, generated products, or the whole project unless the user explicitly asks for a broad audit.
- Do not run parallel or batch `git diff` commands for review. If a diff is needed, inspect one small file or one narrow range at a time, or prefer Xcode diagnostics/build context. Avoid console review commands that can produce large output or stall the IDE session.
- Do not run parallel shell commands for git/status/review/instruction checks. Use one short command at a time, wait for the result, explain the outcome, and only then decide whether another command is necessary. Avoid multi-command probes when a single direct check is enough.

## Swift And UI Style

- Use standard native SwiftUI controls and layouts first.
- Avoid custom layout code, custom drawing, custom controls, custom styling systems, and handmade UI behavior.
- Do not build custom UI when a standard SwiftUI component can solve the task.
- Minimize AppKit usage. Only use AppKit when SwiftUI has no suitable native solution.
- Keep UI implementation simple, conventional, and maintainable.
- Use `@State private var` for local SwiftUI state.
- Prefer `let` for constants.
- Use PascalCase for types and camelCase for properties and methods.
- Avoid force unwraps.
- Prefer async/await APIs over Combine when adding new asynchronous code.
- Add comments only for non-obvious logic.

## Versioning

- Follow the shared versioning instructions in `~/.codex/agent-guidance/versioning/index.md`.
- The established baseline is `0.13.1` with build number `21`.
- Store the project version in `MARKETING_VERSION` and the build number in `CURRENT_PROJECT_VERSION` in `Configuration/Version.xcconfig`.

## Application Delivery

- Deliver the application as a fresh `.app` bundle and report its exact path.
- Keep intermediate build files and caches in the single stable DerivedData directory `/Users/dieruki/Projects/RimWorld-Utilities/.build/CodexBuild`. Never create build or DerivedData directories in `/tmp`, and never create timestamped or randomly named build directories.
- Build agent-generated app bundles in the `Release` configuration unless the user explicitly requests a different configuration. Form the final app bundle directly at `/Applications/RimWorld Utilities.app`; do not create a local `.app` copy in the repository.
- Report `/Applications/RimWorld Utilities.app` as the delivered application path only after a successful build. If the build fails, report the failure and do not present the installed app as an updated working build.
- Do not create or run UI automation tests in this project. Available validation methods are builds, diagnostics, and targeted unit tests.

## Communication

- Do not produce noisy status updates about missing tools when a known fallback exists.
- When using shell commands, prefer the fewest useful commands.
- For every requested change or new feature idea, ask 1-3 clarifying questions or offer options when needed.

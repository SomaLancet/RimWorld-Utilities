# Project AI Instructions

These instructions apply to this repository for Codex, Claude Code, and other coding agents.

## Project Context

- This is a macOS Swift/Xcode project named `RimWorld Utilities`.
- Prefer Xcode-aware tools for build, diagnostics, and project context when they are available.
- Keep changes narrowly scoped to the user's request.
- Do not refactor unrelated code or rewrite existing architecture unless explicitly asked.
- Preserve user changes. Do not revert files unless the user explicitly requests it.
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
- Prefer existing project patterns and reuse existing views, components, and helpers where possible.
- Follow Apple Human Interface Guidelines as much as possible.
- Keep UI implementation simple, conventional, and maintainable.
- Use `@State private var` for local SwiftUI state.
- Prefer `let` for constants.
- Use PascalCase for types and camelCase for properties and methods.
- Avoid force unwraps.
- Prefer async/await APIs over Combine when adding new asynchronous code.
- Add comments only for non-obvious logic.

## Validation

- Use fast diagnostics first when available.
- Build the project when the change affects compile-time behavior or shared code.
- After every fix that changes application code or resources, build a fresh `.app` bundle before reporting completion. A compile-only diagnostic is not a substitute; report the exact path to the new bundle.
- Always build agent-generated app bundles into the single stable DerivedData directory `/Users/dieruki/Projects/RimWorld-Utilities/.build/CodexBuild`. Use `clean build` so the new bundle replaces the previous one. Never create build or DerivedData directories in `/tmp`, and never create timestamped or randomly named build directories.
- Build agent-generated app bundles in the `Release` configuration unless the user explicitly requests a different configuration. Report the build artifact at `/Users/dieruki/Projects/RimWorld-Utilities/.build/CodexBuild/Build/Products/Release/RimWorld Utilities.app`.
- After a successful `Release` build, replace `/Applications/RimWorld Utilities.app` with the fresh bundle so it is available in Applications. Never modify the installed app when the build fails, and report both the build artifact path and the installed path.
- Do not perform visual verification or launch the app for verification unless the user explicitly requests it.
- Do not create or run UI automation tests in this project. Validate changes with builds, diagnostics, and targeted unit tests only.
- Mention clearly if validation could not be run.

## Communication

- Be concise and direct.
- Do not produce noisy status updates about missing tools when a known fallback exists.
- When using shell commands, prefer the fewest useful commands.
- Before making any file or code changes, first provide a concrete implementation plan and wait for explicit user approval. A request to fix, add, or change something does not itself count as approval to begin editing. Inspection and read-only diagnostics are allowed before approval; all write actions are prohibited.
- For every requested change or new feature idea, first restate the task as understood, outline a short plan, and ask 1-3 clarifying questions or offer options when needed.
- Wait for explicit user confirmation before editing files, changing code, running write actions, or making project changes.
- After confirmation, implement the approved plan, validate the work as appropriate, and report the result clearly.

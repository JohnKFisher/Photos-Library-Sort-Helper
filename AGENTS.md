# AGENTS.md — Universal Project Rules

This file is the single source of truth for AI coding agents across this project. It is read by both OpenAI Codex (natively) and Claude Code (via `CLAUDE.md` pointer).
Work safely, conservatively, and transparently.
Assume I may not deeply review code and may not notice hidden risks in my request.
If a change is destructive, user-visible, security-sensitive, privacy-sensitive, materially worse for the app’s core job, materially slower/heavier, architecturally surprising, or meaningfully expands scope, stop and ask first.
Follow everything in this file regardless of which agent is running. Sections marked `(If relevant)` apply only when the project or task touches that area.

## Rule Hierarchy

Apply instructions in this order:

1. Safety, security, privacy, data integrity, reversibility, and truthfulness
2. Explicit project approvals in the brief, milestone plan, or decision log
3. Project workflow and continuity rules
4. Default product, UX, implementation, and communication preferences

If there is a conflict, the higher-priority rule wins unless I explicitly override it.

## Who I Am

Solo developer building personal-use apps. Optimize for usefulness, clarity, reliability, and low friction over impressiveness. Not building for a broad market. Favor practical daily usability over feature count. Favor understandable, inspectable behavior over magic or hidden automation. Do not add complexity in anticipation of future needs unless there is a strong reason.

Default stack: Swift for Apple-native projects, Tauri (Rust + WebView) for cross-platform desktop apps, unless I specify otherwise. If a different stack would be meaningfully better for a given project, suggest it with reasoning — but do not switch without approval.

Core values: safe by default; local-first and least-privilege by default; visible behavior over hidden behavior; reversible changes over destructive changes; measured impact over assumptions; explicit tradeoffs over silent fallbacks; honest status over confident-sounding partial work.

## Session Startup

At the start of every session, read these files if they exist in the repo:
- `docs/DECISIONS.md` — the project decision log
- `docs/WHERE_WE_STAND.md` — the current project status snapshot
- any current project brief or milestone plan if present

Use them to understand approved decisions, current state, known risks, open priorities, and prior constraints that should not be re-litigated accidentally before beginning work.

## Safety-First Principles (Non-Negotiable)

- Do not run destructive commands or perform destructive actions without explicit approval.
  - Examples: deleting files, bulk modifications, irreversible migrations, removing user content, force-overwriting outputs, resetting data, discarding current work, or destructive rollback.
- Do not modify files outside the current repository or explicitly approved workspace.
- Do not introduce telemetry, analytics, tracking, ads, or background network calls unless I explicitly request them. Local-only crash logs and explicit user-initiated "send report" actions are acceptable without per-project approval, but must not phone home silently.
- Do not add new third-party dependencies unless they are necessary, justified, and called out before implementation.
- Never include secrets in code, config, logs, tests, screenshots, docs, or commits.
  - Store secrets in platform keychain/credential store or runtime environment variables. Use `.env` files only for local development and always include `.env` in `.gitignore`.
- Avoid "download and execute" patterns such as `curl | bash`.
- Do not silently weaken privacy, security, data integrity, or determinism through hidden retries, fallbacks, uploads, writes, overwrites, or permission expansion.
- If actual behavior differs from requested behavior, report both the requested result and the actual result, with the reason.

## Ask-First Gate

Stop and ask first unless the behavior is already clearly approved by the project brief, the decision log (`docs/DECISIONS.md`), the current milestone plan, or an explicit user instruction.

Especially ask before:
- destructive actions or irreversible outputs,
- user-visible behavior changes,
- compatibility breaks,
- permission or entitlement changes,
- new network behavior,
- new long-running background work,
- materially heavier behavior,
- architectural pivots,
- reduced privacy/security,
- or major/minor version changes,
- or scope expansion beyond the request.

If approval is needed, present 2 to 3 options with pros/cons and recommend one.

If a project-specific brief, milestone plan, or decision log explicitly approves behavior that would otherwise require re-asking under these general rules, follow that approval while still honoring safety, privacy, reversibility, and transparency. If there is a conflict, the stricter safety/privacy rule wins unless I explicitly override it.

## Working With Me

- Ask clarifying questions freely when they will improve the result, expose a tradeoff, or reduce the chance of a wrong turn.
- Offer suggestions freely when they may improve safety, usability, maintainability, fit, or overall quality.
- Distinguish clearly between what I asked for, what you recommend, and what is optional.
- Do not treat suggestions as approved changes unless I explicitly approve them.
- I value back-and-forth iteration and course correction more than one giant "finished" pass.
- Small related improvements are welcome when low-risk and clearly disclosed. Do not silently turn one requested change into a broad rewrite. If additional improvements seem worthwhile, mention them in the plan before coding, or list them separately as suggestions. Smart adjacent judgment is useful. Silent scope expansion is not.
- Be clear, direct, and practical. Do not hide uncertainty behind confident language. Surface meaningful tradeoffs. When there are real choices, present them cleanly and recommend one. Avoid unnecessary jargon when a plain description will do. Be helpful without becoming overeager or sprawling.
- Do not treat defaults or preferences in this file as approval to make behavior-changing edits without the normal ask-first checks.

## Implementation Style

- Prefer the simplest solution that genuinely solves the problem.
- Prefer small, reviewable steps over large, sweeping rewrites.
- Prefer straightforward code over clever code.
- Prefer explicitness over hidden indirection.
- Keep comments concise, useful, and focused on intent.
- Avoid broad tooling churn unless it clearly helps.
- Do not modify dependency manifests, lockfiles, formatter rules, lint rules, compiler settings, CI config, or build scripts unless the task actually requires it. If such changes are required, call them out explicitly in the plan and summary.
- Follow the project's existing code formatting and linting conventions. If none exist, use the language's community-standard formatter (e.g., swift-format for Swift, rustfmt for Rust, Prettier for JS/TS) with default settings.
- Preserve existing behavior unless the requested task requires changing it.
- Update docs when behavior, setup, architecture, or operational expectations materially change.
- For risky, user-visible, or behavior-changing work, prefer opt-in controls, staged rollout paths, feature flags, or isolated code paths. Default new risky behavior to off unless the project plan clearly says otherwise.

## Task Workflow

### Before Coding

Provide:
1. a short plan,
2. the files expected to change,
3. any new dependencies, permissions, entitlements, migrations, external tools, or network behavior,
4. risk level: low / medium / high.

Also:
- Call out meaningful uncertainty or hidden risk.
- Note whether the task appears likely to affect performance, reliability, compatibility, output quality, or user data.
- Check `docs/DECISIONS.md` for relevant prior decisions before proposing something that may have already been decided.

### Verification (Required Output)

Provide:
- exact build/run/test steps,
- a short manual smoke-test checklist,
- meaningful before/after measurements when performance, reliability, or output quality may have changed.

If the task could affect user data, permissions, fallbacks, or long-running work, verify the relevant safety conditions from the applicable conditional sections below.

### Change Summary (Required Output)

Provide:
- files changed,
- what was added, removed, or behaviorally changed,
- known limitations,
- follow-ups or deferred risks,
- whether a new build was completed, not completed, or not attempted (make this the final line — do not make me infer build status from context).

## Decision Log

Maintain `docs/DECISIONS.md` as a living decision log for the project.

**When to update it:** when a meaningful architectural, design, scope, tooling, or behavioral decision is made or approved; when an open question is resolved; when a decision is reversed or superseded.

**Format:** date, short decision summary, brief rationale (why this over alternatives), status (approved / reversed / superseded).

**Rules:**
- Append new entries; do not delete or rewrite old ones. Mark superseded entries as such.
- Keep entries concise — one to three sentences each.
- Do not use the decision log for task status, changelogs, or TODO lists. Those belong in `docs/WHERE_WE_STAND.md` or issue trackers.
- Do not propose something that contradicts an approved decision without flagging the conflict.

## Status Document

For projects with meaningful versioning, milestone releases, or durable rollback points, maintain a concise status document at `docs/WHERE_WE_STAND.md`.

**When to update it:** at the end of every session that changes the project materially; on major or minor version bumps; when a durable known-good anchor is created; when I ask; when implemented-vs-missing status materially changes.

**What to include:** project name, current version/build, plain-language overall status, what works now, what is partial, what is not implemented yet, known limitations and trust warnings, setup/runtime requirements, important operational risks, recommended next priorities, most recent durable known-good anchor if one exists.

**Rules:**
- Keep it short, practical, and written for a tech-savvy but programming-new owner.
- Do not let it become marketing copy, vague filler, or a changelog dump.
- Update it at session end if the project state changed.

## Git Workflow and Recovery

- Default branch strategy is commit-to-main unless I specify otherwise. Do not create feature branches, pull requests, or branch-based workflows without being asked.
- Write commit messages as short imperative sentences, ≤72 characters for the subject line. e.g. `Add login screen`, `Fix empty CSV export crash`. Add a body paragraph for non-obvious changes explaining why, not just what.
- At session end, commit completed work with a clear message. Leave work-in-progress uncommitted and note what remains in the change summary.
- Do not make material code changes in a repo with no commit history. If no baseline commit exists, stop and ask first.
- For medium- or high-risk tasks, create or recommend a rollback point before material edits.
- Prefer small, reviewable commits at stable milestones over large opaque changes.
- Do not delete history, rewrite history, reset branches, or discard uncommitted work without explicit approval.
- If I explicitly identify a state as known good, create or recommend a durable rollback anchor using the repo's normal workflow.
- Before any rollback or reset-like action, explain exactly what target would be restored and what current work could be lost.

## Versioning

- Use an ever-increasing build number for every build across the life of the project.
- Increment the patch version automatically for each build by default.
- Do not bump the minor or major version without my explicit approval. Bumps can be suggested with brief reasoning, but not applied automatically.
- App marketing version and build number must come from source-controlled files, not from local caches, `.build/`, DerivedData, or other untracked machine-specific state. Before any release build, report the exact version that will be produced and stop if local state could alter it. Update versioning files in the same commit as the build change.
- Prefer deterministic versioning that reproduces the same app version/build from the same committed source.
- For projects that publish through CI, prefer workflows where a pushed checked-in version bump on `main` automatically creates or updates the corresponding GitHub Release. Do not require a separate manual tag push unless the project brief or decision log explicitly prefers tag-driven releases.


## Performance, Reliability, and Output Quality

- Assume real-world datasets can be large.
- Avoid loading everything at once when streaming, paging, batching, or incremental work is feasible.
- Prefer event-driven updates over polling loops where practical.
- Bound concurrency deliberately.
- Handle errors explicitly. No silent failures.
- Prefer actionable error surfaces over generic failures.

If a proposed change is likely to make the app noticeably worse at its core job, or create a noticeable or avoidable regression in correctness, output quality, responsiveness, startup time, memory use, I/O, network use, battery use, or hang risk, stop and ask first unless that operating model is already approved.

Before implementing a materially heavier or lower-quality approach, provide:
1. baseline behavior,
2. expected impact or risk envelope,
3. safer alternatives, including a no-regression option,
4. recommendation.

If exact baseline numbers are not yet available, provide a measurement plan before coding and actual before/after measurements after implementation.

## Compatibility and Interface Stability (If relevant)

If the project already has users, saved data, config files, scripts, documented commands, or public/internal interfaces:

- Preserve existing behavior by default.
- Do not rename, remove, or repurpose interfaces without approval unless the change is clearly internal and unused.
- If a compatibility break is necessary, explain:
  1. what breaks,
  2. who or what is affected,
  3. the migration path,
  4. the rollback path.
- Prefer additive changes, compatibility shims, or deprecation paths over abrupt breaking changes.

## Honesty and Integrity

### Completion Honesty

- Do not describe scaffolded, mocked, placeholder, temporary-workaround, or unverified work as complete.
- Label partial, temporary, or deferred work clearly.
- Distinguish between: implemented, partial, scaffolded, planned.
- Do not update docs, comments, screenshots, or status files to describe behavior that does not actually exist.
- Prefer slightly incomplete docs over confidently inaccurate docs.
- When behavior changed but verification is incomplete, say that directly.

### Test Integrity

- Do not weaken or rewrite tests just to make failures disappear.
- Change tests only when behavior, requirements, or expectations have genuinely changed.
- Do not change snapshots, fixtures, tolerances, or expected outputs without a real behavioral reason.
- If a test is wrong or outdated, say so explicitly and justify the change.
- Write tests for non-trivial logic, edge cases, and anything that has broken before. Skip tests for simple glue code, trivial UI wiring, and straightforward config. When in doubt about coverage expectations, ask.

## App Defaults

### UX and Interaction

- Follow the target platform's native design conventions and interaction patterns. On Apple platforms this means Apple HIG; on Windows this means Fluent/WinUI conventions. When no platform is specified, default to Apple HIG. Favor strong information hierarchy, good spacing, readable typography, and native controls over custom replacements.
- Avoid noisy UI, excessive chrome, gimmicky interactions, or flashy design. Optimize for repeated daily use, not first-impression effect.
- Keep primary screens focused; put secondary detail in drill-downs, panels, or debug views.
- Prefer obvious controls and predictable behavior over novelty.
- Prefer empty states, warnings, and errors that explain what is happening, what still works, and what I can do next. Avoid dead-end messages that only announce failure without guidance.
- Support both light and dark system appearances using platform-standard dynamic colors. Do not hardcode colors.
- Include basic accessibility support: label interactive elements for screen readers, ensure sufficient contrast, and support keyboard navigation.
- Default to English-only. Do not add localization infrastructure or string tables unless I explicitly request it.
- Unless the project specifies otherwise, target the current major OS version minus one (e.g., if current is macOS 15, target macOS 14).

### Behavior

- Prefer local-first behavior where practical.
- Prefer conservative defaults and opt-in power features.
- Prefer graceful degradation over brittle all-or-nothing behavior when integrity is not at risk.
- Prefer visible status over hidden background activity.
- Prefer explicit progress, state, and health signals when something may take time or become stale.
- Prefer predictable output and deterministic behavior where practical.
- Store app data, settings, and user-authored content in inspectable, recoverable formats and predictable locations. Do not trap important content in opaque internal state.
- Make settings visible, understandable, and grouped by real user meaning. Do not bury important behavior behind hidden toggles or obscure configuration.

## Platform and Safety (If relevant)

### User Data, Files, and Permissions (If relevant)

If the project touches user data such as local files, cloud files, photos, notes, contacts, calendars, mail, messages, or personal documents:

- Default to read-only behavior unless I explicitly request write features.
- Any write operation must be user-initiated and should include, where feasible: dry-run mode, preview of changes, explicit scope display, and additional confirmation for large scopes.
- Add guardrails against unintended scope.
- Never implement deletion or destructive changes unless I explicitly ask.
- Prefer reversible alternatives.

When reading, writing, moving, renaming, or deleting files:
- Resolve and surface the exact target path before destructive or user-visible operations.
- Guard against path traversal, ambiguous relative paths, and unintended broad globs.
- Prefer app-owned directories and explicitly approved workspace roots.
- For bulk operations, preview scope and count before execution when feasible.
- Never overwrite existing files without explicit confirmation when the target is user-owned or outside normal app-owned storage.

For app permissions, entitlements, sandbox settings, signing settings, privacy strings, hardened runtime settings, or OS capabilities:
- Never add or modify them without asking first and explaining:
  1. what changes,
  2. why it is required,
  3. what user-visible prompts or impacts occur,
  4. the least-privilege alternative.
- Request only what is required, and as late as possible.
- Handle denied, restricted, and limited-access states gracefully. Explain what is limited and what still works.

### Apple Platform and OS Data (If relevant)

- Prefer official, documented, current Apple APIs and recommended platform patterns. Avoid deprecated APIs and superseded frameworks unless there is a clear compatibility reason; if an older API must be used, explain why, what modern approach would normally be preferred, and the migration plan.
- Never rely on private APIs or undocumented system behavior. Do not read or modify private internals directly. Do not treat private on-disk paths as stable application inputs.
- Keep processing local unless I explicitly request network behavior.
- Minimize collected and retained data.

### Windows Platform (If relevant)

- Prefer platform-native appearance and controls where feasible. For native Windows apps, follow Fluent/WinUI conventions. When the same codebase targets both macOS and Windows, accept visual differences between platforms rather than forcing a single aesthetic.
- Windows builds should be unsigned unless I explicitly set up code signing.
- Prefer portable or per-user installs over system-wide MSI installers unless the project specifically requires it. Avoid requiring admin elevation for basic app functionality.
- Handle Windows path length limits (MAX_PATH), reserved filenames (CON, PRN, NUL, etc.), and backslash vs forward slash differences explicitly. Do not assume Unix path behavior.
- For Windows CI builds, do not assume Unix shell commands — use PowerShell or ensure cross-shell compatibility. This applies to native Windows projects; Tauri cross-platform builds are covered in the CI section.

### Web / Tauri Frontend (If relevant)

- For Tauri apps, the web frontend is the UI layer — not a standalone web app. Keep frontend dependencies minimal and justified.
- Prefer vanilla HTML/CSS/JS or a lightweight framework unless the project's complexity clearly warrants a heavier one. Do not introduce React, Vue, or similar without justification and approval.
- Respect the Tauri security model: use the IPC bridge for system access, do not attempt to bypass Tauri's API allowlist, and keep the frontend sandboxed from direct filesystem/OS access.
- If the frontend needs to work across macOS and Windows Tauri shells, test for and handle platform rendering differences (WebView2 on Windows vs WebKit on macOS).

### Cross-Platform (If relevant)

- When the project targets multiple platforms, document which platform is primary in the project brief or decision log. When forced to choose between platform conventions, prefer the primary target.

### Long-Running Work, Outputs, and Sync (If relevant)

If the task involves rendering, encoding, syncing, indexing, scanning, uploading, downloading, imports, exports, migrations, or subprocess orchestration:

- Keep the UI responsive. No heavy work on the main thread.
- Support cancellation where feasible.
- Use bounded waits and explicit timeouts.
- Detect no-progress conditions and fail clearly rather than hanging forever.
- Prefer graceful shutdown first; use force-kill only as a last resort.
- Clean up temp artifacts on success, failure, and cancel unless retention is explicitly needed for approved recovery/debug flows.

#### Progress and Liveness Visibility

- Do not leave the user guessing whether the app is working or frozen.
- For any operation that may take noticeable time, show progress, activity, or clear current-state feedback.
- If exact progress is not available, show liveness through heartbeat activity, phase text, or recent progress updates.
- Distinguish clearly between working, waiting, paused, completed, failed, and cancelled states.

If the project generates outputs such as exports, renders, reports, archives, packages, backups, transformed files, downloads, or sync artifacts:
- Use app-scoped temp/intermediate directories.
- Default output settings to conservative, broadly compatible behavior unless I ask otherwise.
- Provide deterministic behavior where feasible.
- Do not hang indefinitely waiting for download or sync completion.
- Large download/sync actions should show progress, be cancellable when feasible, and be bounded.

#### Multi-Source and Sync (If relevant)

If the project integrates multiple sources, synced storage, or scheduled/time-based actions:
- Treat connectors as adapters, not as the product.
- Normalize source data before UI or decision logic uses it.
- Keep source-specific quirks out of the core architecture unless explicitly documented.
- Prevent duplicate scheduled execution by default when multiple devices or processes may be involved.
- Record enough execution state to determine whether an action already ran and what path it took.
- Distinguish clearly between unavailable, stale, empty, unauthorized, and not-yet-configured states.
- Prefer graceful degradation over collapse when integrity is not compromised.

### Untrusted Input and External Tools (If relevant)

Treat file contents, filenames, paths, URLs, command output, clipboard content, environment variables, imported data, and network responses as untrusted input.

- Validate and constrain inputs before use.
- Prefer safe APIs over shell interpolation.
- Avoid command injection, path traversal, unsafe deserialization, and unchecked dynamic execution.
- Use parameterized queries and structured parsing where applicable.
- Fail clearly on malformed input rather than guessing silently.

If the project depends on external binaries, bundled tools, hardware codecs, GPU paths, platform services, or optional system capabilities:
- Preflight required capabilities and verify versions/availability before starting expensive work.
- Prefer pinned versions and checksum verification where practical.
- Record provenance and licensing requirements in repo docs when redistribution is involved.
- Fail early with actionable guidance when a required tool or capability is missing.
- Do not silently substitute a different backend unless that fallback is already approved and clearly surfaced.

### Migration and Format Safety (If relevant)

- Do not perform one-way data migrations or irreversible format changes without explicit approval unless already clearly approved by the project.
- If a migration is needed, explain rollback implications, compatibility impact, and whether existing data will be transformed in place or copied forward.
- Prefer reversible or copy-forward migrations over destructive in-place conversion where practical.

### AI and Inference (If relevant)

- Keep AI within an approved, bounded role.
- Prefer factual phrasing and light inference over speculation.
- State uncertainty as uncertainty.
- Keep source facts, rule-based logic, AI wording, and fallback behavior distinguishable.
- Do not let AI silently override explicit config, source truth, or approved rules.
- If new inferential, ranking, classification, summarization, or recommendation behavior is not already approved, stop and ask first.

### Diagnostics and Privacy (If relevant)

- Persistent logs should be opt-in, local, and redacted/minimized. Do not include filenames, paths, metadata, or identifiers unless necessary for diagnosis.
- Never commit sensitive logs, sample user data, or crash artifacts without explicit approval.

## README, Distribution, and About Screen

- Default to MIT license unless I specify otherwise.
- For personal apps, hobby projects, or largely vibe-coded repos, the README MUST say that plainly near the top when it is materially true. It should make clear that the project primarily exists to satisfy the owner's needs, that outside usefulness is incidental, and that no warranties, support commitments, stability guarantees, or roadmap promises are implied beyond the actual license.
- If a repo ships a user-facing app that is not notarized, not signed for public distribution, or otherwise likely to trigger OS security warnings, the README should disclose that explicitly and include safe, user-facing steps for running it. On macOS: Finder Open or System Settings > Privacy & Security > Open Anyway. On Windows: Properties → Unblock or "Run anyway" from SmartScreen. Prefer platform UI guidance over shell-based bypass instructions unless advanced troubleshooting is specifically requested.
- For personal macOS apps where I have not chosen to pay for Apple Developer Program membership and notarization, the README should say that plainly. It should explain that these are personal-use apps, that notarization is intentionally not being paid for, and that users can still open the app by attempting launch once and then going to `System Settings -> Privacy & Security -> Open Anyway`.
- When packaging apps, prefer portable builds that run across supported machine architectures when practical, such as universal macOS binaries. Do not lower deployment targets, broaden compatibility claims, or change minimum supported OS versions without explicit approval. If a build remains host-specific or requires external third-party files, say so clearly in the README or release notes.
- About Screen of all apps must give copyright credit to "John Kenneth Fisher" and include a clickable link to the public GitHub page if one exists.

## CI / GitHub Actions

### Desktop CI / Release Defaults (If relevant)

For desktop apps, default to a **two-workflow** GitHub Actions release
model unless the project brief or decision log explicitly approves
something else:

- `.github/workflows/build.yml`
- `.github/workflows/release.yml`

This applies to:
- Tauri desktop apps
- native macOS apps
- native Windows apps
- other traditional desktop app repos where CI artifacts and tagged
  releases make sense

### Default workflow shape

`build.yml`:
- trigger on push to `main`
- also support `workflow_dispatch`
- set explicit least-privilege permissions:
    permissions:
      contents: read
- produce downloadable artifacts retained 30 days
- use `fail-fast: false` on any matrix
- build from committed source only
- do not mutate tracked version files or other tracked source during CI

`release.yml`:
- trigger on push to `main` when the checked-in version source-of-truth file changes (for example `version.json`, or the project’s equivalent tracked version file)
- also support `workflow_dispatch`
- set explicit least-privilege permissions:
    permissions:
      contents: write
- publish release assets to GitHub Releases for the checked-in app version from committed source
- derive the release tag/version name from the tracked version source-of-truth in the repo, not from local/generated state


### GitHub Actions runtime rules

For JavaScript-based GitHub Actions:
- prefer current Node 24-compatible majors of official
  GitHub-maintained actions
- do not leave workflows on deprecated Node 20 action majors
- add this at workflow level:
  ```yml
  env:
    FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
  ```
- prefer current Node 24-compatible majors for:
  - `actions/checkout`
  - `actions/setup-node`
  - `actions/upload-artifact`
- if Node is needed, use:
  ```yml
  with:
    node-version: lts/*
  ```
- never hardcode personal paths, API keys, or machine-specific values
- if a workflow already exists, update it rather than replacing it

### Packaging defaults

For desktop app packaging, default to:
- **macOS:** `.app` packaged inside a `.dmg`
- **Windows:** portable `.exe` unless installer behavior is explicitly
  requested

Use clear artifact names that include app name, platform, and packaging
style.
Examples:
- `my-app-windows-portable-exe`
- `my-app-macos-universal-dmg`

### macOS distribution defaults

For macOS apps:
- prefer distributing a `.dmg`
- if Apple signing credentials are **not** configured, prefer **ad-hoc
  signing** over leaving the app completely unsigned
- clearly document that ad-hoc signing improves compatibility but does
  **not** replace Developer ID signing or notarization
- do not claim ad-hoc signing eliminates Gatekeeper approval prompts
- if the goal is a downloaded app that opens cleanly without
  malware-verification or Privacy & Security overrides, the real fix is:
  - Developer ID signing
  - notarization
  - proper CI secret/config setup for Apple credentials

If building a traditional native macOS app:
- ad-hoc sign the `.app` in CI when full Apple signing is not available

If building a Tauri app:
- configure ad-hoc signing in `tauri.conf.json` with:
  ```json
  "macOS": {
    "signingIdentity": "-"
  }
  ```

### Windows distribution defaults

For Windows apps:
- prefer a portable `.exe` by default unless installer behavior is
  explicitly requested
- if the app needs Windows icon/resources, ensure a real committed `.ico`
  exists
- do not assume a PNG-only icon setup is sufficient for Windows
  packaging
- clearly disclose that unsigned builds may still trigger SmartScreen

### Before writing any workflow

- If a build script exists (`build_app.sh`, `Makefile`, `scripts/build*`,
  etc.), treat it as the ground truth for assembly steps and mirror it
  faithfully. Do not invent your own assembly logic when a script
  already encodes it.
- Check Package.swift targets and whether `.xcodeproj` / `.xcworkspace`
  exists before deciding on a build approach.

### Build method by project type

**Swift CLI / library** (executableTarget, no GUI assembly): `swift build
-c release`, `swift test`, upload binary from `.build/release/<n>`.

**Swift macOS GUI app, SPM-only** (no `.xcodeproj`): If a build script
exists (`build_app.sh`, `Makefile`, `scripts/build*`, etc.), mirror it
faithfully. If no build script exists, produce the same result a good
build script would:
1. Build a universal binary via two swift build invocations and lipo:
     swift build -c release --triple arm64-apple-macosx
     swift build -c release --triple x86_64-apple-macosx
     lipo -create -output <n> \
       .build/arm64-apple-macosx/release/<n> \
       .build/x86_64-apple-macosx/release/<n>
2. Assemble a proper `.app` bundle:
     <n>.app/Contents/MacOS/<n>   ← the lipo'd binary
     <n>.app/Contents/Resources/  ← any `.bundle` resources from SPM
     <n>.app/Contents/Info.plist  ← from the repo or generate one
3. Generate an `.icns` from source PNG if icon assets are present
   (`iconutil` or `sips`), and place it in Resources/
4. Ad-hoc codesign the bundle:
     codesign --force --deep --sign - <n>.app
5. Wrap in a DMG with `hdiutil` and upload the `.dmg` as the artifact.
Do not produce a bare binary or a zip of a bare binary.

**Swift macOS GUI app, Xcode project** (has `.xcodeproj` /
`.xcworkspace`): `xcodebuild` with `CODE_SIGNING_ALLOWED=NO`, then
`hdiutil` for the DMG.
    xcodebuild -scheme <SchemeName> -configuration Release \
               -derivedDataPath build CODE_SIGNING_ALLOWED=NO

**Tauri (Rust + WebView)**:
- use `tauri-apps/tauri-action@v0`
- prefer a push-build workflow plus a tag-release workflow
- default matrix/package targets:
  - `windows-latest` / `x86_64-pc-windows-msvc` / portable EXE
  - `macos-14` / `universal-apple-darwin` / universal DMG
- ensure `withGlobalTauri` is in `app {}` in `tauri.conf.json`, not
  `build {}`
- ensure Windows packaging assets exist:
  - `src-tauri/icons/icon.ico`
- ensure macOS bundle configuration is explicit when signing is relevant
- commit `Cargo.lock`
- commit `package-lock.json` when Node packaging state changes

### Native app defaults

For non-Tauri desktop apps, follow the same release structure:
- push builds on `main`
- tagged releases on `v*`
- least-privilege workflow permissions
- downloadable artifacts retained 30 days
- current Node 24-compatible majors for any JS-based GitHub Actions

For native macOS apps:
- prefer `.dmg`
- ad-hoc sign by default if no Apple certificate is configured
- document that notarization is still required for the cleanest
  end-user launch path

For native Windows apps:
- prefer a portable `.exe` unless installer behavior is requested
- ensure Windows icons/resources are present and committed, not implied

### Release flow default

Default release flow is:
1. bump the checked-in app version/build in source control
2. push to `main`
3. let CI create or update the GitHub Release for that version automatically

Treat a committed version bump as an intentional “done for now / publish”
signal unless the project brief or decision log says otherwise.

Do **not** rewrite or force-move an existing release tag unless I
explicitly approve it. If a release fix is needed after a published
version already exists, create a new patch version/build and publish that
instead.

### Release notes default

For version-triggered GitHub Releases:
- Do not use placeholder or generic release notes.
- Release notes must describe the actual changes since the previous release.
- Prefer generating the release body from commit subjects (and, if useful, short bodies) between the previous release tag and the release commit.
- Exclude routine version-bump-only commits from the human-facing notes when possible.
- If the workflow needs git history or tags to build release notes, ensure checkout fetches enough history in CI (for example `fetch-depth: 0`).
- If no previous release tag exists, fall back to a clear first-release summary derived from available commit history rather than a placeholder body.


### Verification required for CI / release work

Before closing CI/release work, verify:
- workflow YAML parses cleanly
- checked-in version/source-of-truth files are in sync
- relevant local tests pass if toolchains are available
- the new GitHub Actions run has started
- if a previous remote failure existed, inspect the actual failing job
  log and fix the root cause, not just the wrapper error
- if packaging/signing changed, update README and status docs to
  describe real end-user behavior honestly

### Required final report for CI / release work

When reporting back after CI/release changes, include:
- pushed commit SHA
- pushed tag, if any
- Build workflow URL
- Release workflow URL, if any
- whether remote runs are pending, running, passed, or failed
- any remaining signing, Gatekeeper, SmartScreen, or notarization
  limitations that still affect users

### Honesty rule for macOS distribution

Do not describe a macOS app as “fixed” for distribution if it is only
ad-hoc signed. Ad-hoc signing is an improvement, not the final trust
solution. If notarization is not configured, say that clearly.

When adding a new feature, check whether the CI workflow needs updating
too.

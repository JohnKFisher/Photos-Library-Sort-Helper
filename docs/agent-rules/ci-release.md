# CI / GitHub Actions Rules

Read this file when the task touches GitHub Actions, CI, releases, packaging, build artifacts, code signing, notarization workflow, or app distribution automation.

## Desktop CI / Release Defaults

For desktop apps, default to a **two-workflow** GitHub Actions release model unless the project brief or decision log explicitly approves something else:

- `.github/workflows/build.yml`
- `.github/workflows/release.yml`

This applies to:
- Tauri desktop apps
- native macOS apps
- native Windows apps
- other traditional desktop app repos where CI artifacts and tagged releases make sense

## Default workflow shape

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

## GitHub Actions runtime rules

For JavaScript-based GitHub Actions:
- prefer current Node 24-compatible majors of official GitHub-maintained actions
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

## Packaging defaults

For desktop app packaging, default to:
- **macOS:** `.app` packaged inside a `.dmg`
- **Windows:** portable `.exe` unless installer behavior is explicitly requested

Use clear artifact names that include app name, platform, and packaging style.

## macOS distribution defaults

For macOS apps:
- prefer distributing a `.dmg`
- if Apple signing credentials are **not** configured, prefer **ad-hoc signing** over leaving the app completely unsigned
- clearly document that ad-hoc signing improves compatibility but does **not** replace Developer ID signing or notarization
- do not claim ad-hoc signing eliminates Gatekeeper approval prompts
- if the goal is a downloaded app that opens cleanly without malware-verification or Privacy & Security overrides, the real fix is:
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

## Windows distribution defaults

For Windows apps:
- prefer a portable `.exe` by default unless installer behavior is explicitly requested
- if the app needs Windows icon/resources, ensure a real committed `.ico` exists
- do not assume a PNG-only icon setup is sufficient for Windows packaging
- clearly disclose that unsigned builds may still trigger SmartScreen

## Before writing any workflow

- If a build script exists (`build_app.sh`, `Makefile`, `scripts/build*`, etc.), treat it as the ground truth for assembly steps and mirror it faithfully. Do not invent your own assembly logic when a script already encodes it.
- Check Package.swift targets and whether `.xcodeproj` / `.xcworkspace` exists before deciding on a build approach.

## Build method by project type

**Swift CLI / library**: `swift build -c release`, `swift test`, upload binary from `.build/release/<n>`.

**Swift macOS GUI app, SPM-only**:
1. Build a universal binary via two swift build invocations and lipo
2. Assemble a proper `.app` bundle
3. Generate an `.icns` if icon assets are present
4. Ad-hoc codesign the bundle
5. Wrap in a DMG with `hdiutil`

**Swift macOS GUI app, Xcode project**: `xcodebuild` with `CODE_SIGNING_ALLOWED=NO`, then `hdiutil` for the DMG.

**Tauri (Rust + WebView)**:
- use `tauri-apps/tauri-action@v0`
- prefer a push-build workflow plus a tag-release workflow
- default matrix/package targets:
  - `windows-latest` / `x86_64-pc-windows-msvc` / portable EXE
  - `macos-14` / `universal-apple-darwin` / universal DMG
- ensure `withGlobalTauri` is in `app {}` in `tauri.conf.json`, not `build {}`
- ensure Windows packaging assets exist:
  - `src-tauri/icons/icon.ico`
- commit `Cargo.lock`
- commit `package-lock.json` when Node packaging state changes

## Release flow default

Default release flow is:
1. bump the checked-in app version/build in source control
2. push to `main`
3. let CI create or update the GitHub Release for that version automatically

Treat a committed version bump as an intentional “done for now / publish” signal unless the project brief or decision log says otherwise.

Do **not** rewrite or force-move an existing release tag unless I explicitly approve it. If a release fix is needed after a published version already exists, create a new patch version/build and publish that instead.

## Release notes default

For version-triggered GitHub Releases:
- Do not use placeholder or generic release notes.
- Release notes must describe the actual changes since the previous release.
- Prefer generating the release body from commit subjects between the previous release tag and the release commit.
- Exclude routine version-bump-only commits from the human-facing notes when possible.
- If the workflow needs git history or tags to build release notes, ensure checkout fetches enough history in CI.
- If no previous release tag exists, fall back to a clear first-release summary derived from available commit history rather than a placeholder body.

## Verification required for CI / release work

Before closing CI/release work, verify:
- workflow YAML parses cleanly
- checked-in version/source-of-truth files are in sync
- relevant local tests pass if toolchains are available
- the new GitHub Actions run has started
- if a previous remote failure existed, inspect the actual failing job log and fix the root cause
- if packaging/signing changed, update README and status docs to describe real end-user behavior honestly

## Required final report for CI / release work

When reporting back after CI/release changes, include:
- pushed commit SHA
- pushed tag, if any
- Build workflow URL
- Release workflow URL, if any
- whether remote runs are pending, running, passed, or failed
- any remaining signing, Gatekeeper, SmartScreen, or notarization limitations that still affect users

## Honesty rule for macOS distribution

Do not describe a macOS app as “fixed” for distribution if it is only ad-hoc signed. Ad-hoc signing is an improvement, not the final trust solution. If notarization is not configured, say that clearly.

When adding a new feature, check whether the CI workflow needs updating too.

# CI, Release, Packaging, and Distribution Rules

Read this when the task touches GitHub Actions, CI, releases, release automation, packaging, build artifacts, DMGs, EXEs, installers, code signing, notarization, App Store/TestFlight, version-triggered releases, release build numbers, distribution artifacts, or public release workflows.

Do not read this for non-release local implementation tasks.

For commits, branches, worktrees, tags, rollback/recovery, repository state, or checked-in version source files, also apply `git-versioning.md` when those repo-state details materially affect the task.

## Release safety

CI/release/distribution work is high leverage and high-risk.

Ask before changing release topology, signing, notarization, installer behavior, versioning, artifact naming, deployment triggers, permissions, release publishing behavior, App Store/TestFlight flow, or public distribution behavior.

Preserve the current known-good release path by default. Do not invent a new packaging, signing, notarization, App Store, TestFlight, DMG, EXE, installer, or release-automation flow unless the task is specifically to change that flow.

Do not change bundle IDs, marketing versions, signing settings, entitlements, privacy strings, store metadata, export options, release branches, tags, notarization settings, packaging scripts, or archival/distribution workflows unless explicitly requested.

If a release-path change seems necessary, explain:

- what changes,
- why the current path is insufficient,
- risk to rollback or future releases,
- how to verify the new path.

## Existing workflow is ground truth

If workflows, build scripts, Makefiles, package scripts, Fastlane lanes, Xcode schemes, Tauri config, or documented release scripts already exist, treat them as the ground truth for assembly and release steps.

Update existing workflows surgically instead of replacing them.

Do not hardcode personal paths, machine-specific values, API keys, tokens, certificates, provisioning profiles, or secrets.

Use current official GitHub Actions versions and avoid deprecated runtimes.

Use least-privilege permissions and limited artifact retention.

Do not mutate tracked source or version files during CI unless the workflow is explicitly designed and approved to do so.

## Packaging defaults

Only use defaults when a release/package flow is being created and the user has approved that direction.

Reasonable desktop defaults:

- macOS: `.app` inside `.dmg`
- Windows: portable `.exe` unless installer behavior is requested

Artifact names should include app name, platform, and packaging style.

## Versioning and build numbers

For release-managed apps, treat marketing versions and build numbers as release-sensitive.

Build numbers may be increased automatically when creating or preparing a release/build, if consistent with the existing project release process.

When automatically increasing a build number:

- change only the checked-in build-number source of truth used by the existing project workflow,
- report the old build number, new build number, and file changed,
- do not change marketing version, bundle ID, signing, entitlements, privacy strings, store metadata, or release workflow,
- do not invent a second build-number system,
- do not derive build numbers from local caches, generated artifacts, DerivedData, `.build/`, or machine-specific state,
- do not mutate build numbers only inside generated artifacts.

Build numbers should be ever-increasing, may skip, and must never reuse a number that may already have been uploaded or distributed.

Do not bump marketing versions, package versions, or public release metadata without explicit approval.

Before App Store, TestFlight, archive, notarization, packaged release, or public distribution work, report the current marketing version/build number when applicable.

Stop if local state could alter version/build unexpectedly.

## Version-triggered releases

For version-triggered releases:

- derive release tags and names from the checked-in version source of truth,
- do not rewrite or force-move existing release tags unless the user explicitly approves,
- if a release fix is needed after publication, prefer a new patch/build,
- do not use placeholder release notes,
- base release notes on actual changes since the previous release when practical.

## Distribution honesty

Do not imply a release, upload, tag, push, notarization, signing, remote workflow run, or artifact publication happened unless it actually did.

If an app is unsigned, ad-hoc signed, unnotarized, host-specific, or requires Gatekeeper/SmartScreen workarounds, say so clearly.

State remaining distribution limitations clearly, such as unsigned builds, ad-hoc signing, missing notarization, Gatekeeper prompts, SmartScreen risk, missing installer signing, or other user-facing install friction.

## Verification

For CI/release work, verify workflow syntax where possible, inspect expected triggers, permissions, artifact paths, and release conditions, and state what was not tested locally.

For CI failures, inspect the failing job/step log first. Do not rewrite workflows or repeatedly rerun CI until the failure mode is identified from the smallest relevant log section.

## Reporting

When adding or changing a feature, consider whether CI, packaging, signing, release notes, artifacts, permissions, or distribution docs need a targeted update. Do not make those updates unless required by the task or approved.

For substantive CI/release/distribution work, report only the relevant facts:

- workflow files changed,
- release/version files changed,
- artifact names or locations changed,
- signing/notarization/SmartScreen/Gatekeeper limitations,
- local verification performed,
- remote run status if a remote run was triggered,
- pushed commit or tag only if the user explicitly instructed a commit/tag/push.
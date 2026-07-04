# Git, Repository State, Version Files, and Recovery Rules

Read this when tasks touch branches, worktrees, commits, pushes, tags, merges, rebases, resets, cherry-picks, rollback/recovery, repository state, release tags, or source-controlled version files.

For CI, packaging, signing, notarization, App Store/TestFlight, distribution artifacts, release automation, or public release workflows, prefer `ci-release-distribution.md` unless the task also changes repository state, tags, branches, commits, rollback, or checked-in version files.

Do not read this for ordinary localized edits with no git/versioning impact.

## Non-negotiable agent behavior

Do not commit, push, tag, merge, rebase, reset, cherry-pick, create branches, switch branches, delete branches, create worktrees, or delete worktrees unless explicitly instructed.

You may suggest sensible commit points, tags, release anchors, or worktree strategies, but do not perform them without instruction.

The user manages branch and worktree strategy manually. Do not prescribe whether a project should use `main`, branches, or worktrees unless asked.

## Before material edits

For material edits, report:

- current working directory,
- current branch,
- `git status --short`.

If there are unrelated uncommitted changes, avoid touching them and call them out.

## Philosophy

Git workflow exists to protect stable states, preserve recoverability, reduce accidental regressions, isolate risky work, and make release history understandable.

Prefer simple, explicit, reversible workflows. Avoid hidden workspace manipulation, unnecessary branching complexity, silent history rewrites, and automation that obscures what shipped.

## Commit guidance

When asked to commit:

- keep commits focused,
- do not include unrelated changes,
- use clear, factual commit messages,
- inspect the diff first,
- avoid committing secrets, logs, generated artifacts, local caches, or user data.

When not asked to commit, simply summarize a suggested checkpoint if useful.

After meaningful successful work, suggest a known-good checkpoint when useful, such as a commit, tag, or status-doc update. Do not create the checkpoint unless the user explicitly instructs it.

## Push and rewrite safety

Never force-push, rewrite shared history, delete remote branches, or push tags unless explicitly instructed and the risk is clear.

## Tags and release anchors

For release-managed projects, tags can be durable known-good anchors. Do not create tags unless instructed. If suggesting tags, include the reason and rollback value.

## Version files

Do not bump marketing versions, package versions, build numbers, or release metadata unless asked, the task explicitly requires it, or the release/build process rules allow it.

When changing a checked-in version source-of-truth file, explain the old value, new value, file changed, and likely release/distribution effect.

Detailed release/build-number rules live in `ci-release-distribution.md`.

## Rollback and recovery

Before rollback, reset, restore, checkout, clean, revert, or recovery-like actions:

- inspect current branch/worktree state,
- identify uncommitted changes,
- explain what will be lost, preserved, or recreated,
- identify the target restore point,
- prefer reversible recovery over destructive reset,
- avoid touching unrelated user work.

Do not discard uncommitted work, generated-but-needed outputs, local configuration, user data, or release artifacts unless the user explicitly approves that exact loss.

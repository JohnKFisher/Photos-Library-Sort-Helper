# Context Efficiency Rules

Read this when repo discovery, searching, command output, logs, generated files, or token use may affect the task.

Do not read this for tiny tasks where only one known file is needed.

## Core principle

Protect the context window aggressively. Tools, searches, file reads, and command executions are expensive.

Before reading/searching/running anything, ask whether the current context is already sufficient.

## Rule loading

Do not read all agent rule files as a default context-gathering step.

Start with `AGENTS.md`, then load only the project profile and conditional rule files that are directly triggered or likely to change the plan.

When uncertain, inspect filenames/headings before reading full files.

## Search discipline

Prefer targeted search over broad discovery. Search for symbols, filenames, error strings, config keys, and user-facing text.

Avoid broad repo-wide searches unless cross-cutting understanding is required. If results are large, refine the query instead of reading many matches.

Do not inspect generated, vendored, dependency, cache, build, packaged, archive, or local-agent-state directories unless directly relevant.

Default exclusions include:

- `.build/`
- `.swiftpm/`
- `.home/`
- `.claude/`
- `.codex/`
- `node_modules/`
- `dist/`
- `build/`
- `DerivedData/`
- `output/`
- `tmp/`
- `third_party/ffmpeg/` binary payloads
- generated graph/output folders such as `graphify-out/`

Project profiles may add more exclusions.

Prefer source and docs paths:

- `Sources/`
- `Tests/`
- `docs/`
- `scripts/`
- `Package.swift`
- `.github/workflows/`

If repository exploration continues expanding without converging on an implementation, stop and summarize.

Describe:

- what is known,
- remaining uncertainty,
- the smallest next search likely to resolve it.

Avoid consuming additional context simply because more information exists.

## Command output discipline

Any command with unknown or potentially large output must be byte-capped, not only line-capped.

Prefer:

```sh
COMMAND 2>&1 | head -c 4000
COMMAND 2>&1 | tail -c 4000
```

For failure logs, prefer recent output with `tail -c`.

Do not paste full build/test logs into final answers. Summarize pass/fail and include only important failure lines.

Do not byte-cap directly relevant instruction files, agent rules, project briefs, decision logs, or status docs unless unexpectedly huge.

## Graphify and review skills

Graphify output is generated architecture/context material. Do not read, regenerate, or update `graphify-out/` by default.

If a project has a Graphify graph, use it as optional orientation only when architecture, module relationships, dependency flow, or cross-file navigation matters.

Update or recommend updating Graphify only when the user asks, when project structure materially changes, or when architecture/dependency relationships become misleading. Do not update it for ordinary localized edits, copy changes, small bug fixes, or routine implementation work.

`/grill-me` is an explicit review/critique mode. Do not invoke, simulate, or optimize for it unless the user asks for it.

## Tool usage discipline

- Avoid repeated searches, file reads, or commands whose results are still valid.
- Prefer acting on strong local evidence over gathering excessive context.
- If a previous step established the answer with high confidence, continue instead of re-verifying unnecessarily.

## Communication discipline

Do not provide transcripts of commands, searches, file reads, or routine work.

Keep communication proportional to task size and risk. For tiny, obvious, or mechanical changes, one brief sentence with the change and narrow check is enough.

For substantive work, report only what helps the user understand the result:

- decisions made,
- files changed when useful,
- user-visible behavior changed,
- verification performed,
- failures, uncertainty, or meaningful skipped checks,
- remaining risks or follow-ups,
- final build/test status when relevant.

Avoid repeating the same information in multiple places.

## Exact command reporting

Include exact commands only when useful for reproducibility, troubleshooting, handoff, or when verification details materially matter.

Do not include exact commands merely to prove effort.

## Safety beats token savings

Minimize context, but do not skip safety-critical context.

Always read the applicable conditional rule file before changing behavior involving:

- user data or permissions,
- destructive or bulk operations,
- releases, signing, packaging, or distribution,
- migrations or irreversible format changes,
- external tools, shell commands, subprocesses, or untrusted input,
- diagnostics, logs, support bundles, or privacy-sensitive output,
- core product behavior or protected workflows.

Token efficiency is not a reason to bypass safety, privacy, data integrity, or release discipline.

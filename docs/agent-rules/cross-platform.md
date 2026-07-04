# Cross-Platform Rules

Read this when a task affects behavior, packaging, storage, UX, rendering, build/release logic, file paths, permissions, or distribution across more than one platform.

Do not read this for single-platform edits unless cross-platform compatibility may be affected.

## Cross-platform behavior

Document the primary platform in the project brief or decision log when it matters.

When forced to choose between platform conventions, prefer the primary target while avoiding unnecessary breakage elsewhere.

Accept visual and behavioral differences where native conventions materially differ.

Do not silently broaden platform compatibility claims, lower deployment targets, change minimum supported OS versions, or imply tested platform support without approval and verification.

## Cross-platform storage and paths

Avoid hardcoded platform paths. Handle path separators, reserved names, case sensitivity, path length, sandboxed locations, and user-writable directories intentionally.

Prefer platform-neutral path APIs over manually constructing paths with separators.

## Cross-platform verification

When a change affects multiple platforms, verify the highest-risk platform path and state which platforms were not checked.

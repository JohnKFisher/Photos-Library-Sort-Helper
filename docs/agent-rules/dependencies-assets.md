# Dependencies, Media, and Asset Rules

Read this when the task touches third-party dependencies, package manifests, lockfiles, media, images, sounds, fonts, bundled binaries, licenses, attributions, or asset redistribution.

Do not read this for tasks with no dependency or asset impact.

## Dependencies

Do not add new third-party dependencies unless necessary, justified, and called out before implementation.

Before adding a dependency, first check whether native platform APIs, standard libraries, existing project utilities, or a small local implementation can solve the problem safely.

Default to native/project APIs over third-party packages unless the dependency clearly reduces risk, complexity, maintenance burden, or implementation time enough to justify its cost.

Do not add a package for convenience alone.

Before adding a dependency, explain:

- what problem it solves,
- why native/project APIs are insufficient,
- license,
- App Store/commercial/distribution safety,
- attribution requirements,
- whether modifications require source disclosure.

Prefer MIT, Apache 2.0, BSD, and public-domain/CC0 assets when appropriate.

Avoid dependency churn, broad upgrades, lockfile rewrites, or package-manager changes unless required.

## Media and assets

Never scrape random sounds, images, fonts, or media from the internet.

Bundled media/assets must have clear redistribution rights, documented source, documented license, and tracked attribution requirements.

Keep a machine-readable `ATTRIBUTIONS.md` where practical, listing asset/library name, source URL, license, and attribution requirements.

About/Licenses screens should surface required attributions where practical.

Do not share or redistribute font files unless clearly licensed and explicitly requested.

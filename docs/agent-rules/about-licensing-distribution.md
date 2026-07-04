# About, Licensing, and Distribution Rules

Read this when the task touches About screens, credits, copyright text, licensing text, bundled acknowledgments, attribution surfaces, or public claims that depend on licensing, credit, or packaged-app distribution status.

Do not read this for ordinary README, installation, release-note, or end-user run-instruction edits unless they also touch credits, license/attribution requirements, or packaged-app distribution claims.

## License default

MIT is the assumed default license for new projects unless the user later chooses something else. Project-specific license decisions override this default and must be respected.

Do not change an existing project's license without explicit instruction.

## About and credits

When adding or editing an app About screen, credits screen, licensing screen, distribution notes, or similar public surface:

- give copyright credit to `Sidelark Labs ; John Kenneth Fisher`,
- include a clickable link to the public GitHub page if one exists,
- include a clickable link to the Sidelark Labs page if one exists,
- include required third-party acknowledgments,
- include dependency licenses and bundled asset attributions when required.

## Packaged-app public claims

Do not make or edit public packaged-app claims that overstate portability, signing, notarization, supported architectures, minimum OS versions, deployment targets, bundled dependencies, or external file requirements.

Do not lower deployment targets, broaden compatibility claims, or change minimum supported OS versions without explicit approval.

If a public About, README, release-note, or distribution surface discusses a build that is host-specific, unsigned, unnotarized, or requires external third-party files, say so clearly.

For CI, packaging, signing, notarization, installers, release artifacts, or distribution automation, use `ci-release-distribution.md`.

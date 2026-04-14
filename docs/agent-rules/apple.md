# Apple Platform and App Identity Rules

Read this file when the task touches Apple platforms, Swift, SwiftUI, AppKit, UIKit, Xcode, bundle IDs, entitlements, signing, notarization, sandboxing, PhotoKit, or Apple platform APIs.

## Apple Platform and OS Data

- Prefer official, documented, current Apple APIs and recommended platform patterns. Avoid deprecated APIs and superseded frameworks unless there is a clear compatibility reason; if an older API must be used, explain why, what modern approach would normally be preferred, and the migration plan.
- Never rely on private APIs or undocumented system behavior. Do not read or modify private internals directly. Do not treat private on-disk paths as stable application inputs.
- Keep processing local unless I explicitly request network behavior.
- Minimize collected and retained data.

## Apple App Identity and Bundle IDs

- Use stable reverse-DNS bundle identifiers for Apple app targets.
- Default personal namespace: `com.jkfisher`
- Default pattern: `com.jkfisher.<appname>`
- Use lowercase only. Prefer short, readable app names in identifiers. Avoid spaces, hyphens, and generic names like `test` or `demo`.
- Treat bundle identifiers as durable app identity. Do not rename them casually after a project has been built, signed, distributed, or connected to capabilities/services.
- If a task adds or changes bundle IDs, targets, app extensions, or capability-bound identifiers, call that out explicitly in the plan and ask first when the change is user-visible or compatibility-relevant.

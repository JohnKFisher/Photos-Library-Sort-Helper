# Apple Platform Rules

Read this when Apple platform rules may materially affect the plan: bundle IDs, targets, capabilities, entitlements, signing, notarization, hardened runtime, sandboxing, App Store/TestFlight, macOS/iOS distribution, privacy prompts, PhotoKit, MusicKit, permissions, background behavior, startup performance, main-thread responsiveness, media/import/export workflows, or Apple API/lifecycle choices.

Do not read this for non-Apple tasks or for localized Swift/SwiftUI/AppKit/UIKit/Xcode edits where platform policy, capabilities, privacy, distribution, performance, lifecycle, or compatibility concerns are unlikely to affect the plan.

## Localized Apple edits

For tiny/localized Swift, SwiftUI, AppKit, UIKit, or Xcode edits, prefer existing project patterns and narrow verification.

Escalate when the change touches capabilities, permissions, entitlements, signing, privacy prompts, distribution, app identity, saved data, import/export, media playback/rendering, startup behavior, lifecycle/state ownership, main-thread responsiveness, or compatibility.

## APIs and platform behavior

Prefer official, documented, current Apple APIs and recommended platform patterns.

Avoid deprecated APIs unless compatibility requires them; if used, explain why and the migration path.

Never rely on private APIs, undocumented system behavior, or private on-disk paths as stable app inputs.

Keep processing local unless network behavior is explicitly requested or already approved. Minimize collected and retained data.

## App identity and capabilities

Treat bundle identifiers as durable app identity. Do not rename them casually after a project has been built, signed, distributed, or connected to capabilities/services.

Bundle identifiers default to `com.sidelarklabs.<appname>`.

If a task adds or changes bundle IDs, targets, extensions, capabilities, entitlements, signing, or privacy strings, call it out in the plan and ask first when compatibility or user-visible behavior may be affected.

When adding Apple capability-dependent code, verify matching project settings, entitlements, provisioning assumptions, and graceful denied/unavailable states.

## App Store, TestFlight, entitlements, and privacy

Before App Store, TestFlight, archive, signing, entitlement, capability, sandbox, privacy-string, or App Privacy-impacting work, call out review-sensitive changes in the plan.

Specifically flag changes involving:

- MusicKit, PhotoKit, camera, microphone, contacts, calendars, location, notifications, files, network access, background modes, in-app purchases, subscriptions, analytics, or user tracking,
- new or changed entitlements,
- new or changed privacy prompts,
- new background behavior,
- new data collection, retention, export, upload, or sharing behavior.

Do not change entitlements, signing, bundle IDs, capabilities, privacy strings, App Store metadata, or TestFlight/App Store release behavior without approval unless the task explicitly requires it.

## Swift, SwiftUI, and app responsiveness

Prefer native platform patterns, straightforward state flow, system colors, system typography, accessibility labels where practical, and responsive layouts.

Avoid unnecessary abstraction, third-party UI frameworks, or custom style systems unless justified.

For small SwiftUI/view copy or layout changes, prefer narrow verification and batch builds.

For state, persistence, permissions, media, import/export, signing, or release work, use stronger verification.

Protect launch and UI responsiveness. Do not move expensive loading, indexing, media work, network calls, file scans, migrations, or package parsing into app startup or SwiftUI body evaluation unless clearly justified.

Keep expensive work off the main actor/main thread unless it is truly UI work. Use async work, batching, caching, progress states, and cancellation where practical.

Watch for memory and lifetime issues in SwiftUI, media, import/export, and long-running workflows. Avoid retain cycles, unbounded caches, accumulating media players, repeated observers, runaway tasks, and view models that outlive their intended scope.

For performance-sensitive Apple changes, verify the affected workflow and report any unmeasured risk.

## Native Apple conventions

Prefer native Apple platform conventions unless custom behavior has a clear product benefit.

Avoid fighting SwiftUI/AppKit/UIKit lifecycle, state ownership, accessibility, sandboxing, entitlement, signing, or distribution expectations.
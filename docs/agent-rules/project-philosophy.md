# Project Philosophy Rules

Read this when choosing among materially different UX, product, or architecture approaches; proposing significant behavioral changes; evaluating tradeoffs that affect project direction; or when broader product philosophy may change the plan.

Do not read this for localized implementation of an already-requested change, routine UI polish, copy edits, bug fixes, or low-risk layout work unless a real product tradeoff is unclear.

## Product direction

Favor tools that are useful, personal, understandable, and reliable over tools that look impressive but add complexity.

Prefer features that solve a real workflow problem. Avoid speculative options, cockpit-style control panels, and configuration sprawl unless there is a clear user need.

## UX direction

Prefer:

- reducing cognitive load,
- setup-first and preset-first flows,
- ready/not-ready guidance,
- clear user-visible state,
- safe defaults,
- graceful degradation,
- inspectable and recoverable user data.

Keep technical internals out of primary flows unless the user is intentionally in an advanced context.

Before considering user-facing work complete, review all newly added or changed user-visible wording.

Prefer language that is clear, concise, actionable, and understandable by normal users rather than developers.

Support light/dark system appearance, basic accessibility, keyboard navigation where practical, and platform-native colors/controls.

Default to English-only unless localization is requested.

Protect first-run and onboarding experiences.

New functionality should not unintentionally complicate or regress the initial user experience. Verify onboarding, first launch, and zero-data states whenever the change could affect them.

## UI polish checklist for meaningful UI changes

For meaningful UI changes, do a final polish pass before calling the work complete. For tiny/local copy, spacing, or layout edits, keep the polish check proportional.

Check:

- wording, labels, titles, and button text,
- spacing, alignment, hierarchy, and visual consistency,
- empty states,
- error states,
- loading or in-progress states,
- disabled/unavailable states,
- basic accessibility, including VoiceOver labels where practical, Dynamic Type/resizing, keyboard navigation when relevant, and sufficient contrast through system colors.

Do not add elaborate UI states for unlikely edge cases unless the project needs them. Prefer simple, helpful, user-understandable states.

## Platform preferences

Default stack preferences:

- Swift for Apple-native apps,
- Tauri/Rust + WebView for cross-platform desktop apps when appropriate,
- small static/front-end approaches for simple websites.

Prefer current major OS version minus one unless a project decision says otherwise.

## Product bias

Favor the project's core job over feature count.

Prefer:

- speed, clarity, reliability, and real-world usability,
- native platform conventions unless custom UI has a clear product benefit,
- preserving user setup, content, and learned workflows,
- customization only when it adds real value, delight, safety, or efficiency.

Avoid:

- accounts, cloud sync, social features, backend infrastructure, subscriptions, or broad platform expansion unless explicitly approved,
- making users redo meaningful setup without a strong reason,
- adding options that increase cognitive load more than they improve the product.

Prefer removing unnecessary complexity over adding new abstractions.

When two solutions solve the problem equally well, favor the simpler system with fewer concepts to maintain.

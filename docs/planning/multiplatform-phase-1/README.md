# Multiplatform Expansion — Phase 1

This folder contains the repository audit, PhotoKit feasibility findings, architecture recommendation, three interactive UI concepts, their comparison, and the approved Phase 2 roadmap. The browser prototype remains a demonstration; Phase 2 production code is now present in the repository. Current implementation and verification status are recorded in the roadmap and [project status](../../WHERE_WE_STAND.md).

## Start here

1. Read [the current implementation audit](CURRENT_IMPLEMENTATION_AUDIT.md). It records source behavior and calls out a material conflict between the prompt's description and the code.
2. Open [the interactive prototype lab](prototypes/index.html) in a browser. The prototype is self-contained, uses generated vector sample scenes, and makes no Photos requests. See [prototype instructions](prototypes/README.md).
3. Read [feasibility and architecture](FEASIBILITY_AND_ARCHITECTURE.md), [the design comparison](DESIGN_COMPARISON.md), and [the implementation roadmap](PHASE2_ROADMAP.md).

## Prototype boundary

The prototype stores only temporary demonstration choices in its own browser storage. It does not import or inspect the owner's Photos library. Production apps do not use its sample media or browser storage.

## Required source correction for Phase 2

The no-Vision requirement was settled before Phase 2. The implementation now uses adjacent-gap time grouping and keeps videos as singletons; Live Photos remain photo items.

## Owner decisions (2026-10-29)

- Approved: Review Console across Mac, iPhone, and iPad, using Photo-First Triage's small in-thumbnail classification indicators in Console photo navigation. Keep the Console's overall layout, navigation, information density, and other controls.
- Approved: system SQLite for local review state, the shared pending queue, and commit journaling; keep JSON scan preferences and preserve the existing session JSON until a verified migration.
- Approved: best-effort cross-device conflict detection/review with the documented residual race; do not add a separate synchronization service.
- Approved: full Phase 2 implementation according to [the roadmap](PHASE2_ROADMAP.md), preserving Mac functionality and safety requirements. No general design approval checkpoint remains.

The interactive prototype retains Review Console's layout and controls while using Photo-First Triage's bottom-right in-thumbnail markers in Console photo navigation. It stages explicit per-photo decisions immediately, including when a group is later skipped; untouched items remain unresolved, and Next Group stages their current defaults. The marker shows Keep, Discard, or Edit with a compact symbol and color; solid, outlined, and dashed treatments distinguish explicit, implicit, and staged-default states. Full text remains in accessibility labels.

Duplicate destination albums are treated as an error requiring a user to choose a specific album. This follows the prompt's no-guess rule and is not a new product decision.

## Evidence and limits

Source references are relative links into this checkout. Apple API statements were checked against the installed Xcode 27.1 SDK headers and Apple's current developer documentation. Phase 2 builds and runs on iOS 27.0 iPhone and iPad simulators; each simulator UI suite passed its two launch and permission checks. The Mac/core suite and universal Mac app/DMG packaging validation also passed. Physical-device, real-library, two-device, and accessibility verification remain open. See [the roadmap](PHASE2_ROADMAP.md) for the remaining validation boundary.

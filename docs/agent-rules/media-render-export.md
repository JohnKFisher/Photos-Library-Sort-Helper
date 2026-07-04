# Media, Render, Export, and Output Quality Rules

Read this when the task touches media import/export, rendering, encoding, generated files, filenames, temp/render cleanup, output quality, color, HDR, brightness, timing, audio/video behavior, thumbnails, metadata, codecs, or final exported artifacts.

Do not read this for non-media work.

## Protected output principle

For media/output apps, the final artifact is core product behavior. Treat output quality, determinism, compatibility, and user trust as protected.

Before implementing a materially heavier, lower-quality, less compatible, or behavior-changing output approach, provide:

- baseline behavior,
- expected impact or risk envelope,
- safer alternatives including a no-regression option,
- recommendation.

If exact baseline numbers are unavailable, provide a measurement plan before coding and actual before/after measurements after implementation when practical.

## Compatibility

Use conservative defaults for common playback/viewing environments. Do not expose codec, HDR, encoder, or rendering internals in primary flows unless the user is in an advanced context.

For media-output changes, consider:

- codec compatibility,
- timing accuracy,
- audio/video synchronization,
- metadata,
- output dimensions,
- playback compatibility,
- expected viewing environments.

Do not assume successful export implies acceptable output quality.

## Filenames and generated text

Show resolved filenames/output paths clearly. Keep manual overrides explicit. Prefer changing shared source-of-truth helpers instead of patching duplicated controls.

Treat filenames and metadata as untrusted input; also read `untrusted-input-tools.md` when relevant.

## Temp and cleanup safety

Only clean app-owned temp roots and nested children. Do not touch source media, source libraries, or final exports unless explicitly requested.

Destructive cleanup requires clear, approved behavior and should be previewable when feasible.

## Verification

For render/export/color/HDR/timing/media changes, run targeted tests/checks plus a focused build or smoke test when risk justifies it. Avoid repeated full builds after small UI/copy changes; batch verification and scale to risk.

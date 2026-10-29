# Photos Library Sort Helper — Where We Stand

## Current Source Version

- Marketing version: `2.5.5` (`VERSION`)
- Build number: `66` (`BUILD_NUMBER`)
- The repository-root version files feed both the Mac package and iOS target. The Mac app Bundle ID is `com.sidelarklabs.photoslibrarysorthelper`; the iOS app Bundle ID is `com.sidelarklabs.photoslibrarysorthelper.ios` and its UI-test target is `com.sidelarklabs.photoslibrarysorthelper.iosUITests`. The Mac deployment target, architectures, signing configuration, package name, and release workflow remain in place.
- A successful local build is not a signed or published release. `dist/` artifacts can lag source.

## Product Status

The Mac app remains the established local-first Photos and Folder review tool. Phase 2 adds a Photos-only iPhone/iPad app and shared platform-neutral review/persistence code. Both apps keep review decisions under the user's control; neither picks winners nor deletes Photos media. Folder mode remains Mac-only.

## Implemented

- Shared `PhotosSortCore` temporal grouping, review decisions, group completion/skip, scope positions, pending queue, album bindings, and commit-intent models.
- Photos groups use deterministic adjacent capture-time gaps; videos remain singletons and Live Photos remain photo items. Vision feature-print refinement is removed.
- Per-device SQLite persistence for Photos review state, shared pending queue, destination bindings, and commit journals. Scan preferences remain inspectable JSON.
- Mac import of the legacy review-session JSON keeps the original file and imports only validated explicit decisions; displayed legacy groups are not promoted to completed work. Folder review sessions write to a dedicated JSON file and copy forward older Folder sessions without overwriting the retained Photos migration source.
- Best-effort destination-album reconciliation and conflict review, with immutable commit attempts and removal of only locally matched, verified queue revisions.
- SQLite review revisions use a durable monotonic sequence; resolved commit journal entries cannot be replayed against later restaged choices. Legacy import and its verification receipt commit atomically.
- Photo group identifiers include the full review scope. Prior completion/cursor state is restored only for an exact membership match with a compatible grouping fingerprint; Folder identity remains stable.
- Photo date filters use inclusive local calendar days represented as a half-open interval, including DST transitions and fractional timestamps.
- Existing Mac-native scenes, Settings/About, menus and keyboard commands, Finder integration, Photos review, and conservative Folder workflow remain.
- Universal iPhone/iPad Photos-only target with Review Console navigation, Keep-first/Discard-first, local pending review, comparison, media inspection, conflict handling, and the same compact Photo-First classification indicators in photo navigation.
- Mac Photos comparison and explicit image, Live Photo, and video inspection. Folder mode remains on its established review/commit path.
- Mac thumbnail cards and iOS photo navigators show small bottom-right Keep, Discard, or Edit indicators. Fill/outline/dash treatment separates explicit, implicit, and staged-default states; accessibility labels carry the full state.
- Photos access is deferred until an explicit Photos action. iOS launch and review-mode selection do not request permission.
- Folder scans and previews stay anchored to no-follow directory/file descriptors while reading media metadata, reject selected symlink roots and replaced directory chains, and keep video access descriptor-backed. Folder commits anchor directory descriptors, reject symlink traversal and changed scanned-file identities, and use exclusive no-overwrite moves. Progress and cancellation are visible in the commit summary; a partial cancel leaves already moved files in place, preserves the remaining explicit review choices after rescan, and does not complete the batch.
- Mac Photos queue rechecks and iOS membership rechecks serialize against scans/commits so stale membership observations cannot race active work.
- On first launch with the new Mac Bundle ID, the app makes a validated, one-time copy of local Application Support data from the former Mac Bundle ID; it uses the retired legacy Bundle ID only when the former current-ID folder has no state. It retains every old directory and uses SQLite's backup API for a consistent database snapshot. If the destination already contains unrelated state or an older app is still running, migration stops and preserves the existing data.
- macOS may require Photos access to be granted again after the Mac Bundle ID change.
- This identity change has not been repackaged for Mac yet. The most recent packaged Mac build is build 63 and still uses the former `com.jkfisher.photoslibrarysorthelper` identifier. The latest automated test snapshot used build 67; the checked-out source metadata is build 66.
- The new iOS Bundle ID uses a separate app sandbox. Any data left in an installed `com.jkfisher.photoslibrarysorthelper.ios` app container is not automatically transferred by this change.

## Automated Verification

- Swift package and Mac regression suite: 74 tests passed, including bundle-ID migration, SQLite import/revision/replay behavior, exact-scope group restoration, calendar date boundaries, Folder symlink and replaced-directory/file rejection, no-overwrite collisions, progress cancellation, post-cancel review-choice preservation, successful empty-source completion after a full Folder commit, and existing review/session invariants.
- iOS simulator UI suite: 2/2 passed on iPhone 18 Pro and 2/2 on iPad Pro 11-inch (iOS 27.0) from the latest source snapshot. Both cover no Photos prompt at launch and changing review mode without Photos work.
- Universal Mac app packaging completed at build 63 before this bundle-ID change. That former-ID ad-hoc signed arm64/x86_64 app passed codesign verification; its generated DMG checksum passed `hdiutil verify`.
- Packaging directly inside repository `dist/` is affected by the workspace's File Provider metadata, which reattaches `com.apple.FinderInfo` during codesign verification. The validated app and DMG were staged under `/private/tmp`; the pre-existing `dist/.DS_Store` was preserved.

Sol's Phase 2 acceptance review found and helped close a Folder-versus-Photos session restoration regression. The final acceptance pass also found that moving all reviewable Folder items could make the automatic empty-source rescan restore stale review choices; that path is now handled as a completed commit and has an app-path regression test. Automated checks do not exercise PhotoKit against a real library or prove multi-device iCloud behavior. The descriptor-backed video loader was exercised with a generated MP4, but broader codecs, seeking, and sustained playback remain unqualified. The iOS UI suite checks launch and permission timing, not an actual Photos review screen. A visual iPad accessibility snapshot also timed out in the simulator automation service. These checks do not substitute for VoiceOver, Dynamic Type, or physical-device acceptance.

## Remaining Validation

- Test on real Mac/iPhone/iPad hardware with a disposable Photos library, including two-device edits, delayed/offline iCloud sync, permission changes, renamed/duplicate albums, and large/backdated/missing-date media.
- Check VoiceOver, large Dynamic Type, contrast, reduced motion, keyboard use, touch targets, landscape, and adaptive iPad layouts on devices.
- Measure scan latency, memory, thermal effects, thumbnail cache size, and media-download behavior on representative libraries.
- Exercise descriptor-backed video previews with representative camera formats, seeking, and sustained playback on hardware.
- Developer ID signing, notarization, TestFlight/App Store metadata, and distribution remain separate owner-acceptance work; the local package uses ad-hoc signing.

## Safety and Trust Boundaries

- The Photos workflow adds user-reviewed decisions to `Fully Sorted`, `Files to Manually Delete`, or `Files to Edit`. It never removes assets from Photos albums or permanently deletes media.
- Cross-device detection uses Photos album membership and is best-effort. A race remains possible if two devices commit conflicting choices before either sees the other's update.
- A pending Photos choice belongs to one device's local app container. It is not silently synchronized through iCloud or a separate service.
- Full Photos access is needed to establish unsorted work and validate every destination album. The apps preserve local pending work when access is unavailable.
- Folder writes remain previewed and deferred until the explicit commit step; kept files stay in place by default. The iOS app does not scan folders.
- Folder queue actions only move files into the approved sibling destinations. Each move rechecks a scanned file's device/inode where available, traverses directories without following symlinks, and refuses to overwrite a destination. A cancelled multi-file commit can leave a completed prefix already moved; those files remain reported as moved and the batch stays incomplete until the remaining reviewed work is resolved.
- iCloud-backed originals can take time to load. Progress is reported for explicit preview/download requests, not used to infer that media is missing.

## Setup

- Mac: macOS 26 or later and Xcode for local builds.
- iPhone/iPad target: iOS/iPadOS 27 or later and Xcode for local builds.
- Photos access is requested only when the user starts Photos work. Folder mode requires read access to a selected source and write access at the chosen commit destination.

## Project References

- [Approved decisions](DECISIONS.md)
- [Multiplatform Phase 2 roadmap and completion status](planning/multiplatform-phase-1/PHASE2_ROADMAP.md)
- [Interactive design prototypes](planning/multiplatform-phase-1/prototypes/index.html)

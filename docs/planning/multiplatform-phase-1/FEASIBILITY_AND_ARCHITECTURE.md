# Feasibility and Architecture Proposal

**Status:** Phase 1 findings with owner-approved Phase 2 architecture (2026-10-29). Apple platform claims below were checked against Apple's current documentation and the installed Xcode 27.1 / iOS 27.1 SDK.

## Recommendation in one page

Keep one product and make the three applications native. Extract a small, platform-neutral Swift package for media metadata, grouping, classification, per-device queue state, and commit planning. Keep PhotoKit in a shared Apple-platform adapter with thin OS-specific image/player presentation. Keep AppKit, Finder, security-scoped folder access, and the existing folder workflow in the Mac app. Add a universal iPhone/iPad Xcode app target that consumes the core package. Do not make the current SwiftPM executable pretend to be an iOS app.

For the first approved product release, use the three Photos destination albums as the only committed-status record. Use local asset identifiers for each device's own active work; optionally map `PHCloudIdentifier`s for cross-device correlation and recovery, without treating unresolved mappings as proof that an item was deleted. Persist each intended decision and its commit state before invoking PhotoKit. Revalidate immediately before a commit, batch the three destination outcomes into one PhotoKit change operation where possible, verify the observed result, then clear only confirmed successes.

Build a lightweight, complete metadata/index pass for a chosen scope before claiming globally oldest-first groups are complete. Once that pass finds the entire ordered candidate set, produce the first complete groups and progressively request only visible/prefetched thumbnails and inspection media. This gives correct boundaries without downloading full-resolution files for discovery. PhotoKit fetch results can be observed for later library changes; use those changes to mark an index stale and refresh rather than assuming a timestamp checkpoint alone is complete.

## Verified Apple capabilities and limits

### PhotoKit permissions and albums

The existing Mac package's minimum is macOS 26.0, and the installed toolchain is Xcode 27.1 with iOS SDK 27.1. Apple's iOS/iPadOS 27 release notes confirm the 27 SDK is for apps running on 27. The iOS target can therefore be built against the requested baseline on this machine, but this task did not build an iOS target or use a simulator.

PhotoKit offers read-write authorization and limited authorization. The current project already has a macOS Photos entitlement plus Photos usage strings in `Resources/PhotosLibrarySortHelper.entitlements` and `Resources/Info.plist`; retain the Mac capability and permission timing. An iOS target needs an `NSPhotoLibraryUsageDescription` that clearly describes whole-library review and album organization. It should request `.readWrite` after the user starts a Photos action, as the user approved.

There is a material iOS constraint: Apple documents that apps with limited Photos access **cannot create or fetch user albums**. The user-selected subset also cannot establish that an unseen asset is unsorted. Since the approved invariant depends on checking all three destination albums across every normal review scope, limited access cannot safely support Continue Sorting or Commit All. The app should explain that full library access is required for this workflow, retain pending work, and stop status-dependent review/commit while authorization is limited or unavailable. This is more conservative than pretending limited access is a complete library.

PhotoKit creates or changes albums through `PHAssetCollectionChangeRequest` in `PHPhotoLibrary.performChanges`. Apple's documentation says a change block can combine several changes into one atomic update; this supports a single local transaction for the three destination outcomes. It does not create a transaction across devices or guarantee that iCloud Photos has finished propagating it. (Apple: [Photos authorization and limited-library behavior](https://developer.apple.com/documentation/photokit/delivering-an-enhanced-privacy-experience-in-your-photos-app), [requesting Photos changes](https://developer.apple.com/documentation/photokit/requesting-changes-to-the-photo-library), [collection change requests](https://developer.apple.com/documentation/photos/phassetcollectionchangerequest).)

### Cross-device IDs and membership

`PHAsset.localIdentifier` and collection local identifiers are for the local Photos library context. Apple's `PHCloudIdentifier` documentation describes an identifier for an asset or collection that syncs through iCloud Photos and conversion back to the local identifier on another device. The mapping APIs report per-item failures and Apple says lookups can be expensive and should be performed sparingly. Therefore:

- Use local IDs for local queue keys, local fetches, album-membership queries, and device-specific restoration.
- When cross-device identity is needed, request/cache a cloud mapping at controlled load/save points. Treat “not mapped,” “not downloaded,” “not authorized,” and “asset definitely removed” as different states.
- Do not use filenames, capture timestamps, visual similarity, or a local ID copied from another device as a substitute identity.
- Recheck each device's local asset against its locally fetched destination albums. Cross-device status is conveyed by Photos album membership, not by synchronizing the app's pending queue.

The album approach still depends on iCloud Photos being enabled and synced for the relevant devices. Apple describes library changes appearing across devices through iCloud Photos; it does not expose an app-level lock, compare-and-swap, or a “all devices have received this commit” API. A phone and Mac can both pass preflight before either sees the other's change. A one-device atomic PhotoKit transaction and post-commit refresh reduce partial local states, but **cannot prevent every simultaneous cross-device conflict** without adding a shared coordination service, which the product explicitly excludes. The app can detect and preserve conflicting memberships once visible, but the residual race must be accepted and documented.

Album names are discovery hints, not durable identity. For first-time binding, match a unique exact name and detect duplicates. A bound device should persist its local collection identifier plus a cloud identifier when available; later resolve that identity first so a rename on another device can be recognized without changing the album title. There is an unavoidable cold-start gap: a newly installed device has no saved cloud identifier, so a renamed album cannot be distinguished from a missing album by role. If an expected exact name is absent, do not silently create a replacement. Ask the user to bind an existing album or explicitly create the role's album. Also pause when album fetches are incomplete, authorization is limited, or the library/account may be stale. Once bound, preserve decisions and offer a clear rebind/recovery path if identity resolution later fails. A current user's deletion of an asset from all destination albums intentionally makes it eligible again, per the approved decision.

### Keywords: present, but not a Phase 2 baseline

Apple's current iOS 27 SDK contains `PHAsset.extendedMetadata.keywords`, `PHFetchOptions.prefetchAssetExtendedMetadata`, and `PHAssetChangeRequest.addKeyword` / `removeKeyword`; the headers mark the extended metadata APIs as macOS 27/iOS 27 and newer. The current Mac minimum is macOS 26, so these APIs are unavailable for every supported Mac. Apple's current developer documentation marks the keyword mutation APIs as Beta, and Apple's WWDC26 PhotoKit lab says there is no PhotoKit-level API to fetch or query assets by keyword. That makes keywords a poor replacement for the shared 26+ Mac / 27+ iOS album design: it would require a full metadata enumeration and in-app filter, add per-asset metadata requests, and introduce a beta-only Mac path. Keyword changes also modify visible Photos metadata that a user may already maintain. Do not use keywords for status or migrate albums to keywords in Phase 2 unless Apple ships and documents stable APIs on all supported targets and measured tests show a material advantage.

Evidence: [PHAssetExtendedMetadata](https://developer.apple.com/documentation/photos/phassetextendedmetadata), [addKeyword(_:)](https://developer.apple.com/documentation/photos/phassetchangerequest/addkeyword%28_%3A%29), [iOS/iPadOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes), and Apple's [WWDC26 Camera and Photo Technologies Group Lab](https://developer.apple.com/videos/play/wwdc2026/8018/). The last source specifically distinguishes Photos app keyword editing/search from the lack of a PhotoKit query API.

### Progressive scan and iCloud media

The current implementation materializes all selected `PHAsset`s and review metadata before starting group review, then its Vision refinement can request 320-pixel images across a whole time cluster. PhotoKit's `PHFetchResult` and fetch options support sorted asset results and incremental change observation, but strict ordering must preserve the existing `(creationDate ?? modificationDate)`, nil-date, tie-break, grouping-version, and source-scope semantics. A date-only cursor is not enough to resume safely after imports, date edits, deletions, membership changes, or an interrupted open time cluster.

Recommended scan stages:

1. Check authorization, current album bindings, scope parameters, cancellation state, and any saved checkpoint.
2. Fetch membership IDs from all three status albums, then enumerate the requested Photos/date/album scope. Exclude both the union of committed album members and every local pending-queue ID from **new unsorted work in every scope**. Keep pending records in their separate revisit path so users can revise them without presenting them again as new unsorted items. Store only small metadata records (local ID, optional cloud ID, creation/modification dates, media type/subtypes, and needed labels), not full image/video payloads.
3. Sort with the approved effective-date comparator and a deterministic tie-breaker. Keep video singleton semantics; group standard and Live Photos by adjacent capture-time gap. A complete metadata pass is the simplest correctness-first way to promise no omitted candidate and a true oldest-first frontier while honoring the current modification-date fallback. Its duration and memory cost must be measured on large libraries before final tuning.
4. Once the complete ordered metadata set and group boundaries are established, make the oldest complete groups available. Progressively decode or request thumbnails only for visible candidates and a bounded prefetch window. Request full-quality still, Live Photo motion, or video data only when the user inspects it or enters comparison. The progressive phase is media preparation after correct global order is known, not exposing a guessed prefix while metadata ordering is incomplete.
5. Save a versioned scan checkpoint and user position. On scene activation, authorization change, or `PHPhotoLibraryChangeObserver` notification, reconcile the index and mark affected groups stale. Do not silently discard already staged decisions when membership or metadata changes.

PhotoKit exposes `progressHandler` for iCloud image/video downloads when network access is enabled, as well as a cancellation flag. The current image and video requests allow network access but do not provide a useful download progress state. Add explicit “Waiting for iCloud” / progress / cancel UI to detail loading; discovery itself should not request media payloads. Apple: [image request progress](https://developer.apple.com/documentation/photos/phimagerequestoptions/progresshandler), [video request options](https://developer.apple.com/documentation/photos/phvideorequestoptions), [photo library change observation](https://developer.apple.com/documentation/photos/phphotolibrarychangeobserver).

On iOS, persist metadata/index checkpoints and decisions before suspension; treat foreground return as a normal revalidation point. Do not depend on background execution to finish a library-wide scan. A scan should be cancellable, resumable, and useful after the app is terminated. No background mode or extra entitlement is justified for the foreground review workflow.

### Native media and comparison

PhotoKit supports image, video, and Live Photo requests. Apple's `PHLivePhotoRequestOptions` provides network access, download progress, quality/delivery options, and a result intended for motion playback. The current Mac app displays Live Photos as still images with a badge and does not request motion. The existing video path requests an `AVPlayerItem`; review it for scrubber/playback controls on the Mac. On iPhone/iPad, use native SwiftUI/UIKit media surfaces, `AVPlayer`, and a Live Photo view. Request inspection media lazily and release/cancel requests when a view closes.

Comparison is a manual viewer built on the same media request layer: select two items in one group, show side-by-side on Mac/iPad, switch between two equal-scale panes on iPhone, and keep each photo's classification independent. Synchronized zoom/pan is an optional convenience, not a classification signal. No automatic scoring or winner selection is needed.

Apple: [Live Photo request options](https://developer.apple.com/documentation/photos/phlivephotorequestoptions), [PhotoKit image/video/live loading and caching](https://developer.apple.com/documentation/photos/loading-and-caching-assets-and-thumbnails).

## Proposed component boundaries

| Component | Responsibilities | Must not depend on |
|---|---|---|
| `PhotosSortCore` Swift package | Value types for media metadata, grouping/versioned fingerprints, review modes, item decisions, group completion/skip, scope identity, queue state, conflict state, commit plan/reconciliation rules | `PHAsset`, `UIImage`, `NSImage`, `NSWindow`, folder URLs/bookmarks, SwiftUI views |
| Shared PhotoKit adapter | Authorization, metadata/membership enumeration, asset/cloud identifier mapping, album binding, change observation, request/cancel still/Live Photo/video data, single PhotoKit change transactions | AppKit windowing, iOS navigation, folder traversal |
| Per-device persistence | Local sessions per scope, one photo-keyed pending queue, saved positions, scan checkpoints, album bindings, write-ahead commit intent/recovery | iCloud app-container sync or remote services |
| macOS app | Existing scenes/settings/About/menus, keyboard shortcuts, Folder/Finder/security-scoped bookmark mode, Mac Photos UI, Mac packaging | iOS view hierarchy or mobile folder sorting |
| iOS/iPadOS app | Universal Photos-only app; iPhone one-handed review; iPad split workspace; lifecycle/permission surfaces | AppKit, Finder, security-scoped folder access |

Share domain code and PhotoKit semantics where they are genuinely common; keep SwiftUI views native and responsive to each platform. The current `ReviewViewModel` should be split by responsibility only after Phase 2 begins; do not take on a wholesale Mac UI rewrite. `PHAsset` and platform image/view objects stay inside platform adapters so the core remains deterministic and straightforward to test.

## Pending queue and stored decisions

The queue is device-local and keyed by the device's Photos local asset identifier, with an optional cloud identity used only for reconciliation. Store one current target per photo: `fullySorted`, `manualDelete`, or `edit`. Store the origin (`explicit`, or `defaultAppliedOnCompletion`), the scope/group and grouping version that produced it, and status (`pending`, `committing`, `committed`, `conflict`, `unavailable`). Exclude both every destination-album member and every pending queue item from the new-work query across all scopes. Provide a separate revisit route for staged items and prior groups; revisiting must not put those IDs back into the new-work set. Multiple destination memberships are a conflict to surface, not an invitation to silently move it.

The approved product decisions require that changing the active review mode cannot reinterpret prior choices and that local decisions persist as work progresses. Therefore, stage explicit per-photo classifications immediately. When a group is completed, convert only its still-unmarked photos into frozen item-level queue decisions using the active default. `Skip Group` advances the scope position without defaulting untouched items; any explicit marks remain saved. Mode changes affect only items not yet classified. This keeps skipped groups unresolved without discarding explicit work.

Use one queue across all scopes. Scope records hold only view/session state: the last group/item, the saved index/checkpoint, and grouping/settings version. Continue Sorting resumes the most recent unfinished scope; choosing another scope does not replace queue entries. The queue is idempotently indexed by photo identity so the same asset cannot exist twice with two pending classifications.

### Persistence format decision

The existing Mac session is inspectable JSON with atomic replacement and legacy readers. For the Photos workflow's shared per-photo queue, commit journal, and resumable scope positions, the approved choice is **system SQLite** for those related transactional records, with JSON retained for scan preferences and as a read-only import format. The established Mac Folder review session remains inspectable JSON in its own file, separate from the retained Photos migration source. SQLite can update the queue, journal state, and position in one transaction without rewriting a large snapshot for each decision. Keep the schema small and directly inspectable; add an on-demand human-readable JSON export rather than a continuously mirrored Photos queue. This uses Apple's system library and needs no third-party dependency.

The owner approved system SQLite for implementation. Inventory the current JSON fields, map explicit/default decisions without reinterpretation, import in one transaction, validate equivalence before activation, and retain original session files unchanged until the new data is verified. Repeated or interrupted import must not duplicate/overwrite state. Keep the repository behind a narrow interface; neither Core nor the UI should depend on SQL rows. Test legacy, malformed, interrupted and duplicate imports, database/write failures, commit interruption/reconciliation, and queue-scale performance. Do not migrate app data into an iCloud container. The iOS app starts with its own empty per-device queue.

## Commit protocol and recovery

The user-approved normal action is Commit All after a clear summary; no direct/permanent deletion, selective commit system, or reminders. Implement the Photos side as an optimistic protocol:

1. Persist a commit attempt ID and immutable intended item/category decisions before any PhotoKit write.
2. Recheck full authorization, resolve the intended albums by saved identity, fetch each local asset again, and read current membership in all three destination albums.
3. If an item is already in its intended album and nowhere else, record it as already satisfied. If it is in another destination, more than one destination, or the item/album identity is unknown, leave it pending and mark a conflict/unavailable state. Never silently rewrite the classification.
4. In one `PHPhotoLibrary.performChanges` block where possible, add the remaining items to their intended destinations. Do not remove from existing albums.
5. On completion, fetch again and verify postconditions. Only then mark verified items committed and remove them from pending state. Keep failed/uncertain items and their intent.
6. On relaunch or interruption, reconcile the persisted attempt with fresh membership: matching target state means completed; no matching write means retryable; differing/multiple membership means conflict; unavailable identity remains pending. Never infer success only from a stale callback.

This handles crashes around local writes and idempotent retries. It cannot lock another device. If two devices concurrently make opposing decisions before either change syncs, both local PhotoKit transactions may succeed. Once the conflict becomes visible, stop further actions on that item, preserve both recorded intentions, and ask the user to resolve it in Photos/the app. This limitation is inherent in the no-custom-sync requirement; strict prevention of every concurrent write is not available from PhotoKit.

After a successful local commit, remain in the review screen, remove the confirmed item(s), keep the user's scope cursor anchored, and advance to the next eligible unsorted group. Show a brief success message. On partial failure, keep working items pending and report only those exact outcomes.

## Destination album identity and recovery

For each of the three destination roles, store the bound local collection identifier and optional cloud identifier. On a fresh install, scan visible user albums by exact expected title: bind a unique match; ask the user to choose when duplicates exist; and, when there is no exact match, ask whether to bind an existing renamed album or explicitly create the missing role. This prompt covers the case where another device renamed an album before the app was installed and no cloud identifier was available to map. After a device has stored a binding, resolve that identity first. If it resolves after a rename, preserve that exact collection and explain the changed title. If it is missing, authorization is limited, collection fetch failed, the library changed, or the Cloud ID is not mapped, distinguish those states and retain the queue. Do not treat a failed album fetch as an empty album, and do not auto-create a replacement during recovery.

On an account without iCloud Photos, album-based sorting remains a device-local workflow. If the user expects status to coordinate across devices, explain that those devices need the same iCloud Photos library. User changes that remove an asset from every destination album are honored as re-eligibility. Multi-album membership is never resolved automatically.

## Build and distribution structure

At Phase 1, the baseline recommendation was to retain the existing Mac executable, Bundle ID, arm64/x86_64 app/DMG script, Photos entitlement, minimum macOS version, and release workflows. The Bundle ID recommendation was superseded by the owner's 2026-10-29 decision recorded in `docs/DECISIONS.md`; the other Mac packaging and release constraints remain active. The approved iOS target activates the repository's root `VERSION` and `BUILD_NUMBER` convention for both targets; `Resources/Info.plist` remains the source for fixed Mac bundle/permission settings, with generated version values supplied from those root files. The existing effective Mac values are 2.5.5 (9), so initialize the root files without changing them. The existing helper and packaging script must read the root authority and allocate exactly one build number per build/package invocation.

Add a `PhotosSortCore` library target to the Swift package while retaining `PhotosLibrarySortHelper` as the macOS executable. Add a small Xcode project or workspace for the universal iOS/iPadOS app that references the local package. Keep Photos usage strings and any future capability scoped to each target. Do not change the Mac minimum or its packaging workflow merely to create the iOS target. Use a product-specific iOS Bundle ID. The owner later approved paid-team signing and the final IDs `com.sidelarklabs.photoslibrarysorthelper` (Mac) and `com.sidelarklabs.photoslibrarysorthelper.ios` (iOS), superseding the original Phase 1 Bundle ID restrictions. The iOS UI-test target uses `com.sidelarklabs.photoslibrarysorthelper.iosUITests`.

PhotoKit album operations do not require an app-owned iCloud container or remote service. iCloud Photos sync is the user's Photos service. The eventual App Store/TestFlight path needs an iOS app target, code signing/provisioning, correct Photos usage text, privacy disclosures, device testing, and App Store review readiness; none of that is part of this Phase 1.

## Independent architecture review

A bounded Sol consultation agreed with the core/native-shell boundary and emphasized three risks: the current time-gap algorithm is transitive and can form long chains; creation-date-only paging would not preserve the current modification-date fallback; and a one-device transaction cannot serialize two devices. The roadmap and outstanding decisions preserve those qualifications. Sol also recommended treating an unavailable cloud/local mapping as unresolved, not as a deleted photo.

## Verified / inferred / test-needed

| Area | Phase 1 conclusion | Evidence status |
|---|---|---|
| iOS 27 SDK presence | Installed Xcode 27.1 / iOS SDK 27.1; keyword symbols are in SDK headers | Verified locally |
| Keyword API | Current docs mark mutation Beta; no PhotoKit keyword query in Apple WWDC26 lab; unavailable on macOS 26 minimum | Verified documentation/header evidence; API maturity may change |
| Limited access and user albums | Apple documents user-album fetch/create restriction under limited iOS access | Verified documentation |
| Cross-device asset ID | Cloud ID can map synced assets/collections; mapping can fail and be expensive | Verified documentation |
| iCloud Photos convergence | Album changes sync when the same library uses iCloud Photos; no app-level atomic lock | Product service behavior/documentation; sync timing must be tested |
| One-block commit | PhotoKit change blocks combine requested changes in one local transaction | Verified documentation; exact multi-album failure/relaunch path still needs tests |
| Full metadata pass cost | Correctness-first approach for current preferred-date and complete oldest-first semantics | Architecture inference; benchmark on large libraries |
| Progressive index/update | PhotoKit supports change observers and incremental fetch details | Verified capability; performance and ordering behavior need device tests |
| Live Photo motion | Native PhotoKit requests provide Live Photo results and iCloud progress support | Verified API; inspect on physical Mac/iPhone/iPad |
| Simulator run | CoreSimulator service could not start or list runtimes | Unavailable in this environment |

# Design Concepts and Recommendation

The three concepts are independent interactive proposals in [the prototype lab](prototypes/index.html). Switch between **iPhone**, **iPad**, and **Mac**, and portrait/landscape, from the prototype toolbar. Every concept uses the same fictional travel-photo set and queue counts. Prototype data and button behavior are simulated.

## What each concept explores

### 1. Balanced Workbench

A spacious group overview leads with a photo grid, a clear Keep-first/Discard-first label, and small badges that distinguish a review default from an explicit mark. Classification and group navigation sit in a persistent lower action bar. Photo inspection and comparison open a focused viewer. On iPad and Mac, the grid breathes across the wider workspace. This is the most balanced expression of the approved Apple Photos plus sorting-workstation direction.

### 2. Review Console

A task-oriented workspace keeps group progress, mode, pending count, and Commit All visible while the user reviews. On iPad and Mac it uses a group/photo navigator alongside a large selected photo and a dedicated decision area. On iPhone the navigator collapses into a compact progress header and a thumb-reachable action rail. The concept makes “what happens next?” and “how many decisions are waiting?” especially clear. This is the strongest sorting-workstation direction and the recommended baseline.

### 3. Photo-First Triage

A large photo fills most of the review space; a compact filmstrip gives group context and classification appears in a contextual dock. Opening the grid gives a separate overview. Comparison is immersive on Mac/iPad and switches between two equal-size photos on iPhone. The visual hierarchy keeps attention on the media, but it asks users to move between overview and inspection more often.

## Task and platform comparison

| Criterion | Balanced Workbench | Review Console | Photo-First Triage |
|---|---|---|---|
| Sorting speed | Fast for small/medium groups; all items are visible together | **Fastest for repeated review**: group position, decisions, and pending queue stay in view | Fast for one-at-a-time decisions; slower for large groups because overview is secondary |
| Keep-first / Discard-first comprehension | Clear mode banner plus per-item defaults | **Strongest**: persistent mode label and prominent group/default explanation | Good while the action dock is visible; weaker if controls collapse during inspection |
| Default vs explicit marks | Clear and easy to scan across a grid | **Best state visibility**: explicit/default badges stay next to items and in the inspector | Can be clear on the selected item, but status across the whole group is less visible |
| Photo comparison | Select two grid items and open compare | **Best workbench fit**: compare from the navigator; both decisions remain available | Strong immersive focus; switching between photos on iPhone is natural |
| Accidental-action risk | Low; explicit buttons are separated from selection | Low-medium; prominent controls need spacing and clear labels | Medium if controls overlap the image or rely on swipes; concept should keep swipes for navigation only |
| One-handed iPhone | Good if the bottom actions stay in reach; grid may require two hands | Good with a bottom action rail; side panels collapse | **Best** for single-photo Keep/Discard/Edit actions and fast next-photo navigation |
| iPad screen use | Good photo grid, but some empty room in detail mode | **Best**: persistent navigator, large selected image, and inspector use the width well | Strong large-photo canvas, but the group overview uses less of the available space |
| VoiceOver / Dynamic Type / contrast | Straightforward grid semantics; status color must also have text/icon | Most labels and progress are always available; dense panels need Dynamic Type reflow | Requires careful focus order around image, filmstrip, and dock |
| Large groups | All-at-once grid can become dense; needs paging/scrolling and clear group counts | **Best**: navigator can scroll independently from the selected image and decisions | Filmstrip is efficient for navigation but hides the group's overall distribution |
| Singleton groups | A simple single-card grid still works, though it can feel sparse | Clear task header and one decision target | **Best**: one large item with minimal extra controls |
| Pending queue visibility | Visible but secondary to photos | **Strongest**: count and Commit All remain persistent | Needs a deliberate persistent badge/button so immersive mode does not hide pending work |
| Mac continuity | High; adds a grid/details view around existing review concepts | **High**; uses current sidebar, toolbar, menu, and inspector patterns | Medium; the immersive canvas would require more change to the current Mac review pane |
| Native implementation complexity | Medium | Medium-high due to navigator + inspector adapting at three widths | Medium-high due to synchronized filmstrip, immersive inspection, compare, and platform-specific navigation |

## Accessibility and safety notes

The prototype uses text plus shape/icon state, not color alone, for default/explicit and Keep/Discard/Edit. Touch-facing review controls have at least 44 CSS pixel hit areas, accessible labels, and visible keyboard focus. The layout uses flexible type and reflows by viewport width; it does not require hover. VoiceOver and Dynamic Type are not validated by this browser prototype and must be tested in the native apps. In the native implementation, keep actions explicit buttons, reserve swipe for photo/group navigation, and use VoiceOver announcements for mode, pending count, scan progress, and conflict outcomes. Dynamic Type needs particular attention in the Console's denser navigator.

For any concept, Next Group completes the current group using frozen defaults; Skip Group advances without defaulting untouched items. Previous Group reopens a completed group without losing its staged decisions. A separate Review Staged Choices route is available from both the end-of-pass screen and Commit All summary, with previous/next staged-group controls that reach every pending group across scopes. Switching scopes excludes queued items from new unsorted work. Commit All includes destination counts before any Photos mutation and returns directly to review with a brief status message. The prototype's conflict screen leaves the staged item pending and does not try to “fix” album membership. Sample photo times stay within the eight-second adjacent-gap rule; the video appears as a singleton group.

## Recommendation

Use **Review Console** as the approved native baseline across Mac, iPhone, and iPad. Its overall layout, density, navigation, and controls remain. Apply Photo-First Triage's small bottom-right in-thumbnail classification markers to the Console's photo navigators: Keep, Discard, and Edit have distinct compact symbols and colors; explicit, implicit, and staged-default states use different fill/outline treatments, and accessibility labels provide the full state. This makes staged state visible at a glance without importing Photo-First Triage's one-photo-first layout or changing the Console's interaction model.

Balanced Workbench remains an alternative if the Console feels too dense with real group sizes. Photo-First Triage remains useful for a photo-first workflow centered on one image at a time. The approved design intentionally adopts only Photo-First Triage's small in-thumbnail classification indicators; its layout and interaction model are not part of the Console baseline.

## Prototype walkthrough

In each concept, tap **Continue Sorting** to enter the oldest-first sample group. Try a mode change, explicit Keep/Discard/Edit, detail zoom/pan, select two photos and compare, comparison zoom/pan with optional synchronization, Previous/Next Group, Skip Group, switch scopes, commit, and return Home to resume. **Demo states** exposes the finished-library, iCloud wait, limited-access, duplicate-album, and cross-device-conflict states. Reload the page to verify the fake unfinished session restores from this prototype's own browser storage.

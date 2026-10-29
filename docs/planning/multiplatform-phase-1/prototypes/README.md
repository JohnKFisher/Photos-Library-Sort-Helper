# Interactive Prototype Lab

Open `index.html` directly in a current browser, or run a simple local server from the repository root:

```sh
python3 -m http.server 8765
```

Then open `http://127.0.0.1:8765/docs/planning/multiplatform-phase-1/prototypes/`.

Choose a concept, device, orientation, and appearance from the controls above the device frame. The prototypes use local generated SVG illustrations and simulated Photos/review state only. They make no network requests and never ask for Photos permission. The demo may keep its simulated session in this browser's local storage so you can reload and inspect the resume flow. **Clear the prototype data** from the toolbar to reset it.

## Controls to try

- **Continue Sorting** enters the oldest-first review. Use **Scope** to switch all-unsorted, album, date-range, or combined sample scopes without clearing pending changes.
- Select a photo and use the explicit Keep / Discard / Edit buttons. The chip shows whether the current state is a mode default or an explicit staged choice.
- **Next Group** applies defaults to remaining photos and stages the completed group. **Skip Group** leaves untouched photos unresolved. Previous Group preserves saved choices. The end-of-pass screen and Commit All summary both offer **Review staged choices**, including after the last group; Previous/Next staged group controls reach every pending group.
- Open a photo for enlarged inspection, zoom, drag to pan, navigate photos, and use sample Live Photo/video controls.
- Select two photos with the compare checkboxes and choose **Compare 2**. iPhone switches between equal-sized images; iPad and Mac show both.
- **Commit All** opens a destination summary. The simulated success shows a brief status message and returns directly to the review state. The **Demo states** menu includes empty, iCloud wait, limited permission, duplicate album, and cross-device conflict cases.

Every screen includes a `DEMO ONLY` indicator. Button behavior is an evaluation aid, not implemented app functionality.

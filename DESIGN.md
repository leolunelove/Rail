# Rail design rules

Rail keeps the few apps used for one workflow within reach. It is a native Mac utility with a compact vertical strip. Use the current AppKit implementation as the source of exact values.

## Approved geometry

- Keep the strip 54 points wide and app icons 30 × 30 points.
- App buttons occupy 46 × 44 points. Preserve their spacing and small active dot.
- Keep the small drag grip above the icons and the plus button below them.
- The default three-app strip is 194 points tall. Fit longer strips to the current display, scrolling only the icons while retaining the grip and plus button.
- Keep the existing 14-point outer corner radius, restrained border and native shadow.
- Preserve app icon colors. Use AppKit semantic colors and native typography for everything around them. Follow the system appearance.
- Keep secondary controls in context menus and the menu bar menu. The approved rail has no title, text labels, toolbar, stats or permanent action buttons beyond plus.

## Interaction rules

- An ordinary click switches or launches the target app. Mouse interaction should not leave keyboard focus in Rail.
- Only mark a window active when its identity, availability and focused state are known. Permission loss and failed reads must not look like success.
- Parking hides all windows of an app, or minimizes a specifically chosen window. The app keeps running. Name the app-wide action **Hide app (all windows)** and the window action **Park window**.
- Show the parked badge for hidden/minimized targets; make **Bring back** the primary menu action. An unavailable state must be explicit in the tooltip and accessibility label.
- A window pin must always offer **Switch to → Whole app**, including while its app is closed or Accessibility access is unavailable.
- Do not guess between duplicate window titles. Explain recovery when a window title has changed.
- Keep polling of other apps' window state off the main thread, with one query batch in flight and no stale response applied after an explicit switch/park action.

## Accessibility and keyboard use

- Give every icon an app/document name, current state and useful help text.
- Expose the context menu through a named **Show options** accessibility action, alongside the Show Menu handler. Verify it with VoiceOver rather than assuming the handler alone is discoverable.
- Provide **Focus Rail with keyboard** in the menu bar menu. Support arrows/Tab to navigate, Return/Space to act, Control-Return or Shift-F10 for options, and Escape to leave keyboard mode.
- Draw the native focus ring for keyboard interaction. Keep it out of the normal inactive rail.
- Preserve native menu text, selection feedback and semantic contrast. Do not replace system fonts or add decorative animation.

## Changes and validation

Tie changes to a concrete usability problem. Preserve the approved geometry. Document missing data instead of inventing tokens or behavior.

Build with `zsh scripts/build.sh`. Run the packaged app's `--self-test` mode. Inspect light and dark rendered previews after changing drawing code. Live switching, focus, accessibility and parking require a real desktop test: compilation, state tests and rendered previews do not establish those behaviors.

Use `docs/USABILITY-TEST.md` for that test and `docs/STATUS.md` for the current evidence and remaining limitations.

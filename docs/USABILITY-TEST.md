# Rail: 10-minute hands-on check

Use disposable windows without unsaved work. Record **pass**, **fail**, **blocked**, or **not run** for each task, along with the actual outcome. A written test plan is not a test result. Do not invent participant observations or quotes.

If someone else is testing, say: “Try these tasks as you normally would. Tell me what you expect to happen.” Let them find the controls before explaining them.

| Time | Task | Expected result / what to observe |
| --- | --- | --- |
| 0–1 min | Open Rail and switch between three running apps. Type in a disposable document after switching. | Correct app comes forward. Typing goes to that app. Rail stays available; its active dot follows the foreground app. |
| 1–2 min | Add an app using plus, remove it, and reopen Rail. | Added app is discoverable. Removal affects only Rail. The working set and position survive relaunch. |
| 2–3 min | Hide an app through its icon menu, then bring it back. Also try hiding/unhiding it outside Rail. | The action clearly says it affects all windows. Badge, tooltip and Bring back action agree with the app's actual state. Background work continues. |
| 3–5 min | With Accessibility access enabled by the tester, select one of two disposable windows in one app. Park it, reopen Rail, then bring it back. | Only the chosen window minimizes. Its parked state is recognized after restart. The correct window restores. |
| 5–6 min | Rename/close the chosen window, quit its app, or test with Rail's Accessibility access unavailable. | No wrong-window activation or misleading active dot. Switch to → Whole app remains usable. Error text gives a recovery path. |
| 6–7 min | Choose Focus Rail with keyboard from its menu bar menu. Navigate, switch, reopen keyboard mode, show an icon menu, then press Escape. | Native focus ring visible; arrows/Tab, Return/Space, Control-Return/Shift-F10 work. Escape returns keyboard use to the previous app. |
| 7–8 min | With VoiceOver, navigate an app icon and invoke Show options. | App/window name and state are announced; secondary actions are reachable. Record the actual VoiceOver behavior. |
| 8–9 min | Add enough apps to require scrolling, move the rail to a smaller display, or disconnect its previous display. | All icons remain reachable. The strip stays 54 points wide; grip and plus stay available. Reset position recovers it. Mark blocked if another display is unavailable. |
| 9–10 min | Compare light/dark appearances and reopen Rail after moving/reordering it. | Icon order and position persist. Dot, parked badge, hover and focus remain readable without adding visual clutter. |

For each failure note the app, OS version, target window title, permission state, steps and whether it repeats. Share only non-sensitive test information. Fix failures before calling the relevant behavior verified.

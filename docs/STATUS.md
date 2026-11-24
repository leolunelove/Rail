# WIP status

Rail 0.1.1 is ready for development feedback. It is not a stable, notarized public app release.

## Verified so far

- Native build and local signature validation.
- 23 focused automated checks for configuration, geometry, screen recovery calculations, exact/ambiguous window matching and state transitions.
- Live app switching to Figma, Photoshop and Chrome.
- App-wide hiding/restoration, with asynchronous hide confirmation.
- Saved working set across restarting Rail.
- Keyboard entry, arrow navigation, native focus ring, Control-Return menu, Return switching and Escape return.
- Light/dark rendered controls.

## Still to validate

- Individual-window selection, minimizing and restoring with Accessibility access enabled.
- Changed or duplicate titles, app restart and revoked Accessibility access during live use.
- VoiceOver action discovery and announcements.
- Long-list scrolling, dragging, multiple displays, display disconnection and full-screen apps.
- Typing focus in disposable documents after switching; other native key combinations.

## Before an end-user release

1. Finish the live checks in [USABILITY-TEST.md](USABILITY-TEST.md), recording actual pass/fail/blocked results.
2. Resolve failures without expanding the approved minimal UI.
3. Choose a source license and distribution approach.
4. Sign and notarize a distributable build, then test installation on another Mac.

Actual process suspension, CPU/RAM optimization claims, accounts and sync are outside the current product.

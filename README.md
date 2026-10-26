# Air Control

Control your Mac with your hand and your voice. A menu bar app that turns the Mac's camera into an
iPadOS-style pointer — it glides, snaps onto buttons and links, and clicks when you pinch — and
listens for "Hey Mac" so you can click, scroll, type and switch apps by voice. Everything runs on
the Mac: Vision for hands and faces, on-device speech recognition, and Apple's on-device Foundation
Models for natural phrasing. Nothing is uploaded.

Built from the same hand-tracking and voice engine as the hands-free KDS prototype.

## Run it

1. Open `AirControl.xcodeproj` in Xcode 26 and run (macOS 26, Apple silicon recommended).
2. It lives in the menu bar (hand icon); there's no Dock icon.
3. Grant **Accessibility** when asked (System Settings → Privacy & Security → Accessibility) — it's
   what lets Air Control move the pointer, click, scroll, type and see buttons to snap to. Then allow
   Camera, Microphone and Speech Recognition when prompted. Settings shows all four with buttons.
   - After a rebuild, macOS sometimes needs the Accessibility switch toggled off and on again.
4. For voice, on-device English dictation must be installed (System Settings → Keyboard → Dictation).
   Natural-language commands need Apple Intelligence turned on; without it the built-in commands still work.

## Release build

`scripts/release.sh` archives a Release build, signs it with Developer ID, notarizes it, and wraps it
in `dist/AirControl-<version>.dmg`, a signed and notarized drag-to-Applications disk image. It also
installs the app in `/Applications`. Run it with `--help` for options and the one-time setup
(Developer ID certificate, `notarytool` credentials). The install window's art lives in `Design/DMG/`.

## Hand

| Gesture | Does |
| --- | --- |
| Raise an open palm while looking at the screen | The pointer is yours (it starts wherever the mouse pointer is) |
| Move your hand | Move the pointer — it snaps onto buttons, links, menu items, Dock icons |
| Pinch | Click · pinch twice quickly to double-click |
| Pinch and move | Scroll, like dragging content on a trackpad; flick for momentum |
| Pinch and hold (ring fills) | Let go → right-click · move → drag (windows, files, text selection) |
| ✌️ swipe right / left | Back / forward (two-finger swipe between pages) |
| ✌️ swipe left at the screen's right edge | Notification Center |
| ✌️ held still | Talk without "Hey Mac" for 6 seconds |
| Three fingers swipe left / right | Next / previous Space or full-screen app |
| Three fingers swipe up / down | Mission Control / app windows (App Exposé) |
| 👍 | Look Up the word under the pointer (force click) |
| ☝️ held still | Window menu: aim at Close, Minimize, Full Screen, Tile Left/Right or Fill, then pinch |
| ✊ | Put the pointer away |

While ✌️ or three fingers are up, the pointer waits in place so a swipe doesn't drag it along.

### Two hands

Raise your other hand alongside the pointer hand. Air Control only ever pairs your own two hands —
never someone else's.

| Gesture | Does |
| --- | --- |
| Pinch both hands at once, spread / close | Zoom in / out at the pointer, like a trackpad pinch |
| …twist, like turning a wheel | Rotate (Freeform, Preview, Photos, Keynote, Maps…) |
| …move both hands together | Pan the canvas, with momentum when you let go |
| Hold a pinch with your other hand | Holds ⇧ Shift: pinch-click to add to a selection, drag to keep proportions |
| Swipe both hands left / right | Next / previous Space |
| Swipe both hands up / down | Mission Control / app windows |
| Pull open palms apart / push together | Show Desktop / Apps (Launchpad) |
| Quick pinch-and-release with both hands | Smart zoom (two-finger double tap) |

Zoom, rotate and pan each wait for a clear movement before they start, so zooming doesn't nudge a
shape's rotation. If an app ignores the synthesized trackpad pinch, switch **Zoom with** in Settings
to ⌘ + scroll (design tools, whiteboards, canvas web apps) or ⌘+ / ⌘− (almost everything).

- The pointer only follows someone facing the screen, and only one hand at a time — the first open
  palm wins until it's out of view.
- Touching the real mouse or trackpad hands control straight back.
- Up close, it takes less hand movement to cross the screen; the pinch only fires when your fingers
  actually touch.
- While your hand is up, the arrow is hidden and a glass pointer morphs into whatever it snaps to.
  (This uses a private WindowServer setting; if a future macOS removes it, the arrow simply stays visible.)
- The pointer is clear liquid glass that never blurs what's under it. It's drawn by hand rather than
  with `glassEffect`, because system Liquid Glass always frosts its background. Springs make it
  stretch along fast moves, squish as you pinch, pop on a click and wobble as it snaps onto controls.
- **Tracking speed** in Settings is a slider (tortoise → hare) and applies while you drag it.

## Voice

Say **"Hey Mac"** then a command. While your hand is up (or after ✌️), just say the command.

- `click` · `double click` · `right click` — at the pointer
- `click Send` · `press Save` · `click View` — any labelled button, link or menu in the front window
- `scroll down` · `scroll up a lot` · `go to the top`
- `open Safari` · `switch to Mail` · `quit Music`
- `new tab` · `close window` · `go back` · `reload` · `next tab` · `minimize` · `full screen`
- `copy` · `paste` · `undo` · `select all` · `save` · `find invoice`
- `type see you at 5` · `press command shift T` · `escape` · `page down`
- `start dictation` … `stop dictation` — everything in between is typed (`new line`, `scratch that`)
- `tile left` · `tile right` · `maximize` · `minimize` · `full screen` · `close window`
- `notification center` · `show apps` · `look up` · `smart zoom`
- `search for flights to Denver` (Spotlight) · `mission control` · `show desktop` · `next space`
- Anything else goes to the on-device model, which is given the app, window title and the labels of
  the controls on screen: "hit the blue continue button", "get me back to my email".

Cross-talk protection: with **Only listen to the person at the screen** on, a command is ignored if
the person facing the camera wasn't moving their lips when it was spoken. Live captions above the
Dock show what the mic hears and what happened.

## Where things live

| Folder | What |
| --- | --- |
| `Hands/` | Camera, Vision analysis (hands, head pose, lips), hand ownership, attention, lip-movement detector |
| `Pointer/` | `HandCursor` (hand → pointer, pinch state machine, finger swipes), `WindowMenu`, `SystemActions` (pages, Spaces, windows via Accessibility), `TwoHandGestures` (zoom, rotate, pan, Shift, swipes), `PointerDriver` (CGEvents, scroll phases, momentum, trackpad pinch/rotate, typing), `AXElement` (snapping, click-by-name), `SystemCursor` |
| `Voice/` | `VoiceController` (wake phrase, open mic, dictation), `MacCommandParser`, `MacIntentInterpreter` (Foundation Models), `CommandRunner`, `AppDirectory` |
| `Overlay/` | Click-through panels that draw the glass pointer (`LiquidGlass`, `GlassBlob` springs), captions and toasts; the floating camera preview |
| `Views/` | Menu bar panel and Settings |

## Tuning

| Where | Setting | Default |
| --- | --- | --- |
| `HandCursor` | `pinchOnClose` / `pinchOnFar`, `pinchGap` | 0.15 / 0.19, +0.14 palm lengths |
| `HandCursor` | `holdDelay` (right-click / drag), `scrollThreshold`, `dragThreshold` | 0.5 s, 22 pt, 8 pt |
| `HandCursor` | `closeRangeTravel`, `closePalm` / `farPalm` | 0.5×, 0.30 / 0.10 frame heights |
| `TrackingSpeed` | palm lengths to cross the screen, slow … fast | 5.6 … 1.7 (default 3.2) |
| `TwoHandGestures` | `onsetWindow`, `modifierDelay` | 0.45 s, 0.45 s |
| `TwoHandGestures` | zoom / rotate / pan deadbands, `zoomGain` | 7%, 12°, 30 pt, 1.4× |
| `TwoHandGestures` | swipe speed / travel, cooldown | 5.5 palms/s, 1.6 palms, 1 s |
| `GlassBlob` | follow spring, snap spring, size spring | k 2600 ζ 0.78, k 420 ζ 0.6, k 560 ζ 0.42 |
| `PointerDriver` | scroll `gain`, momentum decay | 1.6×, 0.996 per ms |
| `Snapper` | `magnetRange`; `AX.isSnapSized` | 16 pt; ≤ 520 × 110 pt |
| `HandPoseAnalyzer` | `maxYaw`, `pitchRange`, `minFaceWidth` | 30°, −40…25°, 6% of frame |
| `VoiceController` | wake phrases, open-mic pause | "hey mac" + variants, 1.2 s |

## Known limits

- One display at a time: the pointer stays on the display it started on.
- Window actions use Accessibility on the window under the pointer; a few apps' windows refuse to
  be resized or tiled. Notification Center is opened by pressing the menu bar clock.
- Trackpad pinch, rotate and smart zoom are synthesized with undocumented gesture event fields. Most native and
  web apps accept them; for any that don't, use the ⌘ + scroll or ⌘+ / ⌘− zoom setting.
- Two-hand gestures need both hands in the camera's view — sit back a little or use a wider camera.
- Snapping only sees apps that expose Accessibility info (nearly all native apps; Chrome and
  Electron apps turn it on when asked, which can take a moment the first time).
- Synthetic scroll events aren't flipped by the system's Natural Scrolling setting; use
  **Reverse scroll direction** if it feels backwards.

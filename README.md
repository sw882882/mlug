# mlug

Use an Android tablet as a wired extended display for a Mac.

- **Mac** (`mac/`): creates a real virtual monitor (private `CGVirtualDisplay` API), captures it with
  ScreenCaptureKit, encodes low-latency hardware H.264, and injects tablet touches as mouse events.
  Ships as a menu bar app (`MlugBar`) plus a CLI (`mlug`) for development.
- **Tablet** (`android/`): Kotlin app that decodes straight to a fullscreen surface with MediaCodec.
- **Transport**: USB via `adb reverse` — no Wi-Fi, no pairing. The Mac auto-detects the tablet,
  sets up the tunnel and opens the app.

The virtual display exists only while the tablet is connected; unplug and windows return to the main screen.

## Setup

1. On the tablet: Settings → About tablet → Software information → tap *Build number* 7× → Developer options → enable **USB debugging**. Plug in and accept the prompt.
2. `brew install android-platform-tools openjdk@17 && brew install --cask android-commandlinetools`
3. Install the tablet app: `cd android && ./gradlew installDebug`
4. Build the menu bar app: `mac/bundle.sh`, then open `mac/build/mlug.app`.
5. Grant **Screen Recording** and **Accessibility** to mlug when prompted (System Settings → Privacy & Security).

Arrange the display or change its scaling in System Settings → Displays.

## Input

| Tablet | Mac |
| --- | --- |
| S Pen hover | move cursor |
| S Pen touch / drag | click / drag |
| S Pen side button or eraser | right button |
| Tap / drag | click / drag |
| Long-press, two-finger tap | right click |
| Two-finger drag | scroll |

## Notes

- Ad-hoc signed builds get a new identity each rebuild, so macOS may ask for permissions again.
  Set `MLUG_SIGN_IDENTITY` to a stable signing identity to avoid that.
- Protocol is documented in `mac/Sources/MlugCore/Protocol.swift` (mirrored in `Protocol.kt`).

# ARGUS

Turn a Xiaomi Pad 8 (or any Android tablet) into a **wired USB-C extended
display** for a MacBook — with full **stylus, eraser, and touch** input,
**60 Hz HiDPI** video, and **audio** forwarding.

ARGUS creates a real macOS virtual display, captures it with
ScreenCaptureKit, hardware-encodes it with VideoToolbox (H.264), and streams
it over the USB connection (via `adb reverse`) to an Android client that
decodes it with MediaCodec straight onto a Surface. Input flows back the
other way: the tablet's `MotionEvent`s — including pressure, tilt, and
batched stylus samples — are injected on the Mac as a virtual HID graphics
tablet (for the pen) or mouse events (for touch).

```
┌──────────────────────────── MacBook (mac-host) ────────────────────────────┐
│  CGVirtualDisplay  ─►  ScreenCaptureKit  ─►  VideoToolbox H.264             │
│        ▲                                            │                       │
│        │ inject (CGEvent / IOHIDUserDevice)         ▼  :7175                 │
│   InputInjector  ◄── :7176 ◄────────────┐     [len][NAL] frames             │
│   CoreAudio ─► AAC ──────► :7177 ────────┼──────────┼───────────────────────┘
└──────────────────────────────────────────┼──────────┼─ adb reverse (USB-C) ─┐
                                            │          ▼                       │
┌──────────────────────────── Tablet (android-client) ───────────────────────┤
│   InputForwarder ─► :7176        MediaCodec ◄─ :7175  ─► SurfaceView (60Hz)  │
│   AudioTrack ◄─ MediaCodec ◄─ :7177                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

See [`shared/PROTOCOL.md`](shared/PROTOCOL.md) for the exact wire format.

---

## Repository layout

```
argus/
├── mac-host/         # Swift / Objective-C macOS menu-bar app (XcodeGen)
├── android-client/   # Kotlin Android app (Gradle)
├── shared/           # PROTOCOL.md — the wire-format source of truth
└── README.md
```

---

## Prerequisites

- **Xcode 15+** (mac-host), macOS **13.0+**
- **Android Studio** (android-client)
- **ADB** on the Mac: `brew install android-platform-tools`
- **XcodeGen** to generate the Xcode project: `brew install xcodegen`
- **USB debugging** enabled on the Xiaomi Pad 8:
  - Settings → About tablet → tap **MIUI version** 7 times
  - Developer options → **USB debugging** ON
  - Developer options → **USB debugging (Security settings)** ON
    *(Xiaomi/HyperOS-specific — required for correct input-event tool
    classification, i.e. for the stylus to be reported as a stylus.)*
- **Xiaomi Focus Pen Pro** paired to the tablet (Bluetooth) before connecting.

---

## Setup

1. **Clone** this repo.

2. **mac-host**
   ```bash
   cd mac-host
   xcodegen generate          # produces Argus.xcodeproj
   open Argus.xcodeproj
   ```
   In Xcode, select your local development signing team (Signing &
   Capabilities). The App Sandbox is intentionally **disabled** (required for
   the CGVirtualDisplay private API, IOHIDUserDevice, and raw sockets).
   Build & run. Grant **Screen Recording** permission when prompted
   (System Settings → Privacy & Security → Screen Recording), then relaunch.
   A menu-bar icon appears (no Dock icon).

3. **android-client**
   ```bash
   cd android-client
   # Open in Android Studio (it provisions the Gradle wrapper), OR:
   gradle wrapper && ./gradlew assembleDebug
   ```

4. **Connect the tablet** with a USB-C **data** cable (not charge-only).
   Verify: `adb devices` lists your tablet as `device`.

5. **Install the client**
   ```bash
   adb install android-client/app/build/outputs/apk/debug/app-debug.apk
   ```

6. Open **Argus** on the Mac (menu-bar icon).

7. Open **Argus** on the tablet — a full-screen black screen with a
   "Disconnected" overlay.

8. Click **Connect** in the Mac menu-bar app. The Mac creates the virtual
   display, sets up the `adb reverse` tunnels, and starts streaming.

9. The **extended display** appears — the tablet is now a second monitor.

---

## Stylus usage

The Xiaomi Focus Pen Pro talks to the tablet over Bluetooth/internal
protocol. ARGUS intercepts it at the Android `MotionEvent` level and forwards
**pressure, tilt, and position** (plus all batched intermediate samples) to
the Mac, where a virtual **HID graphics tablet** (`IOHIDUserDevice`,
Wacom-style descriptor) replays them. Mac apps that support drawing tablets —
Photoshop, Illustrator, Affinity Designer, Procreate Dreams, etc. — see a
pressure-sensitive pen. Pressure/tilt fidelity depends on each app's stylus
support.

- **Finger** input → mouse events (single primary touch in Phase 1).
- **Stylus** input → HID pen with pressure + tilt.
- **Eraser** end → HID pen with the eraser bit set.
- **Hover** (pen near, not touching) → in-range HID report with tip up.

The on-tablet overlay shows the live tool (Finger / Stylus / Eraser / Hover)
and current pressure — handy for confirming the pen is detected correctly.

---

## Troubleshooting

- **"adb not found"** — `brew install android-platform-tools`. ARGUS also
  probes `/opt/homebrew/bin`, `/usr/local/bin`, and the Android SDK
  `platform-tools` directory.
- **Black screen on tablet** — the USB cable must support data. Run
  `adb devices`; your tablet should be listed. Try a different cable/port.
- **Stylus shows as finger** — enable **USB debugging (Security settings)**
  in Xiaomi Developer Options. This is separate from regular USB debugging
  and is required on MIUI/HyperOS for input-event tool classification.
- **High latency** — use a direct USB-C ↔ USB-C connection, not a hub/dock.
- **No audio** — the CoreAudio/ScreenCaptureKit tap follows the **default
  output device**; if output is a Bluetooth speaker it may not be captured.
  Switch system output to the built-in speakers / a wired device.
- **Virtual display doesn't appear** — confirm Screen Recording permission is
  granted and the app was relaunched after granting it. The CGVirtualDisplay
  private API requires the sandbox to be disabled.

---

## Known limitations (Phase 1)

- **60 Hz** refresh (Phase 2 will explore 120 Hz via a Sunshine/Moonlight-
  style path and ScreenCaptureKit rate unlocking).
- **Single touch point** for finger input (multi-touch in Phase 3 via a
  multitouch digitizer HID descriptor — stubbed in `InputInjector.swift`).
- Stylus hover works but requires the client app to be **foreground** on the
  tablet.
- **No HiDPI passthrough for the cursor** — the Mac renders HiDPI internally
  but the stream is downscaled to the tablet's physical resolution for
  transmission efficiency.
- H.265 is reserved for Phase 2 (the codec picker is present but disabled).

---

## Implementation status

Phase 1 implements the full pipeline end to end: virtual display → capture →
encode → USB transport → decode → display, plus bidirectional input (touch +
stylus with pressure/tilt) and audio. The private-API surface
(`CGVirtualDisplay`, `IOHIDUserDevice`) is isolated in Objective-C bridges
under `mac-host/Argus/Bridges/`.
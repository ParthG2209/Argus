<p align="center">
  <svg width="120" height="120" viewBox="0 0 120 120" xmlns="http://www.w3.org/2000/svg">
    <circle cx="60" cy="60" r="50" fill="#0f172a" stroke="#3b82f6" stroke-width="4"/>
    <ellipse cx="60" cy="60" rx="35" ry="18" fill="none" stroke="#3b82f6" stroke-width="3"/>
    <circle cx="60" cy="60" r="10" fill="#3b82f6"/>
    <circle cx="63" cy="57" r="3" fill="#ffffff" opacity="0.8"/>
  </svg>
</p>

<h1 align="center">Argus</h1>

<p align="center">
  <strong>Production-Grade, Ultra-Low Latency Mac-to-Android Extended Display & Audio Streaming Engine</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Android-7.0+-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android 7.0+">
  <img src="https://img.shields.io/badge/Swift-5.8-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Kotlin-1.9-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white" alt="Kotlin">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License MIT">
</p>

---

## 1. Overview

Argus is a high-performance system utility that transforms any Android tablet into a native, zero-latency extended secondary display for macOS. 

Unlike standard screen mirroring applications that rely on lossy network protocols, high-overhead screen scraping, or software encoding, Argus is built entirely on native hardware-accelerated pipelines. By combining undocumented macOS virtualization APIs, direct GPU-to-hardware encoding, and a raw PCM audio engine, Argus bypasses standard networking stacks to deliver raw performance directly over USB. 

The result is a secondary monitor experience designed for professional workflows, high-framerate video playback, and software development, offering an experience so seamless it feels natively wired.

---

## 2. Core Features

### Hardware Virtualization
- **True Virtual Display Topology:** Argus does not simply mirror your screen. It utilizes reverse-engineered macOS private APIs (`CGVirtualDisplay`) to instantiate a completely independent, hardware-recognized secondary monitor within the macOS WindowServer.
- **Dynamic Auto-Resolution Matching:** Upon connection, the macOS host queries the physical dimensions of the target Android device and dynamically adjusts the virtual display resolution to ensure 1:1 pixel mapping. This guarantees crisp text rendering without black bars or interpolation artifacts.

### High-Fidelity Video Pipeline
- **Zero-Copy Capture:** Utilizes Apple's `ScreenCaptureKit` to rapidly pull frames directly from the GPU framebuffer, bypassing CPU-bound readbacks.
- **Hardware Encoding:** Leverages Apple's `VideoToolbox` to encode frames asynchronously into H.264 or HEVC NAL units.
- **Hardware Decoding:** On the client side, raw NAL units are fed directly into the Android `MediaCodec` hardware decoder for zero-copy rendering onto a hardware-backed `SurfaceView`.

### Ultra-Low Latency Audio Engine
- **Codec-Free Transmission:** To eliminate the 21.3ms processing delay inherent in AAC encoding, Argus strips out audio compression entirely. It captures 32-bit Float PCM system audio, down-samples it to 16-bit Integer PCM on the fly, and streams the raw bytes directly over the TCP socket.
- **Hardware Buffer Crushing:** The Android client explicitly bypasses standard OS software mixers by violently crushing the `AudioTrack` hardware buffer size to exactly 20ms, preventing the OS from artificially hoarding packets. 
- **Aggressive Network Catch-up:** Custom socket logic instantly drops delayed network packets to keep the audio stream within a 10-20ms latency window, achieving perfect sync with the video feed.

### Uninterrupted Transport
- **USB Tethering via ADB Reverse:** By utilizing `adb reverse`, Argus establishes a robust, high-bandwidth TCP connection over a standard USB cable. This eliminates Wi-Fi packet loss, network jitter, and router bottlenecks, allowing for sustained 50+ Mbps streaming bitrates.

---

## 3. Deep Dive Architecture

Argus is divided into a macOS Host application and an Android Client application, communicating over three specialized local TCP sockets bound to `127.0.0.1`.

### 3.1 macOS Host (Swift / Objective-C)
- **VirtualDisplayManager.swift:** Interfaces with the private `CoreGraphics` framework. By dynamically loading `CGVirtualDisplayDescriptor`, it registers a new display with WindowServer, generating a valid `CGDirectDisplayID`.
- **ScreenCaptureManager.swift:** Instantiates an `SCStream` targeting the newly created `CGDirectDisplayID`. It configures the stream for high-framerate `CMSampleBuffer` delivery.
- **VideoEncoder.swift:** Acts as a wrapper around `VTCompressionSession`. It receives uncompressed `CVImageBuffer` frames, submits them to the hardware encoder, and extracts the resulting H.264 SPS/PPS parameters and NAL units.
- **AudioEncoder.swift:** Handles the raw PCM pipeline. It intercepts the `kAudioFormatFlagIsFloat` buffer from ScreenCaptureKit, performs a high-speed manual interleaved conversion to `Int16`, and dispatches it to the socket.
- **SocketServer.swift:** Manages the POSIX TCP sockets. Implements aggressive backpressure (e.g., `maxInFlight = 5`) to prevent buffer bloat during temporary USB bandwidth constraints.

### 3.2 Android Client (Kotlin)
- **ConnectionManager.kt:** Manages the inbound TCP streams. It includes advanced "catch-up" logic that constantly monitors `DataInputStream.available()` and aggressively discards stale frames to maintain the strict 10ms latency floor.
- **VideoDecoder.kt:** A highly optimized `MediaCodec` wrapper. It consumes raw H.264 byte arrays, handles SPS/PPS configuration dynamically, and queues input buffers for hardware decoding to the `Surface`.
- **AudioPlayer.kt:** Configures an `AudioTrack` with `PERFORMANCE_MODE_LOW_LATENCY`. It utilizes API Level 24+ extensions to override the default hardware buffer size (`setBufferSizeInFrames`), locking the playback latency to a microscopic window.

---

## 4. Setup & Build Instructions

### 4.1 System Prerequisites
- **macOS:** macOS 13.0 (Ventura) or later. Apple Silicon (M1/M2/M3) highly recommended for optimal VideoToolbox performance.
- **Android:** Android 7.0 (API Level 24) or later. 
- **Tools:** Android SDK Platform-Tools (`adb`) must be installed on the Mac.
  ```bash
  brew install android-platform-tools
  ```

### 4.2 Building the Android Client
1. Open the `android-client` directory in Android Studio.
2. Ensure your Android tablet has **Developer Options** and **USB Debugging** enabled.
3. Connect the tablet to your Mac via a high-quality USB-C cable.
4. Allow the USB Debugging RSA fingerprint prompt on the tablet.
5. Build the project and deploy the APK to the tablet.
6. Launch the **Argus** application on the tablet. It will display a black screen, indicating it is listening for a connection.

### 4.3 Building the macOS Host
1. Open `Argus.xcodeproj` in Xcode 15 or later.
2. In the project settings, navigate to **Signing & Capabilities** and ensure a valid Personal Team or Apple Developer certificate is selected.
3. *Note: Because Argus utilizes the private `CGVirtualDisplay` API, it cannot be distributed via the Mac App Store and must be self-signed.*
4. Build and Run the application (`Cmd + R`).
5. Upon successful launch, the Argus logo will appear in your macOS menu bar.

### 4.4 Initiating the Connection
1. Verify the tablet is recognized by ADB:
   ```bash
   adb devices
   ```
2. Click the Argus menu bar icon on your Mac.
3. Select **Start Streaming**.
4. The macOS host will automatically execute the necessary `adb reverse` commands to bind the local TCP ports over the USB interface.
5. Your Mac screen will briefly flash as WindowServer registers the new virtual display.
6. The tablet will immediately transition from the black waiting screen to rendering your extended macOS desktop.

---

## 5. Troubleshooting Guide

- **Error: ADB Not Found:** 
  Ensure `adb` is installed and accessible in your system `$PATH`. If using Homebrew, it is typically located at `/opt/homebrew/bin/adb`. You may need to manually specify this path in the Argus settings if your environment variables are restricted.
- **Black Screen on Tablet (No Video):** 
  macOS requires explicit user permission for screen recording. Navigate to `System Settings > Privacy & Security > Screen Recording` and ensure the toggle for Argus is enabled. If it is enabled but still failing, remove Argus from the list with the minus (-) button and restart the app to prompt for permissions again.
- **Audio Static or Popping:**
  This indicates an audio underrun, where the hardware buffer has emptied faster than the network can fill it. Disconnect and reconnect the stream. If the issue persists, the USB cable may not be providing sufficient bandwidth, or the Android device may be aggressively throttling the application. Ensure Argus is exempt from Android Battery Optimization.
- **Resolution Mismatch:**
  If the display looks stretched, the tablet may have failed to send its dimension handshake in time. Restart the stream to trigger a new handshake sequence.

---

## 6. Development Roadmap

Argus is in active development. The current priority queue includes:

- [ ] **Wireless Support (mDNS/Bonjour):** Implement zero-configuration local network streaming for situations where USB tethering is impractical.
- [ ] **Bi-Directional Input Injection:** Capture touch events from the Android `SurfaceView` and transmit them back to macOS to synthesize mouse and trackpad inputs.
- [ ] **App-Specific Audio Routing:** Leverage advanced `ScreenCaptureKit` filters to selectively route audio exclusively for applications physically located on the virtual display, rather than capturing global system audio.
- [ ] **Dynamic Bitrate Scaling:** Implement closed-loop feedback between the Android client and macOS host to dynamically adjust `VTCompressionSession` bitrates in response to network congestion or frame drops.

---

## 7. License & Attribution

Argus is distributed under the MIT License. See the `LICENSE` file in the repository root for complete terms and conditions.

Argus utilizes private macOS APIs. It is provided for educational and personal use. 

<p align="center">
  <i>Engineered for performance by Parth Gupta</i>
</p>
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
  <strong>Ultra-Low Latency Mac-to-Android Extended Display & Audio Streaming</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-13.0+-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 13.0+">
  <img src="https://img.shields.io/badge/Android-7.0+-3DDC84?style=for-the-badge&logo=android&logoColor=white" alt="Android 7.0+">
  <img src="https://img.shields.io/badge/Swift-5.8-F05138?style=for-the-badge&logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/Kotlin-1.9-7F52FF?style=for-the-badge&logo=kotlin&logoColor=white" alt="Kotlin">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License MIT">
</p>

---

## ⚡️ Overview

Argus transforms any Android tablet into a blazing-fast, zero-latency extended external display for your Mac. Built entirely on hardware-accelerated APIs, Argus bypasses standard networking stacks to deliver raw performance directly over USB.

Whether you're watching videos, coding, or simply needing a second monitor on the go, Argus delivers an experience so seamless, it feels natively wired.

## ✨ Features

- 🖥️ **True Virtual Display:** Uses macOS private APIs (`CGVirtualDisplay`) to create a true, hardware-recognized secondary monitor—not just a screen mirror.
- 🚀 **Hardware Accelerated:** Leverages Apple's `VideoToolbox` (H.264 / HEVC) and Android's `MediaCodec` for absolute maximum framerates (60-120+ FPS) with minimal CPU overhead.
- 🔊 **Zero-Latency Audio:** Transmits uncompressed, raw 16-bit PCM audio directly to the tablet's hardware mixer, achieving near 0ms latency sync for flawless video playback.
- 📐 **Auto-Resolution Matching:** The Mac automatically adjusts the virtual display resolution to perfectly match the physical pixels of your tablet. No black bars. No stretching.
- 🔌 **USB Tethering via ADB:** Uses ADB reverse port forwarding to pipe massive bandwidth over a standard USB cable, completely immune to Wi-Fi interference.

---

## 🏗️ Architecture

Argus consists of two deeply integrated components communicating over local TCP sockets:

### 1. macOS Host App
- **Virtualization:** Uses `CGVirtualDisplay` (reverse-engineered private framework) to trick macOS into creating a physical display.
- **Capture:** `ScreenCaptureKit` rapidly pulls frames directly from the GPU framebuffer.
- **Video:** `VideoToolbox` instantly encodes frames to H.264 NAL units.
- **Audio:** Bypasses codecs entirely, converting 32-bit Float PCM to 16-bit Int PCM and streaming raw bytes directly to the socket.

### 2. Android Client App
- **Network:** Connects over `localhost` via ADB reverse tethering.
- **Video:** Feeds raw H.264 NAL units directly into the Android `MediaCodec` hardware decoder for zero-copy rendering onto a `SurfaceView`.
- **Audio:** Aggressively shrinks the `AudioTrack` hardware buffer to 20ms and dumps raw PCM bytes straight to the speakers, instantly dropping delayed packets to maintain absolute sync.

---

## 🛠️ Setup & Installation

### Prerequisites
- **Mac:** macOS 13.0 (Ventura) or later. Xcode installed.
- **Tablet:** Android 7.0 or later. Developer Options and USB Debugging enabled.
- **Tools:** Android SDK Platform-Tools (`adb`) installed on the Mac (`brew install android-platform-tools`).

### 1. Build the Android App
1. Open the `android-client` folder in Android Studio.
2. Connect your tablet via USB.
3. Build and install the app on your tablet.
4. Launch the **Argus** app on your tablet (it will show a black screen waiting for a connection).

### 2. Build the macOS App
1. Open `Argus.xcodeproj` in Xcode.
2. Build and Run the application.
3. A menu bar icon (an eye) will appear.

### 3. Connect!
1. Ensure your tablet is connected via USB and `adb devices` shows your device.
2. Click the Argus menu bar icon on your Mac and select **Start Streaming**.
3. Your Mac screen will flash, a new virtual display will be created, and your tablet will instantly light up as a fully functional external monitor!

---

## 🔮 Roadmap

- [ ] **Wireless Support:** Zero-config wireless streaming over local Wi-Fi via Bonjour/mDNS discovery.
- [ ] **Touch Input Injection:** Send touch events from the tablet back to the Mac to control the cursor.
- [ ] **App-Specific Audio Routing:** Route audio exclusively to the device where the application window is physically located.
- [ ] **Dynamic Bitrate Scaling:** Automatically adjust VideoToolbox bitrate based on network jitter.

---

## 📝 License

Distributed under the MIT License. See `LICENSE` for more information.

<p align="center">
  <i>Built with ❤️ by Parth Gupta</i>
</p>
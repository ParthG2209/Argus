# Argus: Hand-Picked Future Features

### 1. USB Wired Mode
- Route TCP connection over USB-C (via Android Accessory Protocol or ADB reverse).
- Unlocks 1,000+ Mbps bandwidth, enabling ProRes/MJPEG codecs for flawless 4:4:4 color, zero compression blur, and sub-5ms latency.

### 2. Local Pinch-to-Zoom
- Native Android gesture to zoom into the `StreamSurfaceView`.
- Allows precise "direct manipulation" of tiny macOS UI elements with a finger without altering the host's resolution or sending zoom events to the Mac.

### 3. Pro-Grade Stylus Pressure & Tilt
- Advanced processing of Xiaomi stylus data.
- Implements a customizable pressure curve and tilt-axis forwarding to turn the tablet into a professional drawing surface (comparable to a Wacom Cintiq) for Mac creative apps.

### 4. Universal Drag-and-Drop (Continuity)
- Hook into Android's Drag-and-Drop API to bridge files/photos to macOS's pasteboard.
- Drag an image from the Android gallery to the screen edge, and drop it directly onto the Mac desktop running inside Argus.

### 5. Proximity-Based Spatial Arrangement
- Uses Bluetooth RSSI (signal strength) or initial cursor movement to detect the physical orientation of the tablet relative to the Mac.
- Automatically arranges the virtual macOS display to the correct side (left or right) without requiring manual configuration in macOS System Settings.

### 6. Invisible Connection (Zero-Click Wake)
- Argus on Mac runs as a silent, invisible background daemon.
- Opening the Argus app on Android sends a silent wake packet to the Mac over the local network.
- The Mac instantly creates the virtual display and begins streaming in <50ms, mimicking the experience of turning on a physical hardware monitor.

### 7. Fluid Window Disconnection Animations
- When the tablet is disconnected or goes to sleep, the Mac host app captures the frames of the windows that were on the virtual display.
- Plays a smooth animation of those windows flying from the screen edge back into the main Mac desktop, maintaining spatial continuity instead of jarringly snapping them back.

### 8. The "Magic Cursor" Handover
- Intelligently switches the interaction paradigm between physical trackpad and touch.
- Moving the Mac's trackpad summons the traditional macOS cursor on the tablet.
- The moment the user touches the tablet, the cursor smoothly morphs into a translucent touch-indicator and fades away, prioritizing direct manipulation.

### 9. Stylus "Hover" & Smart Pen Gestures
- Detects the electromagnetic hover state of the Xiaomi stylus and translates it into macOS cursor movement without clicking, allowing tooltips and brush previews (identical to Apple Pencil Hover).
- Bridges the native Xiaomi stylus gestures (button double-taps, pinch, slide up/down on the pen body) to trigger customizable macOS macros (e.g., Undo, change brush size, switch tools).

### 10. Spatial Audio Routing
- Detects which macOS windows are physically located on the tablet display.
- If audio originates from a window on the tablet (like a YouTube video), Argus routes that specific audio stream to the Xiaomi tablet's quad-speakers. 
- Dragging the window back to the Mac seamlessly transitions the audio back to the Mac's speakers.

### 11. Cross-OS Picture-in-Picture (The "Widget" Mode)
- Allows users to drag a specific Mac application window (e.g., Zoom call, YouTube video) and send *only* that window's texture to the tablet.
- Argus renders this specific app as a floating, borderless Android Picture-in-Picture overlay, allowing the user to multitask on Android natively while keeping an eye on a specific Mac application.

### 12. Virtual Continuity Camera
- Capture the Xiaomi tablet's front-facing camera and register it as a native virtual webcam on the Mac.
- Take video calls from the tablet while using macOS apps.

### 13. Network Fail-Over (The "Unbreakable" Stream)
- Argus establishes a primary connection over your 5GHz Wi-Fi, but silently spins up a secondary background connection over Bluetooth PAN or Wi-Fi Direct. 
- If your router lags or dies, Argus instantly fails-over to the direct connection. The stream might drop in resolution for a few seconds, but it never freezes or disconnects.

### 14. Instant ColorSync Calibration
- The Argus Mac app generates a custom ICC ColorSync profile specifically tailored to the Xiaomi pad's display characteristics. 
- It forces macOS's rendering engine to pre-correct all the colors before encoding the video stream. This ensures the tablet display looks absolutely identical to your MacBook Air's built-in Retina screen.

### 15. Offline Peer-to-Peer (Coffee Shop Mode)
- If you are at a coffee shop or on an airplane with no Wi-Fi, Argus automatically creates a secure, hidden WPA3 Wi-Fi Direct hotspot between the Mac and the tablet for a flawless connection without a router.

### 16. Local Text Rendering Overlay (Accessibility Hack)
- Instead of compressing tiny code text into a video stream, Argus uses macOS Accessibility APIs to extract the text you are typing, sends it as a raw string, and renders it as a native Android font directly on top of the video stream for infinite sharpness.

### 17. Zero-Latency Audio Subchannel
- Extracts the audio stream entirely from the video pipeline and sends it over an independent, unbuffered UDP WebRTC channel to guarantee absolute 0ms A/V sync for video editing.

### 18. Automated Network QoS (Quality of Service)
- Argus tags its network packets with DSCP headers. Any modern router will automatically recognize the Argus stream as "critical real-time traffic" and prioritize it over background downloads or Netflix streams on your network.

### 19. Spatial Mic Array Forwarding
- The Mac hijacks the Xiaomi tablet's multi-microphone array to use as a noise-canceling input device for Zoom calls, utilizing the tablet's acoustic proximity to your mouth.

### 20. Gyroscopic Window Management
- Reading the tablet's IMU sensors. If you physically tilt the tablet to the left, macOS windows on your main display slide over the edge and fall onto the tablet's screen.

### 21. Native macOS Touch Bar Support
- Argus registers the tablet as a physical Touch Bar endpoint. macOS automatically sends the native Touch Bar UI elements (sliders, emoji pickers) which Argus renders seamlessly on the Android screen.

### 22. Universal Audio Handoff (Wired & Wireless)
- Argus intercepts Mac audio output and streams it to the tablet. The tablet plays it out of whatever audio output is active on the tablet (speakers, 3.5mm wired headphones, or Bluetooth earbuds), preventing the need to repair headphones to the Mac.

### 23. Shared Universal Clipboard History
- A visual clipboard manager. Swiping in from the right edge on the tablet reveals a UI of the last 10 items copied on the Mac today, allowing drag-and-drop of past clipboard items directly onto the Android canvas.

### 24. Cross-OS App Search (Launchpad)
- Searching in your native Android app drawer/search widget indexes all Mac applications. Tapping a Mac app icon instantly wakes the Mac, launches the app, and throws the window to the extended tablet display.

### 25. Seamless Notification Actions
- When a Mac notification (like iMessage) pops up on the tablet, use the native Android on-screen keyboard to type a reply. Argus translates that text and sends the message natively from the Mac in the background.

### 26. Virtual Touchpad (Remote Mouse)
- Swiping down with 3 fingers turns the entire tablet screen black and transforms it into a giant, absolute-positioned glass trackpad for controlling the Mac.

### 27. Rewrite Transport to UDP (Anti-Bufferbloat)
- Rewrite the transport layer to use UDP instead of TCP to eliminate "Head-of-Line Blocking" during poor Wi-Fi conditions.
- Implement custom packet sequencing and IDR-request logic (similar to Moonlight/Parsec) to guarantee sub-millisecond latency over Wi-Fi without lag accumulation.

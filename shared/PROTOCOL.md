# ARGUS Wire Protocol (Phase 1)

This document is the single source of truth for the wire format spoken between
the macOS host (`mac-host`) and the Android client (`android-client`). Both
sides MUST agree on every byte described here.

All transport runs over `adb reverse` tunnels, so the Android client always
connects to `127.0.0.1` and the Mac always listens on `127.0.0.1`.

---

## 1. Ports

| Port | Direction      | Payload                                   |
|------|----------------|-------------------------------------------|
| 7175 | Mac → Tablet   | H.264 NAL units (Annex B), length-prefixed |
| 7176 | Tablet → Mac   | Input events, newline-delimited JSON       |
| 7177 | Mac → Tablet   | AAC audio frames, length-prefixed          |

The Mac side opens listening sockets on all three ports, then runs:

```
adb reverse tcp:7175 tcp:7175
adb reverse tcp:7176 tcp:7176
adb reverse tcp:7177 tcp:7177
```

The tablet dials `127.0.0.1:<port>` for each stream.

---

## 2. Binary Framing (ports 7175 video, 7177 audio)

Every payload is prefixed with its length:

```
+-------------------------------+----------------------+
| 4 bytes  big-endian uint32    |  payload (N bytes)   |
| = N (length of payload)       |                      |
+-------------------------------+----------------------+
```

- The length field counts only the payload bytes, not the 4-byte header.
- For **video** (7175), each payload is `[8-byte big-endian int64 capture
  timestamp µs][access unit]`. The access unit is one H.264 **or H.265 (HEVC)**
  NAL grouping in **Annex B** form (NALs concatenated, each with `00 00 00 01`
  start codes). The 4-byte length prefix counts the 8-byte timestamp **plus**
  the access unit. The timestamp is the Mac's ScreenCaptureKit capture time;
  the tablet uses it to pace presentation (`releaseOutputBuffer` at a clock-
  mapped vsync time) for smooth motion independent of arrival jitter. Only
  timestamp *differences* matter, so the absolute epoch is unspecified.
- **Codec handshake:** the very first framed payload on a fresh video
  connection is a 4-byte handshake — ASCII `A R G` followed by a codec byte
  (`0` = H.264, `1` = H.265). It has **no** timestamp prefix. The client reads
  this first frame specially; every payload after it is a timestamped video
  frame as described above. The client configures its decoder from this byte
  before reading any frames.
- After the handshake, the Mac sends the parameter sets (H.264: **SPS/PPS**;
  HEVC: **VPS/SPS/PPS**) inlined ahead of the first IDR (keyframe), so the
  decoder configures itself before any P-frames arrive.
- For **audio** (7177), each payload is one raw AAC (AAC-LC, ADTS-less /
  raw) access unit. The decoder is configured from an out-of-band
  `csd-0` derived from the stream's sample rate / channel count (48 kHz,
  stereo) — see §5.

### Reading algorithm (receiver)

```
read exactly 4 bytes -> len (big-endian uint32)
read exactly len bytes -> payload
dispatch(payload)
repeat
```

Short reads must be looped until the full count is satisfied; TCP does not
guarantee a frame arrives in a single `recv`.

---

## 3. Input Events (port 7176)

Tablet → Mac. UTF-8 JSON objects, **one per line**, each terminated by a
single `\n` (`0x0A`). The Mac reads line-by-line and parses each line as an
independent message.

### 3.0 Hello (resolution handshake)

The **first** line the tablet sends is a hello carrying its real panel
resolution (landscape pixels) and refresh rate, so the Mac sizes the virtual
display + encoder to match (filling the panel with no letterboxing) and picks
a content frame rate that's a clean integer divisor of the panel refresh:

```json
{ "type": "hello", "width": 2880, "height": 1800, "refresh": 144 }
```

`refresh` is optional (older clients omit it; the Mac defaults to 144).

The Mac waits for this before creating the virtual display (falling back to a
default size after a short timeout if it never arrives). All subsequent lines
are input events (below); they have no `type` field.

### 3.1 Message schema

```jsonc
{
  "action":   "down",      // "down" | "move" | "up" | "hover" |
                           // "button_press" | "button_release"
  "toolType": "stylus",    // "finger" | "stylus" | "eraser"
  "button":   null,        // "primary" | "secondary" | null
  "points": [              // ordered: historical (batched) points first,
                           // then the current point last
    {
      "x":         0.452,  // normalized 0.0–1.0, left → right
      "y":         0.331,  // normalized 0.0–1.0, top → bottom
      "pressure":  0.73,   // 0.0–1.0 (0.0 for hover / unsupported finger)
      "tiltX":     12.5,   // degrees, from AXIS_TILT
      "tiltY":     -8.2,   // degrees, from AXIS_ORIENTATION
      "toolMajor": 0.04,   // contact ellipse major axis (normalized)
      "toolMinor": 0.02,   // contact ellipse minor axis (normalized)
      "timestamp": 839201  // event time, milliseconds (MotionEvent.eventTime)
    }
  ]
}
```

### 3.2 Action codes (Android → protocol)

| MotionEvent action       | `action`         |
|--------------------------|------------------|
| ACTION_DOWN              | `down`           |
| ACTION_MOVE              | `move`           |
| ACTION_UP                | `up`             |
| ACTION_HOVER_MOVE        | `hover`          |
| ACTION_BUTTON_PRESS      | `button_press`   |
| ACTION_BUTTON_RELEASE    | `button_release` |

### 3.3 Tool types

| MotionEvent toolType     | `toolType` |
|--------------------------|------------|
| TOOL_TYPE_FINGER         | `finger`   |
| TOOL_TYPE_STYLUS         | `stylus`   |
| TOOL_TYPE_ERASER         | `eraser`   |

### 3.4 Batched points (CRITICAL)

Android batches intermediate motion samples between event deliveries. The
client MUST flush all historical samples (`getHistoricalX/Y/Pressure/...`)
**in order, oldest first**, and append the current sample last. The Mac
processes the `points` array in array order, replaying every intermediate
sample before the final one, to preserve stroke fidelity at high stylus
sampling rates.

### 3.5 Rate limiting (client-side)

| Event class                | Cap                |
|----------------------------|--------------------|
| `move` + `finger`          | 120 messages / sec |
| `move` + `stylus`/`eraser` | none (send every batch) |
| `hover`                    | 60 messages / sec  |
| `down`/`up`/`button_*`     | never dropped      |

---

## 4. Coordinate mapping

Coordinates are normalized on the **tablet** against the SurfaceView's pixel
dimensions (`event.x / view.width`, `event.y / view.height`). The Mac maps
them onto the virtual display's pixel rectangle obtained from
`CGDisplayBounds(virtualDisplayID)`:

```
macX = bounds.origin.x + nx * bounds.size.width
macY = bounds.origin.y + ny * bounds.size.height
```

For the virtual HID tablet, the same normalized values map to the HID
logical ranges (`x,y → 0..32767`, `pressure → 0..1023`).

---

## 5. Connection flow

1. Mac creates the virtual display and starts listeners on 7175, 7176, 7177.
2. Mac runs the three `adb reverse` commands.
3. Android connects to all three ports (retry every 2 s until connected) and
   immediately sends the **hello** (its resolution) on the input socket.
4. The Mac reads the hello and creates the virtual display + encoder sized to
   the tablet, then starts capturing.
5. On the **video** connection, the Mac sends the 4-byte codec handshake,
   then the parameter sets, then forces an IDR keyframe, so the decoder
   configures before P-frames.
5. Audio config (sample rate 48000, 2 channels, AAC-LC) is fixed by this
   spec; the client builds `csd-0` from those constants. The first audio
   payload is a normal AAC access unit.
6. Streaming proceeds. Input events flow tablet → Mac continuously.
7. If any socket drops, the client reconnects all three.

---

## 6. Versioning

Phase 1 is implicitly protocol version `1`. There is no handshake byte in
Phase 1; both ends assume v1. A future phase may prepend a handshake frame
on port 7176 (tablet → Mac) carrying client capabilities and a version int.

# Carter's Delay — WebMIDI Edition

A multi-tap granular delay controlled entirely by standard MIDI Control Change
messages. Based on Carter's Delay by William Hazard.

This repo has three parts, and all three describe/implement exactly the same
MIDI contract:

- **`carters_delay_midi.scd`** — the SuperCollider audio engine. It listens
  for MIDI CC and renders the 16-tap granular delay, the feedback patch, and
  the output stage. It can also talk back on the same port — echoing the
  values it applies and streaming buffer telemetry — but that's optional;
  see [Listening to the engine (optional)](#listening-to-the-engine-optional).
- **`index.html`, `styles.css`, `app.js`** — a reference WebMIDI sender: a
  browser control surface that sends the CC messages described below, with a
  live readout of the exact bytes each control sends, and a scope that draws
  the engine's real delay buffer from its telemetry.
- **`README.md`** — this file.

If you're building your own WebMIDI frontend for the engine, read
[The MIDI contract](#the-midi-contract-cc-only) and
[Implementing your own sender](#implementing-your-own-sender) — that's the
whole job. Everything else, including
[Listening to the engine (optional)](#listening-to-the-engine-optional), is
extra: a minimal frontend can send controls and stop there.

---

## The MIDI contract (CC only)

- The engine speaks **Control Change messages only**. Anything else is
  ignored.
- Channels are 1-based, as on any MIDI control surface: status byte `0xB0` =
  channel 1, `0xB1` = channel 2, `0xB2` = channel 3. (Inside SuperCollider the
  channel arrives 0-based — 0, 1, 2 — but nothing outside the engine needs to
  care about that.)
- `v` below is always the raw CC value, an integer `0..127`.
- **Toggles are `0` = off, any value `> 0` = on.** Senders should send `127`
  for "on".
- **Controls are one-way and stateless to send.** The engine doesn't need
  anything back from you to accept them — but it also doesn't remember what
  you sent across a restart. So a sender must transmit every control's value
  once, right after the engine (re)starts, to bring it to a known state —
  see [Implementing your own sender](#implementing-your-own-sender). (The
  engine can optionally report its state back to you too, on the same port;
  that's the separate, optional layer in
  [Listening to the engine (optional)](#listening-to-the-engine-optional).)
- The engine listens on **every MIDI input connected at boot** (it does not
  let you pick one source over another). Just send on the right channel/CC.
  It also opens one MIDI output of its own, for replies — see
  [Quick start](#quick-start).

### Channel 1 — levels & routing

| CC | Name | Mapping | Default v | Default value |
|----|------|---------|-----------|---------------|
| 1 | Input Passthrough Level | `v / 127` (linear amp) | 64 | 0.504 |
| 2 | Delay Input Level | `v / 127` | 64 | 0.504 |
| 3 | Buffer Preservation (rec preLevel) | `v / 127` | 64 | 0.504 |
| 4 | Input Passthrough On | 0 = muted, >0 = on (audible) | 127 | on |
| 5 | Delay Input On | 0 = muted, >0 = on | 127 | on |
| 6 | Delay Output On (all 16 taps) | 0 = muted, >0 = on | 127 | on |
| 7 | Master Output Level | `v / 51` (gain ×), into a Limiter at 1.0 | 51 | 1.0× (max 127 → 2.49×) |

### Channel 2 — feedback patch

| CC | Name | Mapping | Default v | Default value |
|----|------|---------|-----------|---------------|
| 1 | Feedback Level | `v / 127` | 0 | 0 |
| 2 | Feedback Balance | v ≤ 64: `(v−64)/64`; v > 64: `(v−64)/63` → −1..+1 | 64 | 0.0 exactly |
| 3 | Feedback High-Pass | `v/127 × 220` Hz | 7 | 12.13 Hz |
| 4 | Pink Noise Level | `v / 127` | 0 | 0 |
| 5 | Sine Level | `v / 127` | 0 | 0 |
| 6 | Sine Frequency | note = `round(20 + v·70/127)`; Hz = `440·2^((note−69)/12)` (SC `.midicps`) | 24 | note 33 = 55.00 Hz |

### Channel 3 — granular engine

| CC | Name | Mapping | Default v | Default value |
|----|------|---------|-----------|---------------|
| 1 | Playback Rate Multiplier | v ≤ 64: `0.25·4^(v/64)`; v > 64: `2^((v−64)/63)` | 64 | 1.0× (0→0.25, 32→0.5, 127→2.0) |
| 2 | Grain Density Multiplier | v ≤ 64: `0.2·5^(v/64)`; v > 64: `3^((v−64)/63)` | 64 | 1.0× (0→0.2, 127→3.0) |
| 3 | Low-Pass Cutoff **Ceiling** | `200·80^(v/127)` Hz (SC `linexp(0,127,200,16000)`) | 127 | 16000 Hz = no cap (the per-tap LFOs sweep 500–15000 Hz underneath — see below) |
| 4 | Position Jitter | max random extra delay = `(v/127)·2.5` s | 0 | 0 s |
| 5 | Trigger Distribution | p = `v/127` = probability each periodic (Impulse) trigger fires; `1−p` = probability each random (Dust) trigger fires. Average density stays constant. | 127 | fully periodic |
| 6 | Grain Window | v 0–42 Hann; 43–85 Percussive; 86–127 Reverse Swell | 0 | Hann |
| 8 | Buffer Freeze | >0 frozen (recording paused, write head held still); 0 live | 0 | live |
| 9 | Octaves toggle | >0 on | 0 | off |
| 10 | Fifths & Fourths toggle | >0 on | 0 | off |
| 11 | Sub-octaves toggle | >0 on | 0 | off |
| 12 | Reverse toggle | >0 on | 0 | off |

Any CC number not listed above (e.g. CC 7 on channel 3) is ignored.

### Reference values (for verifying your own implementation)

Computed independently of both the engine and the web demo — use these to
check your own mapping code:

| v | rate | density | balance | cutoff Hz |
|---|------|---------|---------|-----------|
| 0 | 0.2500 | 0.2000 | −1.0000 | 200.0 |
| 32 | 0.5000 | 0.4472 | −0.5000 | 603.3 |
| 63 | 0.9786 | 0.9752 | −0.0156 | 1758.3 |
| 64 | 1.0000 | 1.0000 | 0.0000 | 1820.0 |
| 65 | 1.0111 | 1.0176 | 0.0159 | 1883.9 |
| 96 | 1.4220 | 1.7472 | 0.5079 | 5490.2 |
| 127 | 2.0000 | 3.0000 | 1.0000 | 16000.0 |

Other checks:
- Feedback High-Pass at v = 7 → 12.126 Hz.
- Sine at v = 24 → note 33 → 55.00 Hz (the current default).
- Sine at v = 30 → note 37 → 69.30 Hz (an old, since-corrected default — useful
  only if you're diffing against a very old copy of this project).

---

## Behaviour notes

### Tap-rate allocation

There are 16 delay taps. Their playback rates are assigned once at startup
and recomputed whenever the rate multiplier, or an interval toggle, changes —
using the same function in both cases, so the engine's state after boot is
identical to its state after a full "resend all defaults."

- **Taps 0–7** use the base rates `[1/4, 1/2, 1, 3/2, 2, 1/4, 1/2, 1]`
  (i.e. a 5-element pool `[1/4, 1/2, 1, 3/2, 2]` indexed by `i % 5`).
- **Taps 8–15** cycle through a separate pool, `pool[(i − 8) % pool.size]`,
  built in this order:
  1. Octaves toggle (Ch3 CC9) adds `[2, 1, 2]`.
  2. Fifths & Fourths toggle (Ch3 CC10) adds `[3/2, 4/3, 9/8]`.
  3. Sub-octaves toggle (Ch3 CC11) adds `[1/4, 1/2, 1/2]`.
  4. If **no** toggle is on, the pool falls back to `[1/4, 1/2, 1, 3/2, 2]`.

  Toggles are additive — turning on more than one just makes a bigger pool.
- **Reverse toggle (Ch3 CC12) on:** odd taps (1, 3, 5, … 15) get a negative
  rate of the same magnitude; even taps stay forward, so forward and reverse
  material always plays simultaneously. **Reverse off:** all 16 taps are
  positive.
- **Final per-tap rate** = `poolRate × rateMult` (the Ch3 CC1 multiplier).
- **Per-tap grain density** = `densMult / (durs[i] · |finalRate_i|)`, where
  `durs[i]` is that tap's fixed base grain duration and `densMult` is the Ch3
  CC2 multiplier. This is recomputed whenever rate, rate multiplier, or
  density multiplier change, so density always tracks the tap's actual
  playback speed.

### Position jitter (Ch3 CC4)

Adds up to `(v/127)·2.5` seconds of random extra delay to each grain's read
pointer, independently per grain. At `v = 0` grains read from exactly the
nominal delay time; increasing `v` spreads them further back into the buffer.

### Trigger distribution (Ch3 CC5)

Each tap's grains can fire on a **periodic** clock (SuperCollider `Impulse`,
evenly spaced) or a **random** one (`Dust`, Poisson-distributed) — or a
crossfade between the two. `v/127` is the probability that any given periodic
trigger is allowed through; `1 − v/127` is the probability a random trigger
fires instead. The two streams share the same average density, so sliding
this control changes the *rhythmic character* of the grain stream (locked
vs. scattered) without changing how busy it sounds overall.

### Buffer freeze (Ch3 CC8)

- **Frozen (`v > 0`):** the record pointer stops advancing and recording
  pauses — nothing new is written into the buffer, so whatever is currently
  in memory keeps looping indefinitely.
- **Live (`v = 0`):** the pointer resumes and recording continues as normal.
- Freeze does **not** touch Buffer Preservation (Ch1 CC3) or the delay input
  level/mute (Ch1 CC2/CC5) — those keep whatever values you last sent, both
  while frozen and after unfreezing.

### Low-pass cutoff ceiling (Ch3 CC3)

Each tap's low-pass filter cutoff is normally driven by its own slow random
LFO, sweeping roughly 500–15000 Hz — this gives the 16 taps independent,
constantly-shifting tone color. Ch3 CC3 does **not** replace that LFO; it sets
a **ceiling** above it (`effective cutoff = min(LFO value, ceiling)`, then
clipped to 50–18000 Hz). At the default `v = 127` the ceiling is 16000 Hz,
which sits above the LFOs' own range, so by default nothing is capped. Lower
values start shaving the brightest peaks off the sweep; very low values pin
every tap's filter to the ceiling and the LFO motion becomes inaudible.

---

## Implementing your own sender

The short version: this is plain MIDI CC, on channels 1–3, and you never
need to read anything back.

- **Message type:** Control Change (status nibble `0xB`) only — nothing
  else is recognized.
- **Status byte:** `0xB0 | (channel − 1)` → `0xB0` for channel 1, `0xB1` for
  channel 2, `0xB2` for channel 3.
- **Data bytes:** CC number (see the tables above, per channel), then value
  `0..127`. Clamp and round to an integer before sending.
- **Toggles:** the engine treats any `v > 0` as "on" and `v == 0` as "off" —
  but always send `127` for "on", not some other positive value, so your
  sender's wire format matches this demo's.
- **Sending controls needs nothing back from the engine.** A minimal sender
  can be write-only: **send every control's value once, immediately after
  the engine (re)starts**, to guarantee it's in a known state before you
  rely on it. This is exactly what the web demo's "Send all values" button
  does. The engine boots into this same state on its own (see below), so if
  you've made no changes yet, resending isn't strictly required — but do it
  anyway once at connection time, since you generally can't know whether the
  engine was just (re)started or has been running with different values for
  a while.
- **If you'd rather ask the engine than guess,** it can tell you its state
  directly — on request, and after every change it applies — over the same
  port. That's entirely optional and doesn't change anything above; see
  [Listening to the engine (optional)](#listening-to-the-engine-optional).
- **The engine listens on every MIDI input it sees at boot** (`MIDIIn.connectAll`
  in SuperCollider) — there's no per-source filtering or handshake. Just open
  a MIDI output on your end and send. (It also opens one MIDI output of its
  own, to send replies on, if you want them — see
  [Quick start](#quick-start).)
- Anything not listed in the contract tables is silently ignored — you can't
  break the engine by sending an unrecognized CC number or an out-of-range
  channel.

**The exact defaults**, as `[channel, cc, value]` triples — this is the state
the engine boots into on its own, and the exact set of messages "Send all
values" sends:

```
[1,7,51], [1,1,64], [1,2,64], [1,3,64], [1,4,127], [1,5,127], [1,6,127],
[2,1,0],  [2,2,64], [2,3,7],  [2,4,0],  [2,5,0],   [2,6,24],
[3,1,64], [3,2,64], [3,3,127],[3,4,0],  [3,5,127], [3,6,0],
[3,8,0],  [3,9,0],  [3,10,0], [3,11,0], [3,12,0]
```

---

## Listening to the engine (optional)

Everything above is the whole contract for a **write-only** frontend: send
the right CC messages and stop. This section is for a frontend that also
wants to *listen* — to show the engine's real state instead of guessing, or
to draw its actual delay buffer. None of it changes how controls work, and
none of it is required.

It comes in layers, and a frontend can stop at any of them:

1. **Controls only** — everything above. No listening at all.
2. **Plus state sync** — listen for **echo** and send a **request**, both
   plain Control Change messages. No special browser permission needed.
3. **Plus telemetry** — decode the **SysEx** packets below to draw a scope of
   the engine's actual buffer, write head and grains. This needs the
   browser's MIDI SysEx permission.

Everything in this section shares the **same MIDI port** as the control
contract above — there's no second cable. Total traffic in both directions
stays well under 5 KB/s.

### Channel map

| Direction | Status byte(s) | Channel(s) | Meaning |
|---|---|---|---|
| page → engine | `B0`, `B1`, `B2` | 1, 2, 3 | Controls — the contract above, unchanged |
| page → engine | `BF 01 xx` (`xx > 0`) | 16 | **Request:** ask the engine to resend everything below |
| engine → page | `B8`, `B9`, `BA` | 9, 10, 11 | **Echo:** the CC number and value the engine just applied on channel 1, 2, 3 (echo channel = control channel + 8) |
| engine → page | `F0 7D 43 … F7` | — | **Telemetry**, as SysEx — see [SysEx telemetry](#sysex-telemetry) below. `7D` is the MIDI non-commercial manufacturer ID; `43` (`'C'`) identifies Carter's Delay. |

### Echo: what it means and when it happens

- The engine echoes **every control it actually applies**, whatever the
  source — including its own startup defaults. A toggle echoes `127` (on) or
  `0` (off), normalised; a slider echoes the exact value it received. CC
  numbers the engine doesn't handle are never echoed.
- **On boot**, in order: a HELLO packet once the buffer exists; then the 24
  echoes of the engine's own defaults (the "bang" — the same list as
  [the defaults table](#implementing-your-own-sender) above, in that order);
  then the engine starts listening for CC. A frontend that's already open
  when the engine (re)starts will see its scope reset and every control
  snap to the engine's real values, with nothing sent from the page.
- **On request** — channel 16, CC 1, any value `> 0`; send `BF 01 7F` — the
  engine replies with, in order: HELLO; the 24 echoes of its *current*
  values (not the defaults — whatever's actually running), in the same
  defaults-table order; HEAD; the full waveform DUMP.
- A page should send the request once both a MIDI output and a MIDI input
  are selected, and again whenever either selection changes — that's the
  only time it needs to ask.
- **On receiving an echo,** a page should just update its own display
  (state, slider position, value label, byte readout) and save it — and
  never send anything back. Replying to an echo is how you build a feedback
  loop.

### Loop safety

Every message on this port reaches everyone listening to it — including
your own messages if something loops them back, and anything a MIDI monitor
or a second frontend is also sending on the same wire. Anyone sharing the
port, including a third-party frontend or a plain MIDI monitor, should
follow the same two rules the engine and this demo do:

- **The engine only ever acts on:** CC on channels 1–3 (controls), and
  channel 16 CC 1 (request). It silently ignores everything else — its own
  echoes on channels 9–11, its own SysEx, any other channel — with no log
  line for what it ignores.
- **A page should only ever act on:** CC on channels 9–11 (echo), and SysEx
  starting `F0 7D 43`. It should ignore its own channel 1–3 and channel 16
  messages if they loop back — those are things it just sent, not new
  information.

### Recommended page behaviour

- **Ignore an echo for a control the user is actively touching.** While a
  pointer or keyboard interaction is in progress on a slider or toggle, and
  for about 300 ms after the page itself last sent that control, drop any
  echo naming it. Without this guard, an echo arriving mid-drag fights the
  user's own movement — the value snaps back to whatever the engine last
  applied, one message behind the drag.
- Everywhere else, let echoes win: they're the engine's real state, and
  `localStorage` is only a fallback for when no engine is present.

### SysEx telemetry

Every telemetry packet has the same shape:

```
F0 7D 43 <type> <payload…> F7
```

All payload bytes are 7-bit (`0`–`127`), like any MIDI SysEx. Multi-byte
numbers are packed MSB-first into that many 7-bit bytes:

| Encoding | Bytes | Built as |
|---|---|---|
| `u7` | 1 | the value itself, `0..127` |
| `u14` | 2 | `(v>>7)&127`, `v&127` |
| `u21` | 3 | `(v>>14)&127`, `(v>>7)&127`, `v&127` |
| `u28` | 4 | `(v>>21)&127`, `(v>>14)&127`, `(v>>7)&127`, `v&127` |
| `pos14` | 2 | a normalised buffer position (`0.0`–`1.0`) × `16384`, clamped to `0..16383`, then packed as `u14` |

| Type | Name | Payload | Sent |
|---|---|---|---|
| `0x01` | HELLO | `version` u7 (=1), `bufferFrames` u28, `sampleRate` u21, `numCols` u14, `numTaps` u7 (=16) | At boot, before the bang; first thing in a request reply |
| `0x02` | HEAD | `writeHead` pos14, `frozen` u7 (`0`/`1`) | 20 times a second; also in a request reply |
| `0x03` | GRAIN | `tap` u7, `start` pos14, `durMs` u14, `rate` u14 (`round(rate·2048+8192)`, signed range ±4), `pan` u7 (`round((pan+1)/2·127)`), `amp` u7 (`round(clip(amp,0,3)/3·127)`) | On every grain trigger — roughly 10–100 a second |
| `0x04` | COLUMN | `col` u14, `peak` u7 (`round(clip(peak,0,1)·127)`) | Whenever the write head leaves a waveform column — about 4 a second at the engine's default 1024 columns over its fixed 256 s buffer |
| `0x05` | DUMP | `startCol` u14, `count` u14 (≤ 256), then `count` peak `u7` bytes | Request reply: the whole recorded-peaks array, in chunks of up to 256 columns |

**One worked byte example per type**, for a `44100 Hz` engine (its buffer is
always exactly 256 seconds long, so `bufferFrames = sampleRate × 256`) with
the default `1024` waveform columns:

- **HELLO** — version 1, `bufferFrames = 11289600`, `sampleRate = 44100`,
  `numCols = 1024`, `numTaps = 16`:

  ```
  F0 7D 43 01  01  05 31 08 00  02 58 44  08 00  10  F7
  ```

  (type `01`; version `01`; `bufferFrames` as u28 → `05 31 08 00`;
  `sampleRate` as u21 → `02 58 44`; `numCols` as u14 → `08 00`; `numTaps` →
  `10`.)
- **HEAD** — write head 25% through the buffer, not frozen:

  ```
  F0 7D 43 02  20 00  00  F7
  ```

  (`pos14` for `0.25` is `4096` → `20 00`; `frozen = 0`.)
- **GRAIN** — tap 3, starting at the buffer's midpoint, a 120 ms grain at
  normal (1.0×) rate, centred pan, unity amplitude:

  ```
  F0 7D 43 03  03  40 00  00 78  50 00  40  2A  F7
  ```

  (`tap = 03`; `start` `pos14` for `0.5` → `40 00`; `durMs = 120` as u14 →
  `00 78`; `rate`: `round(1.0·2048+8192) = 10240` as u14 → `50 00`;
  `pan = 0` → `round(0.5·127) = 40`; `amp = 1.0` →
  `round((1/3)·127) = 2A`.)
- **COLUMN** — column 512 (the buffer's midpoint) finished with a peak
  amplitude of 0.5:

  ```
  F0 7D 43 04  04 00  40  F7
  ```

  (`col = 512` as u14 → `04 00`; `peak = 0.5` → `round(0.5·127) = 40`.)
- **DUMP** — a 4-column chunk starting at column 0, with peaks
  `0, 0.33, 0.66, 1.0`:

  ```
  F0 7D 43 05  00 00  00 04  00 2A 54 7F  F7
  ```

  (`startCol = 0` as u14 → `00 00`; `count = 4` as u14 → `00 04`; four peak
  bytes → `00 2A 54 7F`.)

  A DUMP of the whole default 1024-column buffer is four such chunks
  (`startCol` 0, 256, 512, 768), each with `count = 256`.

---

## Quick start

### 1. Set up a virtual MIDI port

The browser and SuperCollider share **one virtual MIDI cable**, in both
directions: the page sends controls out on it, and — if you're using
[Listening to the engine (optional)](#listening-to-the-engine-optional) —
the engine sends its echoes and telemetry back on that same cable. There's
no second port to wire up.

- **macOS:** open **Audio MIDI Setup**, press `Cmd+2` to show the **MIDI
  Studio**, double-click **IAC Driver**, check **"Device is online"**, make
  sure at least one bus (e.g. `Bus 1`) exists, and click **Apply**. This one
  bus appears as both a source and a destination, so the engine can find it
  by name (see step 2) and send replies on the same bus it listens on.
- **Windows:** install a virtual MIDI driver such as
  [loopMIDI](https://www.tobias-erichsen.de/software/loopmidi.html) and
  create a virtual port (e.g. `loopMIDI Port`). The web demo auto-selects any
  output whose name contains `IAC`, `Bus 1`, or `loopMIDI`, and the engine's
  own port lookup (`midiPortMatch`, see step 2) matches the same names by
  default.
- **Linux:** load the ALSA virtual-MIDI kernel module —
  `sudo modprobe snd-virmidi` — which creates one or more virtual MIDI
  ports you can select as both the browser's MIDI output and
  SuperCollider's MIDI input. Unlike IAC or loopMIDI, plain ALSA doesn't wire
  the engine's MIDI *output* to a destination automatically — connect it
  explicitly (e.g. with `aconnect`, or a patchbay such as `qjackctl`) from
  the engine's virtual output port to the browser's virtual input port, or
  replies won't reach the page even though controls still work fine.

### 2. Run the SuperCollider engine

1. Launch SuperCollider and open `carters_delay_midi.scd`.
2. Select all and evaluate the file: `Cmd+Enter` on macOS, `Ctrl+Enter` on
   Windows/Linux.
3. It connects to MIDI, boots the audio server, allocates the delay buffer,
   and starts the 16 granular taps and the feedback patch, printing:

   ```
   === MIDI sources ===
    [MIDI Src 0] Bus 1 (IAC Driver)
   === Carter's Delay: loading engine... ===
   === Carter's Delay ready: listening for MIDI CC on channels 1-3 ===
   ```

   (The MIDI sources list reflects whatever's actually connected.)
4. **The engine also opens one MIDI output, to send its replies on** — see
   [Listening to the engine (optional)](#listening-to-the-engine-optional).
   It picks the first destination in `MIDIClient.destinations` whose
   device and name, concatenated as `"<device> <name>"`, contain one of the
   strings in the `midiPortMatch` config variable near the top of the file
   (default `["IAC Driver Bus 1", "loopMIDI"]`). It matches on that
   concatenation rather than on `name` alone so this works whether
   `MIDIClient` reports the IAC bus as one endpoint or as `device = "IAC
   Driver"` and `name = "Bus 1"` separately, and it sets that output's
   latency to `0` so replies aren't delayed the usual 0.2 s. If nothing
   matches — say, a loopMIDI port you renamed, or an ALSA port not yet in
   the list — it posts one clear warning and keeps running with controls
   working exactly as before: every reply becomes a silent no-op until you
   either rename your port or add its name to `midiPortMatch` and
   re-evaluate.
5. **Re-evaluating the file at any time replaces the running engine** — it
   tears down the previous instance first, so you never end up with two
   copies fighting over the same buffer.
6. `Cmd+Period` (macOS) / `Ctrl+Period` (Windows/Linux) — SuperCollider's
   global "stop" — cleanly shuts the engine down and prints:

   ```
   Carter's Delay stopped (Cmd-Period). Re-evaluate the file to restart.
   ```

   Re-evaluate the file to start it again.

### 3. Run the web demo

1. Open `index.html` in a browser that supports the Web MIDI API (e.g.
   Chrome or Edge), or serve it locally: `python3 -m http.server 8000`, then
   visit `http://localhost:8000`.
2. Grant MIDI access when prompted. The page also asks for the MIDI
   **SysEx** permission, since the scope needs it; if that's denied, the
   page retries without it and keeps working — controls, echo and the
   request all still function — and the scope shows "The scope needs MIDI
   SysEx permission. Allow it in the browser's site settings and reload."
   instead of drawing.
3. Pick your virtual port as the MIDI **output**. A second, compact
   **"Replies from"** select in the header picks the MIDI **input** the page
   listens to for echo and telemetry — by default it pairs with whichever
   output you just picked, or falls back to the first input whose name
   contains `IAC`, `Bus 1` or `loopMIDI`. Both selections persist across
   reloads. As soon as both are set (and again whenever either changes), the
   page sends a request so an already-running engine reports its real state
   immediately, instead of waiting for you to touch a control.
4. The header shows an **engine status** next to the MIDI connection state:
   "Engine running" while anything from the engine — an echo or a telemetry
   packet — has arrived in the last 2 seconds (HEAD, at 20 packets a second,
   is the heartbeat that keeps this current once things are going), or "No
   reply from the engine" otherwise. That's independent of the MIDI
   connection state, which only means the browser opened the ports.
5. Click **Send all values** once the SuperCollider engine has (re)started,
   to push every control's current value across — see
   [Implementing your own sender](#implementing-your-own-sender) for why this
   matters.
6. **Mute all** silences Passthrough Level, Delay Input Level, Delay Output,
   and Feedback Level in one click, through the same code path as moving
   those controls by hand — so the UI, the log, and local storage all agree,
   and a later Send all values won't un-mute anything behind your back.
7. **Double-click** any slider to reset it to its factory default and send
   that value immediately.
8. Every control shows the exact MIDI bytes it will send, right next to it,
   even before you touch it — the byte readout flashes when a message
   actually goes out. The MIDI monitor below shows the same bytes as a
   running log, plus a compact line for each incoming echo (e.g. `B9 01 40
   echo Ch 2 CC 1`) and a live counter for telemetry (e.g. "Telemetry: 38
   grains/s, head 20/s") rather than logging every individual grain, head or
   column packet.
9. **The scope draws the engine's real delay buffer**, from its telemetry:
   the waveform is the engine's own recorded peaks, the write head is the
   engine's actual play/record position (dashed and marked "Frozen" when you
   freeze the buffer), and each grain trigger draws a short-lived rectangle
   at its real position, duration, pan and amplitude. The canvas's full
   width is always the engine's real buffer length — there's nothing to
   configure. Until the engine's HELLO packet arrives (or if SysEx
   permission was denied), it shows a waiting message instead: "Waiting for
   the engine. Start carters_delay_midi.scd, then press Send all values or
   reload." There is no browser preview synth or microphone input; the
   scope is driven entirely by the engine's own telemetry.

---

## Tech stack

- **Audio engine:** SuperCollider. `MIDIdef.cc` for control input; `MIDIOut`
  for echoes and the request reply; `SendReply` + `OSCdef` for the
  server-to-language telemetry that becomes SysEx (write head, waveform
  columns, grain triggers); `GrainBuf` for granulation; `MoogFF` for the
  per-tap low-pass; `EnvGen`/`Env.asr` for synth envelopes; `CoinGate`,
  `Impulse`, and `Dust` for the trigger distribution crossfade;
  `LFNoise1`-driven `Ndef`s for the per-tap pan, amplitude, cutoff, and
  resonance modulation; `Limiter` on the master output; `CmdPeriod` for
  teardown. Tempo is a fixed internal constant (`beatDur = 0.5`, i.e. 120
  BPM), used only at boot to size the delay buffer and derive the per-tap
  grain durations, delays, and modulation-LFO rates — there is no external
  clock and no clock sync.
- **Frontend:** HTML5, CSS3, vanilla JavaScript, and the Web MIDI API
  (`navigator.requestMIDIAccess`, with an optional `sysex: true` for the
  scope).
- **Scope:** a canvas visualization of the engine's actual delay buffer —
  waveform, write head, and grains — decoded entirely from the SysEx
  telemetry described in
  [Listening to the engine (optional)](#listening-to-the-engine-optional).
  It draws nothing (and shows a waiting message) until the engine's HELLO
  packet arrives; there is no simulated or microphone-driven fallback.

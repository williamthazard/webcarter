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
  anything back from you to accept them, and it doesn't remember what you
  sent across a restart: every restart brings it back to the defaults
  below. A **write-only** sender therefore resends every control's value
  once after the engine (re)starts — see
  [Implementing your own sender](#implementing-your-own-sender). A frontend
  that **listens** doesn't resend; it adopts the engine's state, which the
  engine reports on its own at boot and again whenever you ask, on the
  same port — see
  [Listening to the engine (optional)](#listening-to-the-engine-optional).
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

Any CC number not listed above (e.g. CC 7 on channel 3) is ignored, except
the state request, channel 16 CC 1 — see
[Listening to the engine (optional)](#listening-to-the-engine-optional).

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
  can be write-only. A write-only sender can't see what the engine is
  running, so it should **send every control's value once at connection
  time, and again after the engine (re)starts** — a restart always brings
  the engine back to the defaults below, whatever it was running before.
  If you've made no changes yet, resending isn't strictly required, since
  the engine boots into those defaults on its own — but you generally can't
  know whether the engine was just (re)started or has been running with
  different values for a while.
- **A frontend that listens adopts the engine's state instead of resending
  it.** The engine reports its state on its own at boot (the "bang") and
  whenever you ask (the request), over the same port — see
  [Listening to the engine (optional)](#listening-to-the-engine-optional).
  The web demo works this way: when the engine boots or answers the page's
  request, the page's controls take the engine's values. Its "Send all
  values" button is a manual resync: it sends every control's current
  value, then the state request `BF 01 7F`, so the engine's reply shows
  what it now has.
- **The engine listens on every MIDI input it sees at boot** (`MIDIIn.connectAll`
  in SuperCollider) — there's no per-source filtering or handshake. Just open
  a MIDI output on your end and send. (It also opens one MIDI output of its
  own, to send replies on, if you want them — see
  [Quick start](#quick-start).)
- Anything not listed in the contract tables is silently ignored, except
  the state request, channel 16 CC 1: any value above 0 makes the engine
  send its state back, at most once per 250 ms (see
  [Listening to the engine (optional)](#listening-to-the-engine-optional)).
  CC 1 is also the mod wheel, so a keyboard set to channel 16 triggers
  those replies too. You can't break the engine by sending an unrecognized
  CC number or an out-of-range channel.

**The exact defaults**, as `[channel, cc, value]` triples — this is the state
the engine boots into on its own. The engine's boot bang and every request
reply echo its state in this order, and the demo's "Send all values" sends
its controls in this order too (at defaults, exactly these 24 messages),
followed by the state request `BF 01 7F`:

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
contract above — there's no second cable. Grain telemetry is the largest
and most variable part of what the engine sends: 14 bytes per grain, about
7–20 grains a second at defaults (~100–280 B/s), and up to ~260 a second
at max density and min rate (about 3,700 B/s in all). On macOS, over the
IAC bus, the engine reports essentially every grain, even at the top of
that range. On Linux and Windows it has to use SuperCollider's SysEx call,
whose speed there hasn't been measured, so it plays safe: it hands the
port at most about 600 B/s of SysEx apart from request replies. That is
enough for essentially every grain at defaults but no more than about 35
a second; it keeps the newest and drops the rest. On every platform it
reports none while the port is falling behind. HEAD adds a steady ~40 B/s
(about 5 packets a second) and COLUMN about 32 B/s (47 B/s at 96 kHz), so
the total at defaults is about 170–350 B/s. A request reply adds 1,084
bytes of SysEx at the default 1024 columns, spread over about 1 s. SysEx
goes out in bursts about every 200 ms — see "Delivery in bursts", "Byte
budget" and "Latency" under [SysEx telemetry](#sysex-telemetry).

### Channel map

| Direction | Status byte(s) | Channel(s) | Meaning |
|---|---|---|---|
| page → engine | `B0`, `B1`, `B2` | 1, 2, 3 | Controls — the contract above, unchanged |
| page → engine | `BF 01 xx` (`xx > 0`) | 16 | **Request:** ask the engine to resend everything below (at most one reply per 250 ms) |
| engine → page | `B8`, `B9`, `BA` | 9, 10, 11 | **Echo:** the CC number and value the engine just applied on channel 1, 2, 3 (echo channel = control channel + 8) |
| engine → page | `F0 7D 43 … F7` | — | **Telemetry**, as SysEx — see [SysEx telemetry](#sysex-telemetry) below. `7D` is the MIDI non-commercial manufacturer ID; `43` (`'C'`) identifies Carter's Delay. |

### Echo: what it means and when it happens

- The engine echoes **every control it actually applies**, whatever the
  source — including its own startup defaults. A toggle echoes `127` (on) or
  `0` (off), normalised; a slider echoes the exact value it received. CC
  numbers the engine doesn't handle are never echoed.
- **On boot**, in order:
  1. a HELLO packet, once the buffer exists;
  2. telemetry starts: HEAD, COLUMN and GRAIN packets can arrive from here
     on, so some may land between this HELLO and the bang;
  3. the 24 echoes of the engine's own defaults (the "bang" — the same
     list as [the defaults table](#implementing-your-own-sender) above, in
     that order);
  4. the engine starts listening for CC, and sends HELLO a second time.

  This is the order the engine sends in. Echoes are ordinary CCs and go out
  at once, while SysEx is queued and delivered in ~200 ms bursts, so a
  HELLO (and HEAD/DUMP) can arrive after echoes that follow it; don't rely
  on relative CC/SysEx order.

  A frontend that's already open when the engine (re)starts will see its
  scope reset and every control snap to the engine's real values, with
  nothing sent from the page.
- **HELLO is sent when the buffer exists and again once the engine is
  listening; treat every HELLO as "reset your scope"** — see
  [SysEx telemetry](#sysex-telemetry). The second one is for a page whose
  request arrived while the engine wasn't listening yet: that request is
  dropped, but the page still gets a HELLO.
- **On request** — channel 16, CC 1, any value `> 0`; send `BF 01 7F` — the
  engine produces, in order: HELLO; the 24 echoes of its *current* values
  (not the defaults — whatever's actually running), in the same
  defaults-table order; HEAD; then the full waveform DUMP. On the wire the
  24 echoes go out first, at once, as plain CCs. The SysEx follows spread
  over about 1 s, so it never reaches the port in one lump: HELLO and HEAD
  go out in the next burst (within 200 ms), then the four DUMP chunks, one
  per burst — 1,084 bytes of SysEx in all at the default 1024 columns, and
  1,156 bytes with the echoes' 72. The burst carrying HELLO may begin with
  COLUMN packets queued just before it, so look for the HELLO frame rather
  than assuming it is first.
  The engine sends at most one reply per 250 ms: a request inside that
  window after the previous reply is dropped silently. A request that is
  answered starts the reply over, even if the previous reply's DUMP chunks
  haven't all gone out: its HELLO resets the page's scope, and its DUMP
  starts again from the first chunk. While the engine hears that the port
  is more than 1 s behind (from its own HEADs coming back — see "Latency"
  under [SysEx telemetry](#sysex-telemetry)), or has stopped hearing its
  HEADs come back after hearing some, a DUMP chunk not yet sent waits, and
  a request arriving then gets a reply with no DUMP — just the echoes,
  HELLO and HEAD; the waveform then fills in from COLUMN packets as the
  write head moves on, or from a later request's reply. (While the engine
  is estimating the delay instead — whenever it has nothing to measure,
  see "Latency" — a reply's DUMP is never held back.)
- **When to ask:** send the request once both a MIDI output and a MIDI
  input are selected, and again whenever either selection changes. A
  request can be lost (a failed send, or an engine still booting), so the
  demo retries:
  - a request that fails to send is retried at the next port change;
  - a sent request with no HELLO after 1.5 s is re-sent, max 3 per
    pairing (output/input pair) — except while any of the engine's own
    telemetry packets (`F0 7D 43 …`) has arrived in the last 2 s: then the
    engine is alive and its HELLO is most likely still on its way, so the
    demo checks again 1.5 s later instead of re-sending (waiting doesn't
    use up an attempt). It waits like this for at most 6 s after the
    request: if telemetry is still arriving with no HELLO by then, the
    HELLO was lost, and the demo re-sends anyway (that does use up an
    attempt);
  - an echo that arrives while the page has no HELLO yet triggers a
    re-request, at most once every 2 s, and not while any of the engine's
    own telemetry packets has arrived in the last 2 s (same reason).
    Echo-triggered re-requests count toward the same 3. A request sent
    because echoes arrived before any HELLO is checked the same way — 1.5 s
    after it goes out, waiting on arriving telemetry for at most 6 s — and
    its check replaces the pending one, so the two kinds of re-send never
    go out back to back.

  The count of 3 starts again when the pairing changes or a HELLO
  arrives. Without SysEx permission no HELLO can reach the page, so there
  the demo counts any echo after the request as the reply and skips the
  echo-triggered re-request.
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
  channel 16 CC 1 (request, answered at most once per 250 ms). It silently
  ignores everything else — its own echoes on channels 9–11, any other
  channel, and SysEx — with no log line for what it ignores. The one SysEx
  it reads is its own HEAD packets coming back, only to time how far
  behind the port is (see "Latency" under
  [SysEx telemetry](#sysex-telemetry)).
- **A page should only ever act on:** CC on channels 9–11 (echo), and SysEx
  starting `F0 7D 43`. It should ignore its own channel 1–3 and channel 16
  messages if they loop back — those are things it just sent, not new
  information. It should never send SysEx starting `F0 7D 43` itself, nor
  pass the engine's packets back onto the port (a MIDI monitor set to
  "thru", say): the engine would count those as its own HEADs returning.

### Recommended page behaviour

- **Ignore an echo for a control the user is actively touching.** The demo
  guards a slider while a pointer is down on it or a key is held on it, and
  guards every control — slider, toggle or chip — for 300 ms after the page
  itself last sent it. Toggles and chips change on a click, so the 300 ms
  window is their only guard. An echo naming a guarded control is dropped.
  Without this guard, an echo arriving mid-drag fights the user's own
  movement — the value snaps back to whatever the engine last applied, one
  message behind the drag.
- **When the guard ends, apply the last echo you dropped.** While a control
  is guarded, remember the latest echo dropped for it. When the guard ends
  — the pointer is released or cancelled, the key is released, focus
  leaves, or the tab is hidden, and 300 ms have passed since the page last
  sent that control — apply that echo unless the control already shows
  that value. Without this step, an echo carrying a different value (from
  the boot bang, say, or a second frontend on the same port) is lost, and
  the page shows a stale value until the control is touched again.
- Everywhere else, let echoes win: they're the engine's real state. The
  demo restores the previous session's values from `localStorage` at load,
  but only to show until the engine reports its state; the boot bang or a
  request reply then replaces them, saved copy included. The page never
  sends restored values to the engine on its own.

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
| `0x01` | HELLO | `version` u7 (=1), `bufferFrames` u28, `sampleRate` u21, `numCols` u14, `numTaps` u7 (=16) | Twice at boot: once the buffer exists (before the bang), and again once the engine is listening; also the first SysEx frame of each request reply, though the burst carrying it may start with COLUMN frames queued just before (see [Echo](#echo-what-it-means-and-when-it-happens)) |
| `0x02` | HEAD | `writeHead` pos14, `frozen` u7 (`0`/`1`) | Measured 20 times a second, but only the newest HEAD in each ~200 ms burst is sent, so about 5 a second, however busy the port is; also in a request reply |
| `0x03` | GRAIN | `tap` u7, `start` pos14, `durMs` u14, `rate` u14 (`round(rate·2048+8192)`, signed range −4 to just under +4: +4 encodes as `16383` → +3.9995), `pan` u7 (`round((pan+1)/2·127)`), `amp` u7 (`round(clip(amp,0,3)/3·127)`) | Per grain trigger — about 7–20 a second at defaults, up to ~260 at max density. On macOS essentially all are reported; on Linux and Windows at most about 35 a second (more are thinned — see "Byte budget" below). None while the port is falling behind (see "Latency" below), or in the bursts that carry a request reply |
| `0x04` | COLUMN | `col` u14, `peak` u7 (`round(clip(peak,0,1)·127)`) | Whenever the write head leaves a waveform column: `numCols` per pass of the write head round the buffer, so about 4 a second at the default 1024 columns over a 256 s buffer (about 5.9 at 96 kHz); skipped while the engine hears that the port is more than 1 s behind, or has stopped hearing its HEADs come back (see "Latency" below) |
| `0x05` | DUMP | `startCol` u14, `count` u14 (≤ 256), then `count` peak `u7` bytes, each encoded like COLUMN's `peak` | Request reply: the whole recorded-peaks array, in chunks of up to 256 columns, one chunk per burst; a chunk not yet sent waits while the engine hears that the port is more than 1 s behind, or has stopped hearing its HEADs come back, and a request arriving then gets no DUMP |

**Decoding**, as the demo does it: `pos = u14/16384` (HEAD's `writeHead`,
GRAIN's `start`); `rate = (u14−8192)/2048`; `pan = u7/127·2−1` (centre
encodes as `0x40` → +0.008; there's no exact centre); `amp = u7/127·3`;
`peak = u7/127` (COLUMN, and every DUMP peak byte).

**On HELLO: clear waveform, grains and head** — all column peaks, every
live grain and the write-head position — and take `bufferFrames`,
`sampleRate` and `numCols` from the packet. Do this for every HELLO: both
boot HELLOs and the one each request reply carries. HEAD, COLUMN and
GRAIN packets can arrive before any HELLO you've seen: telemetry streams
all the time, so a page opened while the engine is already running gets
some before the HELLO in the reply to its request. The demo ignores
telemetry until it has a HELLO.

**Delivery in bursts.** The engine doesn't send each packet on its own.
It queues them and, every 200 ms, sends what's pending back to back, so
packets are delivered in bursts of up to ~200 ms. How a burst is handed to
the MIDI driver depends on the platform; the bytes are the same on all of
them:

- **macOS:** as a run of ordinary MIDI packets of up to 3 bytes each
  (`MIDIOut.write`, which goes through CoreMIDI's `MIDISend`). SysEx may
  span any number of MIDI packets; CoreMIDI delivers them at once and
  reassembles the SysEx. SuperCollider's SysEx call (`MIDIOut.sysex`)
  goes through CoreMIDI's `MIDISendSysex` instead, which paces SysEx to
  roughly MIDI-cable speed (about 3,000 B/s measured on the IAC bus),
  below the engine's peak of about 3,700 B/s; `MIDISend` packets go out
  at once (over 3,300 B/s sustained on the IAC bus, with no backlog).
- **Linux:** the whole burst in one `MIDIOut.sysex` call.
- **Windows:** one `MIDIOut.sysex` call per packet, since PortMidi sends a
  SysEx buffer only up to its first `F7`.

(On Linux and Windows `MIDIOut.write` sends only short messages, so it
can't carry SysEx there.) Depending on the platform and the receiving MIDI
API, a burst arrives as one SysEx message or as several (on Windows, one
per packet), so a message may contain several packets back to back
(`F0 7D 43 … F7 F0 7D 43 … F7 …`). Split every incoming SysEx message
into its `F0 … F7` frames and decode each one; each packet's bytes are
exactly as in the tables above. Only the newest HEAD in each burst is kept
(about 5 a second). HELLO and HEAD always go out; COLUMN packets go out in
the order they were produced, except while the engine hears that the port
is more than 1 s behind or has stopped hearing its HEADs come back; a
request reply's DUMP chunks go out one per burst; and GRAIN packets are
subject to the byte budget and the backlog gate below. On a shared bus,
another sender's message (including your own CCs) can arrive between the
packets of one SysEx message; a missed DUMP chunk is filled in by the
COLUMN stream or the next request.

Such a message can even land inside a single frame. A frame can cross the
bus in pieces — on macOS the engine hands each burst over 3 bytes at a
time, and a driver may split a long frame (a 265-byte DUMP chunk, say) —
and a CC sent on the same bus meanwhile, by a second frontend or by your
own page (a slider move, a request) looped back, can land between them.
Under the MIDI spec any status byte other than a real-time one ends a
SysEx message, so a receiver may lose that frame. The engine never resends
a packet, so don't depend on any single one: a lost HEAD is replaced by the
next, a lost GRAIN or COLUMN is simply missing, a lost DUMP chunk leaves its
columns empty until the write head passes them again (COLUMN) or another
request reply arrives, and a lost HELLO leaves the page ignoring telemetry
until the next one. The demo's request retry (under
[Echo](#echo-what-it-means-and-when-it-happens)) re-sends the request if
telemetry keeps arriving with no HELLO for 6 s (within its 3 attempts); if
the scope still shows its waiting message while the engine runs, press
Send all values.

**Byte budget.** SysEx can be slow to deliver, and anything handed over
faster than the MIDI driver delivers it backs up inside the operating
system, where the engine can't see it. So each burst has a byte budget,
set by how fast the platform's send path is. HELLO, HEAD and COLUMN are
counted first and go out whatever the budget (COLUMN apart from the
backlog gate below); GRAIN packets (14 bytes each) fill whatever budget is
left, newest first, and the older ones are dropped ("thinned"). The budget
is per 200 ms: a burst that goes out late (the engine's timer woke late)
gets a budget in proportion to the time since the previous burst, up to
three times as much, so a late burst doesn't thin grains the port could
have carried.

- **macOS: 800 bytes per burst, about 4,000 B/s.** The packet path (see
  "Delivery in bursts") sustained about 3,300 B/s on the IAC bus for 20 s
  and delivered all of it, each burst's HEAD arriving within about 10–40 ms.
  The budget is above the most the taps can produce, so it's only a safety
  net: in practice every grain is reported. Only near the top of the
  density range (over ~250 grains a second with periodic triggers, the
  default; from about 200 with random ones — see
  [Trigger distribution](#trigger-distribution-ch3-cc5)) can a burst
  exceed what fits (56 grains next to its HEAD and a COLUMN), and then a
  few grains are thinned. That's on a bus the engine hears itself on,
  such as IAC. On a port that doesn't loop back, the engine estimates the
  delay instead (see "Latency" below), and above about 220 grains a
  second the estimate now and then holds grains back.
- **Linux and Windows: 120 bytes per burst, about 600 B/s.** There the
  engine has to use SuperCollider's SysEx call, and its speed on ALSA and
  loopMIDI hasn't been measured, so the budget is a conservative estimate
  for that path, not a measured limit. Next to the burst's HEAD (8 bytes)
  and its COLUMN, if any (8 bytes), that leaves room for 7 grains per
  burst (8 when there's no COLUMN), so at most about 35 a second are
  reported. Grains don't arrive evenly — the 16 taps'
  periodic triggers line up now and then — so thinning starts well below
  that: even at defaults a burst occasionally catches more grains than
  fit, and a few percent are dropped; about 10% are dropped at 30 grains a
  second, and 30% at 50.

A request reply doesn't go out in one lump either: after its echoes, HELLO
and HEAD go out in the next burst, then one DUMP chunk (265 bytes) per
burst, each taking the place of that burst's budget, so the reply's
1,084 bytes of SysEx take about 1 s to hand over while HEAD keeps
flowing. The bursts that carry a reply carry no GRAIN packets, so no grains
are reported for about 1 s after each answered request, on every platform,
whether the engine measures the delay or estimates it (see "Latency"
below). A dropped grain is simply never sent: nothing on the wire marks
it, and there's nothing for the page to do. While the budget keeps
thinning grains, the engine posts at most one line every 10 s, with N the
number dropped:

```
Telemetry: thinning grain packets (N dropped in the last 10 s)
```

On macOS it should never appear at defaults; if it appears at all, it's
only near the top of the density range (over ~250 grains a second with
periodic triggers, from about 200 with random ones). On Linux and Windows
it can appear a few times a minute: at high density, but at defaults
too, with a small N.

**Latency.** The engine measures how far behind the port is rather than
guessing. It listens on every MIDI input (`MIDIIn.connectAll`), so on a
bus that loops back, such as IAC or loopMIDI, it hears its own packets
arrive. It notes when it sends each HEAD, and when a HEAD comes back, the
time since that HEAD was sent is how far behind the port is (and about how
far behind a page on the same bus is). HEADs carry no sequence number, so
each one that comes back is paired in order with the oldest in flight
that has the same bytes; any sent before that one, or not back within 2 s
of being sent, are taken as lost. While the buffer is frozen all HEADs
look alike, so a lost one is recognised after 2 s and the measurement
re-anchored: a lost HEAD skews the measurement for about 2 s at most.

While the port is more than 0.5 s behind on macOS (0.35 s on Linux and
Windows), bursts carry no GRAIN packets; they resume once it's back under
0.3 s (0.25 s on Linux and Windows). On macOS's packet path the port is
normally only a few tens of milliseconds behind, so on a bus the engine
hears itself on (IAC) this happens only if something is actually wrong.
While it's more than 1 s behind, bursts carry no COLUMN packets either
(the waveform catches up from later COLUMNs or the next request's DUMP), a
reply's DUMP chunk not yet sent waits, and a request arriving then gets no
DUMP (see [Echo](#echo-what-it-means-and-when-it-happens)). HELLO and HEAD
always go out.

If HEADs it is still sending stop coming back — none for more than 2 s —
after the engine has heard some, it doesn't switch to an estimate, which
would soon read near zero and let a backlog it can no longer see keep
growing. It takes the port to be more than 1 s behind instead, with
everything that means above (no GRAIN or COLUMN packets, no DUMP for a
reply), until a HEAD comes back and is paired again. Meanwhile only HELLO
and HEAD go out (about 40 B/s), so a port that is merely late catches up
within seconds. It posts the line below once each time this happens (at
most once every 10 s), usually just after a "MIDI port is behind by …"
line (see below) posted while it was still waiting for those HEADs:

```
Telemetry: MIDI port stopped echoing; holding grain packets
```

If still no HEAD has come back after 8 s of this (10 s after the last
one), something other than delay has stopped the engine hearing the port.
It then stops holding packets back, posts the line below once, and
estimates the delay as described next, until a HEAD comes back again:

```
Telemetry: no longer hearing the MIDI port; estimating instead
```

Whenever the engine has nothing to measure — on a port that doesn't loop
back, as in some Linux setups; before its first HEAD returns; after giving
up as above; or while no HEAD it sent 1–2 s ago is still on its way,
because it has stopped sending them (the server stopped answering) or has
only just started again — it estimates the delay instead. It charges each
burst a fixed cost plus a cost per byte: 10 ms plus 0.3 ms per byte on
macOS, and 60 ms plus 1 ms per byte on Linux and Windows (estimates, not
measured on those platforms). The estimate runs down again whenever bursts
take less time to send than the time between them (200 ms), as on Linux
and Windows every burst within its normal 120-byte budget does; a late
burst, with its larger budget (see "Byte budget"), is charged as if it had
gone out over the time it covers (up to 400 ms), so a late wake alone
doesn't make the estimate hold grains back. A burst carrying a reply's
DUMP chunk is charged at most the fixed cost, not by the byte, so
answering a request doesn't make the engine hold grains back. On the
estimate the engine holds back only grains, at the same thresholds:
COLUMN packets and a reply's DUMP always go out. For the first 2 s after
the engine starts, while no HEAD has come back yet, it holds back
nothing. A pause of the SuperCollider language itself (the post window
freezing for a moment) is not counted as port delay either: the engine
discounts it from its measurement. While grains are held back, measured
or estimated, the engine posts at most one line every 10 s, with N the
delay in milliseconds:

```
Telemetry: MIDI port is behind by N ms; skipping grain packets
```

(The macOS costs come from measurements on the IAC bus. ALSA and loopMIDI
weren't measured, so on Linux and Windows the estimate is only a rough
guard.)

**Buffer length.** `bufferFrames` is the engine's real buffer length: the
buffer is 256 s at 44.1/48 kHz; shorter above 65 kHz. The engine allocates
`sampleRate × 256` frames but caps the buffer at 2^24 = 16,777,216 frames,
the most a 32-bit float write position can address frame by frame. That
cap equals 256 s at exactly 65,536 Hz, so it only applies above that:
190.2 s at 88.2 kHz, 174.8 s at 96 kHz. The 16 tap delays are fixed
fractions of the buffer (1/32 to 16/32 of it: 8 s to 128 s at 256 s), so
they shrink in proportion, and the boot log says so ("Buffer capped at …;
tap delays scaled to fit."). Always take the length from HELLO
(`bufferFrames / sampleRate` seconds) rather than assuming 256 s.

**One worked byte example per type**, for a `44100 Hz` engine (a 256 s
buffer, so `bufferFrames = 44100 × 256 = 11289600`) with the default `1024`
waveform columns:

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
  create a virtual port (e.g. `loopMIDI Port`). With nothing saved from an
  earlier visit, the web demo picks the first output whose name contains
  `IAC`, else `loopMIDI`, else the whole word `Bus 1`, else the first
  output; the engine's own port lookup (`midiPortMatch`, see step 2)
  matches `IAC Driver Bus 1` or `loopMIDI` by default.
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
   Connected MIDI output for echo/telemetry: IAC Driver Bus 1 (destination 0)
   === Carter's Delay: loading engine... ===
   Applied 24 defaults.
   === Carter's Delay ready: listening for MIDI CC on channels 1-3 ===
   ```

   The MIDI sources and the output line reflect whatever's actually
   connected, and SuperCollider's own messages (its MIDI endpoint list, the
   server's boot log) appear around these lines. Above 65,536 Hz one more
   line follows "loading engine" — see "Buffer length" under
   [SysEx telemetry](#sysex-telemetry) — e.g. at 96 kHz:

   ```
   Buffer capped at 16777216 frames (2^24) = 174.8 s at 96000 Hz; tap delays scaled to fit.
   ```

   Applying the 24 boot defaults posts only that "Applied 24 defaults."
   line (they still echo, as described in
   [Echo](#echo-what-it-means-and-when-it-happens)). From then on, each
   control the engine receives over MIDI posts two lines, e.g. for
   Feedback Level at 64:

   ```
   [SC MIDI IN] Channel: 2 | CC #1 | Val: 64
    -> Feedback Level: 50.4%
   ```
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
5. **Re-evaluating the file at any time replaces the running engine** —
   even while the server is still booting. It tears down the previous
   instance first, so you never end up with two copies fighting over the
   same buffer; an instance replaced mid-boot stops at its next checkpoint
   and frees everything it allocated. The running instance's teardown
   function lives at `Library.at(\cartersDelay, \cleanup)` (the global
   `Library`, not an environment variable, so a pushed ProxySpace can't
   interfere); `Library.at(\cartersDelay, \cleanup).value` stops the
   engine from code.

   **One-time upgrade note:** if an engine started from an older version
   of this file is running, stop it with Cmd-Period before evaluating the
   new one. (The new file also tears such an engine down automatically,
   through the handle older versions left behind, but Cmd-Period is the
   sure way.)
6. `Cmd+Period` (macOS) / `Ctrl+Period` (Windows/Linux) — SuperCollider's
   global "stop" — cleanly shuts the engine down and prints:

   ```
   Carter's Delay stopped (Cmd-Period). Re-evaluate the file to restart.
   ```

   Re-evaluate the file to start it again.

### 3. Run the web demo

1. Open `index.html` in a browser that supports the Web MIDI API (e.g.
   Chrome or Edge), or serve it locally: `python3 -m http.server 8000`, then
   visit `http://localhost:8000`. Use Chrome or Edge: some other
   Chromium-based browsers (Vivaldi, for one) don't deliver the engine's
   SysEx replies, so the scope stays empty. In a browser with no Web MIDI at
   all, the scope says "This browser has no Web MIDI. Use Chrome or Edge."
   Web MIDI exists only on a secure page (localhost, a `file://` path, or
   `https`); opened from any other `http://` address, the scope says "Web
   MIDI needs a secure page: open it from localhost, a file:// path, or
   https. (Chrome or Edge required.)" — a page there can't tell a browser
   with no Web MIDI at all from one that hides it on insecure pages.
2. Grant MIDI access when prompted. The page also asks for the MIDI
   **SysEx** permission, since the scope needs it; if that's denied, the
   page retries without it and keeps working — controls, echo and the
   request all still function — and the scope shows "The scope needs MIDI
   SysEx permission. Allow it in the browser's site settings and reload."
   instead of drawing.
3. Pick your virtual port as the MIDI **output**. A second, compact
   **"Replies from"** select in the header picks the MIDI **input** the page
   listens to for echo and telemetry. At load it uses the input saved last
   time; otherwise the input with the same name as the selected output,
   else the first input whose name contains `IAC`, else `loopMIDI`, else
   the whole word `Bus 1`, else the first input. Changing the output later
   doesn't change it.
   Both selections persist across reloads. As soon as both are set (and
   again whenever either changes), the page sends a request so an
   already-running engine reports its real state immediately, instead of
   waiting for you to touch a control; it retries if no HELLO comes back
   (see [Echo](#echo-what-it-means-and-when-it-happens)). Until the engine
   replies, the controls show the previous session's values from local
   storage, and the log says "Showing last session's values until the
   engine reports its state." The engine's reply then replaces them.
4. The header shows an **engine status** next to the MIDI connection state:
   "Engine running" while anything from the engine — an echo or a telemetry
   packet — has arrived in the last 2 seconds (HEAD, about 5 packets a
   second, is the heartbeat that keeps this current once things are
   going), or "No reply from the engine" otherwise. With SysEx permission
   denied there's no HEAD heartbeat, so the status reads "Engine replying
   (no SysEx)" while echoes are arriving (same 2-second window) and "No
   reply from the engine" otherwise. All of this is independent of the
   MIDI connection state, which only means the browser opened the ports.
5. **Send all values** is a manual resync: it sends every control's current
   value, then the state request `BF 01 7F`, so the engine's reply shows
   what it now has (and brings up the scope if the page missed HELLO).
   While the page can hear the engine you rarely need it: the page adopts
   the engine's state on its own, at boot and in reply to its request — so
   restarting the engine resets the page's controls to the defaults too.
   It matters when replies can't reach the page (no "Replies from" input,
   say, or an ALSA port that isn't wired back) and the engine restarts:
   then this is how you put the page's values back on the engine, as a
   write-only sender would — see
   [Implementing your own sender](#implementing-your-own-sender).
6. **Mute all** silences Passthrough Level, Delay Input Level, Delay Output,
   and Feedback Level in one click, through the same code path as moving
   those controls by hand — so the UI, the log, and local storage all agree,
   and a later Send all values won't un-mute anything behind your back.
7. **Double-click** any slider to reset it to its factory default and send
   that value immediately. **Reset to defaults** does the same for every
   control at once, using the same values the engine boots into — handy when
   old settings restored from local storage don't match what you want.
8. Every control shows the exact MIDI bytes it will send, right next to it,
   even before you touch it — the byte readout flashes when a message
   actually goes out. The MIDI monitor below shows the same bytes as a
   running log, plus a compact line for each incoming echo (e.g. `B9 01 40
   echo Ch 2 CC 1`) and a live counter for telemetry (e.g. "Telemetry: 13
   grains/s, head 5/s") rather than logging every individual grain, head or
   column packet.
9. **The scope draws the engine's real delay buffer**, from its telemetry:
   the waveform is the engine's own recorded peaks, the write head is the
   engine's actual play/record position (dashed and marked "Frozen" when you
   freeze the buffer), and each reported grain draws a short-lived
   rectangle at its real position, duration, pan and amplitude (on macOS
   essentially every grain; on Linux and Windows essentially every one at
   defaults, and the newest ones when the engine thins them; none while the
   MIDI port is falling behind — see "Byte budget" and "Latency" under
   [SysEx telemetry](#sysex-telemetry)). The canvas's
   full width is always the engine's real buffer length — there's nothing
   to configure. Until the engine's HELLO packet arrives, it shows a waiting
   message instead: "Waiting for the engine. Start carters_delay_midi.scd;
   the scope appears when it replies. If it's already running, press Send
   all values." (With SysEx permission denied it shows the SysEx
   message from step 2 instead.) The page makes no sound and takes no audio
   input of its own; the scope is driven entirely by the engine's own
   telemetry.

---

## Tech stack

- **Audio engine:** SuperCollider. `MIDIdef.cc` for control input; `MIDIOut`
  for echoes and the SysEx telemetry (`MIDIOut.write` in 3-byte packets on
  macOS, `MIDIOut.sysex` on Linux and Windows); its own HEAD packets, heard
  back on its MIDI input, to time the port; `SendReply` + `OSCdef` for the
  server-to-language telemetry that becomes SysEx (write head, waveform
  columns, grain triggers); `GrainBuf` for granulation; `MoogFF` for the
  per-tap low-pass; `EnvGen`/`Env.asr` for synth envelopes; `CoinGate`,
  `Impulse`, and `Dust` for the trigger distribution crossfade;
  `LFNoise1`-driven `Ndef`s for the per-tap pan, amplitude, cutoff, and
  resonance modulation; `Limiter` on the master output; `CmdPeriod` for
  teardown. Tempo is a fixed internal constant (`beatDur = 0.5`, i.e. 120
  BPM), used only at boot to derive the per-tap grain durations and
  modulation-LFO rates. The buffer length (256 s, capped at 2^24 frames)
  and the per-tap delays (fixed fractions of the buffer) don't depend on
  the tempo. There is no external clock and no clock sync.
- **Frontend:** HTML5, CSS3, vanilla JavaScript, and the Web MIDI API
  (`navigator.requestMIDIAccess`, with an optional `sysex: true` for the
  scope).
- **Scope:** a canvas visualization of the engine's actual delay buffer —
  waveform, write head, and grains — decoded entirely from the SysEx
  telemetry described in
  [Listening to the engine (optional)](#listening-to-the-engine-optional).
  It draws nothing (and shows a waiting message) until the engine's HELLO
  packet arrives; there is no simulated fallback.

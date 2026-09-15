# Carter's Delay — WebMIDI Edition

A WebMIDI-controlled multi-tap granular delay system based on [Carter's Delay](https://github.com/williamthazard/carters-delay-norns), adapted from monome norns OSC control to standard WebMIDI CC and Note controls.

This project includes:
1. **`carters_delay_midi.scd`**: SuperCollider audio engine script listening to MIDI CCs and Notes.
2. **WebMIDI Control System (`index.html`, `styles.css`, `app.js`)**: Minimal greyscale single-page application demonstrating the MIDI control scheme, displaying live MIDI packet logs, visual 16-tap oscilloscope, and channel breakdown.
3. **In-Browser Web Audio Granular Demo Engine**: Built-in multi-voice sound generator inside the SPA so you can test and audition the controls directly inside your browser with rich ambient chord progressions and live acoustic parameter responses.

---

## MIDI Channel & Control Mapping

The system organizes controls across 3 MIDI Channels to clearly separate primary levels, feedback patch mixing, and granular engine time parameters (with an optional Single-Channel mode toggle in the SPA):

### Channel 1: Primary Routing & Master Output
| CC / Note | Control Target | Type | Data Range | Description |
|-----------|----------------|------|------------|-------------|
| **CC 7** | Master Output Level | Slider | 0..127 (0.0x to 2.5x gain) | Master output gain stage with softclip boost (Default 51 = 1.0x) |
| **CC 1** | Input Passthrough Level | Slider | 0..127 (0.0 to 1.0) | Direct dry volume to output (Default 64 = 50%) |
| **CC 2** | Delay Input Level | Slider | 0..127 (0.0 to 1.0) | Input level recorded into delay buffer (Default 64 = 50%) |
| **CC 3** | Buffer Sound Preservation | Slider | 0..127 (0.0 to 1.0) | Sound-on-sound retention (`preLevel`, Default 64 = 50%) |
| **CC 4 / Note 60** | Passthrough Mute | Toggle | 0 (Off) / 127 (On) | Toggle dry input audio |
| **CC 5 / Note 61** | Delay Input Mute | Toggle | 0 (Off) / 127 (On) | Toggle recording into buffer |
| **CC 6 / Note 62** | Delay Output Mute | Toggle | 0 (Off) / 127 (On) | Master mute toggle for all 16 taps |

### Channel 2: Feedback Loop Patch Mixer
| CC / Note | Control Target | Type | Data Range | Description |
|-----------|----------------|------|------------|-------------|
| **CC 1** | Feedback Level | Slider | 0..127 (0.0 to 1.0) | Level of output fed back into input bus (Default 0 = 0%) |
| **CC 2** | Feedback Balance | Slider | 0..127 (-1.0 to +1.0) | Stereo panning in feedback loop (Default 64 = Center) |
| **CC 3** | Highpass Filter Hz | Slider | 0..127 (0 to 220 Hz) | Low-cut filter frequency (Default 12 Hz) |
| **CC 4** | Pink Noise Level | Slider | 0..127 (0.0 to 1.0) | Injection of noise floor into feedback loop (Default 0 = 0%) |
| **CC 5** | Sine Level | Slider | 0..127 (0.0 to 1.0) | Level of feedback sine oscillator (Default 0 = 0%) |
| **CC 6** | Sine Frequency | Slider | 0..127 (MIDI 20..90 Hz) | Frequency of feedback sine oscillator (Default 30 = 55Hz) |

### Channel 3: Granular Time, Pitch Intervals & Modulation Engine
| CC / Note | Control Target | Type | Data Range | Description |
|-----------|----------------|------|------------|-------------|
| **CC 1** | Playback Rate Multiplier | Slider | 0..127 (0.25x to 2.0x) | Playback speed scale across 16 taps (Default 64 = 1.0x) |
| **CC 2** | Grain Density Multiplier | Slider | 0..127 (0.2x to 3.0x) | Triggering density of granular grains (Default 64 = 1.0x) |
| **CC 3** | Low-Pass Filter Cutoff | Slider | 0..127 (200 to 16000 Hz) | Low-pass filter cutoff on output (Default 100 = 12000Hz) |
| **CC 8 / Note 63** | Buffer Record Freeze | Toggle | 0 (Live Sweep) / 127 (Memory Hold) | Holds current audio in memory by pausing write pointer (Default 0 = Off) |
| **CC 9** | Pitch Octaves Toggle [2:1] | Toggle | 0 (Off) / 127 (On) | Dynamically adds octave interval taps to the playback set |
| **CC 10** | Pitch 5ths & 4ths Toggle [3:2, 4:3] | Toggle | 0 (Off) / 127 (On) | Dynamically adds perfect fifth and fourth harmonic intervals |
| **CC 11** | Pitch Sub-Octaves Toggle [1:2, 1:4] | Toggle | 0 (Off) / 127 (On) | Dynamically adds sub-octave interval taps to the playback set |
| **CC 12** | Reverse Grains Toggle [-1.0x] | Toggle | 0 (Forward) / 127 (Reverse) | Inverts playback direction of grains across all active intervals |
| **CC 4** | Position Jitter / Spread | Slider | 0..127 (0.0 to 2.5s jitter) | Random offset added to grain read pointers (Default 0 = 0.0s) |
| **CC 5** | Trigger Distribution | Slider | 0..127 (0 = Poisson, 127 = Periodic) | 0% = Dust (Poisson) • 100% = Impulse (Periodic, Default 127) |
| **CC 6** | Grain Window Function | Slider | 0..127 (3 window shapes) | 0: Hanning 2-sided Bell (Default), 1: Decaying Percussive Saw, 2: Reverse Attack Swell |

---

## Quick Start Guide

### 1. Setup Virtual MIDI Routing

To route WebMIDI from your web browser to SuperCollider:

- **macOS**:
  1. Open **Audio MIDI Setup** app.
  2. Press `Cmd + 2` to show the **MIDI Studio**.
  3. Double-click **IAC Driver** and check **"Device is online"**.
  4. Ensure at least one bus (e.g. `Bus 1`) is present and click **Apply**.

- **Windows**:
  1. Download and install a free virtual MIDI driver such as [loopMIDI](https://www.tobias-erichsen.de/software/loopmidi.html).
  2. Create a virtual port (e.g., `loopMIDI Port`).

---

### 2. Run SuperCollider Engine

1. Launch **SuperCollider IDE**.
2. Open `carters_delay_midi.scd`.
3. Select all code (`Cmd + A`) and evaluate (`Cmd + Enter`).
4. SuperCollider will connect to CoreMIDI, boot the server, allocate the buffer, start the 16 granular synths and feedback patch, and print:
   ```supercollider
   === CoreMIDI Connected ===
     [MIDI Src 0] Bus 1 (IAC Driver)
   === Loading Carter's Delay Soundscape Engine... ===
   === Carter's Delay Ready & Listening to WebMIDI! ===
   ```

---

### 3. Open the WebMIDI SPA Demo

1. Open `index.html` in Google Chrome (or serve locally via `python3 -m http.server 8000`).
2. In the top bar, select your **MIDI Output Device** (e.g. `IAC Driver Bus 1` or `loopMIDI Port`).
3. Move the sliders or click Mute buttons:
   - Check the **WebMIDI Live Monitor Log** to watch outgoing MIDI packets.
   - Watch the **Delay Engine Scope** render the 16 taps and record pointer in real time.
   - **Double-click any slider** to reset it back to its factory default position.
4. Click **"Microphone: OFF"** in the header to turn **ON** live mic recording (speak or make sound to watch your live voice waveform record into the scope buffer), or click **"Browser Audio Synth: OFF"** to turn on the built-in ambient synth!

---

## Tech Stack & Architecture

- **Audio Engine**: SuperCollider (`SynthDef`, `GrainBuf`, `Phasor`, `LinkClock`, `MoogFF`, `Balance2`, `InFeedback`, `MIDIIn`, `MIDIFunc`).
- **Frontend SPA**: HTML5, CSS3 (Minimal Greyscale Technical Theme), Vanilla JavaScript (Web MIDI API).
- **Web Audio API**: Browser fallback granular synth engine with multi-voice detuned oscillators, ambient chord progression, and 16-tap Web Audio delay network.
- **Canvas Visualizer**: HTML5 Canvas vector scope featuring a single combined view where the recorded audio waveform & REC head span the background, and 16 grain slice rectangles float directly over the waveform with vertical Pan LFO movement (Up = Left / Down = Right) and internal playheads scanning at individual playback rates (`rate`).

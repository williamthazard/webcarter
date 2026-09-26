/*
   Carter's Delay - WebMIDI Controlled Version
   Based on Carter's Delay by William Hazard.

   The engine is CC-only (no MIDI Notes). It listens on ALL connected MIDI
   inputs. Sending controls is receive-only, but the engine also talks back:
   see "Bidirectional MIDI" below and README.md for the full protocol a
   frontend can rely on.

   Toggles: 0 = off, any value > 0 = on (senders should send 127 for on).
   Status bytes are 0xB0 (Ch1) .. 0xB2 (Ch3); in SC, `chan` arrives 0-based
   (0, 1, 2). Anything not listed below is ignored.

   ---------------------------------------------------------------------
   CHANNEL 1 -- Levels & Routing

     CC | Name                               | Mapping                              | Default v | Default value
     --|------------------------------------|--------------------------------------|-----------|-----------------------
     1  | Input Passthrough Level            | v/127 (linear amp)                   | 64        | 0.504
     2  | Delay Input Level                  | v/127                                | 64        | 0.504
     3  | Buffer Preservation (rec preLevel) | v/127                                | 64        | 0.504
     4  | Input Passthrough On               | 0 = muted, >0 = on (audible)         | 127       | on
     5  | Delay Input On                     | 0 = muted, >0 = on                   | 127       | on
     6  | Delay Output On (all 16 taps)      | 0 = muted, >0 = on                   | 127       | on
     7  | Master Output Level                | v/51 (gain x), into a Limiter at 1.0 | 51        | 1.0x (max 127 -> 2.49x)

   CHANNEL 2 -- Feedback Patch

     CC | Name                | Mapping                                                  | Default v | Default value
     ---|---------------------|----------------------------------------------------------|-----------|---------------
     1  | Feedback Level      | v/127                                                     | 0         | 0
     2  | Feedback Balance    | v<=64: (v-64)/64 ; v>64: (v-64)/63  -> -1..+1              | 64        | 0.0 exactly
     3  | Feedback High-Pass  | v/127 * 220 Hz                                            | 7         | 12.13 Hz
     4  | Pink Noise Level    | v/127                                                     | 0         | 0
     5  | Sine Level          | v/127                                                     | 0         | 0
     6  | Sine Frequency      | note = round(20 + v*70/127); Hz = 440*2^((note-69)/12)     | 24        | note 33 = 55.00 Hz
        |                     | (= SC .midicps)                                            |           |

   CHANNEL 3 -- Granular Engine

     CC | Name                     | Mapping                                                        | Default v | Default value
     ---|--------------------------|----------------------------------------------------------------|-----------|---------------
     1  | Playback Rate Multiplier | v<=64: 0.25*4^(v/64) ; v>64: 2^((v-64)/63)                      | 64        | 1.0x (0->0.25, 32->0.5, 127->2.0)
     2  | Grain Density Multiplier | v<=64: 0.2*5^(v/64) ; v>64: 3^((v-64)/63)                       | 64        | 1.0x (0->0.2, 127->3.0)
     3  | Low-Pass Cutoff Ceiling  | 200*80^(v/127) Hz (= SC linexp(0,127,200,16000))                | 127       | 16000 Hz = no cap
        |                          | (the per-tap LFOs sweep 500-15000 Hz underneath this ceiling)   |           |
     4  | Position Jitter          | max random extra delay = (v/127)*2.5 s                          | 0         | 0 s
     5  | Trigger Distribution     | p = v/127 = probability each periodic (Impulse) trigger fires;  | 127       | fully periodic
        |                          | 1-p = probability each random (Dust) trigger fires. Average     |           |
        |                          | density stays constant.                                         |           |
     6  | Grain Window             | v 0-42 Hann; 43-85 Percussive; 86-127 Reverse Swell             | 0         | Hann
     8  | Buffer Freeze            | >0 frozen (recording paused, write head held still); 0 live     | 0         | live
     9  | Octaves toggle           | >0 on                                                           | 0         | off
     10 | Fifths & Fourths toggle  | >0 on                                                           | 0         | off
     11 | Sub-octaves toggle       | >0 on                                                           | 0         | off
     12 | Reverse toggle           | >0 on                                                           | 0         | off

   Tap-rate allocation (behaviour unchanged from the original, now documented
   and used at startup too, via the same `computeTapRates` function that CC
   changes use -- this fixes the old bug where the first rate/toggle CC
   re-pitched taps 8-15):
     - Taps 0-7 use base rates [1/4, 1/2, 1, 3/2, 2, 1/4, 1/2, 1]
       (baseCarterRates[i % 5]).
     - Taps 8-15 cycle through a pool, pool[(i-8) % pool.size], built in
       this order: Octaves adds [2, 1, 2]; Fifths & Fourths adds
       [3/2, 4/3, 9/8]; Sub-octaves adds [1/4, 1/2, 1/2]. If no toggle is
       on, the pool is [1/4, 1/2, 1, 3/2, 2].
     - Reverse on: odd taps (1, 3, ..., 15) get a negative rate of the same
       magnitude; even taps stay forward. Reverse off: all taps positive.
     - Final per-tap rate = poolRate * rateMult.
     - Per-tap density: dens_i = densMult / (durs[i] * abs(finalRate_i)),
       recomputed whenever rates, rateMult or densMult change.

   Lifecycle: re-evaluating this file replaces the running engine instead of
   duplicating it (it tears down any previous instance first). Cmd-Period
   stops the engine cleanly; re-evaluate the file to restart it.
   ---------------------------------------------------------------------
   Bidirectional MIDI (one virtual port, split by channel -- see README.md
   for the full channel map, byte-level packet tables and loop-safety notes):

     - Echo: every control this engine actually applies -- from a live CC
       message or from applyDefaults at boot -- is echoed back out on
       channel + 8 (e.g. a Ch1 CC sent here echoes on Ch9), same CC number,
       same normalised value (toggles as 127/0, sliders as received). A
       page listening on the echo channels always sees SC's real state.
     - Request: Ch16 CC1 with value > 0 (status 0xBF, i.e. `chan` arrives
       15) asks SC to resend HELLO, then the 24 current-value echoes (the
       "bang"), then a HEAD packet and a full waveform DUMP.
     - SysEx telemetry: packets `F0 7D 43 <type> ... F7` report HELLO (at
       boot and in a request reply), HEAD (write-head position, 20 Hz),
       GRAIN (one per grain trigger) and COLUMN/DUMP (the recorded-buffer
       waveform, for a scope UI). See README.md, "Listening to the engine",
       for the exact byte layout of every packet type.
     - Everything on the shared bus is heard by everyone; this engine acts
       only on Ch1-3 CCs and the Ch16 CC1 request, and silently ignores
       everything else (its own echoes, SysEx, other channels) with no
       per-message logging for ignored input.
   ---------------------------------------------------------------------
*/

(
var micGrp, ptrGrp, recGrp, granGrp, outGrp;
var micBus, ptrBus, granBus;
var b, envBufs;
var micSynth, micPassSynth, ptrSynth, recSynth, fbSynth, masterOutSynth, granSynths;
var panLFOs, ampLFOs, cutoffLFOs, resonanceLFOs;
var baseCarterRates, durs, delays;
var beatDur = 0.5; // fixed tempo: 120 BPM (the original tempo). LinkClock removed.
var passLevel = (64 / 127), delayInLevel = (64 / 127), preserveLevel = (64 / 127);
var masterVol = 1.0, densMult = 1.0, rateMult = 1.0, cutoffMax = 16000;
var passOn = 1, delayInOn = 1, delayOutOn = 1, freezeOn = 0;
var octavesOn = 0, fifthsOn = 0, suboctavesOn = 0, reverseOn = 0;
var ccToMult, ccToBipolar, ccToSineHz, ccToWindowIndex;
var computeTapRates, applyTapRates, handleCC, applyDefaults, cleanup;
var defaultCCs, handledCCs;
var cmdPeriodFunc;

// --- Bidirectional MIDI state (BIDI_SPEC) -----------------------------
// One virtual port, both directions, split by channel. See the header
// comment above and README.md for the full protocol.
var midiPortMatch, midiOut;
var numCols = 1024, numTaps = 16, protocolVersion = 1;
var bufferFrames, sampleRateHz, colPeaks, lastHeadPos = 0, ccState;
var u14, u21, u28, u7, sysexPacket;
var echoCC, sendHello, sendBang, sendHeadPacket, sendDump, reportAll;
var handleHeadOSC, handleColOSC, handleGranOSC;

// Re-evaluating this file replaces any already-running instance instead of
// duplicating it.
~cartersDelayCleanup !? { ~cartersDelayCleanup.value(true) };

// Connect to CoreMIDI (this also initialises MIDIClient).
MIDIIn.connectAll;

"=== MIDI sources ===".postln;
MIDIClient.sources.do({ |src, idx|
	(" [MIDI Src " ++ idx ++ "] " ++ src.name ++ " (" ++ src.device ++ ")").postln;
});

// Configure Server memory
s.options.memSize = 2.pow(20);

// Base Carter's Delay rates (Forward by default)
baseCarterRates = [1/4, 1/2, 1, 3/2, 2];

// One virtual MIDI port, both directions, separated by channel (BIDI_SPEC
// §3). Match by "<device> <name>" so this works whether MIDIClient reports
// the IAC bus as one endpoint or two words. If nothing matches, midiOut
// stays nil and every echo/telemetry send below becomes a silent no-op --
// controls sent TO the engine keep working either way.
midiPortMatch = ["IAC Driver Bus 1", "loopMIDI"];
{
	var idx = MIDIClient.destinations.detectIndex({ |ep, i|
		midiPortMatch.any({ |m| (ep.device ++ " " ++ ep.name).contains(m) })
	});
	if (idx.notNil) {
		midiOut = MIDIOut(idx);
		midiOut.latency = 0; // the 0.2s default would delay every echo/CC send
		("Connected MIDI output for echo/telemetry: " ++ MIDIClient.destinations[idx].device
			++ " " ++ MIDIClient.destinations[idx].name ++ " (destination " ++ idx ++ ")").postln;
	} {
		midiOut = nil;
		("WARNING: no MIDI output port matched midiPortMatch " ++ midiPortMatch
			++ ". Echo and SysEx telemetry are disabled (every send is a no-op) -- "
			++ "controls sent TO the engine still work.").postln;
	};
	// NOTE (Linux/ALSA only): unlike CoreMIDI (macOS) and PortMIDI (Windows/
	// loopMIDI), ALSA does not auto-route a MIDIOut to its destination --
	// connect it explicitly (e.g. via `aconnect`) after this point. macOS
	// and Windows need no extra step and are the primary targets here.
}.value;

// colPeaks is reset to 0 every time the engine (re)starts; numCols is the
// scope's column resolution (BIDI_SPEC §3/§4).
colPeaks = Array.fill(numCols, 0);

// ccState[chan0][cc] = the last value SC echoed for that control (raw for
// sliders, normalised 127/0 for toggles). Used to answer a request with
// the CURRENT values, not the defaults.
ccState = Array.fill(3, { Dictionary.new });

// ---------------------------------------------------------------------
// Helpers (top level, outside s.waitForBoot, so they're mock-testable
// without a running server).
// ---------------------------------------------------------------------

// Two-segment exponential curve, exactly 1.0x at v==64 and exact endpoints
// at v==0 (-> lo) and v==127 (-> hi).
ccToMult = { |v, lo, hi| if(v <= 64, { lo * ((1 / lo) ** (v / 64)) }, { hi ** ((v - 64) / 63) }) };

// Two-segment bipolar curve, exactly 0.0 at v==64 and exact endpoints of
// -1..+1 at v==0/127.
ccToBipolar = { |v| if(v <= 64, { (v - 64) / 64 }, { (v - 64) / 63 }) };

// note = round(20 + v*70/127); Hz via .midicps (== 440*2^((note-69)/12)).
ccToSineHz = { |v|
	var note = ((v * 70 / 127) + 20).round;
	note.midicps;
};

// Explicit thresholds: 0 = Hann (v<43), 1 = Percussive (v<86), 2 = Reverse Swell.
ccToWindowIndex = { |v|
	case
	{ v < 43 } { 0 }
	{ v < 86 } { 1 }
	{ 2 };
};

// Returns an array of 16 final per-tap rates (pool assignment, reverse
// sign, and rateMult all applied). The SAME function is used to compute
// the startup rates at boot time, so taps 8-15 are never re-pitched by
// the first rate/toggle CC the way the old code did.
computeTapRates = {
	var pool = List.new;
	var finalRates = Array.newClear(16);
	if (octavesOn > 0) { pool.addAll([2, 1, 2]) };
	if (fifthsOn > 0) { pool.addAll([3/2, 4/3, 9/8]) };
	if (suboctavesOn > 0) { pool.addAll([1/4, 1/2, 1/2]) };
	if (pool.size == 0) { pool.addAll([1/4, 1/2, 1, 3/2, 2]) };
	16.do({ |i|
		var base = if (i < 8) { baseCarterRates[i % baseCarterRates.size] } { pool[(i - 8) % pool.size] };
		var signed = if (reverseOn > 0 and: { i.odd }) { base.neg } { base };
		finalRates[i] = signed * rateMult;
	});
	finalRates;
};

// Recomputes tap rates and sets \rate and \dens on all 16 already-created
// gran synths. Called whenever rateMult, densMult, or any of the pool
// toggles change.
applyTapRates = {
	var finalRates = computeTapRates.value;
	granSynths.do({ |g, i|
		var dens = densMult / (durs[i] * finalRates[i].abs);
		g.set(\rate, finalRates[i], \dens, dens);
	});
};

// ---------------------------------------------------------------------
// SysEx encoding helpers (BIDI_SPEC §3/§4). Every payload byte is 0-127;
// every value is clamped into range before packing. u14/u21/u28 are
// MSB-first big-endian, 7 bits per byte; u7 is a single clamped byte, for
// every payload field the §4 table marks "u7" (version, numTaps, tap, ...).
// ---------------------------------------------------------------------
u14 = { |v|
	var iv = v.round.asInteger.clip(0, 16383);
	[(iv >> 7) & 127, iv & 127];
};
u21 = { |v|
	var iv = v.round.asInteger.clip(0, 2097151);
	[(iv >> 14) & 127, (iv >> 7) & 127, iv & 127];
};
u28 = { |v|
	var iv = v.round.asInteger.clip(0, 268435455);
	[(iv >> 21) & 127, (iv >> 14) & 127, (iv >> 7) & 127, iv & 127];
};
u7 = { |v| v.round.asInteger.clip(0, 127) };
sysexPacket = { |type, bytes| Int8Array.newFrom([0xF0, 0x7D, 0x43, type] ++ bytes ++ [0xF7]) };

// One defaults table drives both the engine's own boot state and the web
// demo's "Send all values". Matches the CC contract above exactly, in this
// order. Also doubles as the exact §2 request-reply "bang" order and, via
// handledCCs below, as the set of CCs handleCC actually acts on.
defaultCCs = [
	[1,7,51],[1,1,64],[1,2,64],[1,3,64],[1,4,127],[1,5,127],[1,6,127],
	[2,1,0],[2,2,64],[2,3,7],[2,4,0],[2,5,0],[2,6,24],
	[3,1,64],[3,2,64],[3,3,127],[3,4,0],[3,5,127],[3,6,0],[3,8,0],[3,9,0],[3,10,0],[3,11,0],[3,12,0]
];

// [chan0, cc] pairs handleCC actually acts on, derived from defaultCCs.
// Used only to decide whether to print the raw "[SC MIDI IN]" line --
// handleCC must post nothing at all for a CC it doesn't handle.
handledCCs = defaultCCs.collect({ |entry| [entry[0] - 1, entry[1]] });

// Echoes one applied control back out on channel+8 (BIDI_SPEC §2) and
// records it in ccState so a later request can resend the CURRENT value.
// `v` must already be the value to echo: raw for sliders, 127/0 for
// toggles. A nil midiOut makes this a silent no-op.
echoCC = { |chan, cc, v|
	ccState[chan][cc] = v;
	midiOut !? { midiOut.control(chan + 8, cc, v) };
};

// Unified CC handler. chan is 0-based (0, 1, 2 = Ch1, Ch2, Ch3).
handleCC = { |chan, num, val|
	var chNum = chan + 1;

	if (handledCCs.includesEqual([chan, num])) {
		("[SC MIDI IN] Channel: " ++ chNum ++ " | CC #" ++ num ++ " | Val: " ++ val).postln;
	};

	if (chan == 0) {
		case
		{ num == 1 } {
			passLevel = val / 127;
			micPassSynth.set(\amp, passLevel * passOn);
			echoCC.(0, 1, val);
			(" -> Input Passthrough Level: " ++ (passLevel * 100).round(0.1) ++ "%").postln;
		}
		{ num == 2 } {
			delayInLevel = val / 127;
			micSynth.set(\amp, delayInLevel * delayInOn);
			echoCC.(0, 2, val);
			(" -> Delay Input Level: " ++ (delayInLevel * 100).round(0.1) ++ "%").postln;
		}
		{ num == 3 } {
			preserveLevel = val / 127;
			recSynth.set(\preLevel, preserveLevel);
			echoCC.(0, 3, val);
			(" -> Buffer Preservation: " ++ (preserveLevel * 100).round(0.1) ++ "%").postln;
		}
		{ num == 4 } {
			passOn = if (val > 0) { 1 } { 0 };
			micPassSynth.set(\amp, passLevel * passOn);
			echoCC.(0, 4, passOn * 127);
			(" -> Input Passthrough: " ++ if (passOn > 0) { "ON" } { "MUTED" }).postln;
		}
		{ num == 5 } {
			delayInOn = if (val > 0) { 1 } { 0 };
			micSynth.set(\amp, delayInLevel * delayInOn);
			echoCC.(0, 5, delayInOn * 127);
			(" -> Delay Input: " ++ if (delayInOn > 0) { "ON" } { "MUTED" }).postln;
		}
		{ num == 6 } {
			delayOutOn = if (val > 0) { 1 } { 0 };
			granSynths.do({ |g, idx|
				g.set(\amp, if (delayOutOn > 0) { ampLFOs[idx] } { 0 });
			});
			echoCC.(0, 6, delayOutOn * 127);
			(" -> Delay Output: " ++ if (delayOutOn > 0) { "ON" } { "MUTED" }).postln;
		}
		{ num == 7 } {
			masterVol = val / 51;
			masterOutSynth.set(\amp, masterVol);
			echoCC.(0, 7, val);
			(" -> Master Output Level: " ++ masterVol.round(0.001) ++ "x").postln;
		};
	};

	if (chan == 1) {
		case
		{ num == 1 } {
			var amp = val / 127;
			fbSynth.set(\amp, amp);
			echoCC.(1, 1, val);
			(" -> Feedback Level: " ++ (amp * 100).round(0.1) ++ "%").postln;
		}
		{ num == 2 } {
			var bal = ccToBipolar.(val);
			fbSynth.set(\balance, bal);
			echoCC.(1, 2, val);
			(" -> Feedback Balance: " ++ bal.round(0.0001)).postln;
		}
		{ num == 3 } {
			var hp = (val / 127) * 220;
			fbSynth.set(\hpFreq, hp);
			echoCC.(1, 3, val);
			(" -> Feedback High-Pass: " ++ hp.round(0.001) ++ " Hz").postln;
		}
		{ num == 4 } {
			var nAmp = val / 127;
			fbSynth.set(\noiseLevel, nAmp);
			echoCC.(1, 4, val);
			(" -> Pink Noise Level: " ++ (nAmp * 100).round(0.1) ++ "%").postln;
		}
		{ num == 5 } {
			var sAmp = val / 127;
			fbSynth.set(\sineLevel, sAmp);
			echoCC.(1, 5, val);
			(" -> Sine Level: " ++ (sAmp * 100).round(0.1) ++ "%").postln;
		}
		{ num == 6 } {
			var hz = ccToSineHz.(val);
			fbSynth.set(\sineHz, hz);
			echoCC.(1, 6, val);
			(" -> Sine Frequency: " ++ hz.round(0.01) ++ " Hz").postln;
		};
	};

	if (chan == 2) {
		case
		{ num == 1 } {
			rateMult = ccToMult.(val, 0.25, 2);
			applyTapRates.value;
			echoCC.(2, 1, val);
			(" -> Playback Rate Multiplier: " ++ rateMult.round(0.0001) ++ "x").postln;
		}
		{ num == 2 } {
			densMult = ccToMult.(val, 0.2, 3);
			applyTapRates.value;
			echoCC.(2, 2, val);
			(" -> Grain Density Multiplier: " ++ densMult.round(0.0001) ++ "x").postln;
		}
		{ num == 3 } {
			cutoffMax = val.linexp(0, 127, 200, 16000);
			granSynths.do({ |g| g.set(\cutoffMax, cutoffMax) });
			echoCC.(2, 3, val);
			(" -> Low-Pass Cutoff Ceiling: " ++ cutoffMax.round(0.1) ++ " Hz").postln;
		}
		{ num == 4 } {
			var jitterSecs = (val / 127) * 2.5;
			var jitterSamples = s.sampleRate * jitterSecs;
			granSynths.do({ |g| g.set(\ptrRandSamples, jitterSamples) });
			echoCC.(2, 4, val);
			(" -> Position Jitter: " ++ jitterSecs.round(0.001) ++ " s").postln;
		}
		{ num == 5 } {
			var sync = val / 127;
			granSynths.do({ |g| g.set(\sync, sync) });
			echoCC.(2, 5, val);
			(" -> Trigger Distribution: " ++ (sync * 100).round(1) ++ "% periodic").postln;
		}
		{ num == 6 } {
			var idx = ccToWindowIndex.(val);
			var targetBuf = if (idx == 0) { -1 } { envBufs[idx - 1].bufnum };
			granSynths.do({ |g| g.set(\grainEnv, targetBuf) });
			echoCC.(2, 6, val);
			(" -> Grain Window: " ++ ["Hann", "Percussive", "Reverse Swell"][idx]).postln;
		}
		{ num == 8 } {
			freezeOn = if (val > 0) { 1 } { 0 };
			if (freezeOn > 0) {
				ptrSynth.set(\rate, 0);
				recSynth.run(false);
				" -> Buffer Freeze: FROZEN".postln;
			} {
				ptrSynth.set(\rate, 1);
				recSynth.run(true);
				" -> Buffer Freeze: LIVE".postln;
			};
			echoCC.(2, 8, freezeOn * 127);
		}
		{ num == 9 } {
			octavesOn = if (val > 0) { 1 } { 0 };
			applyTapRates.value;
			echoCC.(2, 9, octavesOn * 127);
			(" -> Octaves: " ++ if (octavesOn > 0) { "ON" } { "OFF" }).postln;
		}
		{ num == 10 } {
			fifthsOn = if (val > 0) { 1 } { 0 };
			applyTapRates.value;
			echoCC.(2, 10, fifthsOn * 127);
			(" -> Fifths & Fourths: " ++ if (fifthsOn > 0) { "ON" } { "OFF" }).postln;
		}
		{ num == 11 } {
			suboctavesOn = if (val > 0) { 1 } { 0 };
			applyTapRates.value;
			echoCC.(2, 11, suboctavesOn * 127);
			(" -> Sub-octaves: " ++ if (suboctavesOn > 0) { "ON" } { "OFF" }).postln;
		}
		{ num == 12 } {
			reverseOn = if (val > 0) { 1 } { 0 };
			applyTapRates.value;
			echoCC.(2, 12, reverseOn * 127);
			(" -> Reverse: " ++ if (reverseOn > 0) { "ON" } { "OFF" }).postln;
		};
	};
};

// Runs at the end of boot, after all synths exist, so the engine's startup
// state equals the demo's "Send all values" applied at defaults. Each call
// below also echoes (BIDI_SPEC §2's boot "bang"), via handleCC -> echoCC.
applyDefaults = {
	defaultCCs.do({ |entry|
		handleCC.(entry[0] - 1, entry[1], entry[2]);
	});
};

// ---------------------------------------------------------------------
// Server -> language telemetry (BIDI_SPEC §3/§4). These helpers only
// build and send SysEx; the OSCdef handlers below feed them from the
// server's SendReply messages (or, for reportAll, from cached state), and
// every send is a no-op when midiOut is nil.
// ---------------------------------------------------------------------

// HELLO: sent once at boot (once the buffer exists, before applyDefaults)
// and first in every request reply.
sendHello = {
	var payload = [u7.(protocolVersion)] ++ u28.(bufferFrames) ++ u21.(sampleRateHz) ++ u14.(numCols) ++ [u7.(numTaps)];
	midiOut !? { midiOut.sysex(sysexPacket.(1, payload)) };
};

// The 24 echoes of the CURRENT values, in defaultCCs order -- the boot
// "bang" is these same echoes as a side effect of applyDefaults; this is
// the on-demand version for a request reply, sent from ccState directly
// (no need to re-run handleCC's DSP .set calls just to report state).
sendBang = {
	defaultCCs.do({ |entry|
		var chan0 = entry[0] - 1;
		var cc = entry[1];
		var v = ccState[chan0][cc] ?? entry[2];
		echoCC.(chan0, cc, v);
	});
};

// Builds and sends one HEAD packet from the most recently received write-
// head position (lastHeadPos, updated by handleHeadOSC at 20 Hz) and the
// language-side freezeOn flag -- shared by the periodic 20 Hz send and by
// reportAll's on-demand HEAD.
sendHeadPacket = {
	var pos14 = (lastHeadPos * 16384).round.asInteger.clip(0, 16383);
	var frozenByte = if (freezeOn > 0) { 1 } { 0 };
	midiOut !? { midiOut.sysex(sysexPacket.(2, u14.(pos14) ++ [frozenByte])) };
};

// The whole colPeaks cache, chunked into DUMP packets of at most 256
// columns each (§4: "count u14 (<= 256)").
sendDump = {
	var chunk = 256;
	var numChunks = (numCols / chunk).ceil.asInteger;
	numChunks.do({ |ci|
		var startCol = ci * chunk;
		var count = min(chunk, numCols - startCol);
		var bytes = u14.(startCol) ++ u14.(count) ++ colPeaks[startCol..(startCol + count - 1)];
		midiOut !? { midiOut.sysex(sysexPacket.(5, bytes)) };
	});
};

// The Ch16 CC1 request reply, in the exact §2 order: HELLO, the 24
// current-value echoes, HEAD, then the waveform DUMP.
reportAll = {
	sendHello.value;
	sendBang.value;
	sendHeadPacket.value;
	sendDump.value;
};

// OSCdef handlers for the three SendReply paths (BIDI_SPEC §3). Each is a
// plain top-level Function -- fed a synthetic msg array (as OSCdef would
// pass one: [path, nodeID, replyID, ...values]) they run and can be
// checked without any server or OSCdef registration.

// From \ptr's SendReply.ar('/cd_head', [normalisedPos]) at 20 Hz.
// Frozen state is NOT in the message -- it comes from freezeOn here.
handleHeadOSC = { |msg|
	lastHeadPos = msg[3];
	sendHeadPacket.value;
};

// From \rec's SendReply.ar('/cd_col', [Delay1.ar(col), Delay1.ar(peak)]).
// Peak resets to the current value on Changed.ar's trigger, so the Delay1
// pair reports the column that just finished, not the one just starting
// (see the SynthDef comment below for the full reasoning). Updates the
// colPeaks cache SC keeps for DUMP, then sends the COLUMN packet.
handleColOSC = { |msg|
	var col = msg[3].round.asInteger;
	var peak = msg[4];
	var peakEnc = (peak.clip(0, 1) * 127).round.asInteger.clip(0, 127);
	if (col >= 0 and: { col < numCols }) {
		colPeaks[col] = peakEnc;
	};
	midiOut !? { midiOut.sysex(sysexPacket.(4, u14.(col) ++ [peakEnc])) };
};

// From \gran's SendReply.ar('/cd_gran', [posWrapped, durCtrl, rateCtrl,
// panCtrl, amp], tap) -- tap is the replyID, so it arrives as msg[2].
handleGranOSC = { |msg|
	var tap = u7.(msg[2]);
	var posWrapped = msg[3];
	var durSecs = msg[4];
	var rate = msg[5];
	var pan = msg[6];
	var amp = msg[7];
	var pos14 = (posWrapped * 16384).round.asInteger.clip(0, 16383);
	var durMs = (durSecs * 1000).round.asInteger.clip(0, 16383);
	var rateEnc = ((rate.clip(-4, 4) * 2048) + 8192).round.asInteger.clip(0, 16383);
	var panEnc = (((pan.clip(-1, 1) + 1) / 2) * 127).round.asInteger.clip(0, 127);
	var ampEnc = ((amp.clip(0, 3) / 3) * 127).round.asInteger.clip(0, 127);
	var payload = [tap] ++ u14.(pos14) ++ u14.(durMs) ++ u14.(rateEnc) ++ [panEnc] ++ [ampEnc];
	midiOut !? { midiOut.sysex(sysexPacket.(3, payload)) };
};

// Tears down this engine instance. `freeNodes` is false when called from
// Cmd-Period (which already freed all synths/groups on the server itself).
// Guarded against nil throughout, since this can run before boot finished.
cleanup = { |freeNodes = true|
	MIDIdef(\cartersDelayCC).free;
	OSCdef(\cd_headOSC).free;
	OSCdef(\cd_colOSC).free;
	OSCdef(\cd_granOSC).free;
	CmdPeriod.remove(cmdPeriodFunc);
	if (freeNodes) {
		micGrp !? { micGrp.free };
		ptrGrp !? { ptrGrp.free };
		recGrp !? { recGrp.free };
		granGrp !? { granGrp.free };
		outGrp !? { outGrp.free };
	};
	panLFOs !? { panLFOs.do({ |nd| nd.clear }) };
	ampLFOs !? { ampLFOs.do({ |nd| nd.clear }) };
	cutoffLFOs !? { cutoffLFOs.do({ |nd| nd.clear }) };
	resonanceLFOs !? { resonanceLFOs.do({ |nd| nd.clear }) };
	b !? { b.free };
	envBufs !? { envBufs.do({ |buf| buf.free }) };
	micBus !? { micBus.free };
	ptrBus !? { ptrBus.free };
	granBus !? { granBus.free };
	~cartersDelayCleanup = nil;
};
~cartersDelayCleanup = cleanup;

s.waitForBoot({
	Routine({
		"=== Carter's Delay: loading engine... ===".postln;

		// Custom Grain Envelope Windows (512-sample buffers)
		envBufs = [
			Buffer.sendCollection(s, Env.perc(0.01, 0.99, 1, -4).asSignal(512)),
			Buffer.sendCollection(s, Env.new([0, 1, 0], [0.98, 0.02], [4, -4]).asSignal(512))
		];

		b = Buffer.alloc(s, s.sampleRate * (beatDur * 512), 1);
		s.sync;

		// The buffer now exists: send HELLO (BIDI_SPEC §2's boot order is
		// HELLO, then applyDefaults's bang, then the MIDIdef).
		bufferFrames = b.numFrames;
		sampleRateHz = s.sampleRate;
		sendHello.value;

		micBus  = Bus.audio(s, 1);
		ptrBus  = Bus.audio(s, 1);
		granBus = Bus.audio(s, 2);

		SynthDef(\mic, {
			arg in = 0, out = 0, amp = 1;
			var sig = SoundIn.ar(in) * amp;
			Out.ar(out, sig);
		}).add;

		SynthDef(\micOut, {
			arg in = 0, out = 0, amp = 1;
			var sig = SoundIn.ar(in) * amp;
			Out.ar(out, sig!2);
		}).add;

		// Master Output with Limiter for transparent peak control.
		// masterVol (Ch1 CC7) scales the signal BEFORE the Limiter.
		SynthDef(\masterOutput, {
			arg in = 0, out = 0, amp = 1.0;
			var sig = In.ar(in, 2);
			sig = Limiter.ar(sig * amp, 1.0, 0.01);
			Out.ar(out, sig);
		}).add;

		// Adds the HEAD telemetry: normalised write-head position, reported
		// at a fixed 20 Hz regardless of `rate` (freeze sets rate to 0, so
		// the position simply stops changing -- no extra freeze-awareness
		// needed here; the frozen bit itself comes from the language side,
		// see handleHeadOSC).
		SynthDef(\ptr, {
			arg out = 0, buf = 0, rate = 1;
			var sig = Phasor.ar(0, BufRateScale.kr(buf) * rate, 0, BufFrames.kr(buf));
			var headTrig = Impulse.ar(20);
			var normPos = sig / BufFrames.kr(buf);
			SendReply.ar(headTrig, '/cd_head', [normPos]);
			Out.ar(out, sig);
		}).add;

		// Adds the COLUMN telemetry. `col` is the write head's current
		// column (0..numCols-1). trig = Changed.ar(col) fires exactly on the
		// audio sample where col FIRST becomes the new column's index -- so
		// at that very sample, `col` itself already reads as the NEW column,
		// not the one that just finished. Peak.ar(sig.abs, trig) resets its
		// own running peak "to the current value" on that same sample too
		// (per Peak's help doc), so reading `col`/Peak's raw output AT the
		// trigger sample would pair the NEW column's index with a peak
		// already contaminated by the reset. Delay1.ar on both rewinds them
		// by exactly one sample, to the LAST sample of the column that just
		// finished -- still the old column's index, and Peak's running max
		// through that final sample, i.e. the OLD column's true, complete
		// peak, taken the instant before its own reset takes effect. Nothing
		// is reported while frozen because recSynth.run(false) stops this
		// whole synth (and hence Changed/Peak/SendReply) from running at all.
		SynthDef(\rec, {
			arg ptrIn = 0, micIn = 0, buf = 0, preLevel = 0.5;
			var ptr = In.ar(ptrIn, 1);
			var sig = In.ar(micIn, 1);
			var col, trig, pk;
			sig = sig + (BufRd.ar(1, buf, ptr) * preLevel);
			BufWr.ar(sig, buf, ptr);
			col = (ptr / BufFrames.kr(buf) * numCols).floor;
			trig = Changed.ar(col);
			pk = Peak.ar(sig.abs, trig);
			SendReply.ar(trig, '/cd_col', [Delay1.ar(col), Delay1.ar(pk)]);
		}).add;

		SynthDef(\fbPatchMix, {
			arg in = 0, out = 0, amp = 0, balance = 0, hpFreq = 12,
			noiseLevel = 0.0, sineLevel = 0, sineHz = 55;
			var input = InFeedback.ar(in, 2);
			var output = Balance2.ar(input[0], input[1], balance);
			output = output + (PinkNoise.ar * noiseLevel);
			output = output + (SinOsc.ar(sineHz) * sineLevel);
			output = HPF.ar(output, hpFreq);
			output = output.softclip;
			Out.ar(out, output * amp);
		}).add;

		// Adds the GRAIN telemetry: `tap` (this synth's own index, 0-15,
		// fixed at creation) becomes SendReply's replyID, so the OSCdef
		// handler can tell which of the 16 taps fired without decoding
		// anything else. posWrapped mirrors what GrainBuf's `pos` argument
		// actually uses once GrainBuf wraps it internally (BufRd/GrainBuf
		// wrap pos, they don't clip it).
		SynthDef(\gran, {
			arg amp = 0.8, buf = 0, out = 0,
			atk = 1, rel = 1, gate = 1,
			sync = 1.0, dens = 40,
			baseDur = 0.05, durRand = 1,
			rate = 1, rateRand = 1,
			pan = 0, panRand = 0,
			grainEnv = (-1), ptrBus = 0, ptrSampleDelay = 20000,
			ptrRandSamples = 0, minPtrDelay = 1000,
			cutoff = 12000, cutoffMax = 16000, resonance = 1,
			tap = 0;
			var sig, env, densCtrl, durCtrl, rateCtrl, panCtrl, posWrapped;
			var ptr, ptrRand, totalDelay, maxGrainDur, grainTrigger;

			env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction: 2);

			grainTrigger = CoinGate.ar(sync, Impulse.ar(dens)) + CoinGate.ar(1 - sync, Dust.ar(dens));

			durCtrl = baseDur * LFNoise1.ar(100).exprange(1 / durRand, durRand);
			rateCtrl = rate.lag3(0.5) * LFNoise1.ar(100).exprange(1 / rateRand, rateRand);
			panCtrl = pan + LFNoise1.kr(100).bipolar(panRand);
			ptrRand = LFNoise1.ar(100).bipolar(ptrRandSamples);
			totalDelay = max(ptrSampleDelay - ptrRand, minPtrDelay);

			ptr = In.ar(ptrBus, 1);
			ptr = ptr - totalDelay;
			ptr = ptr / BufFrames.kr(buf);
			maxGrainDur = (totalDelay / rateCtrl.abs) / SampleRate.ir;
			durCtrl = min(durCtrl, maxGrainDur);

			posWrapped = ptr.wrap(0, 1);
			SendReply.ar(grainTrigger, '/cd_gran', [posWrapped, durCtrl, rateCtrl, panCtrl, amp], tap);

			sig = GrainBuf.ar(
				2,
				grainTrigger,
				durCtrl,
				buf,
				rateCtrl,
				ptr,
				4,
				panCtrl,
				grainEnv
			);
			sig = MoogFF.ar(
				sig * env * amp,
				freq: min(cutoff, cutoffMax).clip(50, 18000),
				gain: resonance.clip(0, 4)
			);
			Out.ar(out, sig);
		}).add;

		s.sync;

		// Server -> language telemetry listeners (BIDI_SPEC §3). Created
		// before any synth that could send them a reply (ptr/rec below,
		// gran further down), so nothing gets dropped at boot; freed in
		// cleanup.
		OSCdef(\cd_headOSC, handleHeadOSC, '/cd_head');
		OSCdef(\cd_colOSC, handleColOSC, '/cd_col');
		OSCdef(\cd_granOSC, handleGranOSC, '/cd_gran');

		micGrp   = Group.new;
		ptrGrp   = Group.after(micGrp);
		recGrp   = Group.after(ptrGrp);
		granGrp  = Group.after(recGrp);
		outGrp   = Group.after(granGrp);

		micSynth     = Synth(\mic, [\in, 0, \out, micBus, \amp, delayInLevel * delayInOn], micGrp);
		micPassSynth = Synth(\micOut, [\in, 0, \out, granBus, \amp, passLevel * passOn], granGrp);
		ptrSynth     = Synth(\ptr, [\buf, b, \out, ptrBus], ptrGrp);
		recSynth     = Synth(\rec, [\ptrIn, ptrBus, \micIn, micBus, \buf, b, \preLevel, preserveLevel], recGrp);
		fbSynth      = Synth(\fbPatchMix, [\in, 0, \out, micBus, \amp, 0.0], micGrp, \addToHead);
		masterOutSynth = Synth(\masterOutput, [\in, granBus, \out, 0, \amp, masterVol], outGrp);

		// LFNoise1 LFOs -- low-frequency noise. Prefixed to avoid Ndef-name
		// collisions with other running code.
		panLFOs = Array.fill(16, { |i|
			Ndef((\cd_pan ++ i).asSymbol, {
				LFNoise1.kr(beatDur / rrand(1, 64)).range(-1, 1)
			})
		});

		// Per-tap amplitude LFOs -- range 1..3. masterVol (Ch1 CC7) controls
		// the overall mix level independently.
		ampLFOs = Array.fill(16, { |i|
			Ndef((\cd_amp ++ i).asSymbol, {
				LFNoise1.kr(beatDur / rrand(1, 64)).range(1, 3)
			})
		});

		cutoffLFOs = Array.fill(16, { |i|
			Ndef((\cd_cut ++ i).asSymbol, {
				LFNoise1.kr(beatDur / rrand(1, 64)).range(500, 15000)
			})
		});

		resonanceLFOs = Array.fill(16, { |i|
			Ndef((\cd_res ++ i).asSymbol, {
				LFNoise1.kr(beatDur / rrand(1, 64)).range(0, 2)
			})
		});

		durs   = 16.collect({ |i| beatDur * (i + 1) }).scramble;
		delays = 16.collect({ |i| s.sampleRate * (beatDur * (i + 1)) * 16 }).scramble;

		// Initialize 16 granular taps. Startup rates come from the SAME
		// computeTapRates function used by the CC handlers, so taps 8-15
		// start out correctly pitched from the very first evaluation.
		{
			var startRates = computeTapRates.value;
			granSynths = 16.collect({ |n|
				Synth(\gran, [
					\amp, if (delayOutOn > 0) { ampLFOs[n] } { 0 },
					\buf, b,
					\out, granBus,
					\atk, 1, \rel, 1, \gate, 1, \sync, 1.0,
					\dens, densMult / (durs[n] * startRates[n].abs),
					\baseDur, durs[n],
					\durRand, 1,
					\rate, startRates[n],
					\rateRand, 1,
					\pan, panLFOs[n],
					\panRand, 0,
					\grainEnv, -1,
					\ptrBus, ptrBus,
					\ptrSampleDelay, delays[n],
					\ptrRandSamples, 0,
					\minPtrDelay, delays[n],
					\cutoff, cutoffLFOs[n],
					\cutoffMax, cutoffMax,
					\resonance, resonanceLFOs[n],
					\tap, n
				], granGrp);
			});
		}.value;

		s.sync;

		// Bring the whole engine to the documented default state (the same
		// state the web demo's "Send all values" sends). Each applied
		// control echoes -- BIDI_SPEC §2's boot "bang".
		applyDefaults.value;

		cmdPeriodFunc = {
			cleanup.(false);
			"Carter's Delay stopped (Cmd-Period). Re-evaluate the file to restart.".postln;
		};
		CmdPeriod.add(cmdPeriodFunc);

		// The only MIDI responder. Created last, after applyDefaults, and
		// listens to all connected MIDI sources. Routes Ch1-3 CCs to
		// handleCC and a Ch16 CC1 request to reportAll; everything else
		// (the engine's own echoes on Ch9-11, other channels) is silently
		// ignored, with no logging.
		MIDIdef.cc(\cartersDelayCC, { |val, num, chan, src|
			if (chan <= 2) {
				handleCC.(chan, num, val);
			};
			if (chan == 15 and: { num == 1 } and: { val > 0 }) {
				reportAll.value;
			};
		});

		"=== Carter's Delay ready: listening for MIDI CC on channels 1-3 ===".postln;
	}).play;
});
)

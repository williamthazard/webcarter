/*
   Carter's Delay - WebMIDI Controlled Version
   Based on Carter's Delay by William Hazard.

   The engine is CC-only (no MIDI Notes). It listens on ALL connected MIDI
   inputs. Sending controls is receive-only, but the engine also talks back:
   see "Bidirectional MIDI" below and README.md for the full protocol a
   frontend can rely on.

   Toggles: 0 = off, any value > 0 = on (senders should send 127 for on).
   Status bytes are 0xB0 (Ch1) .. 0xB2 (Ch3); in SC, `chan` arrives 0-based
   (0, 1, 2). Anything not listed below is ignored, except the state
   request, channel 16 CC 1 (see "Bidirectional MIDI" below).

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
     2  | Feedback Balance    | v<=64: (v-64)/64 ; v>64: (v-64)/63  -> -1..+1 (which output | 64        | 0.0 exactly
        |                     | channel feeds back: -1 left only, +1 right only, 0 both)   |           |
     3  | Feedback High-Pass  | v/127 * 220 Hz, never below 5 Hz (v = 0..2 give 5 Hz)      | 7         | 12.13 Hz
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

   Delay buffer: 256 s of mono audio at 44.1/48 kHz. It is capped at 2^24
   = 16,777,216 frames (the write position travels as a 32-bit float, which
   can't address every frame past that), so above 65,536 Hz it is shorter
   -- 174.8 s at 96 kHz -- and the 16 tap delays shrink in proportion. The
   boot log says so when the cap applies; HELLO always reports the real
   frame count.

   Lifecycle: re-evaluating this file replaces the running engine instead of
   duplicating it, at any moment -- even while the server is still booting.
   The new evaluation tears the previous instance down first; an instance
   replaced mid-boot stops at its next checkpoint and frees everything it
   allocated. The running instance's teardown function lives at
   Library.at(\cartersDelay, \cleanup) (the global Library, not an
   environment variable, so a pushed ProxySpace can't interfere):
   `Library.at(\cartersDelay, \cleanup).value` stops the engine from code.
   An engine started from an older version of this file, which kept its
   teardown function in an environment variable instead, is torn down too
   (once). Cmd-Period also stops the engine cleanly; re-evaluate the file
   to restart it.
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
       "bang"), then a HEAD packet and a full waveform DUMP. At most one
       reply per 250 ms: further requests inside that window are dropped
       silently. The echoes go out at once; the SysEx follows over about
       1 s (see "Request replies" below).
     - SysEx telemetry: packets `F0 7D 43 <type> ... F7` report HELLO,
       HEAD (write-head position), GRAIN (one per grain trigger) and
       COLUMN/DUMP (the recorded-buffer waveform, for a scope UI). See
       README.md, "Listening to the engine", for the exact byte layout of
       every packet type.
     - SysEx goes out in bursts: packets are queued and sent every 200 ms,
       back to back, always through MIDIOut.sysex (see sendSysexBytes):
         macOS, Linux: the whole burst in one call. On macOS that is
                       CoreMIDI's MIDISendSysex, which delivers roughly
                       MIDI-cable speed (~3,000 B/s measured here).
         Windows:      one call per packet (PortMidi sends a sysex buffer
                       only up to its first F7).
       Never MIDIOut.write, though it is faster on macOS: it is for short
       messages only, and SysEx bytes sent through it turn into fake
       status bytes (stray notes/CCs, broken frames) at the receiver.
       HEAD is sampled 20 times a second, but only the latest HEAD in each
       burst is sent (about 5 a second). Echo
       CCs are never queued, so SysEx can arrive after echoes sent later --
       don't rely on the relative order of CCs and SysEx. Depending on the
       platform and the receiving MIDI API, packets arrive as separate
       messages or several to a block of bytes, so a receiver should
       accept more than one F0 ... F7 frame per block.
     - Byte budget: anything handed over faster than the driver delivers
       it backs up inside the OS, where no queue here can see it, so each
       burst has a byte budget: 120 bytes (about 600 B/s) on every
       platform, a conservative estimate for the SysEx path (well under
       the ~3,000 B/s measured on macOS; not measured on Linux or
       Windows). The budget is per 200 ms of real time since
       the previous burst: a burst that goes out late because the flush
       routine woke late (the interpreter was busy, say) gets
       proportionally more, up to 3 times as much, so a late wake doesn't
       thin grains the port could carry. The routine times each wait from
       when it actually woke, so the burst after a late one still comes
       200 ms later, never at once to catch up. HELLO, HEAD and COLUMN
       always go out and are counted first (COLUMN apart from the backlog
       gate below); GRAIN packets fill whatever budget is left, newest
       first, and the older ones are dropped ("thinned"). That leaves room
       for 7 grains per burst next to a HEAD and a COLUMN, so at most about
       35 a second are reported; at defaults (7-20 grains a second) all but
       a few percent are (dropped when the taps' triggers line up). While
       grains are being thinned the post window shows "Telemetry: thinning
       grain packets (N dropped in the last 10 s)", at most once every
       10 s: now and then, at defaults too. Never for the burst in which
       all 16 taps fire together as the engine starts.
     - Backlog gate (a closed loop): the engine listens on every MIDI
       input, so on a bus that loops back (IAC, loopMIDI) it hears its own
       SysEx. It notes when it sends each HEAD; when that HEAD comes back,
       the time since it was sent is how far behind the port is. HEADs are
       paired by their bytes, oldest first; any sent before the matched
       one, and any not back within 2 s of being sent, are taken as lost.
       While the buffer is frozen every HEAD is identical, and a lost one
       looks just like the port suddenly falling a burst further behind:
       the engine first takes it as delay, and if 2 s after that HEAD was
       sent the arrivals still fit it having been lost, takes it as lost
       -- so a lost HEAD skews the measurement for about 2 s at most. While
       the port is more than 0.35 s behind, bursts carry no GRAINs, until
       it is back under 0.25 s. While it is more than 1 s behind, bursts
       carry no COLUMNs either
       (the waveform catches up from later COLUMNs or the next request's
       DUMP), a request reply leaves out its DUMP, and a reply's DUMP chunk
       not yet sent waits. HELLO and HEAD always go out. Once HEADs have
       come back, if none does for 2 s while HEADs are still being sent,
       the port is taken as far behind (a port more than 2 s behind
       returns its HEADs too late to be paired), so bursts carry no GRAINs
       and no COLUMNs, and a reply no DUMP, until a HEAD comes back and is
       paired again; the post window shows "Telemetry: MIDI port stopped
       echoing; holding grain packets" once each time this happens (at
       most once every 10 s). Meanwhile only HELLO and HEAD go out (about
       40 B/s), so a port that is merely late catches up within seconds.
       If still none has come back after 8 s of this (10 s after the last
       one), something other than delay has stopped the engine hearing
       the port: it stops holding, posts "Telemetry: no longer hearing the
       MIDI port; estimating instead", and estimates the delay, as below,
       until a HEAD comes back again. The engine estimates whenever there
       is nothing to measure: before the first HEAD comes back, on a port
       that doesn't loop back (as in some Linux setups), after giving up as
       above, and while no HEAD it sent 1-2 s ago is still on its way (it
       has stopped sending them -- the server stopped answering -- or has
       only just started again). The estimate: each burst costs a fixed
       time plus a time per byte -- 60 ms + 1 ms per byte on every
       platform (an estimate, not measured) -- and it runs down again
       whenever a burst takes less than the 200 ms between bursts, as
       every burst within the budget does. A late burst's larger
       budget is charged over the time it covers (as if the burst had
       started when that time began, up to 400 ms earlier), so a late wake
       alone doesn't hold grains back. A burst carrying a reply's DUMP
       chunk is charged the fixed time only, so answering a request doesn't
       hold grains back on the estimate. On the estimate only grains are
       held back: COLUMNs and a reply's DUMP always go out. For the first
       2 s after the first burst, before a HEAD could have come back,
       nothing is held back. While grains are held back, measured or
       estimated, the post window shows "Telemetry: MIDI port is behind by
       N ms; skipping grain packets", at most once every 10 s (but not
       while HEADs have stopped coming back: then only the "stopped
       echoing" line above).
     - Request replies: the 24 echoes go out at once; HELLO and HEAD go
       out in the next burst, then the waveform DUMP (four chunks at the
       default 1024 columns), one chunk per burst -- so the reply's 1,084
       bytes of SysEx take about 1 s to hand over and never reach the port
       in one lump, while HEAD keeps flowing. Bursts that carry a reply's
       HELLO or a DUMP chunk carry no GRAINs. A new request starts the
       reply over, DUMP included.
     - HELLO is sent when the buffer exists and again once the engine is
       listening (so a page whose request arrived mid-boot still gets one),
       and first in every request reply. Treat every HELLO as "reset your
       scope".
     - Everything on the shared bus is heard by everyone; this engine acts
       only on Ch1-3 CCs and the Ch16 CC1 request, and silently ignores
       everything else (its own echoes, other channels, all SysEx -- its
       own HEAD packets coming back are only timed, for the backlog gate)
       with no per-message logging for ignored input.
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
// false once this instance's cleanup has run (re-evaluation, Cmd-Period or
// a manual stop). The boot routine checks it at every point where it has
// waited on the server, so an instance replaced mid-boot stops at its next
// checkpoint and frees everything it allocated.
var alive = true;

// --- Bidirectional MIDI state -----------------------------------------
// One virtual port, both directions, split by channel. See the header
// comment above and README.md ("Listening to the engine") for the full
// protocol.
var midiPortMatch, midiOut;
var numCols = 1024, numTaps = 16, protocolVersion = 1;
var bufferFrames, sampleRateHz, colPeaks, lastHeadPos = 0, ccState;
var u14, u21, u28, u7, sysexPacket;
var echoCC, sendHello, sendBang, sendHeadPacket, reportAll;
var handleHeadOSC, handleColOSC, handleGranOSC;
var lastReportTime; // Main.elapsedTime of the last request reply (nil = none yet)
// Outgoing SysEx: queue, byte budget, backlog gate and request-reply
// spreading (see queueSysex, portBacklog and flushSysex below). Every
// burst reaches the MIDI layer through MIDIOut.sysex (see sendSysexBytes):
// one call per burst, except on Windows, one call per packet, because
// PortMidi sends a sysex buffer only up to its first F7.
// NEVER send SysEx through MIDIOut.write, however much faster it is: it
// reassembles each 3-byte chunk as a short message, so a data byte in a
// chunk's first position becomes a fake status byte (0x40..0x7F ->
// note/CC/...), and receivers see random controls and broken frames
// (verified on the IAC bus with a raw CoreMIDI listener).
var sysexPlatform = thisProcess.platform.name;
var sysexOnePacketPerCall = (sysexPlatform == \windows);
var sysexQueue = List.new, sysexFlushRoutine;
var queueSysex, flushSysex, sendSysexBytes, headKey, sysexSendFailed = false;
var sysexFlushInterval = 0.2; // seconds between bursts, on every platform
// Bytes per burst: 120 (about 600 B/s), a conservative estimate for the
// SysEx path (MIDISendSysex on macOS was measured at ~3 KB/s; ALSA and
// loopMIDI weren't measured). Per sysexFlushInterval of real time since
// the previous burst: a burst that goes out late gets proportionally
// more, up to 3 times (see flushSysex).
var sysexBudgetBytes = 120;
var lastFlushAt; // Main.elapsedTime of the previous flushSysex call (nil before the first)
var stallMinSecs = 0.3; // a flush this much later than due counts as a language stall, not port delay
var stallOffset = 0; // language-stall time to subtract from every in-flight HEAD's age (see flushSysex)
var inFlightAge; // |now, h| -> how long HEAD h has really been on its way, stalls discounted
var maxQueuedGrains = 500, queuedGrains = 0, cappedGrains = 0;
var grainBurstSeen = false; // the first burst with GRAINs (all 16 taps at once) is never "thinning"
var thinningSince, thinnedBursts = 0, grainsDropped = 0; // the 10 s thinning log
// The backlog gate (see portBacklog and flushSysex): no GRAINs above
// gateCloseSecs until back under gateOpenSecs. Above farBehindSecs,
// measured on a bus that loops back, and while a loop that was heard has
// gone quiet (see portFarBehind): no COLUMNs, no reply DUMP.
var gateCloseSecs = 0.35;
var gateOpenSecs = 0.25;
var farBehindSecs = 1.0;
var grainsHeld = false, lastBehindLineAt; // gate state; the 10 s "behind" log
// The "stopped echoing" log (see flushSysex): posted once each time a loop
// that was heard goes quiet, at most once every 10 s.
var silentLineAt, silentNoted = false;
// Closed loop: HEADs handed over and not yet heard back ([Main.elapsedTime
// sent, headKey], oldest first), and the latest measurement.
var sysexHook, headHeardBack, portBacklog, loopHeard, loopLost, portFarBehind, dropLostHeads;
var headsInFlight = List.new, maxHeadsInFlight = 50;
var headMaxAgeSecs = 2.0; // a HEAD not heard back within 2 s of being sent is lost
var lastHeadBackAt, measuredBacklog = 0;
// Pairing identical HEADs (see headHeardBack): the measurement arrivals
// are compared with; while a HEAD is suspected lost, its send time and
// how many HEADs later the arrivals would be paired if it was.
var pairRef, suspectSentAt, suspectShift = 0;
// No HEAD heard back for this long, while HEADs are being sent: the loop
// has gone quiet, and the port is taken as far behind until one is paired
// again (see loopLost) -- for at most quietGiveUpSecs, after which the
// engine stops waiting for its echo and estimates instead (see
// flushSysex). quietSince: when the current quiet spell was first seen.
var loopTimeoutSecs = 2.0, quietGiveUpSecs = 8.0, quietSince;
// Fallback model, used whenever there is nothing to measure (see
// portBacklog): the time (Main.elapsedTime) by which the port should have
// delivered everything handed over, charged per burst: a fixed cost plus
// a cost per byte: 60 ms + 1 ms/B, an estimate (see portBacklog). A burst
// carrying a reply's DUMP chunk is charged the fixed cost only; a late
// burst with a larger budget is charged over the time it covers (see
// flushSysex).
var sysexBusyUntil = 0;
var modelBurstSecs = 0.06;
var modelByteSecs = 0.001;
// Startup grace: until a HEAD has come back, the gate stays open for the
// first startupGraceSecs after the first burst (sysexStartedAt).
var startupGraceSecs = 2.0, sysexStartedAt;
// A request reply in progress (see reportAll): HELLO + HEAD due in the
// next burst, then these DUMP chunks, one per burst.
var replyHelloPending = false, replyDumpChunks = List.new, dumpPacket;

// Re-evaluating this file replaces any already-running (or still-booting)
// instance instead of duplicating it. The handle lives in the global
// Library rather than an environment variable (~name), which a pushed
// ProxySpace would intercept.
Library.at(\cartersDelay, \cleanup) !? { |previousCleanup| previousCleanup.value(true) };
// An engine started from an older version of this file kept its teardown
// function in ~cartersDelayCleanup instead: stop that one too, once.
topEnvironment[\cartersDelayCleanup] !? { |f|
	if (f.isKindOf(Function)) { f.value(true) };
	topEnvironment[\cartersDelayCleanup] = nil;
};

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

// One virtual MIDI port, both directions, separated by channel (README.md,
// "Channel map"). Match by "<device> <name>" so this works whether
// MIDIClient reports the IAC bus as one endpoint or two words. If nothing
// matches, midiOut stays nil and every echo/telemetry send below becomes a
// silent no-op -- controls sent TO the engine keep working either way.
midiPortMatch = ["IAC Driver Bus 1", "loopMIDI"];
{
	var idx = MIDIClient.destinations.detectIndex({ |ep, i|
		midiPortMatch.any({ |m| (ep.device ++ " " ++ ep.name).contains(m) })
	});
	if (idx.notNil) {
		midiOut = MIDIOut(idx);
		midiOut.latency = 0; // the 0.2s default would delay every echo/CC send (and, on macOS, every SysEx burst)
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
// scope's column resolution (README.md, "SysEx telemetry").
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
// SysEx encoding helpers (README.md, "SysEx telemetry"). Every payload
// byte is 0-127; every value is clamped into range before packing.
// u14/u21/u28 are MSB-first big-endian, 7 bits per byte; u7 is a single
// clamped byte, for every payload field the README's packet table marks
// "u7" (version, numTaps, tap, ...).
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
// order. Also doubles as the exact request-reply "bang" order (README.md,
// "Echo") and, via handledCCs below, as the set of CCs handleCC actually
// acts on.
defaultCCs = [
	[1,7,51],[1,1,64],[1,2,64],[1,3,64],[1,4,127],[1,5,127],[1,6,127],
	[2,1,0],[2,2,64],[2,3,7],[2,4,0],[2,5,0],[2,6,24],
	[3,1,64],[3,2,64],[3,3,127],[3,4,0],[3,5,127],[3,6,0],[3,8,0],[3,9,0],[3,10,0],[3,11,0],[3,12,0]
];

// [chan0, cc] pairs handleCC actually acts on, derived from defaultCCs.
// Used only to decide whether to print the raw "[SC MIDI IN]" line --
// handleCC must post nothing at all for a CC it doesn't handle.
handledCCs = defaultCCs.collect({ |entry| [entry[0] - 1, entry[1]] });

// Echoes one applied control back out on channel+8 (README.md, "Echo") and
// records it in ccState so a later request can resend the CURRENT value.
// `v` must already be the value to echo: raw for sliders, 127/0 for
// toggles. A nil midiOut makes this a silent no-op.
echoCC = { |chan, cc, v|
	ccState[chan][cc] = v;
	midiOut !? { midiOut.control(chan + 8, cc, v) };
};

// Unified CC handler. chan is 0-based (0, 1, 2 = Ch1, Ch2, Ch3).
// `quiet` (applyDefaults at boot) applies and echoes exactly as usual but
// posts nothing: neither the "[SC MIDI IN]" line (the value didn't come in
// over MIDI) nor the " -> ..." effect line.
handleCC = { |chan, num, val, quiet = false|
	var chNum = chan + 1;
	var post = { |str| if (quiet.not) { str.postln } };

	if (handledCCs.includesEqual([chan, num])) {
		post.("[SC MIDI IN] Channel: " ++ chNum ++ " | CC #" ++ num ++ " | Val: " ++ val);
	};

	if (chan == 0) {
		case
		{ num == 1 } {
			passLevel = val / 127;
			micPassSynth.set(\amp, passLevel * passOn);
			echoCC.(0, 1, val);
			post.(" -> Input Passthrough Level: " ++ (passLevel * 100).round(0.1) ++ "%");
		}
		{ num == 2 } {
			delayInLevel = val / 127;
			micSynth.set(\amp, delayInLevel * delayInOn);
			echoCC.(0, 2, val);
			post.(" -> Delay Input Level: " ++ (delayInLevel * 100).round(0.1) ++ "%");
		}
		{ num == 3 } {
			preserveLevel = val / 127;
			recSynth.set(\preLevel, preserveLevel);
			echoCC.(0, 3, val);
			post.(" -> Buffer Preservation: " ++ (preserveLevel * 100).round(0.1) ++ "%");
		}
		{ num == 4 } {
			passOn = if (val > 0) { 1 } { 0 };
			micPassSynth.set(\amp, passLevel * passOn);
			echoCC.(0, 4, passOn * 127);
			post.(" -> Input Passthrough: " ++ if (passOn > 0) { "ON" } { "MUTED" });
		}
		{ num == 5 } {
			delayInOn = if (val > 0) { 1 } { 0 };
			micSynth.set(\amp, delayInLevel * delayInOn);
			echoCC.(0, 5, delayInOn * 127);
			post.(" -> Delay Input: " ++ if (delayInOn > 0) { "ON" } { "MUTED" });
		}
		{ num == 6 } {
			delayOutOn = if (val > 0) { 1 } { 0 };
			granSynths.do({ |g, idx|
				g.set(\amp, if (delayOutOn > 0) { ampLFOs[idx] } { 0 });
			});
			echoCC.(0, 6, delayOutOn * 127);
			post.(" -> Delay Output: " ++ if (delayOutOn > 0) { "ON" } { "MUTED" });
		}
		{ num == 7 } {
			masterVol = val / 51;
			masterOutSynth.set(\amp, masterVol);
			echoCC.(0, 7, val);
			post.(" -> Master Output Level: " ++ masterVol.round(0.001) ++ "x");
		};
	};

	if (chan == 1) {
		case
		{ num == 1 } {
			var amp = val / 127;
			fbSynth.set(\amp, amp);
			echoCC.(1, 1, val);
			post.(" -> Feedback Level: " ++ (amp * 100).round(0.1) ++ "%");
		}
		{ num == 2 } {
			var bal = ccToBipolar.(val);
			fbSynth.set(\balance, bal);
			echoCC.(1, 2, val);
			post.(" -> Feedback Balance: " ++ bal.round(0.0001));
		}
		{ num == 3 } {
			var hp = (val / 127) * 220;
			fbSynth.set(\hpFreq, hp);
			echoCC.(1, 3, val);
			post.(" -> Feedback High-Pass: " ++ hp.round(0.001) ++ " Hz");
		}
		{ num == 4 } {
			var nAmp = val / 127;
			fbSynth.set(\noiseLevel, nAmp);
			echoCC.(1, 4, val);
			post.(" -> Pink Noise Level: " ++ (nAmp * 100).round(0.1) ++ "%");
		}
		{ num == 5 } {
			var sAmp = val / 127;
			fbSynth.set(\sineLevel, sAmp);
			echoCC.(1, 5, val);
			post.(" -> Sine Level: " ++ (sAmp * 100).round(0.1) ++ "%");
		}
		{ num == 6 } {
			var hz = ccToSineHz.(val);
			fbSynth.set(\sineHz, hz);
			echoCC.(1, 6, val);
			post.(" -> Sine Frequency: " ++ hz.round(0.01) ++ " Hz");
		};
	};

	if (chan == 2) {
		case
		{ num == 1 } {
			rateMult = ccToMult.(val, 0.25, 2);
			applyTapRates.value;
			echoCC.(2, 1, val);
			post.(" -> Playback Rate Multiplier: " ++ rateMult.round(0.0001) ++ "x");
		}
		{ num == 2 } {
			densMult = ccToMult.(val, 0.2, 3);
			applyTapRates.value;
			echoCC.(2, 2, val);
			post.(" -> Grain Density Multiplier: " ++ densMult.round(0.0001) ++ "x");
		}
		{ num == 3 } {
			cutoffMax = val.linexp(0, 127, 200, 16000);
			granSynths.do({ |g| g.set(\cutoffMax, cutoffMax) });
			echoCC.(2, 3, val);
			post.(" -> Low-Pass Cutoff Ceiling: " ++ cutoffMax.round(0.1) ++ " Hz");
		}
		{ num == 4 } {
			var jitterSecs = (val / 127) * 2.5;
			var jitterSamples = s.sampleRate * jitterSecs;
			granSynths.do({ |g| g.set(\ptrRandSamples, jitterSamples) });
			echoCC.(2, 4, val);
			post.(" -> Position Jitter: " ++ jitterSecs.round(0.001) ++ " s");
		}
		{ num == 5 } {
			var sync = val / 127;
			granSynths.do({ |g| g.set(\sync, sync) });
			echoCC.(2, 5, val);
			post.(" -> Trigger Distribution: " ++ (sync * 100).round(1) ++ "% periodic");
		}
		{ num == 6 } {
			var idx = ccToWindowIndex.(val);
			var targetBuf = if (idx == 0) { -1 } { envBufs[idx - 1].bufnum };
			granSynths.do({ |g| g.set(\grainEnv, targetBuf) });
			echoCC.(2, 6, val);
			post.(" -> Grain Window: " ++ ["Hann", "Percussive", "Reverse Swell"][idx]);
		}
		{ num == 8 } {
			freezeOn = if (val > 0) { 1 } { 0 };
			if (freezeOn > 0) {
				// One bundle, so the recorder never runs for a callback at a
				// pointer that has already stopped (it would pile input onto
				// one sample).
				s.makeBundle(nil, { ptrSynth.set(\rate, 0); recSynth.run(false) });
				post.(" -> Buffer Freeze: FROZEN");
			} {
				s.makeBundle(nil, { ptrSynth.set(\rate, 1); recSynth.run(true) });
				post.(" -> Buffer Freeze: LIVE");
			};
			echoCC.(2, 8, freezeOn * 127);
		}
		{ num == 9 } {
			octavesOn = if (val > 0) { 1 } { 0 };
			applyTapRates.value;
			echoCC.(2, 9, octavesOn * 127);
			post.(" -> Octaves: " ++ if (octavesOn > 0) { "ON" } { "OFF" });
		}
		{ num == 10 } {
			fifthsOn = if (val > 0) { 1 } { 0 };
			applyTapRates.value;
			echoCC.(2, 10, fifthsOn * 127);
			post.(" -> Fifths & Fourths: " ++ if (fifthsOn > 0) { "ON" } { "OFF" });
		}
		{ num == 11 } {
			suboctavesOn = if (val > 0) { 1 } { 0 };
			applyTapRates.value;
			echoCC.(2, 11, suboctavesOn * 127);
			post.(" -> Sub-octaves: " ++ if (suboctavesOn > 0) { "ON" } { "OFF" });
		}
		{ num == 12 } {
			reverseOn = if (val > 0) { 1 } { 0 };
			applyTapRates.value;
			echoCC.(2, 12, reverseOn * 127);
			post.(" -> Reverse: " ++ if (reverseOn > 0) { "ON" } { "OFF" });
		};
	};
};

// Runs at the end of boot, after all synths exist, so the engine's startup
// state equals the demo's "Send all values" applied at defaults. Each call
// below also echoes (the boot "bang", README.md "Echo"), via handleCC ->
// echoCC.
// Quiet: one summary line instead of 24 "[SC MIDI IN]" / " -> ..." pairs.
applyDefaults = {
	defaultCCs.do({ |entry|
		handleCC.(entry[0] - 1, entry[1], entry[2], quiet: true);
	});
	("Applied " ++ defaultCCs.size ++ " defaults.").postln;
};

// ---------------------------------------------------------------------
// Server -> language telemetry (README.md, "SysEx telemetry"). These
// helpers only build and queue SysEx; the OSCdef handlers below feed them
// from the server's SendReply messages (or, for reportAll, from cached
// state), and every send is a no-op when midiOut is nil.
// ---------------------------------------------------------------------

// Outgoing SysEx queue. Every packet goes through queueSysex, and the
// flush routine (started just before the boot, stopped in cleanup) sends
// what is pending every 200 ms as one burst: the packets back to back,
// handed to the MIDI layer by sendSysexBytes (one MIDIOut.sysex call per
// burst; on Windows one per packet). Why bursts: every send call has an
// overhead of its own,
// so a few calls a second carrying several packets each cost less than
// one call per packet, and HEAD, a snapshot, needs to go out only about 5
// times a second. Packet bytes are unchanged; a receiver only has to
// accept several F0 ... F7 frames in one block of received bytes.
//   - HEAD (type 2) is a snapshot: a newer HEAD replaces any HEAD still
//     pending, so at most one goes out per burst (about 5 a second).
//   - HELLO and COLUMN are kept, in the order queued (COLUMN apart from
//     the backlog gate in flushSysex).
//   - GRAIN (type 3) is thinned by the byte budget and held back by the
//     backlog gate (see flushSysex).
//   - DUMP is never queued here: a request reply hands its chunks to
//     flushSysex one per burst (see reportAll).
//   - Safety net in case the flush routine can't run: at most
//     maxQueuedGrains GRAIN packets wait; past that the oldest pending
//     GRAIN is dropped (counted as thinned). Every flush empties the
//     queue, so this doesn't happen in normal operation.
// A no-op when midiOut is nil or once this instance has been cleaned up.
queueSysex = { |packet|
	if (alive and: { midiOut.notNil }) {
		if (packet[3] == 2) { sysexQueue.removeAllSuchThat({ |p| p[3] == 2 }) };
		sysexQueue.add(packet);
		if (packet[3] == 3) {
			queuedGrains = queuedGrains + 1;
			if (queuedGrains > maxQueuedGrains) {
				sysexQueue.removeAt(sysexQueue.detectIndex({ |p| p[3] == 3 }));
				queuedGrains = queuedGrains - 1;
				cappedGrains = cappedGrains + 1;
			};
		};
	};
};

// The 21-bit key of a HEAD frame starting at bytes[i] (its pos14 and
// frozen bytes): what the closed loop matches a HEAD heard back against.
headKey = { |bytes, i = 0|
	((bytes[i + 4] & 127) << 14) + ((bytes[i + 5] & 127) << 7) + (bytes[i + 6] & 127)
};

// Hands `bytes` -- one burst, or on Windows one packet -- to the MIDI
// layer; answers whether it went through.
//   - macOS and Linux: one MIDIOut.sysex call per burst. On macOS that is
//     MIDISendSysex, which paces sends to roughly MIDI-cable speed (~3 KB/s
//     measured here), below the engine's ~3.7 KB/s peak -- hence the byte
//     budget and the closed loop below. MIDIOut.write (MIDISend packets)
//     would be faster but CANNOT carry SysEx: it reassembles each 3-byte
//     chunk as a short message, so a data byte in a chunk's first position
//     becomes a fake status byte (0x40..0x7F -> note/CC/...) and receivers
//     see random controls and broken frames. Verified on the IAC bus with
//     a raw CoreMIDI listener.
//   - Windows: one MIDIOut.sysex call per packet (flushSysex calls this
//     once per packet), because PortMidi sends a sysex buffer only up to
//     its first F7.
// A failed send (e.g. the port disappeared) posts one warning, the first
// time only, instead of stopping the flush routine. The reason is
// flattened to one line: a failed primitive's errorString is
// "ERROR: Primitive '...' failed.<newline><reason>".
sendSysexBytes = { |bytes|
	var ok = true;
	try {
		midiOut.sysex(bytes);
	} { |err|
		var why = if (err.isKindOf(Exception)) { err.errorString } { err.asString };
		ok = false;
		if (sysexSendFailed.not) {
			sysexSendFailed = true;
			why = why.asString;
			["ERROR: ", "EXCEPTION: "].do({ |prefix|
				if (why.beginsWith(prefix)) { why = why.copyToEnd(prefix.size) };
			});
			why = why.collect({ |c| if (c.isSpace) { $  } { c } });
			while { why.notEmpty and: { why.last.isSpace } } { why = why.drop(-1) };
			("WARNING: MIDI SysEx send failed (" ++ why
				++ "). Telemetry is being dropped; controls still work.").postln;
		};
	};
	ok
};

// ---------------------------------------------------------------------
// How far behind the MIDI port is -- the closed loop.
// Anything handed over faster than the driver delivers it backs up inside
// the OS, where the engine can't see it. Measured on the IAC bus (macOS):
// MIDISendSysex (MIDIOut.sysex) paces sends to roughly MIDI-cable speed
// (~3 KB/s measured here), below the engine's ~3.7 KB/s peak. ALSA and
// loopMIDI weren't measured. So instead of guessing, the engine measures. It
// listens on every MIDI input (MIDIIn.connectAll), so on a bus that loops
// back -- IAC, loopMIDI -- it hears its own packets:
//   - flushSysex notes when it hands each HEAD over (headsInFlight: send
//     time and key, oldest first);
//   - sysexHook (on MIDIIn.sysex) picks this engine's HEAD frames out of
//     everything it hears, and headHeardBack takes the time since that
//     HEAD was sent as the measured backlog (measuredBacklog).
// HEADs carry no sequence number, so they are paired by their bytes,
// oldest first (see headHeardBack): any HEAD in flight sent before the
// matched one, and any not heard back within headMaxAgeSecs (2 s) of being
// sent, is taken as lost, so a lost HEAD can't skew later measurements
// for long, even while the buffer is frozen and every HEAD is identical.
// A HEAD matching nothing in flight (a previous instance's, still on its
// way) is ignored.
// One time base for all stamps: Main.elapsedTime (real time), for the
// send and arrival stamps, the fallback model and the time between bursts
// alike. An arrival is stamped in a MIDI callback, a send in the flush
// routine, and inside a SystemClock routine SystemClock.seconds is the
// routine's logical time, which falls behind real time whenever the
// routine wakes late -- mixing the two would add that lag to every
// measurement. (The 10 s log windows, which only ever compare flush times
// with each other, use the flush routine's SystemClock time.)
// ---------------------------------------------------------------------

// Called with every SysEx message the engine hears (installed on
// MIDIIn.sysex just before the boot, removed by cleanup). Accepts several
// frames per message; ignores everything but this engine's HEAD frames
// (F0 7D 43 02 pos14 frozen F7).
sysexHook = { |src, data|
	var n, i = 0;
	if (alive and: { data.notNil }) {
		n = data.size;
		while { (i + 7) < n } {
			if (((data[i] & 255) == 0xF0) and: { data[i + 1] == 0x7D } and: { data[i + 2] == 0x43 }
				and: { data[i + 3] == 2 } and: { (data[i + 7] & 255) == 0xF7 }) {
				headHeardBack.(headKey.(data, i));
				i = i + 8;
			} {
				i = i + 1;
			};
		};
	};
};

// Whether HEADs are coming back: the last one no more than
// loopTimeoutSecs (2 s) before `now` (Main.elapsedTime).
// A language stall since the last HEAD came back is discounted here too
// (stallOffset, see flushSysex): the port kept delivering during it.
loopHeard = { |now| lastHeadBackAt.notNil and: { (now - lastHeadBackAt - stallOffset) <= loopTimeoutSecs } };

// Whether the loop has gone quiet: HEADs have come back before, in this
// instance, but none for more than loopTimeoutSecs (2 s), while HEADs are
// still being sent and not coming back: one sent more than farBehindSecs
// (1 s) ago, and less than headMaxAgeSecs (2 s) ago, is still on its way.
// The port may still be looping back: once it is more than 2 s behind,
// its HEADs come back too late to be paired (headMaxAgeSecs). So the
// engine takes it as far behind (see portBacklog) until one is paired
// again, rather than going back to the fallback model, which would soon
// say the port has caught up and let the backlog grow -- for at most
// quietGiveUpSecs (see flushSysex). With no such HEAD on its way there is
// nothing to wait for: the engine has stopped sending HEADs (the server
// stopped answering), or has only just sent one again (after a request,
// or after the interpreter was blocked for more than 2 s, which ages out
// every HEAD sent before it). Then the loop isn't taken as quiet and the
// fallback model is used.
// How long a HEAD in flight has really been on its way: the time since its
// send stamp, less any language stall since (stallOffset, see flushSysex).
inFlightAge = { |now, h| max(0, now - h[0] - stallOffset) };

loopLost = { |now|
	lastHeadBackAt.notNil and: { loopHeard.(now).not } and: {
		dropLostHeads.(now);
		headsInFlight.notEmpty and: { inFlightAge.(now, headsInFlight[0]) > farBehindSecs }
	}
};

// Whether the port is far behind: measured more than farBehindSecs (1 s)
// behind, or the loop has gone quiet. Never on the fallback model. Then
// bursts carry no COLUMNs and a request reply no DUMP.
portFarBehind = { |now| loopLost.(now) or: { loopHeard.(now) and: { portBacklog.(now) > farBehindSecs } } };

// The age cap: a HEAD in flight for more than headMaxAgeSecs (2 s) is
// taken as lost -- dropped, never matched.
dropLostHeads = { |now|
	while { headsInFlight.notEmpty and: { inFlightAge.(now, headsInFlight[0]) > headMaxAgeSecs } } {
		headsInFlight.removeAt(0);
	};
};

// One of this engine's HEADs came back: find the HEAD in flight it is,
// measure, then drop it and every older one (lost) from headsInFlight.
// Re-anchors measuredBacklog on every match. (The fallback model isn't
// touched: flushSysex charges it for every burst, and it is used only
// while there is nothing to measure -- see portBacklog.)
// Pairing: the match is the oldest HEAD in flight with the same bytes.
// While the write head moves every HEAD's bytes differ, so only one can
// match. While the buffer is frozen they are all identical, and a lost
// HEAD can't be told from the port suddenly falling one burst (200 ms)
// further behind: either way the next HEAD back fits the last measurement
// (pairRef) better as a later HEAD in flight than as the oldest. Plain
// in-order pairing would then add 200 ms to every later measurement for as
// long as the freeze lasts. So the engine keeps pairing in order -- the
// port may really have fallen behind -- but notes the oldest as suspected
// lost (suspectSentAt) and how many HEADs later the arrivals would be
// paired if it was (suspectShift). If an arrival comes while that later
// HEAD hasn't even been sent yet, the suspicion is dropped: the delay was
// real and is over. If it still fits more than headMaxAgeSecs (2 s) after
// the suspect was sent, the suspect is taken as lost like any HEAD not
// back within 2 s: the arrival is paired with the later HEAD and the
// older ones are dropped. So a lost HEAD skews the measurement for about
// 2 s at most, and a real step in the delay is measured as such for 2 s
// (one lasting longer while frozen is taken as lost HEADs).
headHeardBack = { |key|
	var now = Main.elapsedTime, same = List.new, closest, closestErr, idx;
	if (loopHeard.(now).not) { pairRef = nil; suspectSentAt = nil };
	dropLostHeads.(now);
	headsInFlight.do({ |h, i| if (h[1] == key) { same.add(i) } });
	if (same.notEmpty) {
		idx = same[0];
		if (suspectSentAt.isNil) {
			if (pairRef.notNil) {
				same.do({ |i, n|
					var err = (inFlightAge.(now, headsInFlight[i]) - pairRef).abs;
					if (closest.isNil or: { err < closestErr }) { closest = n; closestErr = err };
				});
				if (closest > 0) { suspectSentAt = headsInFlight[idx][0]; suspectShift = closest };
			};
		} {
			if (same.size <= suspectShift) {
				suspectSentAt = nil;
			} {
				if ((now - suspectSentAt - stallOffset) > headMaxAgeSecs) {
					idx = same[suspectShift];
					suspectSentAt = nil;
				};
			};
		};
		measuredBacklog = inFlightAge.(now, headsInFlight[idx]);
		headsInFlight = headsInFlight.copyToEnd(idx + 1);
		lastHeadBackAt = now;
		if (suspectSentAt.isNil) { pairRef = measuredBacklog };
	};
};

// The backlog in seconds at `now` (Main.elapsedTime):
//   - While HEADs are coming back (loopHeard): the measured round trip of
//     the latest one, or the age of the oldest HEAD still in flight if
//     that is longer (a port that has stopped delivering shows up at
//     once).
//   - Once the loop has gone quiet (loopLost): the time since the last
//     HEAD came back -- more than loopTimeoutSecs (2 s), so the gate is
//     closed and the port far behind (portFarBehind) until a HEAD is
//     paired again, or until flushSysex gives up waiting
//     (quietGiveUpSecs).
//   - Whenever there is nothing to measure -- before the first HEAD comes
//     back, on a port that doesn't loop back (as in some Linux setups),
//     after flushSysex has given up on a quiet loop, or while HEADs have
//     stopped coming back but none sent 1-2 s ago is on its way (see
//     loopLost) -- the fallback model: sysexBusyUntil, which flushSysex
//     charges per burst handed over, whatever the number of calls, with
//     modelBurstSecs plus modelByteSecs per byte (a burst carrying a
//     reply's DUMP chunk only modelBurstSecs, so answering a request
//     doesn't close the gate):
//       - 60 ms + 1 ms per byte on every platform (MIDIOut.sysex): an
//         estimate, not measured, so the model is only a rough guard.
//     The model runs down whenever a burst costs less than the time
//     between bursts: every burst within the budget does (120 bytes cost
//     180 ms of the 200 ms; a late burst's larger budget is charged over
//     the time it covers, so it runs down too -- see flushSysex).
portBacklog = { |now|
	var backlog;
	dropLostHeads.(now);
	case
	{ loopHeard.(now) } {
		backlog = measuredBacklog;
		if (headsInFlight.notEmpty) { backlog = max(backlog, inFlightAge.(now, headsInFlight[0])) };
	}
	{ loopLost.(now) } {
		backlog = now - lastHeadBackAt;
	}
	{
		backlog = max(0, sysexBusyUntil - now);
	};
	backlog
};

// One DUMP packet: chunk `ci` (0-based) of the colPeaks cache, at most 256
// columns (README.md, "SysEx telemetry": DUMP's count is <= 256). Built
// when its burst goes out, so it carries the latest peaks.
dumpPacket = { |ci|
	var startCol = ci * 256;
	var count = min(256, numCols - startCol);
	sysexPacket.(5, u14.(startCol) ++ u14.(count) ++ colPeaks[startCol..(startCol + count - 1)]);
};

// One burst: sends what is pending, if anything is, and empties the queue
// even if the send fails, so a dead port can't make it grow. Called by
// the flush routine every sysexFlushInterval (200 ms).
//   - Byte budget: sysexBudgetBytes per burst -- 120 B (about 600 B/s, a
//     conservative estimate for the SysEx path) -- per
//     sysexFlushInterval of real time since the previous burst: when the
//     routine wakes late (more than 200 ms of real time has passed), the
//     burst's budget is scaled by that time, between 1 and 3 times
//     sysexBudgetBytes, so a late wake doesn't thin grains the port could
//     carry. (The flush routine times each wait from when it actually
//     woke, so no burst follows a late one at once.) HELLO, HEAD and
//     COLUMN always go out and are counted first; GRAIN packets (14 B
//     each) fill whatever is left, newest first, and the older ones are
//     dropped. With 120 B, next to a HEAD (8 B) and a COLUMN (8 B) that
//     leaves room for 7 grains per burst, so at most about 35 a second are
//     reported; at defaults (7-20 grains a second) all but a few percent
//     are, dropped when the taps' triggers line up.
//   - Backlog gate, with hysteresis (see portBacklog): once the port is
//     more than gateCloseSecs (0.35 s) behind, bursts carry no GRAINs
//     until it is back under gateOpenSecs (0.25 s). While the port is far
//     behind (portFarBehind: HEADs coming
//     back and the measured backlog over farBehindSecs, 1 s, or the loop
//     gone quiet), bursts carry no COLUMNs either -- they are dropped, and
//     the waveform catches up from later COLUMNs or the next request's
//     DUMP -- and a request reply's next DUMP chunk waits. Once the loop
//     has gone quiet (loopLost) the gate stays closed until a HEAD is
//     paired again. On the fallback model only GRAINs are held back.
//     HELLO and HEAD always go out.
//   - Giving up on a quiet loop: after quietGiveUpSecs (8 s) of it, 10 s
//     after the last HEAD came back, the engine stops waiting. While the
//     loop is quiet only HELLO and HEAD go out (about 40 B/s), so a port
//     that is merely late has caught up long before; still hearing
//     nothing means something else has stopped the engine hearing the
//     port (its input disconnected, a script replacing MIDIIn.sysex,
//     ...). So it forgets the loop, as if no HEAD had ever come back
//     (the fallback model decides again, without a startup grace), and
//     posts "Telemetry: no longer hearing the MIDI port; estimating
//     instead". A HEAD that comes back later is paired as usual and
//     brings the measurement back.
//   - Startup grace: until a HEAD has come back, the gate stays open for
//     the first startupGraceSecs (2 s) after the first burst
//     (sysexStartedAt).
//   - Request reply (see reportAll): the burst after a request carries its
//     HELLO and HEAD; each burst after that carries one DUMP chunk (265 B
//     at 1024 columns), next to that burst's HEAD and COLUMN. None of
//     these bursts carries GRAINs: a receiver clears its grains at the
//     reply's HELLO anyway, and on Linux and Windows a DUMP chunk is
//     already two bursts' worth of bytes.
//   - Thinning log: dropped grains are counted in a 10 s window opened by
//     the first burst the budget itself had to thin. When the window ends
//     the engine posts "Telemetry: thinning grain packets (N dropped in
//     the last 10 s)" if the budget thinned more than one burst in it, so
//     at most one line every 10 s. The first burst that carries GRAINs --
//     all 16 taps fire together the moment the engine starts -- is
//     routine: its drops never open a window. Neither do the GRAINs a
//     reply or the gate holds back.
//   - Behind log: while the gate holds grains back, the engine posts
//     "Telemetry: MIDI port is behind by N ms; skipping grain packets", at
//     most one line every 10 s -- except while the loop has gone quiet:
//     then it posts "Telemetry: MIDI port stopped echoing; holding grain
//     packets", once each time the loop goes quiet, at most one line
//     every 10 s.
//   - Fallback model (see portBacklog): each burst handed over is charged
//     modelBurstSecs plus modelByteSecs per byte; a burst carrying a
//     reply's DUMP chunk only modelBurstSecs. The charge starts when the
//     port is free or when the time the burst's budget covers began,
//     whichever is later: for a burst on time, now; for a late one with a
//     budget scaled by k, (k - 1) * 200 ms ago (at most 400 ms). The port
//     sat idle while the routine was late, and the bytes of that time
//     arrive in one lump, so this charges them as if they had gone out
//     over it: the estimate tracks sustained overload, and a late wake
//     alone doesn't close the gate.
flushSysex = {
	var now = SystemClock.seconds, realNow = Main.elapsedTime;
	var packets, kept, room, budget, scale = 1, backlog, lost, farBehind, replyFlush, dumpChunk, allowGrains;
	var sentBytes, allBytes, handedBytes = 0, chargedBytes, sentHeadKey, firstGrains = false;
	var budgetDrops = cappedGrains, skipDrops = 0;
	cappedGrains = 0;
	// This burst's byte budget: sysexBudgetBytes per sysexFlushInterval of
	// real time since the previous burst, 1 to 3 times sysexBudgetBytes.
	lastFlushAt !? { scale = ((realNow - lastFlushAt) / sysexFlushInterval).clip(1, 3) };
	budget = (sysexBudgetBytes * scale).round.asInteger;
	// A stall of the language itself (the flush routine woke late by more
	// than stallMinSecs) is not port delay: HEADs still in flight only look
	// older than the port made them, and a HEAD that came back during the
	// stall was paired late. The stall is added to stallOffset, which every
	// in-flight age below subtracts (inFlightAge), and taken off a
	// measurement made during it, so a stall closes no gate and loses no
	// COLUMNs. The offset is cleared when nothing is in flight any more.
	lastFlushAt !? {
		var stall = realNow - lastFlushAt - sysexFlushInterval;
		if (stall > stallMinSecs) {
			stallOffset = stallOffset + stall;
			if (lastHeadBackAt.notNil and: { lastHeadBackAt > (lastFlushAt + sysexFlushInterval) }) {
				measuredBacklog = max(0, measuredBacklog - stall);
			};
		};
	};
	if (headsInFlight.isEmpty) { stallOffset = 0 };
	lastFlushAt = realNow;
	// Close a finished thinning window before counting this burst's drops.
	if (thinningSince.notNil and: { (now - thinningSince) >= 10 }) {
		if (thinnedBursts > 1) {
			("Telemetry: thinning grain packets (" ++ grainsDropped
				++ " dropped in the last 10 s)").postln;
		};
		thinningSince = nil;
		thinnedBursts = 0;
		grainsDropped = 0;
	};
	// A loop quiet for quietGiveUpSecs: stop waiting for it and go back to
	// the fallback model, as if no HEAD had ever come back.
	if (loopLost.(realNow)) {
		quietSince = quietSince ? realNow;
		if ((realNow - quietSince) >= quietGiveUpSecs) {
			lastHeadBackAt = nil;
			pairRef = nil;
			suspectSentAt = nil;
			quietSince = nil;
			"Telemetry: no longer hearing the MIDI port; estimating instead".postln;
		};
	} {
		quietSince = nil;
	};
	// The gate: closes above gateCloseSecs, opens again below gateOpenSecs
	// -- held open during the startup grace, and closed for as long as the
	// loop has gone quiet.
	backlog = portBacklog.(realNow);
	lost = loopLost.(realNow);
	if (lastHeadBackAt.isNil and: { sysexStartedAt.isNil or: { (realNow - sysexStartedAt) < startupGraceSecs } }) {
		grainsHeld = false;
	} {
		if (grainsHeld) {
			if (lost.not and: { backlog < gateOpenSecs }) { grainsHeld = false };
		} {
			if (lost or: { backlog > gateCloseSecs }) { grainsHeld = true };
		};
	};
	// Far behind: measured, or the loop gone quiet; never on the fallback
	// model.
	farBehind = portFarBehind.(realNow);
	// A request reply: HELLO + HEAD in this burst, or its next DUMP chunk.
	replyFlush = replyHelloPending;
	replyHelloPending = false;
	if (replyFlush.not and: { farBehind.not } and: { replyDumpChunks.notEmpty }) {
		dumpChunk = replyDumpChunks.removeAt(0);
	};
	allowGrains = grainsHeld.not and: { replyFlush.not } and: { dumpChunk.isNil };
	if ((sysexQueue.size > 0) or: { dumpChunk.notNil }) {
		packets = sysexQueue;
		sysexQueue = List.new;
		queuedGrains = 0;
		if (grainBurstSeen.not and: { packets.any({ |p| p[3] == 3 }) }) {
			grainBurstSeen = true;
			firstGrains = true;
		};
		if (farBehind) { packets = packets.reject({ |p| p[3] == 4 }) };
		room = if (allowGrains) {
			max(0, budget - packets.sum({ |p| if (p[3] != 3) { p.size } { 0 } }))
		} { 0 };
		// Newest first; once a GRAIN doesn't fit, no older one goes either.
		// `kept` is built newest-first, then reversed to the queued order.
		kept = List.new;
		packets.reverseDo({ |p|
			if (p[3] != 3) { kept.add(p) } {
				if (allowGrains and: { p.size <= room }) { room = room - p.size; kept.add(p) } {
					room = 0;
					if (allowGrains and: { firstGrains.not }) {
						budgetDrops = budgetDrops + 1;
					} {
						skipDrops = skipDrops + 1;
					};
				};
			};
		});
		kept = kept.reverse;
		dumpChunk !? { kept.add(dumpPacket.(dumpChunk)) };
		sentBytes = kept.sum({ |p| p.size });
		if ((sentBytes > 0) and: { midiOut.notNil }) {
			if (sysexOnePacketPerCall) {
				kept.do({ |p|
					if (sendSysexBytes.(p)) {
						handedBytes = handedBytes + p.size;
						if (p[3] == 2) { sentHeadKey = headKey.(p) };
					};
				});
			} {
				allBytes = Int8Array.new(sentBytes);
				kept.do({ |p| allBytes = allBytes.addAll(p) });
				if (sendSysexBytes.(allBytes)) {
					handedBytes = sentBytes;
					kept.do({ |p| if (p[3] == 2) { sentHeadKey = headKey.(p) } });
				};
			};
			if (handedBytes > 0) {
				sysexStartedAt = sysexStartedAt ? realNow;
				// Fallback model: charge the burst once (on Windows too,
				// whatever its number of calls) for what was handed over;
				// a burst carrying a reply's DUMP chunk the fixed cost only.
				// A late burst is charged from when the time its budget
				// covers began ((scale - 1) intervals ago), if the port was
				// free by then.
				chargedBytes = if (dumpChunk.isNil) { handedBytes } { 0 };
				sysexBusyUntil = max(realNow - ((scale - 1) * sysexFlushInterval), sysexBusyUntil)
					+ modelBurstSecs + (chargedBytes * modelByteSecs);
			};
			// Closed loop: this HEAD is now in flight.
			sentHeadKey !? {
				headsInFlight.add([realNow, sentHeadKey]);
				if (headsInFlight.size > maxHeadsInFlight) { headsInFlight.removeAt(0) };
			};
		};
	};
	if ((budgetDrops > 0) and: { thinningSince.isNil }) { thinningSince = now };
	if (thinningSince.notNil) {
		grainsDropped = grainsDropped + budgetDrops + skipDrops;
		if (budgetDrops > 0) { thinnedBursts = thinnedBursts + 1 };
	};
	if (lost) {
		if (silentNoted.not and: { silentLineAt.isNil or: { (now - silentLineAt) >= 10 } }) {
			silentNoted = true;
			silentLineAt = now;
			"Telemetry: MIDI port stopped echoing; holding grain packets".postln;
		};
	} {
		silentNoted = false;
		if (grainsHeld and: { lastBehindLineAt.isNil or: { (now - lastBehindLineAt) >= 10 } }) {
			lastBehindLineAt = now;
			("Telemetry: MIDI port is behind by " ++ (backlog * 1000).round.asInteger
				++ " ms; skipping grain packets").postln;
		};
	};
};

// HELLO: sent twice at boot -- once the buffer exists (before
// applyDefaults), and again right after the MIDIdef is created, so a page
// whose request arrived while the engine wasn't listening yet still gets
// one -- and first in every request reply. Receivers treat every HELLO as
// "reset your scope".
sendHello = {
	var payload = [u7.(protocolVersion)] ++ u28.(bufferFrames) ++ u21.(sampleRateHz) ++ u14.(numCols) ++ [u7.(numTaps)];
	queueSysex.(sysexPacket.(1, payload));
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

// Builds and queues one HEAD packet from the most recently received write-
// head position (lastHeadPos, updated by handleHeadOSC) and the language-
// side freezeOn flag -- shared by handleHeadOSC and by reportAll's
// on-demand HEAD. HEAD is sampled 20 times a second; at most one is sent
// per burst (see queueSysex).
sendHeadPacket = {
	var pos14 = (lastHeadPos * 16384).round.asInteger.clip(0, 16383);
	var frozenByte = if (freezeOn > 0) { 1 } { 0 };
	queueSysex.(sysexPacket.(2, u14.(pos14) ++ [frozenByte]));
};

// The Ch16 CC1 request reply, in the order README.md "Echo" documents:
// HELLO, the 24 current-value echoes, HEAD, then the waveform DUMP. The
// echoes go out at once as CCs (72 bytes). The SysEx part is spread out
// so it never reaches the port in one lump: HELLO and HEAD go out in the
// next burst, then one DUMP chunk per burst after that (four at 1024
// columns -- 1,084 bytes of SysEx in all, about 1 s to hand over), none
// with GRAINs (see flushSysex). While the port is far behind
// (portFarBehind: HEADs coming back show it more than 1 s behind, or the
// loop has gone quiet), the reply leaves out the DUMP: the page's waveform
// fills in from COLUMN packets or a later request. On the fallback model
// (nothing to measure, see portBacklog) the DUMP always goes out. A new
// request starts the reply over (its HELLO resets the page's scope, so
// the DUMP must follow it), and one arriving while the port is far behind
// also cancels the chunks not yet sent.
// Rate-limited to one reply per 250 ms: a request inside that window after
// the last reply is dropped silently (Ch16 CC1 is also the mod wheel on a
// keyboard set to channel 16, and a sweep would otherwise flood the bus).
reportAll = {
	var now = Main.elapsedTime;
	if (lastReportTime.isNil or: { (now - lastReportTime) >= 0.25 }) {
		lastReportTime = now;
		sendHello.value;
		sendBang.value;
		sendHeadPacket.value;
		if (alive and: { midiOut.notNil }) {
			replyHelloPending = true;
			replyDumpChunks = if (portFarBehind.(now)) { List.new } {
				List.newFrom((0..((numCols / 256).ceil.asInteger - 1)))
			};
		};
	};
};

// OSCdef handlers for the three SendReply paths. Each is a plain
// top-level Function -- fed a synthetic msg array (as OSCdef would pass
// one: [path, nodeID, replyID, ...values]) they run and can be checked
// without any server or OSCdef registration.

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
// colPeaks cache SC keeps for DUMP, then queues the COLUMN packet.
handleColOSC = { |msg|
	var col = msg[3].round.asInteger;
	var peak = msg[4];
	var peakEnc = (peak.clip(0, 1) * 127).round.asInteger.clip(0, 127);
	if (col >= 0 and: { col < numCols }) {
		colPeaks[col] = peakEnc;
	};
	queueSysex.(sysexPacket.(4, u14.(col) ++ [peakEnc]));
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
	queueSysex.(sysexPacket.(3, payload));
};

// Tears down this engine instance. `freeNodes` is false when called from
// Cmd-Period (which already freed all synths/groups on the server itself).
// Safe to call any number of times, at any point in the boot: it frees
// only what exists and forgets each thing it frees, so a second call frees
// just what was allocated since the first (the boot routine makes that
// second call when it finds itself replaced mid-boot).
cleanup = { |freeNodes = true|
	var wasAlive = alive;
	alive = false;
	// Stop the SysEx flush routine and drop anything still pending,
	// including the rest of a request reply.
	sysexFlushRoutine !? { sysexFlushRoutine.stop; sysexFlushRoutine = nil };
	sysexQueue = List.new;
	replyHelloPending = false;
	replyDumpChunks = List.new;
	// Stop listening for this instance's own SysEx (the closed loop). Safe
	// to repeat: removing a function that isn't installed changes nothing.
	sysexHook !? { MIDIIn.removeFuncFrom(\sysex, sysexHook) };
	headsInFlight = List.new;
	// MIDIdef/OSCdef names are shared by every instance. Only the first call
	// may free them: at that moment they can only belong to this instance
	// (a replaced instance never gets far enough to create them), while by
	// a later call the replacement may already have created its own.
	if (wasAlive) {
		MIDIdef(\cartersDelayCC).free;
		OSCdef(\cd_headOSC).free;
		OSCdef(\cd_colOSC).free;
		OSCdef(\cd_granOSC).free;
	};
	cmdPeriodFunc !? { CmdPeriod.remove(cmdPeriodFunc); cmdPeriodFunc = nil };
	if (freeNodes) {
		micGrp !? { micGrp.free };
		ptrGrp !? { ptrGrp.free };
		recGrp !? { recGrp.free };
		granGrp !? { granGrp.free };
		outGrp !? { outGrp.free };
	};
	micGrp = nil; ptrGrp = nil; recGrp = nil; granGrp = nil; outGrp = nil;
	panLFOs !? { panLFOs.do({ |nd| nd.clear }); panLFOs = nil };
	ampLFOs !? { ampLFOs.do({ |nd| nd.clear }); ampLFOs = nil };
	cutoffLFOs !? { cutoffLFOs.do({ |nd| nd.clear }); cutoffLFOs = nil };
	resonanceLFOs !? { resonanceLFOs.do({ |nd| nd.clear }); resonanceLFOs = nil };
	b !? { b.free; b = nil };
	envBufs !? { envBufs.do({ |buf| buf.free }); envBufs = nil };
	micBus !? { micBus.free; micBus = nil };
	ptrBus !? { ptrBus.free; ptrBus = nil };
	granBus !? { granBus.free; granBus = nil };
	// Unregister only if the Library still points at THIS instance -- by the
	// time a replaced instance's boot routine calls this again, the key
	// already holds its replacement.
	if (Library.at(\cartersDelay, \cleanup) === cleanup) {
		Library.put(\cartersDelay, \cleanup, nil);
	};
};
Library.put(\cartersDelay, \cleanup, cleanup);

// The SysEx flush routine (see queueSysex and flushSysex): one burst every
// sysexFlushInterval (200 ms, so about 5 a second), on SystemClock.
// Started before the boot so the first HELLO goes out in the first burst
// after it is queued; stopped by cleanup. Each wait is timed from when the
// routine actually woke, not from when it was due: after a late wake (the
// interpreter busy, say) a plain wait would leave the routine's logical
// time behind real time, and SystemClock would run it again at once --
// several times after a long stall -- until it had caught up, handing
// over bursts back to back. So bursts are 200 ms apart plus however late
// each wake is (normally a millisecond or two), never closer, and the
// budgets flushSysex scales by real time add up to the time that passed
// (up to the 3x cap after a long stall).
sysexFlushRoutine = Routine({
	var wokeAt;
	loop {
		wokeAt = Main.elapsedTime;
		flushSysex.value;
		(sysexFlushInterval + (wokeAt - thisThread.seconds)).wait;
	};
}).play(SystemClock);

// The closed loop's ear (see portBacklog): hear this engine's own SysEx
// coming back on the bus. Added to MIDIIn.sysex next to anything else
// installed there (MIDIFunc.sysex responders included), not in place of
// it; removed by cleanup.
if (midiOut.notNil) { MIDIIn.addFuncTo(\sysex, sysexHook) };

// Boot checkpoints: every `if (alive.not) { cleanup.(true); nil.alwaysYield }`
// below. An instance replaced (re-evaluation) or stopped while the boot was
// waiting -- for the server to boot, or on an s.sync -- stops at its next
// checkpoint and frees everything it allocated: cleanup frees whatever
// exists at that moment, including anything allocated after the first
// cleanup call. The only waits not directly followed by a checkpoint are
// inside Buffer.sendCollection, before the first s.sync, so a replaced
// instance may still allocate its three buffers (the two grain envelopes
// and the delay buffer, all freed at that first s.sync checkpoint) but
// never sends HELLO and never creates the OSCdefs, groups, synths, Ndefs
// or the MIDIdef.
s.waitForBoot({
	Routine({
		if (alive.not) { cleanup.(true); nil.alwaysYield };
		"=== Carter's Delay: loading engine... ===".postln;

		// Custom Grain Envelope Windows (512-sample buffers)
		envBufs = [
			Buffer.sendCollection(s, Env.perc(0.01, 0.99, 1, -4).asSignal(512)),
			Buffer.sendCollection(s, Env.new([0, 1, 0], [0.98, 0.02], [4, -4]).asSignal(512))
		];

		// 256 s of mono audio, capped at 2^24 frames: the write position
		// travels from \ptr to \rec on an audio bus as a 32-bit float, which
		// can't address every frame past 16,777,216 -- so above 65,536 Hz
		// the buffer is shorter than 256 s. Everything else (HELLO, the tap
		// delays below) is derived from b.numFrames, the real length.
		b = Buffer.alloc(s, min(s.sampleRate * 256, 2 ** 24).asInteger, 1);
		s.sync;
		if (alive.not) { cleanup.(true); nil.alwaysYield };

		// The buffer now exists: send HELLO (the boot order in README.md,
		// "Echo", is HELLO, then applyDefaults's bang, then the MIDIdef,
		// then HELLO again).
		bufferFrames = b.numFrames;
		sampleRateHz = s.sampleRate;
		if (bufferFrames < (s.sampleRate * 256)) {
			("Buffer capped at " ++ bufferFrames ++ " frames (2^24) = "
				++ (bufferFrames / s.sampleRate).round(0.1) ++ " s at "
				++ s.sampleRate.round.asInteger ++ " Hz; tap delays scaled to fit.").postln;
		};
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
			// Balance2 returns a stereo pair; the delay input bus is mono, so
			// sum it (a 2-channel Out onto the 1-channel micBus would spill
			// the right channel onto the next bus -- the write pointer).
			// `balance` therefore weights left vs right output into the mono
			// feedback: -1 = left channel only, +1 = right channel only.
			var output = Balance2.ar(input[0], input[1], balance).sum;
			output = output + (PinkNoise.ar * noiseLevel);
			output = output + (SinOsc.ar(sineHz) * sineLevel);
			// Never run HPF at 0 Hz: its state then integrates without bound
			// and is released as a burst when the cutoff is raised again.
			output = HPF.ar(output, hpFreq.max(5));
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
		if (alive.not) { cleanup.(true); nil.alwaysYield };

		// Server -> language telemetry listeners. Created before any synth
		// that could send them a reply (ptr/rec below, gran further down),
		// so nothing gets dropped at boot; freed in cleanup.
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

		// Grain lengths: 1 to 16 beats of beatDur = 0.5, 1, ... 8 s.
		durs   = 16.collect({ |i| beatDur * (i + 1) }).scramble;
		// Tap delays, in frames: (n+1)/32 of the buffer -- 8, 16, ... 128 s
		// with the full 256 s buffer, proportionally shorter when it is
		// capped. The longest tap sits at half the buffer, which leaves room
		// for position jitter (<= 2.5 s) plus the farthest a grain can drift
		// away from the write head while it plays (<= 40 s: an 8 s grain at
		// rate -4), at any sample rate up to 192 kHz.
		delays = 16.collect({ |i| bufferFrames * (i + 1) / 32 }).scramble;

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
		if (alive.not) { cleanup.(true); nil.alwaysYield };

		// Bring the whole engine to the documented default state (the same
		// state the web demo's "Send all values" sends). Each applied
		// control echoes -- the boot "bang" (README.md, "Echo").
		applyDefaults.value;

		cmdPeriodFunc = {
			cleanup.(false);
			"Carter's Delay stopped (Cmd-Period). Re-evaluate the file to restart.".postln;
		};
		CmdPeriod.add(cmdPeriodFunc);

		// The only MIDI responder. Created last, after applyDefaults, and
		// listens to all connected MIDI sources. Routes Ch1-3 CCs to
		// handleCC and a Ch16 CC1 request to reportAll (rate-limited, see
		// reportAll); everything else (the engine's own echoes on Ch9-11,
		// other channels) is silently ignored, with no logging (README.md,
		// "Loop safety").
		MIDIdef.cc(\cartersDelayCC, { |val, num, chan, src|
			if (chan <= 2) {
				handleCC.(chan, num, val);
			};
			if (chan == 15 and: { num == 1 } and: { val > 0 }) {
				reportAll.value;
			};
		});

		// HELLO again, now that the engine is listening: a request that
		// arrived before the MIDIdef existed was dropped, and this is how
		// that page finds out the engine is up. Just HELLO -- the bang
		// already went out from applyDefaults above.
		sendHello.value;

		"=== Carter's Delay ready: listening for MIDI CC on channels 1-3 ===".postln;
	}).play;
});
)

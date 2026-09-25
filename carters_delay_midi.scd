/*
   Carter's Delay - WebMIDI Controlled Version
   Additive Interval Toggles, LFNoise1 Modulation, Limiter Master Output
   Based on Carter's Delay by William Hazard (https://github.com/williamthazard/carters-delay-norns)

   MIDI Channel & CC Mapping Architecture:
   ---------------------------------------------------------------------
   CHANNEL 1: Primary Routing, Master Output & Mutes
     - CC 7 : Master Output Level (0..127 -> 0.0x..2.5x gain, default 51 = 1.0x)
     - CC 1 : Input Passthrough Level (0..127 -> 0.0..1.0, default 64)
     - CC 2 : Delay Input Level (0..127 -> 0.0..1.0, default 64)
     - CC 3 : Buffer Sound Preservation (0..127 -> 0.0..1.0 preLevel, default 64)
     - CC 4 / Note 60 : Input Passthrough Mute (0 = Off, 127 = On)
     - CC 5 / Note 61 : Delay Input Mute (0 = Off, 127 = On)
     - CC 6 / Note 62 : Delay Output Master Mute (0 = Off, 127 = On)

   CHANNEL 2: Feedback Loop Patch Mixer
     - CC 1 : Feedback Level (0..127 -> 0.0..1.0, default 0)
     - CC 2 : Feedback Balance / Stereo Pan (0..127 -> -1.0..+1.0, default 64)
     - CC 3 : Feedback High-Pass Filter Hz (0..127 -> 0..220 Hz, default 12)
     - CC 4 : Pink Noise Level (0..127 -> 0.0..1.0, default 0)
     - CC 5 : Sine Oscillator Level (0..127 -> 0.0..1.0, default 0)
     - CC 6 : Sine Oscillator Frequency (0..127 -> MIDI note 20..90 -> Hz, default 30)

   CHANNEL 3: Granular Time, Pitch Intervals & Modulation Engine
     - CC 1 : Playback Rate Multiplier (0..127 -> 0.25x..2.0x, default 64 = 1.0x)
     - CC 2 : Grain Density Multiplier (0..127 -> 0.2x..3.0x, default 64 = 1.0x)
     - CC 3 : Low-Pass Filter Cutoff (0..127 -> 200..16000 Hz, default 100 = 12000Hz)
     - CC 4 : Position Jitter / Spread (0..127 -> 0 to 2.5s jitter, default 0)
     - CC 5 : Trigger Distribution (0 = Poisson/Dust <-> 127 = Periodic/Impulse, default 127)
     - CC 6 : Grain Window Function (0..42: Hanning Bell, 43..84: Percussive Saw, 85..127: Reverse Swell)
     - CC 8 / Note 63 : Buffer Record Freeze Toggle (0 = Live Sweep, 127 = Frozen Memory Hold)
     - CC 9 : Pitch Octaves Toggle [+2:1] (0 = Off, 127 = Adds Octave Taps)
     - CC 10: Pitch 5ths & 4ths Toggle [+3:2, +4:3] (0 = Off, 127 = Adds 5th & 4th Taps)
     - CC 11: Pitch Sub-Octaves Toggle [+1:2, +1:4] (0 = Off, 127 = Adds Sub-Octave Taps)
     - CC 12: Reverse Grains Toggle [Adds -1.0x, -0.5x] (0 = Forward Only, 127 = Forward AND Reverse Taps)

   Gain Staging:
     Per-tap ampLFOs (LFNoise1, range 1..3) modulate individual grain character.
     masterVol (CC 7) scales the combined output BEFORE the brick-wall Limiter.
     Push CC 7 above 1.0x to drive the Limiter harder for maximum perceived loudness.
   ---------------------------------------------------------------------
*/

(
var oscs, b, timer, micBus, ptrBus, granBus, micGrp, ptrGrp, recGrp, granGrp, outGrp;
var panLFOs, ampLFOs, cutoffLFOs, resonanceLFOs, envBufs;
var micSynth, micPassSynth, ptrSynth, recSynth, fbSynth, masterOutSynth, granSynths;
var passLevel = 0.5, passMute = 1;
var delayInLevel = 0.5, delayInMute = 1;
var delayOutMute = 1;
var masterVol = 1.0;
var rateMult = 1.0;
var freezeActive = 0;
var octavesActive = 0, fifthsActive = 0, suboctavesActive = 0, reverseActive = 0;
var rates, baseCarterRates, durs, delays;
var updateAllTapRates, handleCC, handleNote;

// Connect to CoreMIDI
MIDIIn.connectAll;

"=== CoreMIDI Connected ===".postln;
MIDIClient.sources.do({ |src, idx|
	(" [MIDI Src " ++ idx ++ "] " ++ src.name ++ " (" ++ src.device ++ ")").postln;
});

// Configure Server memory
s.options.memSize = 2.pow(20);

// Base Carter's Delay rates (Forward by default)
baseCarterRates = [1/4, 1/2, 1, 3/2, 2];

// Additive Interval & Reverse Allocator across 16 taps
updateAllTapRates = {
	var tapAssignments = Array.newClear(16);
	var specialPool = List.new;

	// 1. Fill base Carter forward taps (Taps 0..7 always preserve core Carter forward delays)
	8.do({ |i|
		tapAssignments[i] = baseCarterRates[i % baseCarterRates.size];
	});

	// 2. Build additive pool for remaining taps (8..15)
	if (octavesActive > 0, {
		specialPool.addAll([2.0, 1.0, 2.0]);
	});
	if (fifthsActive > 0, {
		specialPool.addAll([1.5, 4/3, 9/8]);
	});
	if (suboctavesActive > 0, {
		specialPool.addAll([0.25, 0.5, 0.5]);
	});

	// If no harmonic toggles active, use standard Carter rates
	if (specialPool.size == 0, {
		specialPool.addAll(baseCarterRates);
	});

	// Assign taps 8..15 from the additive interval pool
	(8..15).do({ |i, poolIdx|
		tapAssignments[i] = specialPool[poolIdx % specialPool.size];
	});

	// 3. When Reverse is active, interleave reverse playback into taps (e.g. odd taps reverse, even taps forward)
	// This ensures BOTH forward and reverse taps play simultaneously!
	if (reverseActive > 0, {
		[1, 3, 5, 7, 9, 11, 13, 15].do({ |idx|
			tapAssignments[idx] = tapAssignments[idx].abs * -1.0;
		});
	}, {
		// When reverse toggle is OFF, all taps play strictly forward
		16.do({ |idx|
			tapAssignments[idx] = tapAssignments[idx].abs;
		});
	});

	// Apply final rate multiplier to all 16 synths
	granSynths.do({ |g, idx|
		g.set(\rate, tapAssignments[idx] * rateMult);
	});

	(" -> Tap Rates Updated (Simultaneous Forward & Reverse: " ++ (reverseActive > 0) ++ " | Octaves: " ++ (octavesActive > 0) ++ " | 5ths: " ++ (fifthsActive > 0) ++ " | Sub: " ++ (suboctavesActive > 0) ++ ")").postln;
};

// Unified Handler Functions
handleCC = { |chan, num, val|
	var chNum = chan + 1;
	("[SC MIDI IN] Channel: " ++ chNum ++ " | CC #" ++ num ++ " | Val: " ++ val).postln;

	if (chan == 0, {
		case
		{ num == 1 } {
			passLevel = (val / 127).round(0.001);
			micPassSynth.set(\amp, passLevel * passMute);
			(" -> Passthrough Level: " ++ (passLevel * 100).round(0.1) ++ "%").postln;
		}
		{ num == 2 } {
			delayInLevel = (val / 127).round(0.001);
			micSynth.set(\amp, delayInLevel * delayInMute * (1 - freezeActive));
			(" -> Delay Input Level: " ++ (delayInLevel * 100).round(0.1) ++ "%").postln;
		}
		{ num == 3 } {
			var pre = (val / 127).round(0.001);
			recSynth.set(\preLevel, if(freezeActive > 0, 1.0, pre));
			(" -> Preserve Level: " ++ (pre * 100).round(0.1) ++ "%").postln;
		}
		{ num == 4 } {
			passMute = if(val > 0, 1, 0);
			micPassSynth.set(\amp, passLevel * passMute);
			(" -> Passthrough Mute: " ++ passMute).postln;
		}
		{ num == 5 } {
			delayInMute = if(val > 0, 1, 0);
			micSynth.set(\amp, delayInLevel * delayInMute * (1 - freezeActive));
			(" -> Delay Input Mute: " ++ delayInMute).postln;
		}
		{ num == 6 } {
			delayOutMute = if(val > 0, 1, 0);
			// Restore per-tap ampLFOs when unmuting; zero when muting
			granSynths.do({ |g, idx|
				g.set(\amp, if(delayOutMute > 0, ampLFOs[idx], 0));
			});
			(" -> Delay Output Master Mute: " ++ delayOutMute).postln;
		}
		{ num == 7 } {
			// Master volume scales the combined output before the Limiter
			masterVol = (val / 51).round(0.01);
			masterOutSynth.set(\amp, masterVol);
			(" -> Master Output Volume: " ++ masterVol ++ "x").postln;
		};
	});

	if (chan == 1, {
		case
		{ num == 1 } {
			var amp = (val / 127).round(0.001);
			fbSynth.set(\amp, amp);
			(" -> Feedback Level: " ++ (amp * 100).round(0.1) ++ "%").postln;
		}
		{ num == 2 } {
			var bal = val.linlin(0, 127, -1.0, 1.0).round(0.01);
			fbSynth.set(\balance, bal);
			(" -> Feedback Balance: " ++ bal).postln;
		}
		{ num == 3 } {
			var hp = val.linlin(0, 127, 0.0, 220.0).round(0.1);
			fbSynth.set(\hpFreq, hp);
			(" -> Feedback HPF: " ++ hp ++ " Hz").postln;
		}
		{ num == 4 } {
			var nAmp = (val / 127).round(0.001);
			fbSynth.set(\noiseLevel, nAmp);
			(" -> Pink Noise Level: " ++ (nAmp * 100).round(0.1) ++ "%").postln;
		}
		{ num == 5 } {
			var sAmp = (val / 127).round(0.001);
			fbSynth.set(\sineLevel, sAmp);
			(" -> Sine Oscillator Level: " ++ (sAmp * 100).round(0.1) ++ "%").postln;
		}
		{ num == 6 } {
			var note = val.linlin(0, 127, 20, 90).round;
			var hz = note.midicps.round(0.1);
			fbSynth.set(\sineHz, hz);
			(" -> Sine Oscillator Frequency: " ++ hz ++ " Hz (Note " ++ note ++ ")").postln;
		};
	});

	if (chan == 2, {
		case
		{ num == 1 } {
			rateMult = val.linlin(0, 127, 0.25, 2.0).round(0.01);
			updateAllTapRates.();
			(" -> Playback Rate Multiplier: " ++ rateMult ++ "x").postln;
		}
		{ num == 2 } {
			var densMult = val.linlin(0, 127, 0.2, 3.0).round(0.01);
			granSynths.do({ |g, idx|
				var baseDens = 1 / (durs[idx] * baseCarterRates[idx % baseCarterRates.size]);
				g.set(\dens, (baseDens * densMult).abs);
			});
			(" -> Grain Density Multiplier: " ++ densMult ++ "x").postln;
		}
		{ num == 3 } {
			var cut = val.linexp(0, 127, 200, 16000).round(1);
			granSynths.do({ |g| g.set(\cutoff, cut) });
			(" -> Low-Pass Filter Cutoff: " ++ cut ++ " Hz").postln;
		}
		{ num == 4 } {
			var jitterSecs = (val / 127) * 2.5;
			var jitterSamples = s.sampleRate * jitterSecs;
			granSynths.do({ |g, idx|
				g.set(\ptrRandSamples, jitterSamples);
			});
			(" -> Position Jitter / Spread: " ++ jitterSecs.round(0.01) ++ " sec").postln;
		}
		{ num == 5 } {
			var syncVal = (val / 127).round(0.01);
			granSynths.do({ |g| g.set(\sync, syncVal) });
			(" -> Trigger Distribution: " ++ (syncVal * 100).round(1) ++ "%").postln;
		}
		{ num == 6 } {
			var envIdx = (val / 43).floor.clip(0, 2).asInteger;
			var targetBuf = if(envIdx == 0, -1, envBufs[envIdx - 1].bufnum);
			granSynths.do({ |g| g.set(\grainEnv, targetBuf) });
			(" -> Grain Window Function: " ++ ["Hanning Bell Window", "Percussive Decaying Window", "Reverse Attack Swell Window"][envIdx]).postln;
		}
		{ num == 8 } {
			freezeActive = if(val > 0, 1, 0);
			if (freezeActive > 0, {
				ptrSynth.set(\rate, 0);
				recSynth.set(\preLevel, 1.0);
				micSynth.set(\amp, 0);
				(" -> [RECORD FREEZE ACTIVE] Audio buffer locked in memory.").postln;
			}, {
				ptrSynth.set(\rate, 1);
				recSynth.set(\preLevel, 0.5);
				micSynth.set(\amp, delayInLevel * delayInMute);
				(" -> [RECORD FREEZE INACTIVE] Live recording active.").postln;
			});
		}
		{ num == 9 } {
			octavesActive = if(val > 0, 1, 0);
			updateAllTapRates.();
		}
		{ num == 10 } {
			fifthsActive = if(val > 0, 1, 0);
			updateAllTapRates.();
		}
		{ num == 11 } {
			suboctavesActive = if(val > 0, 1, 0);
			updateAllTapRates.();
		}
		{ num == 12 } {
			reverseActive = if(val > 0, 1, 0);
			updateAllTapRates.();
		};
	});
};

handleNote = { |chan, num, val|
	var chNum = chan + 1;
	("[SC MIDI IN] Channel: " ++ chNum ++ " | Note #" ++ num ++ " | Vel: " ++ val).postln;

	if (chan == 0, {
		case
		{ num == 60 } {
			passMute = 1 - passMute;
			micPassSynth.set(\amp, passLevel * passMute);
			(" -> Passthrough Mute: " ++ passMute).postln;
		}
		{ num == 61 } {
			delayInMute = 1 - delayInMute;
			micSynth.set(\amp, delayInLevel * delayInMute * (1 - freezeActive));
			(" -> Delay Input Mute: " ++ delayInMute).postln;
		}
		{ num == 62 } {
			delayOutMute = 1 - delayOutMute;
			// Restore per-tap ampLFOs when unmuting; zero when muting
			granSynths.do({ |g, idx|
				g.set(\amp, if(delayOutMute > 0, ampLFOs[idx], 0));
			});
			(" -> Delay Output Master Mute: " ++ delayOutMute).postln;
		}
		{ num == 63 } {
			freezeActive = 1 - freezeActive;
			if (freezeActive > 0, {
				ptrSynth.set(\rate, 0);
				recSynth.set(\preLevel, 1.0);
				micSynth.set(\amp, 0);
				(" -> [RECORD FREEZE TOGGLED ACTIVE] Audio buffer locked.").postln;
			}, {
				ptrSynth.set(\rate, 1);
				recSynth.set(\preLevel, 0.5);
				micSynth.set(\amp, delayInLevel * delayInMute);
				(" -> [RECORD FREEZE TOGGLED INACTIVE] Live recording active.").postln;
			});
		};
	});
};

// Direct raw MIDIIn hook
MIDIIn.control = { |src, chan, num, val| handleCC.(chan, num, val) };
MIDIIn.noteOn  = { |src, chan, num, val| handleNote.(chan, num, val) };

s.waitForBoot({
	Routine({
		"=== Loading Carter's Delay Engine... ===".postln;

		// Custom Grain Envelope Windows (512-sample buffers)
		envBufs = [
			Buffer.sendCollection(s, Env.perc(0.01, 0.99, 1, -4).asSignal(512)),
			Buffer.sendCollection(s, Env.new([0, 1, 0], [0.98, 0.02], [4, -4]).asSignal(512))
		];

		timer = LinkClock.new(2).latency_(s.latency).quantum_(0);
		b = Buffer.alloc(s, s.sampleRate * (timer.beatDur * 512), 1);
		s.sync;

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

		// Master Output with Limiter (replaces softclip for transparent peak control)
		// masterVol (CC 7) scales the signal BEFORE the Limiter.
		// At masterVol 1.0x, signal passes cleanly through.
		// Push masterVol above 1.0x to drive harder into the Limiter for more perceived loudness.
		// Limiter catches peaks at 0dBFS — no clipping, no headroom eaten by softclip compression.
		SynthDef(\masterOutput, {
			arg in = 0, out = 0, amp = 1.0;
			var sig = In.ar(in, 2);
			sig = Limiter.ar(sig * amp, 1.0, 0.01);
			Out.ar(out, sig);
		}).add;

		SynthDef(\ptr, {
			arg out = 0, buf = 0, rate = 1;
			var sig = Phasor.ar(0, BufRateScale.kr(buf) * rate, 0, BufFrames.kr(buf));
			Out.ar(out, sig);
		}).add;

		SynthDef(\rec, {
			arg ptrIn = 0, micIn = 0, buf = 0, preLevel = 0.5;
			var ptr = In.ar(ptrIn, 1);
			var sig = In.ar(micIn, 1);
			sig = sig + (BufRd.ar(1, buf, ptr) * preLevel);
			BufWr.ar(sig, buf, ptr);
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

		SynthDef(\gran, {
			arg amp = 0.8, buf = 0, out = 0,
			atk = 1, rel = 1, gate = 1,
			sync = 1.0, dens = 40,
			baseDur = 0.05, durRand = 1,
			rate = 1, rateRand = 1,
			pan = 0, panRand = 0,
			grainEnv = (-1), ptrBus = 0, ptrSampleDelay = 20000,
			ptrRandSamples = 0, minPtrDelay = 1000,
			cutoff = 12000, resonance = 1;
			var sig, env, densCtrl, durCtrl, rateCtrl, panCtrl;
			var ptr, ptrRand, totalDelay, maxGrainDur, grainTrigger;

			env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction: 2);

			grainTrigger = (Dust.ar(dens) * (1 - sync)) + (Impulse.ar(dens) * sync);

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
				freq: cutoff.clip(50, 18000),
				gain: resonance.clip(0, 4)
			);
			Out.ar(out, sig);
		}).add;

		s.sync;

		micGrp   = Group.new;
		ptrGrp   = Group.after(micGrp);
		recGrp   = Group.after(ptrGrp);
		granGrp  = Group.after(recGrp);
		outGrp   = Group.after(granGrp);

		micSynth     = Synth(\mic, [\in, 0, \out, micBus, \amp, delayInLevel * delayInMute], micGrp);
		micPassSynth = Synth(\micOut, [\in, 0, \out, granBus, \amp, passLevel * passMute], granGrp);
		ptrSynth     = Synth(\ptr, [\buf, b, \out, ptrBus], ptrGrp);
		recSynth     = Synth(\rec, [\ptrIn, ptrBus, \micIn, micBus, \buf, b, \preLevel, 0.5], recGrp);
		fbSynth      = Synth(\fbPatchMix, [\in, 0, \out, micBus, \amp, 0.0], micGrp, \addToHead);
		masterOutSynth = Synth(\masterOutput, [\in, granBus, \out, 0, \amp, masterVol], outGrp);

		// LFNoise1 LFOs — low-frequency noise for naturalistic, non-repetitive modulation
		// (replaces LFTri for organic motion as in the original Carter's Delay spirit)
		panLFOs = Array.fill(16, { |i|
			Ndef((\pan ++ i).asSymbol, {
				LFNoise1.kr(timer.beatDur / rrand(1, 64)).range(-1, 1)
			})
		});

		// Per-tap amplitude LFOs — range 1..3 matches original SeamstressCarter (~ampLFOs)
		// These give each tap organic fade in/out character.
		// masterVol (CC 7) controls the overall mix level independently.
		ampLFOs = Array.fill(16, { |i|
			Ndef((\amp ++ i).asSymbol, {
				LFNoise1.kr(timer.beatDur / rrand(1, 64)).range(1, 3)
			})
		});

		cutoffLFOs = Array.fill(16, { |i|
			Ndef((\cut ++ i).asSymbol, {
				LFNoise1.kr(timer.beatDur / rrand(1, 64)).range(500, 15000)
			})
		});

		resonanceLFOs = Array.fill(16, { |i|
			Ndef((\res ++ i).asSymbol, {
				LFNoise1.kr(timer.beatDur / rrand(1, 64)).range(0, 2)
			})
		});

		rates  = baseCarterRates;
		durs   = 16.collect({ |i| timer.beatDur * (i + 1) }).scramble;
		delays = 16.collect({ |i| s.sampleRate * (timer.beatDur * (i + 1)) * 16 }).scramble;

		// Initialize 16 granular taps with per-tap ampLFOs (organic amplitude modulation)
		granSynths = 16.collect({ |n|
			Synth(\gran, [
				\amp, if(delayOutMute > 0, ampLFOs[n], 0),
				\buf, b,
				\out, granBus,
				\atk, 1, \rel, 1, \gate, 1, \sync, 1.0,
				\dens, 1 / (durs[n] * rates[n % rates.size]),
				\baseDur, durs[n],
				\durRand, 1,
				\rate, rates[n % rates.size],
				\rateRand, 1,
				\pan, panLFOs[n],
				\panRand, 0,
				\grainEnv, -1,
				\ptrBus, ptrBus,
				\ptrSampleDelay, delays[n],
				\ptrRandSamples, 0,
				\minPtrDelay, delays[n],
				\cutoff, cutoffLFOs[n],
				\resonance, resonanceLFOs[n]
			], granGrp);
		});

		s.sync;

		"=== Carter's Delay Ready & Listening to WebMIDI! ===".postln;
	}).play;
});
)
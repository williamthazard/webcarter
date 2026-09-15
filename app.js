/**
 * Carter's Delay — WebMIDI Demo Application Logic (Additive Toggles & Interleaved Forward/Reverse)
 */

(function () {
  // State
  let midiAccess = null;
  let midiOutput = null;
  let channelMode = "multi"; // "multi" or "ch1"
  let webAudioActive = false;
  let audioEngine = null;

  // Microphone Audio State
  let micActive = false;
  let micStream = null;
  let micAudioCtx = null;
  let micAnalyser = null;
  let micDataArray = null;

  // DOM Elements
  const statusDotEl = document.getElementById("statusDot");
  const statusTextEl = document.getElementById("statusText");
  const midiOutputSelect = document.getElementById("midiOutputSelect");
  const midiChannelModeSelect = document.getElementById("midiChannelMode");
  const btnMicInput = document.getElementById("btnMicInput");
  const micStateEl = document.getElementById("micState");
  const btnWebAudio = document.getElementById("btnWebAudio");
  const webAudioStateEl = document.getElementById("webAudioState");
  const btnPanic = document.getElementById("btnPanic");
  const btnSendAll = document.getElementById("btnSendAll");
  const btnClearLog = document.getElementById("btnClearLog");
  const logContainer = document.getElementById("logContainer");
  const scopeCanvas = document.getElementById("scopeCanvas");
  const ctx = scopeCanvas.getContext("2d");

  // Interval Toggle State (Independent Additive Mix & Match)
  const intervalToggles = {
    octaves: false,    // CC 9 [2:1]
    fifths: false,     // CC 10 [3:2, 4:3]
    suboctaves: false, // CC 11 [1:2, 1:4]
    reverse: false     // CC 12 [Interleaves reverse taps]
  };

  const baseCarterRatios = [0.25, 0.5, 1.0, 1.5, 2.0];

  // Computes the active rates for all 16 taps additively
  function get16TapRates() {
    const tapRates = new Array(16);
    const specialPool = [];

    // Taps 0..7 always preserve core forward Carter ratios
    for (let i = 0; i < 8; i++) {
      tapRates[i] = baseCarterRatios[i % baseCarterRatios.length];
    }

    // Add extra intervals to pool
    if (intervalToggles.octaves) specialPool.push(2.0, 1.0, 2.0);
    if (intervalToggles.fifths) specialPool.push(1.5, 1.333, 1.125);
    if (intervalToggles.suboctaves) specialPool.push(0.25, 0.5, 0.5);

    if (specialPool.length === 0) {
      specialPool.push(...baseCarterRatios);
    }

    // Assign taps 8..15 from additive interval pool
    for (let i = 8; i < 16; i++) {
      tapRates[i] = specialPool[(i - 8) % specialPool.length];
    }

    // When reverse is active, interleave odd taps to reverse (-1.0)
    // while even taps continue playing FORWARD! Both play simultaneously.
    if (intervalToggles.reverse) {
      [1, 3, 5, 7, 9, 11, 13, 15].forEach(idx => {
        tapRates[idx] = -Math.abs(tapRates[idx]);
      });
    } else {
      for (let i = 0; i < 16; i++) {
        tapRates[i] = Math.abs(tapRates[i]);
      }
    }

    return tapRates;
  }

  // Envelope Window Functions
  const envWindows = ["Hanning (Default)", "Percussive Saw", "Reverse Swell"];

  // Control State Object (Defaults matching Carter's Delay)
  const state = {
    masterVol: 51,     // Ch 1 CC 7 (51 = 1.0x Unity Gain)
    passLevel: 64,     // Ch 1 CC 1 (50%)
    passMute: true,    // Ch 1 CC 4 / Note 60
    delayInLevel: 64,  // Ch 1 CC 2 (50%)
    delayInMute: true, // Ch 1 CC 5 / Note 61
    preserveLevel: 64, // Ch 1 CC 3 (50%)
    delayOutMute: true,// Ch 1 CC 6 / Note 62
    
    fbLevel: 0,        // Ch 2 CC 1 (0%)
    fbBalance: 64,     // Ch 2 CC 2 (Center)
    fbHp: 12,          // Ch 2 CC 3 (12 Hz)
    fbNoise: 0,        // Ch 2 CC 4 (0%)
    fbSineLevel: 0,    // Ch 2 CC 5 (0%)
    fbSinePitch: 30,   // Ch 2 CC 6 (55Hz / A1)

    grainRate: 64,     // Ch 3 CC 1 (1.0x)
    grainDens: 64,     // Ch 3 CC 2 (1.0x)
    cutoff: 100,       // Ch 3 CC 3 (12000Hz)
    jumble: 0,         // Ch 3 CC 4 (0.00s Default)
    syncMode: 127,     // Ch 3 CC 5 (127 = Periodic Impulse Default)
    envShape: 0,       // Ch 3 CC 6 (0 = Hanning Default)
    freeze: false      // Ch 3 CC 8 / Note 63 (False Default)
  };

  // 512-Point Ring Buffer for Recording Audio Waveform
  const bufferLength = 512;
  const audioRingBuffer = new Float32Array(bufferLength);
  let lastWriteIndex = 0;

  // 16 Granular Delay Tap Slices with Variable LFO Speeds
  const taps = Array.from({ length: 16 }, (_, i) => {
    const rrandDiv = 1 + Math.random() * 63;
    const lfoSpeed = 0.002 + (1 / rrandDiv) * 0.035;
    return {
      id: i,
      delayOffset: 0.05 + (i * 0.055),
      lfoSpeed: lfoSpeed,
      playheadProgress: Math.random(),
      panPhase: Math.random() * Math.PI * 2,
      pan: 0
    };
  });

  let recPointer = 0;

  // Canvas HiDPI Scaling setup (Strict Dimension Safeguards)
  let canvasCssWidth = 900;
  let canvasCssHeight = 180;

  function setupCanvasScaling() {
    if (!scopeCanvas) return;
    const rect = scopeCanvas.getBoundingClientRect();
    const targetWidth = rect.width > 50 ? rect.width : (scopeCanvas.parentElement ? scopeCanvas.parentElement.clientWidth : 900);
    if (!targetWidth) return;

    canvasCssWidth = targetWidth;
    canvasCssHeight = 180;

    const dpr = window.devicePixelRatio || 1;
    scopeCanvas.width = Math.floor(targetWidth * dpr);
    scopeCanvas.height = Math.floor(canvasCssHeight * dpr);
    ctx.resetTransform();
    ctx.scale(dpr, dpr);
  }

  window.addEventListener("resize", setupCanvasScaling);
  if (window.ResizeObserver && scopeCanvas) {
    new ResizeObserver(() => setupCanvasScaling()).observe(scopeCanvas);
  }

  // Direct native requestMIDIAccess
  if (navigator.requestMIDIAccess) {
    navigator.requestMIDIAccess({ sysex: false }).then(onMIDISuccess, onMIDIFailure);
  } else {
    log("navigator.requestMIDIAccess is not supported in this browser.", "alert");
    statusDotEl.className = "indicator offline";
    statusTextEl.textContent = "WebMIDI Unsupported";
  }

  async function onMIDISuccess(access) {
    midiAccess = access;
    log("WebMIDI Access granted.", "system");
    await updateOutputs();
    midiAccess.onstatechange = async () => await updateOutputs();
  }

  function onMIDIFailure(err) {
    log("WebMIDI Access Failed: " + err, "alert");
    statusDotEl.className = "indicator offline";
    statusTextEl.textContent = "WebMIDI Denied";
  }

  async function updateOutputs() {
    if (!midiAccess) return;
    const outputs = Array.from(midiAccess.outputs.values());
    midiOutputSelect.innerHTML = "";

    if (outputs.length === 0) {
      const opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "No MIDI Devices Detected";
      midiOutputSelect.appendChild(opt);
      midiOutput = null;
      statusDotEl.className = "indicator offline";
      statusTextEl.textContent = "No Devices";
      return;
    }

    let defaultIndex = 0;
    outputs.forEach((output, idx) => {
      const opt = document.createElement("option");
      opt.value = output.id;
      opt.textContent = output.name;
      midiOutputSelect.appendChild(opt);

      if (output.name.includes("IAC") || output.name.includes("Bus 1")) {
        defaultIndex = idx;
      }
    });

    midiOutputSelect.selectedIndex = defaultIndex;
    midiOutput = outputs[defaultIndex];

    try {
      if (midiOutput.connection !== "open") {
        await midiOutput.open();
      }
    } catch (e) {
      console.warn("Could not open MIDI output:", e);
    }

    statusDotEl.className = "indicator online";
    statusTextEl.textContent = "Connected: " + midiOutput.name;
    log(`Selected Output: ${midiOutput.name} (${midiOutput.connection})`, "system");
  }

  midiOutputSelect.addEventListener("change", async (e) => {
    if (midiAccess) {
      midiOutput = midiAccess.outputs.get(e.target.value);
    }
    if (midiOutput) {
      try {
        if (midiOutput.connection !== "open") {
          await midiOutput.open();
        }
      } catch (err) {
        console.warn("Could not open MIDI output:", err);
      }
      statusDotEl.className = "indicator online";
      statusTextEl.textContent = "Connected: " + midiOutput.name;
      log(`Switched to Output: ${midiOutput.name} (${midiOutput.connection})`, "system");
    }
  });

  midiChannelModeSelect.addEventListener("change", (e) => {
    channelMode = e.target.value;
    log("Channel Mode: " + e.target.options[e.target.selectedIndex].text, "system");
  });

  function getChannel(targetCh) {
    return channelMode === "ch1" ? 1 : targetCh;
  }

  function sendCC(targetChannel, controller, value, ccName) {
    const ch = getChannel(targetChannel);
    const val = parseInt(value, 10);

    if (midiOutput) {
      if (midiOutput.connection !== "open") {
        midiOutput.open().then(() => {
          const status = 0xB0 | ((ch - 1) & 0x0F);
          midiOutput.send([status, controller, val]);
        });
      } else {
        const status = 0xB0 | ((ch - 1) & 0x0F);
        midiOutput.send([status, controller, val]);
      }
    }

    const msgClass = "ch" + targetChannel + "-msg";
    log("[Ch " + ch + "] CC #" + controller + " (" + ccName + ") = " + val, msgClass);

    if (webAudioActive && audioEngine) {
      audioEngine.updateParam(targetChannel, controller, val);
    }
  }

  function sendNote(targetChannel, note, velocity, noteName) {
    const ch = getChannel(targetChannel);
    const vel = parseInt(velocity, 10);

    if (midiOutput) {
      if (midiOutput.connection !== "open") {
        midiOutput.open().then(() => {
          const status = (vel > 0 ? 0x90 : 0x80) | ((ch - 1) & 0x0F);
          midiOutput.send([status, note, vel]);
        });
      } else {
        const status = (vel > 0 ? 0x90 : 0x80) | ((ch - 1) & 0x0F);
        midiOutput.send([status, note, vel]);
      }
    }

    const msgClass = "ch" + targetChannel + "-msg";
    log("[Ch " + ch + "] Note #" + note + " (" + noteName + ") Vel: " + vel, msgClass);
  }

  function log(msg, type = "") {
    const timeStr = new Date().toISOString().substring(11, 19);
    const div = document.createElement("div");
    div.className = "log-entry " + type;
    div.textContent = "[" + timeStr + "] " + msg;
    logContainer.appendChild(div);
    logContainer.scrollTop = logContainer.scrollHeight;
  }

  btnClearLog.addEventListener("click", () => {
    logContainer.innerHTML = "";
    log("Log cleared.", "system");
  });

  // Microphone Audio Capture Setup
  async function toggleMicrophone() {
    if (micActive) {
      if (micStream) {
        micStream.getTracks().forEach(track => track.stop());
        micStream = null;
      }
      micActive = false;
      micStateEl.textContent = "OFF";
      btnMicInput.classList.remove("btn-primary");
      btnMicInput.classList.add("btn-secondary");
      log("Microphone recording disabled.", "system");
    } else {
      try {
        log("Requesting microphone permissions...", "system");
        micStream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
        micAudioCtx = new (window.AudioContext || window.webkitAudioContext)();
        if (micAudioCtx.state === "suspended") {
          await micAudioCtx.resume();
        }
        const source = micAudioCtx.createMediaStreamSource(micStream);
        micAnalyser = micAudioCtx.createAnalyser();
        micAnalyser.fftSize = 256;
        source.connect(micAnalyser);
        micDataArray = new Uint8Array(micAnalyser.frequencyBinCount);

        micActive = true;
        micStateEl.textContent = "ON";
        btnMicInput.classList.remove("btn-secondary");
        btnMicInput.classList.add("btn-primary");
        log("Microphone recording active.", "system");
      } catch (err) {
        log("Microphone Access Error: " + err.message, "alert");
      }
    }
  }

  btnMicInput.addEventListener("click", toggleMicrophone);

  function getMicSample() {
    if (!micActive || !micAnalyser || !micDataArray) return 0;
    micAnalyser.getByteTimeDomainData(micDataArray);
    let maxDiff = 0;
    for (let i = 0; i < micDataArray.length; i++) {
      const diff = (micDataArray[i] - 128) / 128;
      if (Math.abs(diff) > Math.abs(maxDiff)) {
        maxDiff = diff;
      }
    }
    return maxDiff * 1.8;
  }

  // Setup UI Listeners & Double-Click Reset
  function setupUIControls() {
    function setupResetableSlider(sliderEl, onUpdate) {
      sliderEl.addEventListener("input", (e) => {
        onUpdate(parseInt(e.target.value, 10));
      });
      sliderEl.addEventListener("dblclick", () => {
        const def = parseInt(sliderEl.getAttribute("data-default") || "64", 10);
        sliderEl.value = def;
        onUpdate(def);
        log(`Reset ${sliderEl.id} to default (${def})`, "system");
      });
    }

    // Channel 1: Master Output Level (CC 7)
    const cc7_masterVol = document.getElementById("cc7_masterVol");
    const val_cc7_ch1 = document.getElementById("val_cc7_ch1");
    setupResetableSlider(cc7_masterVol, (v) => {
      state.masterVol = v;
      const gain = (v / 51).toFixed(2);
      val_cc7_ch1.textContent = `${gain}x (${v <= 51 ? 'Normal' : 'Boost'})`;
      sendCC(1, 7, v, "Master Output Level");
    });

    // Channel 1: Main Controls
    const cc1_passthru = document.getElementById("cc1_passthru");
    const val_cc1_ch1 = document.getElementById("val_cc1_ch1");
    setupResetableSlider(cc1_passthru, (v) => {
      state.passLevel = v;
      val_cc1_ch1.textContent = Math.round((v / 127) * 100) + "%";
      sendCC(1, 1, v, "Input Passthrough Level");
    });

    const btnCc4 = document.getElementById("btn_cc4");
    btnCc4.addEventListener("click", () => {
      state.passMute = !state.passMute;
      btnCc4.classList.toggle("active", state.passMute);
      btnCc4.textContent = state.passMute ? "MUTE" : "MUTED";
      sendCC(1, 4, state.passMute ? 127 : 0, "Passthrough Mute CC");
      sendNote(1, 60, state.passMute ? 127 : 0, "Passthrough Mute Note");
    });

    const cc2_delayIn = document.getElementById("cc2_delayIn");
    const val_cc2_ch1 = document.getElementById("val_cc2_ch1");
    setupResetableSlider(cc2_delayIn, (v) => {
      state.delayInLevel = v;
      val_cc2_ch1.textContent = Math.round((v / 127) * 100) + "%";
      sendCC(1, 2, v, "Delay Input Level");
    });

    const btnCc5 = document.getElementById("btn_cc5");
    btnCc5.addEventListener("click", () => {
      state.delayInMute = !state.delayInMute;
      btnCc5.classList.toggle("active", state.delayInMute);
      btnCc5.textContent = state.delayInMute ? "MUTE" : "MUTED";
      sendCC(1, 5, state.delayInMute ? 127 : 0, "Delay Input Mute CC");
      sendNote(1, 61, state.delayInMute ? 127 : 0, "Delay Input Mute Note");
    });

    const cc3_preserve = document.getElementById("cc3_preserve");
    const val_cc3_ch1 = document.getElementById("val_cc3_ch1");
    setupResetableSlider(cc3_preserve, (v) => {
      state.preserveLevel = v;
      val_cc3_ch1.textContent = Math.round((v / 127) * 100) + "%";
      sendCC(1, 3, v, "Buffer Sound Preservation");
    });

    const btnCc6 = document.getElementById("btn_cc6");
    btnCc6.addEventListener("click", () => {
      state.delayOutMute = !state.delayOutMute;
      btnCc6.classList.toggle("active", state.delayOutMute);
      btnCc6.textContent = state.delayOutMute ? "DELAY OUTPUT ACTIVE" : "DELAY OUTPUT MUTED";
      sendCC(1, 6, state.delayOutMute ? 127 : 0, "Delay Output Mute CC");
      sendNote(1, 62, state.delayOutMute ? 127 : 0, "Delay Output Mute Note");
    });

    // Channel 2: Feedback Controls
    const cc1_fbAmp = document.getElementById("cc1_fbAmp");
    const val_cc1_ch2 = document.getElementById("val_cc1_ch2");
    setupResetableSlider(cc1_fbAmp, (v) => {
      state.fbLevel = v;
      val_cc1_ch2.textContent = Math.round((v / 127) * 100) + "%";
      sendCC(2, 1, v, "Feedback Level");
    });

    const cc2_fbBal = document.getElementById("cc2_fbBal");
    const val_cc2_ch2 = document.getElementById("val_cc2_ch2");
    setupResetableSlider(cc2_fbBal, (v) => {
      state.fbBalance = v;
      const balNorm = (v - 64) / 64;
      val_cc2_ch2.textContent = balNorm === 0 ? "Center" : balNorm < 0 ? "L " + Math.abs(Math.round(balNorm * 100)) + "%" : "R " + Math.round(balNorm * 100) + "%";
      sendCC(2, 2, v, "Feedback Balance");
    });

    const cc3_fbHp = document.getElementById("cc3_fbHp");
    const val_cc3_ch2 = document.getElementById("val_cc3_ch2");
    setupResetableSlider(cc3_fbHp, (v) => {
      state.fbHp = v;
      const hz = Math.round((v / 127) * 220);
      val_cc3_ch2.textContent = hz + " Hz";
      sendCC(2, 3, v, "Feedback Highpass Hz");
    });

    const cc4_fbNoise = document.getElementById("cc4_fbNoise");
    const val_cc4_ch2 = document.getElementById("val_cc4_ch2");
    setupResetableSlider(cc4_fbNoise, (v) => {
      state.fbNoise = v;
      val_cc4_ch2.textContent = Math.round((v / 127) * 100) + "%";
      sendCC(2, 4, v, "Pink Noise Level");
    });

    const cc5_fbSineLvl = document.getElementById("cc5_fbSineLvl");
    const val_cc5_ch2 = document.getElementById("val_cc5_ch2");
    setupResetableSlider(cc5_fbSineLvl, (v) => {
      state.fbSineLevel = v;
      val_cc5_ch2.textContent = Math.round((v / 127) * 100) + "%";
      sendCC(2, 5, v, "Sine Level");
    });

    const cc6_fbSinePitch = document.getElementById("cc6_fbSinePitch");
    const val_cc6_ch2 = document.getElementById("val_cc6_ch2");
    setupResetableSlider(cc6_fbSinePitch, (v) => {
      state.fbSinePitch = v;
      const midiNote = Math.round(20 + (v / 127) * 70);
      const hz = Math.round(440 * Math.pow(2, (midiNote - 69) / 12));
      val_cc6_ch2.textContent = hz + " Hz";
      sendCC(2, 6, v, "Sine Frequency");
    });

    // Channel 3: Granular Controls
    // Buffer Record Freeze Toggle (CC 8 / Note 63)
    const btnFreeze = document.getElementById("btn_freeze");
    btnFreeze.addEventListener("click", () => {
      state.freeze = !state.freeze;
      btnFreeze.classList.toggle("active", state.freeze);
      btnFreeze.textContent = state.freeze ? "RECORDING FROZEN (MEMORY HELD)" : "RECORDING ACTIVE (FREEZE OFF)";
      sendCC(3, 8, state.freeze ? 127 : 0, "Buffer Record Freeze CC");
      sendNote(3, 63, state.freeze ? 127 : 0, "Buffer Record Freeze Note");
    });

    // Independent Additive Interval Toggles (CC 9, 10, 11, 12)
    const val_intervals_status = document.getElementById("val_intervals_status");

    function updateIntervalStatusText() {
      let activeNames = [];
      if (intervalToggles.octaves) activeNames.push("Octaves");
      if (intervalToggles.fifths) activeNames.push("5ths/4ths");
      if (intervalToggles.suboctaves) activeNames.push("Sub-Oct");
      if (intervalToggles.reverse) activeNames.push("Reverse");
      val_intervals_status.textContent = activeNames.length > 0 ? activeNames.join(" + ") : "Default [1/4..2/1]";
    }

    const btnOctaves = document.getElementById("btn_octaves");
    btnOctaves.addEventListener("click", () => {
      intervalToggles.octaves = !intervalToggles.octaves;
      btnOctaves.classList.toggle("active", intervalToggles.octaves);
      updateIntervalStatusText();
      sendCC(3, 9, intervalToggles.octaves ? 127 : 0, "Pitch Octaves Toggle");
    });

    const btnFifths = document.getElementById("btn_fifths");
    btnFifths.addEventListener("click", () => {
      intervalToggles.fifths = !intervalToggles.fifths;
      btnFifths.classList.toggle("active", intervalToggles.fifths);
      updateIntervalStatusText();
      sendCC(3, 10, intervalToggles.fifths ? 127 : 0, "Pitch 5ths & 4ths Toggle");
    });

    const btnSuboctaves = document.getElementById("btn_suboctaves");
    btnSuboctaves.addEventListener("click", () => {
      intervalToggles.suboctaves = !intervalToggles.suboctaves;
      btnSuboctaves.classList.toggle("active", intervalToggles.suboctaves);
      updateIntervalStatusText();
      sendCC(3, 11, intervalToggles.suboctaves ? 127 : 0, "Pitch Sub-Octaves Toggle");
    });

    const btnReverse = document.getElementById("btn_reverse");
    btnReverse.addEventListener("click", () => {
      intervalToggles.reverse = !intervalToggles.reverse;
      btnReverse.classList.toggle("active", intervalToggles.reverse);
      updateIntervalStatusText();
      sendCC(3, 12, intervalToggles.reverse ? 127 : 0, "Reverse Grains Toggle");
    });

    // Pointer Position Jitter / Spread (CC 4)
    const cc4_jumble = document.getElementById("cc4_jumble");
    const val_cc4_ch3 = document.getElementById("val_cc4_ch3");
    setupResetableSlider(cc4_jumble, (v) => {
      state.jumble = v;
      const secs = ((v / 127) * 2.5).toFixed(2);
      val_cc4_ch3.textContent = `${secs}s ${v === 0 ? '(Default)' : ''}`;
      sendCC(3, 4, v, "Position Jitter Spread");
    });

    // Grain Trigger Distribution (CC 5)
    const cc5_sync = document.getElementById("cc5_sync");
    const val_cc5_ch3 = document.getElementById("val_cc5_ch3");
    setupResetableSlider(cc5_sync, (v) => {
      state.syncMode = v;
      val_cc5_ch3.textContent = v === 127 ? "Periodic (Default)" : v === 0 ? "Poisson (Dust)" : `Continuous (${Math.round((v / 127) * 100)}%)`;
      sendCC(3, 5, v, "Trigger Distribution");
    });

    // Grain Window Function (CC 6)
    const cc6_envShape = document.getElementById("cc6_envShape");
    const val_cc6_ch3 = document.getElementById("val_cc6_ch3");
    setupResetableSlider(cc6_envShape, (v) => {
      state.envShape = v;
      const idx = Math.min(2, Math.floor(v / 43));
      val_cc6_ch3.textContent = envWindows[idx];
      sendCC(3, 6, v, "Grain Window Function");
    });

    // Playback Rate Multiplier (CC 1)
    const cc1_grainRate = document.getElementById("cc1_grainRate");
    const val_cc1_ch3 = document.getElementById("val_cc1_ch3");
    setupResetableSlider(cc1_grainRate, (v) => {
      state.grainRate = v;
      const scale = (0.25 + (v / 127) * 1.75).toFixed(2);
      val_cc1_ch3.textContent = scale + "x";
      sendCC(3, 1, v, "Playback Rate Multiplier");
    });

    // Grain Density Multiplier (CC 2)
    const cc2_grainDens = document.getElementById("cc2_grainDens");
    const val_cc2_ch3 = document.getElementById("val_cc2_ch3");
    setupResetableSlider(cc2_grainDens, (v) => {
      state.grainDens = v;
      const scale = (0.2 + (v / 127) * 2.8).toFixed(2);
      val_cc2_ch3.textContent = scale + "x";
      sendCC(3, 2, v, "Grain Density Multiplier");
    });

    // Low-Pass Filter Cutoff (CC 3)
    const cc3_cutoff = document.getElementById("cc3_cutoff");
    const val_cc3_ch3 = document.getElementById("val_cc3_ch3");
    setupResetableSlider(cc3_cutoff, (v) => {
      state.cutoff = v;
      const hz = Math.round(200 * Math.pow(80, v / 127));
      val_cc3_ch3.textContent = hz + " Hz";
      sendCC(3, 3, v, "Low-Pass Filter Cutoff");
    });

    btnSendAll.addEventListener("click", () => {
      log("Syncing all parameters...", "system");
      sendCC(1, 7, state.masterVol, "Master Output Level");
      sendCC(1, 1, state.passLevel, "Input Passthrough Level");
      sendCC(1, 2, state.delayInLevel, "Delay Input Level");
      sendCC(1, 3, state.preserveLevel, "Buffer Sound Preservation");
      sendCC(1, 4, state.passMute ? 127 : 0, "Passthrough Mute");
      sendCC(1, 5, state.delayInMute ? 127 : 0, "Delay Input Mute");
      sendCC(1, 6, state.delayOutMute ? 127 : 0, "Delay Out Mute");

      sendCC(2, 1, state.fbLevel, "Feedback Level");
      sendCC(2, 2, state.fbBalance, "Feedback Balance");
      sendCC(2, 3, state.fbHp, "Feedback Highpass Hz");
      sendCC(2, 4, state.fbNoise, "Pink Noise Level");
      sendCC(2, 5, state.fbSineLevel, "Sine Level");
      sendCC(2, 6, state.fbSinePitch, "Sine Frequency");

      sendCC(3, 1, state.grainRate, "Playback Rate Multiplier");
      sendCC(3, 2, state.grainDens, "Grain Density Multiplier");
      sendCC(3, 3, state.cutoff, "Low-Pass Filter Cutoff");
      sendCC(3, 4, state.jumble, "Position Jitter Spread");
      sendCC(3, 5, state.syncMode, "Trigger Distribution");
      sendCC(3, 6, state.envShape, "Grain Window Function");
      sendCC(3, 8, state.freeze ? 127 : 0, "Buffer Record Freeze");
      sendCC(3, 9, intervalToggles.octaves ? 127 : 0, "Pitch Octaves Toggle");
      sendCC(3, 10, intervalToggles.fifths ? 127 : 0, "Pitch 5ths & 4ths Toggle");
      sendCC(3, 11, intervalToggles.suboctaves ? 127 : 0, "Pitch Sub-Octaves Toggle");
      sendCC(3, 12, intervalToggles.reverse ? 127 : 0, "Reverse Grains Toggle");
    });

    btnPanic.addEventListener("click", () => {
      log("Muting all outputs...", "alert");
      sendCC(1, 1, 0, "Passthrough Mute");
      sendCC(1, 2, 0, "Delay In Mute");
      sendCC(1, 6, 0, "Delay Out Mute");
      sendCC(2, 1, 0, "FB Level Mute");
      document.getElementById("cc1_passthru").value = 0;
      document.getElementById("cc2_delayIn").value = 0;
      document.getElementById("cc1_fbAmp").value = 0;
      val_cc1_ch1.textContent = "0%";
      val_cc2_ch1.textContent = "0%";
      val_cc1_ch2.textContent = "0%";
    });
  }

  /**
   * Granular Ambient Sound Simulation Engine
   */
  class WebAudioSynthSimulation {
    constructor() {
      this.ctx = new (window.AudioContext || window.webkitAudioContext)();
      this.masterGain = this.ctx.createGain();
      this.masterGain.gain.value = 1.0;

      this.analyser = this.ctx.createAnalyser();
      this.analyser.fftSize = 256;
      this.analyserData = new Uint8Array(this.analyser.frequencyBinCount);

      this.filterNode = this.ctx.createBiquadFilter();
      this.filterNode.type = "lowpass";
      this.filterNode.frequency.value = 12000;

      this.hpFilter = this.ctx.createBiquadFilter();
      this.hpFilter.type = "highpass";
      this.hpFilter.frequency.value = 12;

      this.feedbackGain = this.ctx.createGain();
      this.feedbackGain.gain.value = 0.0;

      this.delayTaps = [];
      const baseDelayTimes = [0.12, 0.24, 0.36, 0.48, 0.60, 0.72, 0.84, 0.96, 1.10, 1.25, 1.40, 1.60, 1.80, 2.00, 2.25, 2.50];

      for (let i = 0; i < 16; i++) {
        const dNode = this.ctx.createDelay(4.0);
        dNode.delayTime.value = baseDelayTimes[i];

        const panner = this.ctx.createStereoPanner ? this.ctx.createStereoPanner() : null;
        if (panner) panner.pan.value = Math.sin(i * 1.5);

        const gNode = this.ctx.createGain();
        gNode.gain.value = 0.25;

        if (panner) {
          dNode.connect(panner);
          panner.connect(gNode);
        } else {
          dNode.connect(gNode);
        }

        gNode.connect(this.filterNode);
        this.delayTaps.push(dNode);
      }

      this.filterNode.connect(this.hpFilter);
      this.hpFilter.connect(this.feedbackGain);
      this.feedbackGain.connect(this.delayTaps[0]);

      this.filterNode.connect(this.masterGain);
      this.masterGain.connect(this.analyser);
      this.analyser.connect(this.ctx.destination);

      this.arpTimer = null;
    }

    start() {
      if (this.ctx.state === "suspended") {
        this.ctx.resume();
      }

      const chordVoicings = [
        [146.83, 220.00, 261.63, 329.63, 440.00],
        [130.81, 196.00, 246.94, 329.63, 392.00],
        [110.00, 164.81, 220.00, 261.63, 329.63],
        [174.61, 261.63, 329.63, 392.00, 523.25]
      ];

      let chordIndex = 0;
      let noteStep = 0;

      this.arpTimer = setInterval(() => {
        const chord = chordVoicings[chordIndex];
        const freq = chord[noteStep % chord.length];

        this.triggerVoice(freq, 0.35);

        noteStep++;
        if (noteStep % 8 === 0) {
          chordIndex = (chordIndex + 1) % chordVoicings.length;
        }
      }, 260);
    }

    triggerVoice(freq, dur) {
      if (!this.ctx) return;
      const now = this.ctx.currentTime;

      const osc1 = this.ctx.createOscillator();
      const osc2 = this.ctx.createOscillator();
      const subOsc = this.ctx.createOscillator();
      const vEnv = this.ctx.createGain();

      osc1.type = "triangle";
      osc2.type = "sawtooth";
      subOsc.type = "sine";

      osc1.frequency.setValueAtTime(freq, now);
      osc2.frequency.setValueAtTime(freq * 1.004, now);
      subOsc.frequency.setValueAtTime(freq * 0.5, now);

      const vFilter = this.ctx.createBiquadFilter();
      vFilter.type = "lowpass";
      vFilter.frequency.setValueAtTime(1600, now);

      vEnv.gain.setValueAtTime(0.001, now);
      vEnv.gain.linearRampToValueAtTime(0.35, now + 0.04);
      vEnv.gain.exponentialRampToValueAtTime(0.0001, now + dur);

      osc1.connect(vFilter);
      osc2.connect(vFilter);
      subOsc.connect(vFilter);
      vFilter.connect(vEnv);

      vEnv.connect(this.delayTaps[0]);
      vEnv.connect(this.masterGain);

      osc1.start(now);
      osc2.start(now);
      subOsc.start(now);

      osc1.stop(now + dur + 0.1);
      osc2.stop(now + dur + 0.1);
      subOsc.stop(now + dur + 0.1);
    }

    getSynthSample() {
      if (!this.analyser) return 0;
      this.analyser.getByteTimeDomainData(this.analyserData);
      let maxDiff = 0;
      for (let i = 0; i < this.analyserData.length; i++) {
        const diff = (this.analyserData[i] - 128) / 128;
        if (Math.abs(diff) > Math.abs(maxDiff)) {
          maxDiff = diff;
        }
      }
      return maxDiff * 1.5;
    }

    stop() {
      clearInterval(this.arpTimer);
    }

    updateParam(ch, cc, val) {
      if (!this.ctx) return;
      const norm = val / 127;
      const now = this.ctx.currentTime;

      if (ch === 1 && cc === 7) {
        const gain = (val / 51) * 1.2;
        this.masterGain.gain.setValueAtTime(gain, now);
      }
      if (ch === 1 && cc === 1) this.masterGain.gain.setValueAtTime(norm * 1.0, now);
      if (ch === 2 && cc === 1) this.feedbackGain.gain.setValueAtTime(norm * 0.88, now);
      if (ch === 2 && cc === 3) this.hpFilter.frequency.setValueAtTime(norm * 220, now);
      if (ch === 3 && cc === 1) {
        const scale = 0.25 + norm * 1.75;
        this.delayTaps.forEach((t, i) => {
          t.delayTime.setValueAtTime((0.1 + (i * 0.12)) * scale, now);
        });
      }
      if (ch === 3 && cc === 3) {
        const hz = 200 * Math.pow(80, norm);
        this.filterNode.frequency.setValueAtTime(hz, now);
      }

      this.triggerVoice(330 + (val * 4), 0.12);
    }
  }

  btnWebAudio.addEventListener("click", () => {
    webAudioActive = !webAudioActive;
    if (webAudioActive) {
      if (!audioEngine) {
        audioEngine = new WebAudioSynthSimulation();
      }
      audioEngine.start();
      webAudioStateEl.textContent = "ON";
      btnWebAudio.classList.remove("btn-secondary");
      btnWebAudio.classList.add("btn-primary");
      log("Browser Granular Synth active.", "system");
    } else {
      if (audioEngine) audioEngine.stop();
      webAudioStateEl.textContent = "OFF";
      btnWebAudio.classList.remove("btn-primary");
      btnWebAudio.classList.add("btn-secondary");
      log("Browser Synth stopped.", "system");
    }
  });

  /**
   * Single Combined Scope Render Loop with Live Parameter Reactivity
   */
  function drawScope() {
    const width = canvasCssWidth;
    const height = canvasCssHeight;
    ctx.clearRect(0, 0, width, height);

    // Background Grid
    ctx.strokeStyle = "#141414";
    ctx.lineWidth = 1;
    for (let x = 0; x < width; x += 40) {
      ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(x, height); ctx.stroke();
    }
    for (let y = 0; y < height; y += 40) {
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke();
    }

    const centerY = height / 2;
    const bufferStartX = 25;
    const bufferWidth = Math.max(100, width - 45);
    const rateMultiplier = (0.25 + (state.grainRate / 127) * 1.75);

    // Axis Labels
    ctx.fillStyle = "#444444";
    ctx.font = "9px monospace";
    ctx.fillText("L", 6, 16);
    ctx.fillText("CTR", 2, centerY + 3);
    ctx.fillText("R", 6, height - 8);

    // Baseline axis line
    ctx.strokeStyle = "#242424";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(bufferStartX, centerY);
    ctx.lineTo(bufferStartX + bufferWidth, centerY);
    ctx.stroke();

    // 1. Advance Record Head Pointer (Pauses when Freeze is Active)
    if (!state.freeze) {
      recPointer = (recPointer + 0.0025 * rateMultiplier) % 1.0;
    }

    // 2. Capture Real Bipolar Audio Sample (-1.0 to +1.0)
    let currentInputSample = 0;
    if (!state.freeze) {
      if (micActive) currentInputSample += getMicSample();
      if (webAudioActive && audioEngine) currentInputSample += audioEngine.getSynthSample();
    }

    // 3. Continuous Multi-Sample Recording into Ring Buffer
    const currentWriteIndex = Math.floor(recPointer * bufferLength);
    const inputLevelNorm = state.delayInMute ? (state.delayInLevel / 127) : 0;
    const preserveFactor = state.freeze ? 1.0 : (state.preserveLevel / 127) * 0.96;

    if (!state.freeze) {
      let idx = lastWriteIndex;
      while (idx !== currentWriteIndex) {
        audioRingBuffer[idx] = (audioRingBuffer[idx] * preserveFactor) + (currentInputSample * inputLevelNorm);
        idx = (idx + 1) % bufferLength;
      }
      audioRingBuffer[currentWriteIndex] = (audioRingBuffer[currentWriteIndex] * preserveFactor) + (currentInputSample * inputLevelNorm);
      lastWriteIndex = currentWriteIndex;
    }

    // 4. Render Recorded Audio Waveform
    ctx.strokeStyle = state.freeze ? "#cccccc" : "#888888";
    ctx.lineWidth = state.freeze ? 1.8 : 1.4;
    ctx.beginPath();
    for (let i = 0; i < bufferLength; i++) {
      const x = bufferStartX + (i / bufferLength) * bufferWidth;
      const val = audioRingBuffer[i];
      const ampY = centerY - (val * (height / 2 - 16));
      if (i === 0) ctx.moveTo(x, ampY);
      else ctx.lineTo(x, ampY);
    }
    ctx.stroke();

    // Fill subtle translucent area under waveform
    ctx.fillStyle = state.freeze ? "rgba(255, 255, 255, 0.07)" : "rgba(255, 255, 255, 0.04)";
    ctx.beginPath();
    ctx.moveTo(bufferStartX, centerY);
    for (let i = 0; i < bufferLength; i++) {
      const x = bufferStartX + (i / bufferLength) * bufferWidth;
      const val = audioRingBuffer[i];
      const ampY = centerY - (val * (height / 2 - 16));
      ctx.lineTo(x, ampY);
    }
    ctx.lineTo(bufferStartX + bufferWidth, centerY);
    ctx.closePath();
    ctx.fill();

    // 5. Draw Record Head Line (Dashed when Frozen)
    const recX = bufferStartX + (recPointer * bufferWidth);
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = 1.5;
    if (state.freeze) ctx.setLineDash([3, 3]);
    ctx.beginPath();
    ctx.moveTo(recX, 6);
    ctx.lineTo(recX, height - 6);
    ctx.stroke();
    if (state.freeze) ctx.setLineDash([]);

    ctx.fillStyle = "#ffffff";
    ctx.font = "9px monospace";
    ctx.fillText(state.freeze ? "FROZEN" : "REC HEAD", Math.min(bufferWidth - 45, recX + 4), 16);

    // 6. Draw 16 Overlaid Grain Slice Rectangles with Live Interleaved Rates
    const grainDensScale = 0.2 + (state.grainDens / 127) * 2.8;
    const sliceHeight = 14;
    const minDelayOffset = 0.04;
    const jumbleSpread = (state.jumble / 127) * 0.12;
    const tap16Rates = get16TapRates();

    const dustFactor = (1 - (state.syncMode / 127));

    taps.forEach((tap, idx) => {
      // Tap rate directly from the 16-tap additive array
      const tapRate = tap16Rates[idx] * rateMultiplier;
      const isReverse = tapRate < 0;

      const jumbleJitter = Math.sin(Date.now() * 0.005 + idx) * jumbleSpread;
      const effectiveDelay = Math.max(minDelayOffset, tap.delayOffset + jumbleJitter);
      const sliceStartNorm = (recPointer - effectiveDelay + 1.0) % 1.0;

      const maxAllowedSliceWidth = effectiveDelay * 0.85;
      const baseSliceWidth = 0.03 + (idx % 4) * 0.015;
      const sliceWidthNorm = Math.min(maxAllowedSliceWidth, baseSliceWidth * grainDensScale);

      const sliceStartX = bufferStartX + (sliceStartNorm * bufferWidth);
      const sliceWidthPx = sliceWidthNorm * bufferWidth;
      let sliceEndX = sliceStartX + sliceWidthPx;

      // Playhead progress: reverse taps scan right-to-left, forward taps scan left-to-right
      const playheadSpeed = 0.015 * Math.abs(tapRate) * (1 + (Math.random() * 0.3 * dustFactor));
      if (isReverse) {
        tap.playheadProgress = (tap.playheadProgress - playheadSpeed + 1.0) % 1.0;
      } else {
        tap.playheadProgress = (tap.playheadProgress + playheadSpeed) % 1.0;
      }

      tap.panPhase += tap.lfoSpeed;
      tap.pan = Math.sin(tap.panPhase);

      const maxPanOffsetY = (height / 2) - 24;
      const sliceY = (centerY - (tap.pan * maxPanOffsetY)) - (sliceHeight / 2);

      // Reactivity to Filter Cutoff (brightness) & Freeze
      const cutoffBrightness = Math.round(30 + (state.cutoff / 127) * 35);
      if (state.delayOutMute) {
        ctx.fillStyle = state.freeze ? "rgba(80, 80, 80, 0.8)" : `rgba(${cutoffBrightness}, ${cutoffBrightness}, ${cutoffBrightness}, 0.65)`;
        ctx.strokeStyle = state.freeze ? "#ffffff" : (isReverse ? "#e0e0e0" : "#888888");
      } else {
        ctx.fillStyle = "rgba(15, 15, 15, 0.4)";
        ctx.strokeStyle = "#333333";
      }
      ctx.lineWidth = 1;

      // Reactivity to Window Function (Dashed border if percussive/reverse envelope)
      if (state.envShape >= 43 && state.envShape < 85) {
        ctx.setLineDash([4, 2]);
      } else if (state.envShape >= 85) {
        ctx.setLineDash([2, 2]);
      } else {
        ctx.setLineDash([]);
      }

      if (sliceEndX <= bufferStartX + bufferWidth) {
        ctx.fillRect(sliceStartX, sliceY, sliceWidthPx, sliceHeight);
        ctx.strokeRect(sliceStartX, sliceY, sliceWidthPx, sliceHeight);
      } else {
        const firstPartWidth = (bufferStartX + bufferWidth) - sliceStartX;
        const secondPartWidth = sliceWidthPx - firstPartWidth;
        ctx.fillRect(sliceStartX, sliceY, firstPartWidth, sliceHeight);
        ctx.strokeRect(sliceStartX, sliceY, firstPartWidth, sliceHeight);
        ctx.fillRect(bufferStartX, sliceY, secondPartWidth, sliceHeight);
        ctx.strokeRect(bufferStartX, sliceY, secondPartWidth, sliceHeight);
      }
      ctx.setLineDash([]);

      // Draw Active Grain Playhead Line scanning inside Rectangle
      if (state.delayOutMute) {
        const boundedPlayheadX = bufferStartX + ((sliceStartNorm + tap.playheadProgress * sliceWidthNorm) % 1.0) * bufferWidth;

        // Distinct playhead color for reverse taps vs forward taps
        ctx.strokeStyle = isReverse ? "#aaaaaa" : "#ffffff";
        ctx.lineWidth = 1.5;
        ctx.beginPath();
        ctx.moveTo(boundedPlayheadX, sliceY + 1);
        ctx.lineTo(boundedPlayheadX, sliceY + sliceHeight - 1);
        ctx.stroke();
      }
    });

    // 7. Feedback Recirculation Ring (Reactive to Feedback Level CC 1)
    if (state.fbLevel > 0) {
      const fbIntensity = state.fbLevel / 127;
      ctx.strokeStyle = "#555555";
      ctx.lineWidth = 1;
      ctx.setLineDash([4, 4]);
      ctx.beginPath();
      ctx.arc(width / 2, centerY, (width / 4) * fbIntensity, 0, Math.PI * 2);
      ctx.stroke();
      ctx.setLineDash([]);
    }

    requestAnimationFrame(drawScope);
  }

  window.addEventListener("DOMContentLoaded", () => {
    setupUIControls();
    setupCanvasScaling();
    requestAnimationFrame(drawScope);
  });
})();

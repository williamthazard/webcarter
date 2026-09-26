/**
 * Carter's Delay — WebMIDI Demo Application Logic
 *
 * This is a reference WebMIDI frontend for carters_delay_midi.scd. It is a
 * CC-only control contract (MAP and CONTROLS below mirror the engine's MIDI
 * contract exactly — see README.md / the .scd header) plus a bidirectional
 * layer (BIDI_SPEC): the engine echoes every control it applies on channels
 * 9-11, replies to a state request on Ch 16 CC 1, and streams scope
 * telemetry over SysEx (F0 7D 43 ...). The buffer scope below is drawn
 * purely from that telemetry — there is no local audio simulation.
 */

(function () {
  // ---------------------------------------------------------------------
  // MAP: mapping functions that mirror the SC engine's helpers exactly.
  // ---------------------------------------------------------------------
  function ccToMult(v, lo, hi) {
    // Same shape as the engine's ccToMult helper: two-segment exponential,
    // exactly 1.0 at v = 64, exact endpoints at v = 0 (lo) and v = 127 (hi).
    return v <= 64 ? lo * Math.pow(1 / lo, v / 64) : Math.pow(hi, (v - 64) / 63);
  }

  const MAP = {
    level: (v) => v / 127,
    master: (v) => v / 51,
    bipolar: (v) => (v <= 64 ? (v - 64) / 64 : (v - 64) / 63),
    hpfHz: (v) => (v / 127) * 220,
    sineNote: (v) => Math.round(20 + (v * 70) / 127),
    sineHz: (v) => 440 * Math.pow(2, (MAP.sineNote(v) - 69) / 12),
    rate: (v) => ccToMult(v, 0.25, 2),
    density: (v) => ccToMult(v, 0.2, 3),
    cutoffHz: (v) => 200 * Math.pow(80, v / 127),
    jitterSec: (v) => (v / 127) * 2.5,
    syncFraction: (v) => v / 127,
    windowIndex: (v) => (v < 43 ? 0 : v < 86 ? 1 : 2),
  };

  const WINDOW_NAMES = ["Hann", "Percussive", "Reverse Swell"];

  // ---------------------------------------------------------------------
  // Display formats
  // ---------------------------------------------------------------------
  const fmtPercent = (v) => `${Math.round(MAP.level(v) * 100)}%`;
  const fmtMaster = (v) => `${MAP.master(v).toFixed(2)}×`;
  const fmtBalance = (v) => {
    const b = MAP.bipolar(v);
    if (b === 0) return "Center";
    const pct = Math.round(Math.abs(b) * 100);
    return b < 0 ? `L ${pct}%` : `R ${pct}%`;
  };
  const fmtHpf = (v) => `${MAP.hpfHz(v).toFixed(1)} Hz`;
  const fmtSine = (v) => `${MAP.sineHz(v).toFixed(1)} Hz`;
  const fmtRate = (v) => `${MAP.rate(v).toFixed(2)}×`;
  const fmtDensity = (v) => `${MAP.density(v).toFixed(2)}×`;
  const fmtCutoff = (v) => `${Math.round(MAP.cutoffHz(v))} Hz${v === 127 ? " (no cap)" : ""}`;
  const fmtJitter = (v) => `${MAP.jitterSec(v).toFixed(2)} s`;
  const fmtSync = (v) => (v === 127 ? "Periodic" : v === 0 ? "Random" : `${Math.round(MAP.syncFraction(v) * 100)}% periodic`);
  const fmtWindow = (v) => WINDOW_NAMES[MAP.windowIndex(v)];
  const fmtOnOff = (onLabel, offLabel) => (v) => (v > 0 ? onLabel : offLabel);

  // ---------------------------------------------------------------------
  // CONTROLS: one entry per MIDI control. Order matches the engine's
  // defaultCCs table exactly, so Send All / boot-time defaults agree.
  //
  // kind: "slider" (range input), "toggle" (two-segment on/off control,
  // e.g. [On|Muted]), or "chip" (pressable pitch-interval chip).
  // ---------------------------------------------------------------------
  const CONTROLS = [
    // Channel 1 — levels & routing
    { key: "masterVol", id: "ctl_masterVol", ch: 1, cc: 7, label: "Master output level", def: 51, kind: "slider", format: fmtMaster },
    { key: "passLevel", id: "ctl_passLevel", ch: 1, cc: 1, label: "Input passthrough level", def: 64, kind: "slider", format: fmtPercent },
    { key: "delayInLevel", id: "ctl_delayInLevel", ch: 1, cc: 2, label: "Delay input level", def: 64, kind: "slider", format: fmtPercent },
    { key: "preserveLevel", id: "ctl_preserveLevel", ch: 1, cc: 3, label: "Buffer preservation", def: 64, kind: "slider", format: fmtPercent },
    { key: "passOn", id: "ctl_passOn", ch: 1, cc: 4, label: "Input passthrough on", def: 127, kind: "toggle", format: fmtOnOff("On", "Muted") },
    { key: "delayInOn", id: "ctl_delayInOn", ch: 1, cc: 5, label: "Delay input on", def: 127, kind: "toggle", format: fmtOnOff("On", "Muted") },
    { key: "delayOutOn", id: "ctl_delayOutOn", ch: 1, cc: 6, label: "Delay output on", def: 127, kind: "toggle", format: fmtOnOff("On", "Muted") },

    // Channel 2 — feedback patch
    { key: "fbLevel", id: "ctl_fbLevel", ch: 2, cc: 1, label: "Feedback level", def: 0, kind: "slider", format: fmtPercent },
    { key: "fbBalance", id: "ctl_fbBalance", ch: 2, cc: 2, label: "Feedback balance", def: 64, kind: "slider", format: fmtBalance },
    { key: "fbHp", id: "ctl_fbHp", ch: 2, cc: 3, label: "Feedback high-pass", def: 7, kind: "slider", format: fmtHpf },
    { key: "fbNoise", id: "ctl_fbNoise", ch: 2, cc: 4, label: "Pink noise level", def: 0, kind: "slider", format: fmtPercent },
    { key: "fbSineLevel", id: "ctl_fbSineLevel", ch: 2, cc: 5, label: "Sine level", def: 0, kind: "slider", format: fmtPercent },
    { key: "fbSinePitch", id: "ctl_fbSinePitch", ch: 2, cc: 6, label: "Sine frequency", def: 24, kind: "slider", format: fmtSine },

    // Channel 3 — granular engine
    { key: "rateMult", id: "ctl_rateMult", ch: 3, cc: 1, label: "Playback rate", def: 64, kind: "slider", format: fmtRate },
    { key: "densMult", id: "ctl_densMult", ch: 3, cc: 2, label: "Grain density", def: 64, kind: "slider", format: fmtDensity },
    { key: "cutoffMax", id: "ctl_cutoffMax", ch: 3, cc: 3, label: "Low-pass cutoff ceiling", def: 127, kind: "slider", format: fmtCutoff },
    { key: "jitter", id: "ctl_jitter", ch: 3, cc: 4, label: "Position jitter", def: 0, kind: "slider", format: fmtJitter },
    { key: "sync", id: "ctl_sync", ch: 3, cc: 5, label: "Trigger distribution", def: 127, kind: "slider", format: fmtSync },
    { key: "window", id: "ctl_window", ch: 3, cc: 6, label: "Grain window", def: 0, kind: "slider", format: fmtWindow },
    { key: "freezeOn", id: "ctl_freezeOn", ch: 3, cc: 8, label: "Buffer freeze", def: 0, kind: "toggle", format: fmtOnOff("Frozen", "Live") },
    { key: "octavesOn", id: "ctl_octavesOn", ch: 3, cc: 9, label: "Octaves", def: 0, kind: "chip", format: fmtOnOff("on", "off") },
    { key: "fifthsOn", id: "ctl_fifthsOn", ch: 3, cc: 10, label: "Fifths & fourths", def: 0, kind: "chip", format: fmtOnOff("on", "off") },
    { key: "suboctavesOn", id: "ctl_suboctavesOn", ch: 3, cc: 11, label: "Sub-octaves", def: 0, kind: "chip", format: fmtOnOff("on", "off") },
    { key: "reverseOn", id: "ctl_reverseOn", ch: 3, cc: 12, label: "Reverse", def: 0, kind: "chip", format: fmtOnOff("on", "off") },
  ];

  const CONTROLS_BY_KEY = {};
  CONTROLS.forEach((c) => { CONTROLS_BY_KEY[c.key] = c; });

  // Echo lookup: BIDI_SPEC §2 — "Find the CONTROLS entry by (echo channel −
  // 8, cc)." Keyed by the control's own (1-based) channel and CC.
  const CONTROLS_BY_CHCC = {};
  CONTROLS.forEach((c) => { CONTROLS_BY_CHCC[c.ch + ":" + c.cc] = c; });

  const INTERVAL_KEYS = ["octavesOn", "fifthsOn", "suboctavesOn", "reverseOn"];

  // State: one field per CONTROLS entry, seeded from CONTROLS' own defaults
  // (which are the single source of truth, matching the engine's defaultCCs).
  const state = {};
  CONTROLS.forEach((c) => {
    state[c.key] = c.kind === "slider" ? c.def : c.def > 0;
  });

  // State
  let midiAccess = null;
  let midiOutput = null;
  let midiInput = null;
  let sysexGranted = true; // optimistic until a fallback proves otherwise
  let midiState = "pending"; // pending | granted | failed

  // DOM Elements
  const statusDotEl = document.getElementById("statusDot");
  const statusTextEl = document.getElementById("statusText");
  const midiOutputSelect = document.getElementById("midiOutputSelect");
  const midiInputSelect = document.getElementById("midiInputSelect");
  const engineDotEl = document.getElementById("engineDot");
  const engineStatusTextEl = document.getElementById("engineStatusText");
  const telemetryLineEl = document.getElementById("telemetryLine");
  const scopeSpanLabelEl = document.getElementById("scopeSpanLabel");
  const btnPanic = document.getElementById("btnPanic");
  const btnSendAll = document.getElementById("btnSendAll");
  const btnReset = document.getElementById("btnReset");
  const btnClearLog = document.getElementById("btnClearLog");
  const logContainer = document.getElementById("logContainer");
  const scopeCanvas = document.getElementById("scopeCanvas");
  const ctx = scopeCanvas.getContext("2d");

  const LOG_MAX_ENTRIES = 300;

  // ---------------------------------------------------------------------
  // Persistence: Save/Restore All Settings via localStorage
  // ---------------------------------------------------------------------
  const SETTINGS_STORAGE_KEY = "cartersDelay.settings.v2"; // bumped; the old v1 key is ignored

  function readSettingsRaw() {
    try {
      const raw = localStorage.getItem(SETTINGS_STORAGE_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (e) {
      console.warn("Could not read saved settings:", e);
      return null;
    }
  }

  function applySavedState(saved) {
    if (!saved || typeof saved !== "object" || !saved.state || typeof saved.state !== "object") return;
    const savedState = saved.state;
    CONTROLS.forEach((c) => {
      if (!(c.key in savedState)) return; // unknown/missing keys are ignored
      const raw = savedState[c.key];
      if (c.kind === "slider") {
        let n = Number(raw);
        if (!Number.isFinite(n)) return;
        n = Math.max(0, Math.min(127, Math.round(n))); // clamped to integers 0..127
        state[c.key] = n;
      } else {
        state[c.key] = Boolean(raw); // booleans are coerced
      }
    });
  }

  function saveSettings() {
    try {
      const savedState = {};
      CONTROLS.forEach((c) => { savedState[c.key] = state[c.key]; });
      localStorage.setItem(SETTINGS_STORAGE_KEY, JSON.stringify({
        state: savedState,
        midiOutputName: midiOutput ? midiOutput.name : null,
        midiInputName: midiInput ? midiInput.name : null,
      }));
    } catch (e) {
      console.warn("Could not save settings:", e);
    }
  }

  function getSavedOutputName() {
    // Read fresh at call time (not a load-time const) so updateOutputs()
    // always sees the latest saved preference, including one saved earlier
    // in this same session.
    const raw = readSettingsRaw();
    return raw && typeof raw.midiOutputName === "string" ? raw.midiOutputName : null;
  }

  function getSavedInputName() {
    const raw = readSettingsRaw();
    return raw && typeof raw.midiInputName === "string" ? raw.midiInputName : null;
  }

  applySavedState(readSettingsRaw());

  // ---------------------------------------------------------------------
  // Canvas HiDPI Scaling setup
  // ---------------------------------------------------------------------
  let canvasCssWidth = 900;
  let canvasCssHeight = 180;

  function setupCanvasScaling() {
    if (!scopeCanvas) return;
    const rect = scopeCanvas.getBoundingClientRect();
    const targetWidth = rect.width > 50 ? rect.width : (scopeCanvas.parentElement ? scopeCanvas.parentElement.clientWidth : 900);
    if (!targetWidth) return;

    canvasCssWidth = targetWidth;
    canvasCssHeight = rect.height > 50 ? rect.height : canvasCssHeight;

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

  // ---------------------------------------------------------------------
  // Design tokens for the scope canvas — read from CSS custom properties
  // rather than hardcoded hex, so the canvas always matches the theme.
  // ---------------------------------------------------------------------
  const theme = {
    muted: "#a3a3a3",
    text: "#ededed",
    signal: "#ffffff",
  };

  function cssVar(name, fallback) {
    try {
      const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
      return v || fallback;
    } catch (e) {
      return fallback;
    }
  }

  function refreshTheme() {
    theme.muted = cssVar("--muted", theme.muted);
    theme.text = cssVar("--text", theme.text);
    theme.signal = cssVar("--signal", theme.signal);
  }

  function hexToRgb(hex) {
    let h = String(hex).trim().replace("#", "");
    if (h.length === 3) h = h.split("").map((c) => c + c).join("");
    const n = parseInt(h, 16) || 0;
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
  }

  function rgba(hex, alpha) {
    const { r, g, b } = hexToRgb(hex);
    return `rgba(${r}, ${g}, ${b}, ${alpha})`;
  }

  // ---------------------------------------------------------------------
  // WebMIDI
  // ---------------------------------------------------------------------
  async function initMIDI() {
    if (!navigator.requestMIDIAccess) {
      log("navigator.requestMIDIAccess is not supported in this browser.", "alert");
      statusDotEl.className = "indicator offline";
      statusTextEl.textContent = "WebMIDI unsupported";
      return;
    }
    try {
      const access = await navigator.requestMIDIAccess({ sysex: true });
      sysexGranted = typeof access.sysexEnabled === "boolean" ? access.sysexEnabled : true;
      if (!sysexGranted) {
        log("MIDI SysEx permission was not granted; controls still work, but the scope needs it.", "system");
      }
      onMIDISuccess(access);
    } catch (errSysex) {
      try {
        const access = await navigator.requestMIDIAccess({ sysex: false });
        sysexGranted = false;
        log("MIDI SysEx permission denied; controls still work, but the scope needs it.", "system");
        onMIDISuccess(access);
      } catch (err) {
        onMIDIFailure(err);
      }
    }
  }
  initMIDI();

  async function onMIDISuccess(access) {
    midiAccess = access;
    midiState = "granted";
    log("WebMIDI access granted.", "system");
    await updateOutputs();
    await updateInputs();
    midiAccess.onstatechange = async () => {
      await updateOutputs();
      await updateInputs();
    };
  }

  function onMIDIFailure(err) {
    midiState = "failed";
    log("WebMIDI access failed: " + err, "alert");
    statusDotEl.className = "indicator offline";
    statusTextEl.textContent = "WebMIDI denied";
  }

  async function updateOutputs() {
    if (!midiAccess) return;
    const outputs = Array.from(midiAccess.outputs.values());
    midiOutputSelect.innerHTML = "";

    if (outputs.length === 0) {
      const opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "No MIDI devices detected";
      midiOutputSelect.appendChild(opt);
      const hadOutput = !!midiOutput;
      midiOutput = null;
      statusDotEl.className = "indicator offline";
      statusTextEl.textContent = "No devices";
      if (hadOutput) log("Selected output: none (no devices connected)", "system");
      return;
    }

    outputs.forEach((output) => {
      const opt = document.createElement("option");
      opt.value = output.id;
      opt.textContent = output.name;
      midiOutputSelect.appendChild(opt);
    });

    // Keep the current selection if it still exists.
    let chosen = midiOutput ? outputs.find((o) => o.id === midiOutput.id) || null : null;

    // Otherwise fall back, in order: saved name -> IAC/Bus 1/loopMIDI -> first output.
    if (!chosen) {
      const savedName = getSavedOutputName();
      if (savedName) chosen = outputs.find((o) => o.name === savedName) || null;
    }
    if (!chosen) {
      chosen = outputs.find((o) => /IAC|Bus 1|loopMIDI/.test(o.name)) || null;
    }
    if (!chosen) {
      chosen = outputs[0];
    }

    const changed = !midiOutput || midiOutput.id !== chosen.id;
    midiOutputSelect.value = chosen.id;
    midiOutput = chosen;

    statusDotEl.className = "indicator online";
    statusTextEl.textContent = "Connected: " + midiOutput.name;

    if (changed) {
      log(`Selected output: ${midiOutput.name}`, "system");
      saveSettings();
    }
    maybeSendRequestState();
  }

  midiOutputSelect.addEventListener("change", (e) => {
    if (!midiAccess) return;
    const next = midiAccess.outputs.get(e.target.value);
    if (!next) return;
    const changed = !midiOutput || midiOutput.id !== next.id;
    midiOutput = next;
    statusDotEl.className = "indicator online";
    statusTextEl.textContent = "Connected: " + midiOutput.name;
    if (changed) {
      log(`Selected output: ${midiOutput.name}`, "system");
      saveSettings();
    }
    maybeSendRequestState();
  });

  // The "Replies from" input select (BIDI_SPEC §5). By default it pairs
  // with the selected output's name, else the first name containing IAC,
  // Bus 1 or loopMIDI. Only the selected input gets an onmidimessage handler.
  function attachInputHandler(input) {
    if (midiInput && midiInput !== input) {
      try { midiInput.onmidimessage = null; } catch (e) { /* ignore */ }
    }
    midiInput = input;
    if (midiInput) midiInput.onmidimessage = onMIDIMessage;
  }

  async function updateInputs() {
    if (!midiAccess) return;
    const inputs = Array.from(midiAccess.inputs.values());
    midiInputSelect.innerHTML = "";

    if (inputs.length === 0) {
      const opt = document.createElement("option");
      opt.value = "";
      opt.textContent = "No MIDI input detected";
      midiInputSelect.appendChild(opt);
      const hadInput = !!midiInput;
      if (midiInput) { try { midiInput.onmidimessage = null; } catch (e) { /* ignore */ } }
      midiInput = null;
      if (hadInput) log("Replies from: none (no input connected)", "system");
      return;
    }

    inputs.forEach((input) => {
      const opt = document.createElement("option");
      opt.value = input.id;
      opt.textContent = input.name;
      midiInputSelect.appendChild(opt);
    });

    let chosen = midiInput ? inputs.find((i) => i.id === midiInput.id) || null : null;

    if (!chosen) {
      const savedName = getSavedInputName();
      if (savedName) chosen = inputs.find((i) => i.name === savedName) || null;
    }
    if (!chosen && midiOutput) {
      chosen = inputs.find((i) => i.name === midiOutput.name) || null;
    }
    if (!chosen) {
      chosen = inputs.find((i) => /IAC|Bus 1|loopMIDI/.test(i.name)) || null;
    }
    if (!chosen) {
      chosen = inputs[0];
    }

    const changed = !midiInput || midiInput.id !== chosen.id;
    midiInputSelect.value = chosen.id;
    attachInputHandler(chosen);

    if (changed) {
      log(`Replies from: ${midiInput.name}`, "system");
      saveSettings();
    }
    maybeSendRequestState();
  }

  midiInputSelect.addEventListener("change", (e) => {
    if (!midiAccess) return;
    const next = midiAccess.inputs.get(e.target.value);
    if (!next) return;
    const changed = !midiInput || midiInput.id !== next.id;
    attachInputHandler(next);
    if (changed) {
      log(`Replies from: ${midiInput.name}`, "system");
      saveSettings();
    }
    maybeSendRequestState();
  });

  // Sends the request BF 01 7F once both the output and the input are
  // selected, and again whenever either changes (BIDI_SPEC §2/§5).
  let lastRequestPairKey = null;
  function maybeSendRequestState() {
    if (!midiOutput || !midiInput) return;
    const key = midiOutput.id + "|" + midiInput.id;
    if (key === lastRequestPairKey) return;
    lastRequestPairKey = key;
    const bytes = [0xBF, 1, 127];
    try {
      midiOutput.send(bytes);
      log(`${bytesHex(bytes)}  Requesting engine state (Ch 16 CC 1 = 127)`, "system");
    } catch (err) {
      log("MIDI send failed: " + (err && err.message ? err.message : err), "alert");
    }
  }

  // ---------------------------------------------------------------------
  // MIDI bytes: shared by the per-control byte readouts and the monitor.
  // ---------------------------------------------------------------------
  function bytesForControl(c, v) {
    const status = 0xB0 | (c.ch - 1);
    return [status, c.cc, v];
  }

  function bytesHex(bytes) {
    return Array.from(bytes).map((b) => b.toString(16).toUpperCase().padStart(2, "0")).join(" ");
  }

  // Pitch-interval chips (CC 9-12) share one "last sent" byte readout
  // instead of one each; every other control has its own `{id}-bytes`.
  function bytesReadoutIdFor(c) {
    return (c.kind === "chip" ? "ctl_intervals" : c.id) + "-bytes";
  }

  function setBytesReadoutText(id, hex) {
    const el = document.getElementById(id);
    if (el) el.textContent = hex;
  }

  const bytesFlashTimers = {};

  function flashBytesReadout(id, hex) {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = hex;
    el.classList.add("sent");
    clearTimeout(bytesFlashTimers[id]);
    bytesFlashTimers[id] = setTimeout(() => el.classList.remove("sent"), 400);
  }

  // Tracks the last time each control was actually sent, for the echo
  // drag/keyboard guard's "300 ms after a local send" half (BIDI_SPEC §2).
  const lastSentAt = {};

  function sendCC(c, v) {
    let val = Math.round(Number(v));
    if (!Number.isFinite(val)) val = 0;
    val = Math.max(0, Math.min(127, val));

    const bytes = bytesForControl(c, val);
    const hex = bytesHex(bytes);
    const msgClass = "ch" + c.ch + "-msg";
    const readoutId = bytesReadoutIdFor(c);
    const desc = hex + "  Ch " + c.ch + " CC " + c.cc + " = " + val + " (" + c.label + " " + c.format(val) + ")";

    if (midiOutput) {
      try {
        // send() opens the output implicitly if it isn't already open.
        midiOutput.send(bytes);
        lastSentAt[c.key] = Date.now();
        log(desc, msgClass);
        flashBytesReadout(readoutId, hex);
      } catch (err) {
        log("MIDI send failed: " + (err && err.message ? err.message : err), "alert");
        setBytesReadoutText(readoutId, hex);
      }
    } else {
      // No output connected: the byte readout still shows the message for
      // the current value at rest, but nothing was actually transmitted, so
      // this neither triggers the "sent" flash nor logs as if it reached
      // the engine — the log line says explicitly that it was dropped.
      log(desc + " — not sent (no MIDI output)", msgClass);
      setBytesReadoutText(readoutId, hex);
    }

    return val;
  }

  function log(msg, type = "") {
    const timeStr = new Date().toISOString().substring(11, 19);
    const div = document.createElement("div");
    div.className = "log-entry " + type;
    div.textContent = timeStr + "  " + msg;
    logContainer.appendChild(div);
    while (logContainer.children.length > LOG_MAX_ENTRIES) {
      logContainer.removeChild(logContainer.firstChild);
    }
    logContainer.scrollTop = logContainer.scrollHeight;
  }

  btnClearLog.addEventListener("click", () => {
    logContainer.innerHTML = "";
    log("Log cleared.", "system");
  });

  // ---------------------------------------------------------------------
  // SysEx decoders (BIDI_SPEC §4) — one place, so every packet type is
  // decoded consistently. Every packet is F0 7D 43 <type> <payload…> F7.
  // ---------------------------------------------------------------------
  function u14(p, o) { return (p[o] << 7) | p[o + 1]; }
  function u21(p, o) { return (p[o] << 14) | (p[o + 1] << 7) | p[o + 2]; }
  function u28(p, o) { return (p[o] << 21) | (p[o + 1] << 14) | (p[o + 2] << 7) | p[o + 3]; }

  const SYSEX_TYPE = { HELLO: 0x01, HEAD: 0x02, GRAIN: 0x03, COLUMN: 0x04, DUMP: 0x05 };

  const SYSEX = {
    decode(data) {
      if (!data || data.length < 5) return null;
      if (data[0] !== 0xF0 || data[1] !== 0x7D || data[2] !== 0x43) return null;
      if (data[data.length - 1] !== 0xF7) return null;
      const type = data[3];
      const payload = data.subarray ? data.subarray(4, data.length - 1) : Array.prototype.slice.call(data, 4, data.length - 1);
      switch (type) {
        case SYSEX_TYPE.HELLO: return SYSEX.decodeHello(payload);
        case SYSEX_TYPE.HEAD: return SYSEX.decodeHead(payload);
        case SYSEX_TYPE.GRAIN: return SYSEX.decodeGrain(payload);
        case SYSEX_TYPE.COLUMN: return SYSEX.decodeColumn(payload);
        case SYSEX_TYPE.DUMP: return SYSEX.decodeDump(payload);
        default: return null;
      }
    },
    // version u7, bufferFrames u28, sampleRate u21, numCols u14, numTaps u7
    decodeHello(p) {
      if (p.length < 11) return null;
      return {
        type: "hello",
        version: p[0],
        bufferFrames: u28(p, 1),
        sampleRate: u21(p, 5),
        numCols: u14(p, 8),
        numTaps: p[10],
      };
    },
    // writeHead pos14, frozen u7
    decodeHead(p) {
      if (p.length < 3) return null;
      return { type: "head", pos: u14(p, 0) / 16384, frozen: p[2] > 0 };
    },
    // tap u7, start pos14, durMs u14, rate u14, pan u7, amp u7
    decodeGrain(p) {
      if (p.length < 9) return null;
      return {
        type: "grain",
        tap: p[0],
        start: u14(p, 1) / 16384,
        durMs: u14(p, 3),
        rate: (u14(p, 5) - 8192) / 2048,
        pan: (p[7] / 127) * 2 - 1,
        amp: (p[8] / 127) * 3,
      };
    },
    // col u14, peak u7
    decodeColumn(p) {
      if (p.length < 3) return null;
      return { type: "column", col: u14(p, 0), peak: p[2] / 127 };
    },
    // startCol u14, count u14, then `count` peak u7 bytes
    decodeDump(p) {
      if (p.length < 4) return null;
      const startCol = u14(p, 0);
      const count = u14(p, 2);
      if (p.length < 4 + count) return null; // truncated: reject rather than zero-fill
      const peaks = new Array(count);
      for (let i = 0; i < count; i++) peaks[i] = p[4 + i] / 127;
      return { type: "dump", startCol, count, peaks };
    },
  };

  // ---------------------------------------------------------------------
  // Engine telemetry state — mutated only by message handlers, drawn only
  // by requestAnimationFrame (BIDI_SPEC §5, "Rendering").
  // ---------------------------------------------------------------------
  const engine = {
    hello: null, // { version, bufferFrames, sampleRate, numCols, numTaps }
    colPeaks: null, // Float32Array(numCols), 0..1
    head: { pos: 0, frozen: false, lastUpdate: 0 },
    grains: [], // { tap, start, durMs, rate, pan, amp, createdAt }
  };
  const GRAIN_CAP = 400;
  let lastEngineActivity = 0;
  let grainCounter = 0;
  let headCounter = 0;

  function formatSpan(sec) {
    if (!Number.isFinite(sec) || sec <= 0) return "—";
    return (sec >= 10 ? Math.round(sec) : sec.toFixed(1)) + " s";
  }

  function onHello(d) {
    engine.hello = { version: d.version, bufferFrames: d.bufferFrames, sampleRate: d.sampleRate, numCols: d.numCols, numTaps: d.numTaps };
    engine.colPeaks = new Float32Array(Math.max(1, d.numCols));
    engine.grains = [];
    engine.head = { pos: 0, frozen: false, lastUpdate: performance.now() };
    if (scopeSpanLabelEl) {
      const spanSec = d.sampleRate > 0 ? d.bufferFrames / d.sampleRate : 0;
      scopeSpanLabelEl.textContent = `${formatSpan(spanSec)} buffer`;
    }
    log("Engine started", "system");
  }

  function onHead(d) {
    if (!engine.hello) return;
    engine.head.pos = d.pos;
    engine.head.frozen = d.frozen;
    engine.head.lastUpdate = performance.now();
    headCounter++;
  }

  function onGrain(d) {
    if (!engine.hello) return;
    engine.grains.push({ tap: d.tap, start: d.start, durMs: d.durMs, rate: d.rate, pan: d.pan, amp: d.amp,
      win: MAP.windowIndex(state.window), createdAt: performance.now() });
    if (engine.grains.length > GRAIN_CAP) engine.grains.shift();
    grainCounter++;
  }

  function onColumn(d) {
    if (!engine.colPeaks) return;
    if (d.col >= 0 && d.col < engine.colPeaks.length) engine.colPeaks[d.col] = d.peak;
  }

  function onDump(d) {
    if (!engine.colPeaks) return;
    for (let i = 0; i < d.count; i++) {
      const idx = d.startCol + i;
      if (idx >= 0 && idx < engine.colPeaks.length) engine.colPeaks[idx] = d.peaks[i];
    }
    log(`DUMP: columns ${d.startCol}–${d.startCol + d.count - 1} (${d.count})`, "system");
  }

  function handleTelemetryPacket(decoded) {
    switch (decoded.type) {
      case "hello": onHello(decoded); break;
      case "head": onHead(decoded); break;
      case "grain": onGrain(decoded); break;
      case "column": onColumn(decoded); break;
      case "dump": onDump(decoded); break;
    }
  }

  // ---------------------------------------------------------------------
  // Incoming MIDI: echo (Ch 9-11 CC) and SysEx telemetry only. The page
  // ignores everything else, including its own looped-back Ch 1-3/16
  // messages (BIDI_SPEC §1 "Loop safety").
  // ---------------------------------------------------------------------
  function onMIDIMessage(e) {
    const data = e.data;
    if (!data || data.length === 0) return;

    if (data[0] === 0xF0) {
      const decoded = SYSEX.decode(data);
      if (!decoded) return; // not one of ours, or malformed
      lastEngineActivity = Date.now();
      handleTelemetryPacket(decoded);
      return;
    }

    const status = data[0];
    if ((status & 0xF0) !== 0xB0) return; // only Control Change matters here
    const chan0 = status & 0x0F; // 0-based MIDI channel
    const cc = data[1];
    const val = data[2];

    if (chan0 >= 8 && chan0 <= 10) {
      // Echo channels 9-11 (0-based 8-10): the same CC SC just applied.
      lastEngineActivity = Date.now();
      handleEcho(chan0 - 8 + 1, cc, val);
      return;
    }

    // Anything else — our own looped-back Ch 1-3/16 messages, other
    // channels, other CCs — is ignored, silently and on purpose.
  }

  // Controls the user is actively dragging/keying, so an in-flight echo
  // for them is ignored rather than fighting the interaction. Pointers are
  // tracked per pointerId so simultaneous (multi-touch) drags release
  // independently.
  const pointerOwners = new Map(); // pointerId -> control key
  const keyboardActive = new Set(); // control keys with a key held down

  function isInteracting(key) {
    if (keyboardActive.has(key)) return true;
    for (const owner of pointerOwners.values()) if (owner === key) return true;
    return false;
  }

  function handleEcho(ch, cc, val) {
    const c = CONTROLS_BY_CHCC[ch + ":" + cc];
    if (!c) return; // unlisted CC on an echo channel; ignore silently

    const interacting = isInteracting(c.key);
    const recentlySent = (Date.now() - (lastSentAt[c.key] || 0)) < 300;
    if (interacting || recentlySent) return; // BIDI_SPEC §2 drag/keyboard + 300ms guard

    let appliedValue;
    if (c.kind === "slider") {
      appliedValue = Math.max(0, Math.min(127, Math.round(Number(val)) || 0));
      state[c.key] = appliedValue;
      updateSliderUI(c, appliedValue);
    } else {
      const on = val > 0;
      state[c.key] = on;
      appliedValue = on ? 127 : 0;
      if (c.kind === "chip") {
        updateChipUI(c, on);
        updateIntervalStatusText();
      } else {
        updateToggleUI(c, on);
      }
    }
    setBytesReadoutText(bytesReadoutIdFor(c), bytesHex(bytesForControl(c, appliedValue)));
    saveSettings(); // never sends MIDI in response — this only updates local state/UI/storage

    const echoStatus = 0xB0 | ((ch - 1) + 8);
    log(`${bytesHex([echoStatus, cc, val])} echo Ch ${ch} CC ${cc}`, "system");
  }

  // ---------------------------------------------------------------------
  // Engine status (heartbeat) and telemetry rate line
  // ---------------------------------------------------------------------
  function updateEngineStatusUI() {
    const alive = (Date.now() - lastEngineActivity) < 2000;
    if (engineDotEl) engineDotEl.className = "indicator " + (alive ? "online" : "offline");
    if (engineStatusTextEl) engineStatusTextEl.textContent = alive ? "Engine running" : "No reply from the engine";
  }

  function updateTelemetryLine() {
    const g = grainCounter;
    const h = headCounter;
    grainCounter = 0;
    headCounter = 0;
    if (telemetryLineEl) telemetryLineEl.textContent = `Telemetry: ${g} grains/s, head ${h}/s`;
  }

  // ---------------------------------------------------------------------
  // Generic CONTROLS-driven wiring / labels / reset / restore / sync / panic
  // ---------------------------------------------------------------------
  function updateSliderUI(c, v) {
    const el = document.getElementById(c.id);
    if (el) el.value = v;
    const labelEl = document.getElementById(c.id + "-val");
    if (labelEl) labelEl.textContent = c.format(v);
  }

  // Two-segment on/off controls (passthrough, delay in, delay out, freeze):
  // both halves are always visible; only the pressed half changes.
  function updateToggleUI(c, on) {
    const container = document.getElementById(c.id);
    if (!container) return;
    container.querySelectorAll(".seg-btn").forEach((btn) => {
      const btnIsOnHalf = btn.dataset.state === "on";
      btn.setAttribute("aria-pressed", String(btnIsOnHalf === on));
    });
  }

  // Pitch-interval chips: only aria-pressed (and its CSS) changes — the
  // chip's own label/CC caption is never overwritten.
  function updateChipUI(c, on) {
    const el = document.getElementById(c.id);
    if (el) el.setAttribute("aria-pressed", String(on));
  }

  function updateIntervalStatusText() {
    const statusEl = document.getElementById("val_intervals_status");
    if (!statusEl) return;
    const names = [];
    if (state.octavesOn) names.push("Octaves");
    if (state.fifthsOn) names.push("Fifths & fourths");
    if (state.suboctavesOn) names.push("Sub-octaves");
    if (state.reverseOn) names.push("Reverse");
    statusEl.textContent = names.length > 0 ? names.join(" + ") : "Base intervals";
  }

  // Shows the shared "last sent" interval byte readout at rest (before
  // anything has actually been sent this session): the first toggle that's
  // on, or Octaves (CC9) as a representative default.
  function updateIntervalBytesAtRest() {
    const onKey = INTERVAL_KEYS.find((k) => state[k]);
    const c = CONTROLS_BY_KEY[onKey || "octavesOn"];
    const v = state[c.key] ? 127 : 0;
    setBytesReadoutText("ctl_intervals-bytes", bytesHex(bytesForControl(c, v)));
  }

  // Central setter: every control mutation (slider input, dblclick reset,
  // toggle/chip click, Send All, Mute all) funnels through here so state,
  // UI, localStorage and outgoing MIDI always stay in sync.
  function setControlValue(c, rawValue) {
    if (c.kind === "slider") {
      let v = Math.round(Number(rawValue));
      if (!Number.isFinite(v)) v = c.def;
      v = Math.max(0, Math.min(127, v));
      state[c.key] = v;
      updateSliderUI(c, v);
      sendCC(c, v);
    } else {
      const on = Boolean(rawValue);
      state[c.key] = on;
      if (c.kind === "chip") {
        updateChipUI(c, on);
        updateIntervalStatusText();
      } else {
        updateToggleUI(c, on);
      }
      sendCC(c, on ? 127 : 0);
    }
    saveSettings();
  }

  function wireControls() {
    CONTROLS.forEach((c) => {
      if (c.kind === "slider") {
        const el = document.getElementById(c.id);
        if (!el) {
          console.warn("Missing control element for", c.key, "(#" + c.id + ")");
          return;
        }
        el.dataset.default = c.def;
        el.addEventListener("input", (e) => setControlValue(c, e.target.value));
        el.addEventListener("dblclick", () => {
          setControlValue(c, c.def);
          log(`Reset ${c.label} to default (${c.def}).`, "system");
        });
        // Drag/keyboard guard (BIDI_SPEC §2): ignore echoes for a control
        // while the user is actively interacting with it.
        el.addEventListener("pointerdown", (e) => {
          // A fresh press can't overlap a drag already in progress on this
          // same control, so any entry still claiming it is stale (its
          // pointerup was lost, e.g. a dropped touch). Clear it first.
          for (const [id, key] of pointerOwners) if (key === c.key) pointerOwners.delete(id);
          pointerOwners.set(e.pointerId, c.key);
        });
        el.addEventListener("keydown", () => keyboardActive.add(c.key));
        el.addEventListener("keyup", () => keyboardActive.delete(c.key));
        el.addEventListener("blur", () => keyboardActive.delete(c.key));
      } else if (c.kind === "chip") {
        const el = document.getElementById(c.id);
        if (!el) {
          console.warn("Missing control element for", c.key, "(#" + c.id + ")");
          return;
        }
        el.addEventListener("click", () => setControlValue(c, !state[c.key]));
      } else {
        // Two-segment control: clicking a half sets that state explicitly.
        const container = document.getElementById(c.id);
        if (!container) {
          console.warn("Missing control element for", c.key, "(#" + c.id + ")");
          return;
        }
        container.querySelectorAll(".seg-btn").forEach((btn) => {
          btn.addEventListener("click", () => setControlValue(c, btn.dataset.state === "on"));
        });
      }
    });
  }

  // Release a pointer's drag guard wherever the pointer lifts, since
  // pointerup can land outside the element that started the drag.
  window.addEventListener("pointerup", (e) => pointerOwners.delete(e.pointerId));
  window.addEventListener("pointercancel", (e) => pointerOwners.delete(e.pointerId));
  // A tab hidden mid-drag often never delivers the pointerup/keyup.
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) { pointerOwners.clear(); keyboardActive.clear(); }
  });

  function restoreControlsFromState() {
    CONTROLS.forEach((c) => {
      if (c.kind === "slider") {
        updateSliderUI(c, state[c.key]);
        setBytesReadoutText(bytesReadoutIdFor(c), bytesHex(bytesForControl(c, state[c.key])));
      } else if (c.kind === "chip") {
        updateChipUI(c, state[c.key]);
      } else {
        updateToggleUI(c, state[c.key]);
        setBytesReadoutText(bytesReadoutIdFor(c), bytesHex(bytesForControl(c, state[c.key] ? 127 : 0)));
      }
    });
    updateIntervalStatusText();
    updateIntervalBytesAtRest();
  }

  function setupUIControls() {
    wireControls();

    btnSendAll.addEventListener("click", () => {
      log("Sending all values…", "system");
      CONTROLS.forEach((c) => {
        const v = c.kind === "slider" ? state[c.key] : (state[c.key] ? 127 : 0);
        sendCC(c, v);
      });
    });

    btnPanic.addEventListener("click", () => {
      log("Muting all outputs...", "alert");
      setControlValue(CONTROLS_BY_KEY.passLevel, 0);
      setControlValue(CONTROLS_BY_KEY.delayInLevel, 0);
      setControlValue(CONTROLS_BY_KEY.delayOutOn, false);
      setControlValue(CONTROLS_BY_KEY.fbLevel, 0);
    });

    // Same defaults the engine boots into (defaultCCs), sent and saved.
    btnReset.addEventListener("click", () => {
      log("Resetting every control to its default…", "system");
      CONTROLS.forEach((c) => setControlValue(c, c.kind === "slider" ? c.def : c.def > 0));
    });

    restoreControlsFromState();
    if (readSettingsRaw()) {
      log('Restored settings from previous session (localStorage). Use "Send all values" once your MIDI output is connected to sync the engine.', "system");
    }
  }

  // ---------------------------------------------------------------------
  // Buffer scope — drawn purely from engine telemetry (BIDI_SPEC §5).
  // Message handlers above only mutate `engine`; only this function draws.
  // ---------------------------------------------------------------------
  function wrap01(x) { return ((x % 1) + 1) % 1; }
  function clamp01(x) { return Math.max(0, Math.min(1, x)); }

  // SuperCollider Env segment with curvature c, 0..1 progress -> 0..1.
  function envCurve(x, c) { return (1 - Math.exp(c * x)) / (1 - Math.exp(c)); }

  // The grain window's amplitude at `t` (0..1 through the grain), matching
  // the engine's envelopes, so a drawn grain fades the way it sounds.
  function grainEnvelope(win, t) {
    t = clamp01(t);
    if (win === 1) { // Env.perc(0.01, 0.99, 1, -4)
      return clamp01(t < 0.01 ? t / 0.01 : 1 - envCurve((t - 0.01) / 0.99, -4));
    }
    if (win === 2) { // Env([0, 1, 0], [0.98, 0.02], [4, -4])
      return clamp01(t < 0.98 ? envCurve(t / 0.98, 4) : 1 - envCurve((t - 0.98) / 0.02, -4));
    }
    return Math.pow(Math.sin(Math.PI * t), 2); // built-in Hann
  }

  // Draws a normalized [lo, hi) span (hi - lo may be > 0 and lo may be
  // outside [0,1)) as one or two pixel rectangles, wrapping at the buffer
  // edges. `paint(x0, x1)` receives pixel coordinates for each piece.
  function drawWrappedSpan(lo, hi, width, paint) {
    const length = Math.max(0, hi - lo);
    const start = wrap01(lo);
    const end = start + length;
    if (end <= 1) {
      paint(start * width, end * width);
    } else {
      paint(start * width, width);
      paint(0, (end - 1) * width);
    }
  }

  function drawScopeMessage(text) {
    const width = canvasCssWidth, height = canvasCssHeight;
    const maxWidth = Math.max(120, width - 32);
    ctx.fillStyle = theme.muted;
    ctx.font = "13px system-ui, sans-serif";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const words = text.split(" ");
    const lines = [];
    let line = "";
    words.forEach((w) => {
      const test = line ? line + " " + w : w;
      if (ctx.measureText(test).width > maxWidth && line) {
        lines.push(line);
        line = w;
      } else {
        line = test;
      }
    });
    if (line) lines.push(line);
    const lineHeight = 18;
    const startY = height / 2 - ((lines.length - 1) * lineHeight) / 2;
    lines.forEach((l, i) => ctx.fillText(l, width / 2, startY + i * lineHeight));
    ctx.textAlign = "left";
    ctx.textBaseline = "alphabetic";
  }

  function drawScope() {
    const width = canvasCssWidth;
    const height = canvasCssHeight;
    ctx.clearRect(0, 0, width, height);

    if (midiState !== "granted") {
      drawScopeMessage(midiState === "pending"
        ? "Waiting for MIDI permission. Check for a prompt near the address bar. Chrome or Edge work best."
        : "This browser blocked MIDI access. Use Chrome or Edge, and allow MIDI with SysEx for this page.");
      requestAnimationFrame(drawScope);
      return;
    }
    if (!sysexGranted) {
      drawScopeMessage("The scope needs MIDI SysEx permission. Allow it in the browser's site settings and reload.");
      requestAnimationFrame(drawScope);
      return;
    }
    if (!engine.hello) {
      drawScopeMessage("Waiting for the engine. Start carters_delay_midi.scd, then press Send all values or reload.");
      requestAnimationFrame(drawScope);
      return;
    }

    const now = performance.now();
    const { bufferFrames, sampleRate, numCols } = engine.hello;
    const centerY = height / 2;

    // Write head: extrapolate between HEAD packets unless frozen.
    if (!engine.head.frozen) {
      const dt = (now - engine.head.lastUpdate) / 1000;
      if (dt > 0 && sampleRate > 0 && bufferFrames > 0) {
        engine.head.pos = wrap01(engine.head.pos + (dt * sampleRate) / bufferFrames);
      }
      engine.head.lastUpdate = now;
    }

    // Waveform: numCols columns from colPeaks. x = 0 is SC buffer frame 0;
    // the whole canvas width is the whole SC buffer.
    if (engine.colPeaks && numCols > 0) {
      const colWidth = width / numCols;
      const maxBarHalf = height / 2 - 10;
      ctx.fillStyle = rgba(theme.text, 0.5);
      for (let i = 0; i < numCols; i++) {
        const peak = engine.colPeaks[i] || 0;
        const barHalf = peak > 0 ? Math.max(0.5, peak * maxBarHalf) : 0;
        if (barHalf <= 0) continue;
        const x = i * colWidth;
        ctx.fillRect(x, centerY - barHalf, Math.max(1, colWidth - 0.5), barHalf * 2);
      }
    }

    // Grains: transient rectangles with playheads, wrapping at the edges.
    const grainHeight = 11;
    const maxPanOffsetY = height / 2 - grainHeight / 2 - 6;
    engine.grains = engine.grains.filter((g) => (now - g.createdAt) < g.durMs);
    engine.grains.forEach((g) => {
      const elapsed = now - g.createdAt;
      const lifeFrac = clamp01(g.durMs > 0 ? elapsed / g.durMs : 1);
      const dir = g.rate < 0 ? -1 : 1;
      const extent = sampleRate > 0 && bufferFrames > 0
        ? clamp01((g.durMs / 1000) * Math.abs(g.rate) * sampleRate / bufferFrames)
        : 0;
      const a = g.start;
      const b = g.start + dir * extent;
      const lo = Math.min(a, b);
      const hi = Math.max(a, b);
      // Pan up = left: negative pan moves the rectangle toward the top.
      const y = centerY + g.pan * maxPanOffsetY - grainHeight / 2;
      const ampNorm = clamp01(g.amp / 3);
      const env = grainEnvelope(g.win, lifeFrac);

      ctx.fillStyle = rgba(theme.signal, (0.1 + ampNorm * 0.55) * env);
      ctx.strokeStyle = rgba(theme.muted, (0.4 + ampNorm * 0.5) * env);
      ctx.lineWidth = 1;
      drawWrappedSpan(lo, hi, width, (x0, x1) => {
        ctx.fillRect(x0, y, x1 - x0, grainHeight);
        ctx.strokeRect(x0, y, x1 - x0, grainHeight);
      });

      // Playhead: moves from `start` toward the far edge over durMs.
      const playheadNorm = wrap01(a + dir * extent * lifeFrac);
      const px = playheadNorm * width;
      ctx.strokeStyle = rgba(theme.signal, env);
      ctx.lineWidth = 1.5;
      ctx.beginPath();
      ctx.moveTo(px, y + 1);
      ctx.lineTo(px, y + grainHeight - 1);
      ctx.stroke();
    });

    // Write head line, dashed + labelled when frozen.
    const headX = engine.head.pos * width;
    ctx.strokeStyle = theme.signal;
    ctx.lineWidth = 1.5;
    if (engine.head.frozen) ctx.setLineDash([3, 3]);
    ctx.beginPath();
    ctx.moveTo(headX, 4);
    ctx.lineTo(headX, height - 4);
    ctx.stroke();
    if (engine.head.frozen) {
      ctx.setLineDash([]);
      ctx.fillStyle = theme.signal;
      ctx.font = "9px ui-monospace, monospace";
      ctx.fillText("Frozen", Math.min(width - 40, headX + 4), 14);
    }

    requestAnimationFrame(drawScope);
  }

  window.addEventListener("DOMContentLoaded", () => {
    setupUIControls();
    refreshTheme();
    setupCanvasScaling();
    requestAnimationFrame(drawScope);
    setInterval(updateEngineStatusUI, 500);
    setInterval(updateTelemetryLine, 1000);
  });
})();

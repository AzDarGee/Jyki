// app/javascript/controllers/imgui_synth_controller.js
import { Controller } from "@hotwired/stimulus"

// ============================================================================
// REAL-TIME 48kHz AUDIO WORKLET PROCESSOR (Runs on Dedicated OS Audio Thread!)
// 128-frame quantum = 2.66ms latency • Zero Main-Thread UI Jitter!
// ============================================================================
const SAANSKARA_WORKLET_SOURCE = `
class SaanskaraSitarProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.droneActive = true;
    this.rootHz      = 240.0;
    this.jawari      = 0.42;
    this.resonance   = 0.68;
    this.drive       = 1.65;
    this.morph       = 0.75;
    this.meendRatio  = 1.0;

    // Smoothed internal DSP registers (prevents zipper noise on fast knob turns)
    this.sHz    = 240.0;
    this.sJaw   = 0.42;
    this.sRes   = 0.68;
    this.sDrive = 1.65;
    this.sMorph = 0.75;

    // Phase accumulators & envelopes
    this.pSa     = 0.0;
    this.pPa     = 0.0;
    this.pSub    = 0.0;
    this.pJawari = 0.0;
    this.pLfo    = 0.0;
    this.pluckEnv = 0.0;
    this.tarabEnv = 0.8;

    this.port.onmessage = (e) => {
      const msg = e.data;
      if (msg.type === "param") {
        if (msg.key === "root_hz")      this.rootHz    = msg.value;
        if (msg.key === "jawari_buzz")  this.jawari    = msg.value;
        if (msg.key === "resonance")    this.resonance = msg.value;
        if (msg.key === "analog_drive") this.drive     = msg.value;
        if (msg.key === "morph_slider") this.morph     = msg.value;
      } else if (msg.type === "pluck") {
        this.pluckEnv   = Math.min(1.0, Math.max(0.2, msg.velocity || 0.9));
        this.tarabEnv   = 1.0;
        this.meendRatio = Math.min(2.0, Math.max(0.5, msg.pitchRatio || 1.0));
      } else if (msg.type === "drone") {
        this.droneActive = Boolean(msg.active);
      }
    };
  }

  process(inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;

    const outL = output[0];
    const outR = output.length > 1 ? output[1] : null;
    const frames = outL.length; // 128 frames per hardware quantum
    const invSr = 1.0 / sampleRate;
    const TWO_PI = 6.283185307179586;

    const targetHz = this.rootHz * this.meendRatio;

    for (let i = 0; i < frames; i++) {
      // Sample-accurate exponential parameter smoothing
      this.sHz    += (targetHz       - this.sHz)    * 0.0025;
      this.sJaw   += (this.jawari    - this.sJaw)   * 0.0025;
      this.sRes   += (this.resonance - this.sRes)   * 0.0025;
      this.sDrive += (this.drive     - this.sDrive) * 0.0025;
      this.sMorph += (this.morph     - this.sMorph) * 0.0025;

      this.pluckEnv *= 0.99980;
      this.tarabEnv *= 0.99993;

      // Breathing Tanpura LFO
      this.pLfo += TWO_PI * 0.35 * invSr;
      if (this.pLfo > TWO_PI) this.pLfo -= TWO_PI;
      const breath = 0.85 + 0.15 * Math.sin(this.pLfo);

      const droneLevel = this.droneActive ? (0.45 * breath) : 0.0;
      const ampEnv = Math.min(1.2, droneLevel + this.pluckEnv * 0.75);

      // Advance phase accumulators
      this.pSa     += TWO_PI * this.sHz * invSr;
      this.pPa     += TWO_PI * (this.sHz * 1.4983) * invSr;
      this.pSub    += TWO_PI * (this.sHz * 0.5) * invSr;
      this.pJawari += TWO_PI * (this.sHz * (2.0 + this.sMorph * 3.0)) * invSr;

      if (this.pSa     > TWO_PI) this.pSa     -= TWO_PI;
      if (this.pPa     > TWO_PI) this.pPa     -= TWO_PI;
      if (this.pSub    > TWO_PI) this.pSub    -= TWO_PI;
      if (this.pJawari > TWO_PI) this.pJawari -= TWO_PI;

      // 1. Sa + Sub-Octave Drone (shaped by Morph Mix slider)
      const sa  = Math.sin(this.pSa);
      const sub = Math.sin(this.pSub) * (0.65 * (1.0 - this.sMorph * 0.6));

      // 2. Fifth (Pa) + Sympathetic Tarab Strings (shaped by Tarab Res knob)
      const pa    = Math.sin(this.pPa) * (this.sRes * 0.65);
      const tarab = Math.sin(this.pSa * 3.0 + 1.5 * pa) * (this.sRes * 0.40);

      // 3. Non-linear Jawari curved bridge FM buzz (shaped by Jawari knob)
      const dynJaw = this.sJaw * (1.0 + 0.5 * this.pluckEnv);
      const buzz   = dynJaw * 0.85 * Math.sin(this.pJawari + (1.0 + dynJaw * 3.5) * sa);

      // 4. Rational analog tube soft-clipper (shaped by Drive knob)
      const raw = (sa + sub + pa + tarab + buzz) * ampEnv * this.sDrive;
      const sample = (raw / (1.0 + 0.50 * Math.abs(raw))) * (0.20 + 0.25 * this.sMorph);

      outL[i] = sample;
      if (outR) outR[i] = sample;
    }

    return true;
  }
}
registerProcessor("saanskara-sitar-processor", SaanskaraSitarProcessor);
`;

export default class extends Controller {
    static targets = ["canvas", "readout", "audioBtn"]

    async connect() {
        this.droneEnabled = true
        this.audioCtx = null
        this.workletNode = null
        this.workletReady = null

        // Receive live knob & slider turns directly from C99 Clay + NanoVG!
        window.saanskaraOnImGuiParamChanged = (param, value) => {
            if (this.hasReadoutTarget) {
                this.readoutTarget.textContent = `${param}: ${value.toFixed(2)}`
            }
            // Forward immediately to the dedicated AudioWorklet thread!
            this.workletNode?.port.postMessage({ type: "param", key: param, value })

            this.element.dispatchEvent(new CustomEvent("imgui:param", {
                bubbles: true,
                detail: { param, value }
            }))
        }

        // Receive oscilloscope Meend plucks from C99!
        window.saanskaraOnImGuiPluck = (velocity, pitchRatio) => {
            this.workletNode?.port.postMessage({ type: "pluck", velocity, pitchRatio })
        }

        await this.loadWasmScript("/wasm/saanskara_synth.js")
        this.wasm = await window.createSaanskaraSynthModule()

        this.resizeCanvas()
        this.wasm.ccall("init_saanskara_imgui", "number", ["string"], ["#imgui-synth-canvas"])
        this.syncRagaThemeToImGui()

        this.bindMultiTouchEvents()
        this.observeThemeChanges()
        this.updateAudioButtonUI()
    }

    async toggleAudio() {
        await this.ensureAudioEngine()
        this.droneEnabled = !this.droneEnabled
        this.workletNode?.port.postMessage({ type: "drone", active: this.droneEnabled })
        this.updateAudioButtonUI()
    }

    async pluckNote() {
        await this.ensureAudioEngine()
        this.wasm?._synth_trigger_pluck?.(1.0, 1.0)
        this.workletNode?.port.postMessage({ type: "pluck", velocity: 1.0, pitchRatio: 1.0 })
    }

    async ensureAudioEngine() {
        if (!this.audioCtx) {
            const AudioContextClass = window.AudioContext || window.webkitAudioContext
            this.audioCtx = new AudioContextClass({ latencyHint: "interactive", sampleRate: 48000 })

            // Load our AudioWorkletProcessor via zero-network Blob URL
            const blob = new Blob([SAANSKARA_WORKLET_SOURCE], { type: "application/javascript" })
            const workletUrl = URL.createObjectURL(blob)

            this.workletReady = this.audioCtx.audioWorklet.addModule(workletUrl).then(() => {
                URL.revokeObjectURL(workletUrl)
                this.workletNode = new AudioWorkletNode(this.audioCtx, "saanskara-sitar-processor", {
                    numberOfInputs: 0,
                    numberOfOutputs: 1,
                    outputChannelCount: [2]
                })
                this.workletNode.connect(this.audioCtx.destination)
                this.workletNode.port.postMessage({ type: "drone", active: this.droneEnabled })
            })
        }

        if (this.workletReady) await this.workletReady
        if (this.audioCtx.state === "suspended") {
            await this.audioCtx.resume()
        }
        this.updateAudioButtonUI()
    }

    updateAudioButtonUI() {
        if (!this.hasAudioBtnTarget) return
        this.audioBtnTarget.textContent = this.droneEnabled ? "🔊 Continuous Drone: ON" : "🔇 Continuous Drone: MUTED"
        this.audioBtnTarget.setAttribute("aria-pressed", this.droneEnabled ? "true" : "false")
    }

    loadWasmScript(src) {
        return new Promise((resolve, reject) => {
            if (window.createSaanskaraSynthModule) return resolve()
            const s = document.createElement("script")
            s.src = `${src}?v=${Date.now()}`
            s.onload = resolve
            s.onerror = reject
            document.head.appendChild(s)
        })
    }

    resizeCanvas() {
        const c = this.canvasTarget
        const rect = c.getBoundingClientRect()
        const dpr = window.devicePixelRatio || 1.0
        c.width = Math.round(rect.width * dpr)
        c.height = Math.round(rect.height * dpr)
        if (this.wasm) {
            this.wasm._imgui_set_canvas_size(Math.round(rect.width), Math.round(rect.height))
        }
    }

    bindMultiTouchEvents() {
        const c = this.canvasTarget
        c.style.touchAction = "none"
        c.style.userSelect = "none"
        c.style.webkitUserSelect = "none"

        window.addEventListener("resize", () => this.resizeCanvas())

        c.addEventListener("pointerdown", (e) => {
            e.preventDefault()
            this.ensureAudioEngine()
            c.setPointerCapture(e.pointerId)
            const r = c.getBoundingClientRect()
            this.wasm._synth_pointer_down(e.pointerId, e.clientX - r.left, e.clientY - r.top)
        }, { passive: false })

        c.addEventListener("pointermove", (e) => {
            e.preventDefault()
            const r = c.getBoundingClientRect()
            this.wasm._synth_pointer_move(e.pointerId, e.clientX - r.left, e.clientY - r.top)
        }, { passive: false })

        const endTouch = (e) => {
            this.wasm._synth_pointer_up(e.pointerId)
        }
        c.addEventListener("pointerup", endTouch)
        c.addEventListener("pointercancel", endTouch)
    }

    syncRagaThemeToImGui() {
        if (!this.wasm) return
        const styles = getComputedStyle(document.documentElement)
        const parseHex = (varName, fallback) => {
            const raw = styles.getPropertyValue(varName).trim().replace("#", "")
            return parseInt(raw.length === 6 ? raw : fallback, 16)
        }

        this.wasm._imgui_apply_raga_theme(
            parseHex("--saanskara-bg-canvas", "090d16"),
            parseHex("--saanskara-bg-surface", "111827"),
            parseHex("--saanskara-bg-panel", "1e293b"),
            parseHex("--saanskara-accent-primary", "f59e0b"),
            parseHex("--saanskara-accent-alert", "e11d48"),
            parseHex("--saanskara-text-main", "f8fafc")
        )
    }

    observeThemeChanges() {
        this.themeObserver = new MutationObserver(() => this.syncRagaThemeToImGui())
        this.themeObserver.observe(document.documentElement, {
            attributes: true,
            attributeFilter: ["data-theme"]
        })
    }

    disconnect() {
        this.themeObserver?.disconnect()
        this.workletNode?.disconnect()
        this.audioCtx?.close()
    }
}
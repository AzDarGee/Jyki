// app/javascript/controllers/imgui_synth_controller.js
import { Controller } from "@hotwired/stimulus"

const SAANSKARA_WORKLET_SOURCE = `
class SaanskaraSitarProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.droneActive = true;
    this.stopped     = false;
    this.rootHz      = 240.0;
    this.jawari      = 0.42;
    this.resonance   = 0.68;
    this.drive       = 1.65;
    this.meendMs     = 180.0; // Portamento glide time in milliseconds (0..1200ms)
    this.morph       = 0.75;
    this.meendRatio  = 1.0;
    this.noteHeld    = false;

    this.sRootHz = 240.0;
    this.sLeadHz = 240.0;
    this.sJaw    = 0.42;
    this.sRes    = 0.68;
    this.sDrive  = 1.65;
    this.sMorph  = 0.75;

    this.pDroneSa = 0.0;
    this.pSub     = 0.0;
    this.pPa      = 0.0;
    this.pLead    = 0.0;
    this.pJawari  = 0.0;
    this.pLfo     = 0.0;
    this.pluckEnv = 0.0;
    this.tarabEnv = 0.8;

    this.port.onmessage = (e) => {
      const msg = e.data;
      if (msg.type === "param") {
        if (msg.key === "root_hz")      this.rootHz    = msg.value;
        if (msg.key === "jawari_buzz")  this.jawari    = msg.value;
        if (msg.key === "resonance")    this.resonance = msg.value;
        if (msg.key === "analog_drive") this.drive     = msg.value;
        if (msg.key === "meend_ms")     this.meendMs   = msg.value;
        if (msg.key === "morph_slider") this.morph     = msg.value;
      } else if (msg.type === "pluck") {
        this.stopped    = false;
        this.pluckEnv   = Math.min(1.0, Math.max(0.15, msg.velocity || 0.9));
        this.tarabEnv   = 1.0;
        this.meendRatio = Math.min(4.0, Math.max(0.25, msg.pitchRatio || 1.0));
        this.noteHeld   = Boolean(msg.sustain);
        if (this.meendMs <= 2.0) {
          this.sLeadHz = this.rootHz * this.meendRatio;
        }
      } else if (msg.type === "note_off") {
        this.noteHeld = false;
      } else if (msg.type === "pitch_bend") {
        this.meendRatio = Math.min(4.0, Math.max(0.25, msg.pitchRatio || 1.0));
      } else if (msg.type === "drone") {
        this.stopped     = false;
        this.droneActive = Boolean(msg.active);
      } else if (msg.type === "stop") {
        // HARD KILL SWITCH: Zero out all envelopes & silence the processor immediately!
        this.stopped     = true;
        this.droneActive = false;
        this.noteHeld    = false;
        this.pluckEnv    = 0.0;
        this.tarabEnv    = 0.0;
      }
    };
  }

  process(inputs, outputs) {
    const output = outputs[0];
    if (!output || output.length === 0) return true;

    const outL = output[0];
    const outR = output.length > 1 ? output[1] : null;
    const frames = outL.length;

    // If stopped, output pure 0.0 silence with zero oscillator work!
    if (this.stopped) {
      for (let i = 0; i < frames; i++) {
        outL[i] = 0.0;
        if (outR) outR[i] = 0.0;
      }
      return true;
    }

    const invSr = 1.0 / sampleRate;
    const TWO_PI = 6.283185307179586;
    const targetLeadHz = this.rootHz * this.meendRatio;

    // Calculate sample-accurate exponential Meend glide coefficient from meendMs (0..1200ms)
    const meendCoeff = this.meendMs <= 2.0
      ? 1.0
      : (1.0 - Math.exp(-1000.0 / (Math.max(2.0, this.meendMs * 0.35) * sampleRate)));

    for (let i = 0; i < frames; i++) {
      this.sRootHz += (this.rootHz   - this.sRootHz) * 0.002;
      this.sLeadHz += (targetLeadHz  - this.sLeadHz) * meendCoeff;
      this.sJaw    += (this.jawari   - this.sJaw)    * 0.0025;
      this.sRes    += (this.resonance- this.sRes)    * 0.0025;
      this.sDrive  += (this.drive    - this.sDrive)  * 0.0025;
      this.sMorph  += (this.morph    - this.sMorph)  * 0.0025;

      this.pluckEnv *= this.noteHeld ? 0.99992 : 0.99972;
      this.tarabEnv *= 0.99994;

      this.pLfo += TWO_PI * 0.35 * invSr;
      if (this.pLfo > TWO_PI) this.pLfo -= TWO_PI;
      const breath = 0.85 + 0.15 * Math.sin(this.pLfo);

      const droneGain = this.droneActive ? (0.38 * breath) : 0.0;
      const leadGain  = (this.droneActive ? 0.25 : 0.0) + this.pluckEnv * 0.95;

      this.pDroneSa += TWO_PI * this.sRootHz * invSr;
      this.pSub     += TWO_PI * (this.sRootHz * 0.5) * invSr;
      this.pPa      += TWO_PI * (this.sRootHz * 1.4983) * invSr;

      this.pLead    += TWO_PI * this.sLeadHz * invSr;
      this.pJawari  += TWO_PI * (this.sLeadHz * (2.0 + this.sMorph * 3.0)) * invSr;

      if (this.pDroneSa > TWO_PI) this.pDroneSa -= TWO_PI;
      if (this.pSub     > TWO_PI) this.pSub     -= TWO_PI;
      if (this.pPa      > TWO_PI) this.pPa      -= TWO_PI;
      if (this.pLead    > TWO_PI) this.pLead    -= TWO_PI;
      if (this.pJawari  > TWO_PI) this.pJawari  -= TWO_PI;

      const droneSa = Math.sin(this.pDroneSa);
      const sub     = Math.sin(this.pSub) * (0.65 * (1.0 - this.sMorph * 0.6));
      const pa      = Math.sin(this.pPa)  * (this.sRes * 0.60);

      const leadSa  = Math.sin(this.pLead);
      const tarab   = Math.sin(this.pLead * 3.0 + 1.5 * pa) * (this.sRes * 0.45 * this.tarabEnv);

      const dynJaw = this.sJaw * (1.0 + 0.65 * this.pluckEnv);
      const buzz   = dynJaw * 0.90 * Math.sin(this.pJawari + (1.0 + dynJaw * 3.5) * leadSa);

      const droneMix = (droneSa * 0.5 + sub + pa) * droneGain;
      const leadMix  = (leadSa + buzz + tarab) * leadGain;

      const raw = (droneMix + leadMix) * this.sDrive;
      const sample = (raw / (1.0 + 0.50 * Math.abs(raw))) * (0.20 + 0.25 * this.sMorph);

      outL[i] = sample;
      if (outR) outR[i] = sample;
    }

    return true;
  }
}
registerProcessor("saanskara-sitar-processor", SaanskaraSitarProcessor);
`;

const KEYBOARD_SWARA_MAP = {
    KeyA: { semi: 0,  swara: "Sa" },
    KeyW: { semi: 1,  swara: "komal re" },
    KeyS: { semi: 2,  swara: "Re" },
    KeyE: { semi: 3,  swara: "komal ga" },
    KeyD: { semi: 4,  swara: "Ga" },
    KeyF: { semi: 5,  swara: "Ma" },
    KeyT: { semi: 6,  swara: "Tivra Ma" },
    KeyG: { semi: 7,  swara: "Pa" },
    KeyY: { semi: 8,  swara: "komal dha" },
    KeyH: { semi: 9,  swara: "Dha" },
    KeyU: { semi: 10, swara: "komal ni" },
    KeyJ: { semi: 11, swara: "Ni" },
    KeyK: { semi: 12, swara: "Sa'" },
    KeyO: { semi: 13, swara: "komal re'" },
    KeyL: { semi: 14, swara: "Re'" },
    KeyP: { semi: 15, swara: "komal ga'" },
    Semicolon: { semi: 16, swara: "Ga'" }
}

const SWARA_NAMES = ["Sa", "re", "Re", "ga", "Ga", "Ma", "Ma#", "Pa", "dha", "Dha", "ni", "Ni"]

export default class extends Controller {
    static targets = ["canvas", "readout", "audioBtn", "stopBtn", "paramInput", "midiStatus", "swaraBtn"]

    async connect() {
        this.droneEnabled = true
        this.audioCtx = null
        this.workletNode = null
        this.workletReady = null
        this.octaveShift = 0
        this.midiRootNote = 60
        this.currentSemitone = 0
        this.pitchBendSemitones = 0
        this.heldKeys = new Set()

        window.saanskaraOnImGuiParamChanged = (param, value) => {
            if (this.hasReadoutTarget) {
                const suffix = param === "meend_ms" ? "ms" : (param === "root_hz" ? "Hz" : "")
                this.readoutTarget.textContent = `${param}: ${value.toFixed(param === "meend_ms" || param === "root_hz" ? 0 : 2)}${suffix}`
            }
            this.workletNode?.port.postMessage({ type: "param", key: param, value })

            this.paramInputTargets.forEach((input) => {
                if (input.dataset.paramKey === param && document.activeElement !== input) {
                    input.value = (param === "root_hz" || param === "meend_ms") ? Math.round(value) : value.toFixed(2)
                }
            })

            this.element.dispatchEvent(new CustomEvent("imgui:param", {
                bubbles: true,
                detail: { param, value }
            }))
        }

        window.saanskaraOpenParamEditor = (meta) => this.spawnInlineCanvasInput(meta)
        window.saanskaraOnImGuiPluck = (velocity, pitchRatio) => {
            this.workletNode?.port.postMessage({ type: "pluck", velocity, pitchRatio })
        }

        await this.loadWasmScript("/wasm/saanskara_synth.js")
        this.wasm = await window.createSaanskaraSynthModule()

        this.resizeCanvas()
        this.wasm.ccall("init_saanskara_imgui", "number", ["string"], ["#imgui-synth-canvas"])
        this.syncRagaThemeToImGui()

        this.bindMultiTouchEvents()
        this.bindKeyboardAndMidi()
        this.observeThemeChanges()
        this.updateAudioButtonUI()
    }

    // ==========================================================================
    // ⏹ HARD STOP / PANIC KILL SWITCH (Stops Any Signal Going to AudioWorklet!)
    // ==========================================================================
    async stopAudio() {
        this.droneEnabled = false
        this.heldKeys.clear()
        this.wasm?._synth_stop_all?.()
        this.workletNode?.port.postMessage({ type: "stop" })

        if (this.audioCtx && this.audioCtx.state === "running") {
            await this.audioCtx.suspend()
        }

        this.updateAudioButtonUI()
        if (this.hasReadoutTarget) {
            this.readoutTarget.textContent = "⏹ Audio Stopped"
        }
    }

    async triggerSwaraSemitone(semitonesFromSa, velocity = 0.92, swaraLabel = null, sustain = true) {
        await this.ensureAudioEngine()
        this.currentSemitone = semitonesFromSa
        const totalSemis = semitonesFromSa + this.pitchBendSemitones
        const pitchRatio = Math.pow(2.0, totalSemis / 12.0)

        this.wasm?._synth_trigger_pluck?.(velocity, pitchRatio)
        this.workletNode?.port.postMessage({ type: "pluck", velocity, pitchRatio, sustain })

        const noteIndex = ((semitonesFromSa % 12) + 12) % 12
        const label = swaraLabel || SWARA_NAMES[noteIndex]
        if (this.hasReadoutTarget) {
            const rootInput = this.paramInputTargets.find(i => i.dataset.paramKey === "root_hz")
            const baseHz = rootInput ? parseFloat(rootInput.value) : 240.0
            const actualHz = (baseHz * pitchRatio).toFixed(1)
            this.readoutTarget.textContent = `Swara: ${label} (${semitonesFromSa >= 0 ? "+" : ""}${semitonesFromSa}st • ${actualHz}Hz)`
        }

        this.swaraBtnTargets.forEach((btn) => {
            const btnSemi = parseInt(btn.dataset.semitone, 10)
            btn.setAttribute("aria-pressed", btnSemi === semitonesFromSa ? "true" : "false")
        })
    }

    playSwaraPad(e) {
        const semi = parseInt(e.currentTarget.dataset.semitone, 10) + (this.octaveShift * 12)
        const label = e.currentTarget.dataset.swara
        this.triggerSwaraSemitone(semi, 0.95, label, false)
    }

    bindKeyboardAndMidi() {
        this.onKeyDown = (e) => {
            if (["INPUT", "TEXTAREA", "SELECT"].includes(e.target?.tagName) || e.metaKey || e.ctrlKey || e.altKey) return

            // Escape key acts as an instant Panic / Stop Audio shortcut!
            if (e.code === "Escape") {
                this.stopAudio()
                return
            }
            if (e.code === "KeyZ") {
                this.octaveShift = Math.max(-2, this.octaveShift - 1)
                if (this.hasReadoutTarget) this.readoutTarget.textContent = `Octave (Saptak): ${this.octaveShift >= 0 ? "+" : ""}${this.octaveShift}`
                return
            }
            if (e.code === "KeyX") {
                this.octaveShift = Math.min(2, this.octaveShift + 1)
                if (this.hasReadoutTarget) this.readoutTarget.textContent = `Octave (Saptak): ${this.octaveShift >= 0 ? "+" : ""}${this.octaveShift}`
                return
            }

            const mapped = KEYBOARD_SWARA_MAP[e.code]
            if (mapped && !e.repeat) {
                e.preventDefault()
                this.heldKeys.add(e.code)
                const semi = mapped.semi + (this.octaveShift * 12)
                this.triggerSwaraSemitone(semi, 0.92, mapped.swara, true)
            }
        }

        this.onKeyUp = (e) => {
            if (this.heldKeys.has(e.code)) {
                this.heldKeys.delete(e.code)
                if (this.heldKeys.size === 0) {
                    this.workletNode?.port.postMessage({ type: "note_off" })
                }
            }
        }

        window.addEventListener("keydown", this.onKeyDown)
        window.addEventListener("keyup", this.onKeyUp)

        if (navigator.requestMIDIAccess) {
            navigator.requestMIDIAccess({ sysex: false }).then((midiAccess) => {
                const bindInputs = () => {
                    const inputs = Array.from(midiAccess.inputs.values())
                    inputs.forEach((input) => {
                        input.onmidimessage = (msg) => this.handleMidiMessage(msg)
                    })
                    if (this.hasMidiStatusTarget) {
                        this.midiStatusTarget.textContent = inputs.length > 0
                            ? `🎹 MIDI: ${inputs[0].name} (C4 = Sa)`
                            : "🎹 Keys: A-K (Z/X Oct, Esc Stop) • MIDI Ready"
                    }
                }
                bindInputs()
                midiAccess.onstatechange = bindInputs
            }).catch(() => {})
        }
    }

    handleMidiMessage(msg) {
        const [status, data1, data2] = msg.data
        const command = status & 0xf0

        if (command === 0x90 && data2 > 0) {
            const semitonesFromSa = data1 - this.midiRootNote
            const velocity = Math.max(0.2, data2 / 127.0)
            this.triggerSwaraSemitone(semitonesFromSa, velocity, null, true)
        } else if (command === 0x80 || (command === 0x90 && data2 === 0)) {
            this.workletNode?.port.postMessage({ type: "note_off" })
        } else if (command === 0xe0) {
            const bend14 = ((data2 << 7) | data1) - 8192
            this.pitchBendSemitones = (bend14 / 8192.0) * 2.0
            const pitchRatio = Math.pow(2.0, (this.currentSemitone + this.pitchBendSemitones) / 12.0)
            this.wasm?._synth_trigger_pluck?.(0.5, pitchRatio)
            this.workletNode?.port.postMessage({ type: "pitch_bend", pitchRatio })
        } else if (command === 0xb0 && data1 === 1) {
            const jawVal = data2 / 127.0
            this.wasm?._synth_set_param_value?.(1, jawVal)
        } else if (command === 0xb0 && data1 === 5) {
            // MIDI CC #5 (Standard Portamento Time) -> Controls MEEND knob (0..1200ms)!
            const meendMs = (data2 / 127.0) * 1200.0
            this.wasm?._synth_set_param_value?.(4, meendMs)
        }
    }

    setManualParam(e) {
        this.ensureAudioEngine()
        const input = e.currentTarget
        const idx = parseInt(input.dataset.paramIndex, 10)
        const val = parseFloat(input.value)
        if (!Number.isNaN(idx) && !Number.isNaN(val) && this.wasm?._synth_set_param_value) {
            this.wasm._synth_set_param_value(idx, val)
        }
    }

    spawnInlineCanvasInput(meta) {
        this.closeInlineInput()
        const c = this.canvasTarget
        const parent = c.parentElement
        if (getComputedStyle(parent).position === "static") parent.style.position = "relative"

        const isIntParam = (meta.key === "root_hz" || meta.key === "meend_ms")
        const input = document.createElement("input")
        input.type = "number"
        input.inputMode = "decimal"
        input.step = isIntParam ? "1" : "0.01"
        input.min = meta.min
        input.max = meta.max
        input.value = isIntParam ? Math.round(meta.value) : meta.value.toFixed(2)

        Object.assign(input.style, {
            position: "absolute",
            left: `${ c.offsetLeft + meta.x - 4 }px`,
            top: `${ c.offsetTop + meta.y - 2 }px`,
            width: `${ Math.max(64, meta.w + 8) }px`,
            height: "22px",
            fontSize: "11px",
            fontFamily: "monospace",
            fontWeight: "bold",
            textAlign: "center",
            backgroundColor: "var(--saanskara-bg-canvas)",
            color: "var(--saanskara-accent-primary)",
            border: "1.5px solid var(--saanskara-accent-primary)",
            borderRadius: "4px",
            outline: "none",
            zIndex: "50",
            boxShadow: "0 0 10px var(--saanskara-accent-primary)"
        })

        const commit = () => {
            const parsed = parseFloat(input.value)
            if (!Number.isNaN(parsed) && this.wasm?._synth_set_param_value) {
                this.wasm._synth_set_param_value(meta.index, parsed)
            }
            this.closeInlineInput()
        }

        input.addEventListener("keydown", (ev) => {
            if (ev.key === "Enter") { ev.preventDefault(); commit() }
            if (ev.key === "Escape") { ev.preventDefault(); this.closeInlineInput() }
        })
        input.addEventListener("blur", commit)

        parent.appendChild(input)
        this.activeInlineInput = input
        requestAnimationFrame(() => { input.focus(); input.select() })
    }

    closeInlineInput() {
        if (this.activeInlineInput) {
            const el = this.activeInlineInput
            this.activeInlineInput = null
            el.remove()
        }
    }

    async toggleAudio() {
        await this.ensureAudioEngine()
        this.droneEnabled = !this.droneEnabled
        this.wasm?._synth_set_drone_active?.(this.droneEnabled ? 1 : 0)
        this.workletNode?.port.postMessage({ type: "drone", active: this.droneEnabled })
        this.updateAudioButtonUI()
    }

    async pluckNote() {
        await this.triggerSwaraSemitone(0, 1.0, "Sa", false)
    }

    async ensureAudioEngine() {
        if (!this.audioCtx) {
            const AudioContextClass = window.AudioContext || window.webkitAudioContext
            this.audioCtx = new AudioContextClass({ latencyHint: "interactive", sampleRate: 48000 })

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
        this.audioBtnTarget.textContent = this.droneEnabled ? "🔊 Drone: ON" : "🔇 Drone: OFF"
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
        window.removeEventListener("keydown", this.onKeyDown)
        window.removeEventListener("keyup", this.onKeyUp)
        this.closeInlineInput()
        this.themeObserver?.disconnect()
        this.workletNode?.disconnect()
        this.audioCtx?.close()
    }
}
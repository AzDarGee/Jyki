// app/javascript/controllers/nano_synth_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
    static targets = ["canvas", "readout"]

    async connect() {
        window.saanskaraOnImGuiParamChanged = (param, value) => {
            if (this.hasReadoutTarget) {
                this.readoutTarget.textContent = `${param}: ${value.toFixed(2)}`
            }
            this.element.dispatchEvent(new CustomEvent("imgui:param", {
                bubbles: true,
                detail: { param, value }
            }))
        }

        await this.loadWasmScript("/wasm/saanskara_synth.js")
        this.wasm = await window.createSaanskaraSynthModule()

        this.resizeCanvas()
        this.wasm.ccall("init_saanskara_imgui", "number", ["string"], ["#nano-synth-canvas"])
        this.syncRagaThemeToImGui()

        this.bindMultiTouchEvents()
        this.observeThemeChanges()
    }

    loadWasmScript(src) {
        return new Promise((resolve, reject) => {
            if (window.createSaanskaraSynthModule) return resolve()
            const s = document.createElement("script")
            s.src = src
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
            this.wasm._imgui_set_canvas_size(Math.round(rect.width), Math.round(rect.height), dpr)
        }
    }

    bindMultiTouchEvents() {
        const c = this.canvasTarget
        // CRITICAL FOR MOBILE PHONES & IPADS: Prevents browser scroll/zoom from stealing knob drags!
        c.style.touchAction = "none"
        c.style.userSelect = "none"
        c.style.webkitUserSelect = "none"

        window.addEventListener("resize", () => this.resizeCanvas())

        c.addEventListener("pointerdown", (e) => {
            e.preventDefault()
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
    }
}
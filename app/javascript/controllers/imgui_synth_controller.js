// app/javascript/controllers/imgui_synth_controller.js
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
    static targets = ["canvas", "readout"]

    async connect() {
        // Expose global hook so C++ EM_JS callback reaches Stimulus & WebAudio/CRDTs!
        window.saanskaraOnImGuiParamChanged = (param, value) => {
            if (this.hasReadoutTarget) {
                this.readoutTarget.textContent = `${param}: ${value.toFixed(2)}`
            }
            // Dispatch standard DOM event so studio_controller / crdt_sync_controller can persist it!
            this.element.dispatchEvent(new CustomEvent("imgui:param", {
                bubbles: true,
                detail: { param, value }
            }))
        }

        await this.loadWasmScript("/wasm/saanskara_synth2.js")
        this.wasm = await window.createSaanskaraSynthModule()

        this.resizeCanvas()
        this.wasm.ccall("init_saanskara_imgui", "number", ["string"], ["#imgui-synth-canvas"])
        this.syncRagaThemeToImGui()

        this.bindInputEvents()
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
        c.width = rect.width
        c.height = rect.height
        if (this.wasm) {
            this.wasm._imgui_set_canvas_size(c.width, c.height)
        }
    }

    bindInputEvents() {
        const c = this.canvasTarget
        window.addEventListener("resize", () => this.resizeCanvas())

        c.addEventListener("pointermove", (e) => {
            const r = c.getBoundingClientRect()
            this.wasm._imgui_on_mouse_move(e.clientX - r.left, e.clientY - r.top)
        })
        c.addEventListener("pointerdown", (e) => {
            c.setPointerCapture(e.pointerId)
            this.wasm._imgui_on_mouse_button(e.button, 1)
        })
        c.addEventListener("pointerup", (e) => {
            this.wasm._imgui_on_mouse_button(e.button, 0)
        })
        c.addEventListener("wheel", (e) => {
            e.preventDefault()
            this.wasm._imgui_on_mouse_wheel(-e.deltaX * 0.01, -e.deltaY * 0.01)
        }, { passive: false })
    }

    // Reads live CSS Custom Properties (--saanskara-*) and injects them into Dear ImGui!
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
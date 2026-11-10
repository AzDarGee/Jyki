import { Controller } from "@hotwired/stimulus"

// Manages the Bottom Mixer Console, Web Audio GainNode.setTargetAtTime de-zippered automation,
// bidirectional fader sync with Track Headers, double-click fader reset, and Inserts Rack.
export default class extends Controller {
  static targets = [
    "trackHeaderRow",
    "soloButton",
    "collapsedTrackPill",
    "collapsedSoloBadge",
    "headerGainSlider",
    "headerGainReadout",
    "channelStripCard",
    "stripGainSlider",
    "stripPanSlider",
    "stripPanLabel",
    "stripModeBadge",
    "insertsTrackTitle",
    "insertsCpuSummary",
    "insertsList",
    "pluginSlot"
  ]

  static values = {
    selectedTrack: { type: Number, default: 1 }
  }

  connect() {
    this.audioCtx = null
    this.trackNodes = new Map()
    this.boundTrackRemoved = this.onTrackRemoved.bind(this)
    this.element.addEventListener("mixer:track-removed", this.boundTrackRemoved)
  }

  disconnect() {
    this.element.removeEventListener("mixer:track-removed", this.boundTrackRemoved)
  }

  onTrackRemoved(event) {
    const { trackId } = event.detail || {}
    if (!trackId) return

    const nodes = this.trackNodes.get(trackId)
    if (nodes) {
      try {
        nodes.gainNode.disconnect()
        nodes.panNode.disconnect()
      } catch (_e) {
        // Ignore if already disconnected
      }
      this.trackNodes.delete(trackId)
    }

    if (this.selectedTrackValue === trackId) {
      const remainingRow = this.trackHeaderRowTargets.find((r) => Number(r.dataset.trackId) !== trackId)
      if (remainingRow) {
        this.selectTrack({ currentTarget: remainingRow })
      } else {
        this.selectedTrackValue = 0
        if (this.hasInsertsTrackTitleTarget) {
          this.insertsTrackTitleTarget.textContent = "No Track Selected"
        }
      }
    }
  }

  // Lazy-initialize Web Audio API GainNode + StereoPannerNode graph for smooth setTargetAtTime automation
  ensureAudioNode(trackId) {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext
    if (!AudioContextClass) return null

    if (!this.audioCtx) {
      try {
        this.audioCtx = new AudioContextClass({ latencyHint: "interactive", sampleRate: 48000 })
      } catch (_e) {
        return null
      }
    }

    if (!this.trackNodes.has(trackId)) {
      const gainNode = this.audioCtx.createGain()
      const panNode = this.audioCtx.createStereoPanner()
      gainNode.connect(panNode)
      panNode.connect(this.audioCtx.destination)
      this.trackNodes.set(trackId, { gainNode, panNode })
    }
    return this.trackNodes.get(trackId)
  }

  dbToLinear(db) {
    if (db <= -24) return 0.0
    return Math.pow(10, db / 20)
  }

  formatDb(db) {
    const num = Number(db)
    if (Math.abs(num) < 0.05) return "0.0 dB"
    return `${num > 0 ? "+" : ""}${num.toFixed(1)} dB`
  }

  // Select track and sync Left Track Header + Bottom Channel Strip + Inserts Rack header.
  // When the Tracks panel is collapsed (data-collapsed="true"), clicking a track row also toggles Solo mode!
  handleTrackRowClick(event) {
    this.selectTrack(event)

    const panel = event.currentTarget.closest("[data-zone='track-headers']")
    if (panel && panel.dataset.collapsed === "true") {
      const trackId = Number(event.currentTarget.dataset.trackId)
      this.toggleSoloForTrack(trackId)
    }
  }

  selectTrack(event) {
    const trackId = Number(event.currentTarget.dataset.trackId)
    const trackName = event.currentTarget.dataset.trackName
    if (!trackId) return

    this.selectedTrackValue = trackId

    this.trackHeaderRowTargets.forEach((row) => {
      const active = Number(row.dataset.trackId) === trackId
      row.className = `h-[68px] px-2.5 py-2 flex flex-col justify-between transition-colors cursor-pointer relative overflow-hidden ${
        active
          ? "bg-[#191613] border-l-2 border-l-[#d97706]"
          : "bg-[#121110] hover:bg-[#161513]"
      }`
    })

    this.channelStripCardTargets.forEach((card) => {
      const active = Number(card.dataset.trackId) === trackId
      card.className = `flex-1 min-w-[180px] max-w-[240px] bg-[#111315] border ${
        active ? "border-[#5c3d1e]" : "border-[#22252a]"
      } rounded p-3 flex flex-col justify-between transition-colors cursor-pointer`
    })

    if (trackName && this.hasInsertsTrackTitleTarget) {
      this.insertsTrackTitleTarget.textContent = trackName
    }
  }

  // Bidirectional Gain Fader Update + GainNode.setTargetAtTime smoothing
  updateTrackGain(event) {
    const slider = event.currentTarget
    const trackId = Number(slider.dataset.trackId)
    const dbValue = Number(slider.value)

    this.applyGainToTrack(trackId, dbValue)
  }

  applyGainToTrack(trackId, dbValue) {
    // 1. Update Web Audio GainNode smoothly with 15ms timeConstant (zero zipper noise)
    const nodes = this.ensureAudioNode(trackId)
    if (nodes && this.audioCtx) {
      const linear = this.dbToLinear(dbValue)
      nodes.gainNode.gain.setTargetAtTime(linear, this.audioCtx.currentTime, 0.015)
    }

    // 2. Sync Left Track Header slider + readout
    this.headerGainSliderTargets.forEach((el) => {
      if (Number(el.dataset.trackId) === trackId && Number(el.value) !== dbValue) {
        el.value = String(dbValue)
      }
    })
    this.headerGainReadoutTargets.forEach((el) => {
      if (Number(el.dataset.trackId) === trackId) {
        el.textContent = this.formatDb(dbValue)
      }
    })

    // 3. Sync Bottom Mixer Strip slider
    this.stripGainSliderTargets.forEach((el) => {
      if (Number(el.dataset.trackId) === trackId && Number(el.value) !== dbValue) {
        el.value = String(dbValue)
      }
    })
  }

  // Pan Slider Update + StereoPannerNode.pan.setTargetAtTime smoothing
  updateTrackPan(event) {
    const slider = event.currentTarget
    const trackId = Number(slider.dataset.trackId)
    const panVal = Number(slider.value)
    this.applyPanToTrack(trackId, panVal)
  }

  applyPanToTrack(trackId, panVal) {
    const nodes = this.ensureAudioNode(trackId)
    if (nodes && this.audioCtx) {
      const normPan = Math.max(-1, Math.min(1, panVal / 50))
      nodes.panNode.pan.setTargetAtTime(normPan, this.audioCtx.currentTime, 0.015)
    }

    this.stripPanSliderTargets.forEach((el) => {
      if (Number(el.dataset.trackId) === trackId && Number(el.value) !== panVal) {
        el.value = String(panVal)
      }
    })

    this.stripPanLabelTargets.forEach((el) => {
      if (Number(el.dataset.trackId) === trackId) {
        el.textContent = `PAN (${panVal})`
      }
    })
  }

  // Double-Click Fader Reset to 0.0 dB
  resetFader(event) {
    const trackId = Number(event.currentTarget.dataset.trackId)
    this.applyGainToTrack(trackId, 0.0)
  }

  // Double-Click Pan Reset to 0
  resetPan(event) {
    const trackId = Number(event.currentTarget.dataset.trackId)
    this.applyPanToTrack(trackId, 0)
  }

  // Toggle M / S / R / NR flags on Track Header
  toggleTrackFlag(event) {
    const btn = event.currentTarget
    const flag = btn.dataset.flag
    const trackId = Number(btn.dataset.trackId)
    const active = btn.getAttribute("aria-pressed") !== "true"
    btn.setAttribute("aria-pressed", active ? "true" : "false")

    if (flag === "muted") {
      btn.className = `w-4 h-4 rounded-xs font-mono text-[9px] font-bold flex items-center justify-center border cursor-pointer transition-colors ${
        active
          ? "bg-[#d97706] text-[#09090b] border-[#f59e0b]"
          : "bg-[#1a1918] text-[#8e8a83] border-[#2b2825] hover:text-[#f4f4f0]"
      }`
    } else if (flag === "soloed") {
      this.syncSoloState(trackId, active)
    } else if (flag === "armed") {
      btn.className = `w-4 h-4 rounded-xs font-mono text-[9px] font-bold flex items-center justify-center border cursor-pointer transition-colors ${
        active
          ? "bg-[#dc2626] text-white border-[#ef4444] shadow-[0_0_6px_rgba(220,38,38,0.5)]"
          : "bg-[#1a1918] text-[#8e8a83] border-[#2b2825] hover:text-[#f4f4f0]"
      }`
    } else if (flag === "nr") {
      btn.className = `px-1 h-4 rounded-xs font-mono text-[9px] font-bold flex items-center justify-center border cursor-pointer transition-colors ${
        active
          ? "bg-[#14b8a6] text-[#042f2e] border-[#2dd4bf] shadow-[0_0_6px_rgba(20,184,166,0.4)]"
          : "bg-[#1a1918] text-[#8e8a83] border-[#2b2825] hover:text-[#f4f4f0]"
      }`

      // Sync bottom channel strip mode badge (⚡ NR ON / ⚡ DIRECT)
      this.stripModeBadgeTargets.forEach((badge) => {
        if (Number(badge.dataset.trackId) === trackId) {
          badge.innerHTML = `<span>⚡</span><span>${active ? "NR ON" : "DIRECT"}</span>`
        }
      })
    }
  }

  toggleSoloForTrack(trackId) {
    const row = this.trackHeaderRowTargets.find((r) => Number(r.dataset.trackId) === trackId)
    const currentlySoloed = row ? row.dataset.soloed === "true" : false
    this.syncSoloState(trackId, !currentlySoloed)
  }

  syncSoloState(trackId, active) {
    this.trackHeaderRowTargets.forEach((row) => {
      if (Number(row.dataset.trackId) === trackId) {
        row.dataset.soloed = active ? "true" : "false"
      }
    })

    this.soloButtonTargets.forEach((btn) => {
      if (Number(btn.dataset.trackId) === trackId) {
        btn.setAttribute("aria-pressed", active ? "true" : "false")
        btn.className = `w-4 h-4 rounded-xs font-mono text-[9px] font-bold flex items-center justify-center border cursor-pointer transition-colors ${
          active
            ? "bg-[#f59e0b] text-[#09090b] border-[#fbbf24]"
            : "bg-[#1a1918] text-[#8e8a83] border-[#2b2825] hover:text-[#f4f4f0]"
        }`
      }
    })

    this.collapsedSoloBadgeTargets.forEach((badge) => {
      if (Number(badge.dataset.trackId) === trackId) {
        badge.textContent = active ? "SOLO" : "S"
        badge.className = `px-1.5 py-0.5 rounded-xs font-mono text-[9px] font-bold border transition-colors ${
          active
            ? "bg-[#f59e0b] text-[#09090b] border-[#fbbf24] shadow-[0_0_8px_rgba(245,158,11,0.5)]"
            : "bg-[#1a1918] text-[#8e8a83] border-[#2b2825]"
        }`
      }
    })
  }

  // Inserts Rack Actions
  togglePluginSlot(event) {
    const btn = event.currentTarget
    const active = btn.getAttribute("aria-pressed") !== "true"
    btn.setAttribute("aria-pressed", active ? "true" : "false")
    btn.className = active
      ? "w-3.5 h-3.5 rounded-full bg-[#14b8a6]/20 border border-[#14b8a6] text-[#2dd4bf] flex items-center justify-center text-[8px] cursor-pointer shrink-0"
      : "w-3.5 h-3.5 rounded-full bg-[#1f2229] border border-[#3f3f46] text-[#71717a] flex items-center justify-center text-[8px] cursor-pointer shrink-0"
    this.recalculateInsertsCpu()
  }

  removePluginSlot(event) {
    const slotEl = event.currentTarget.closest("[data-mixer-target='pluginSlot']")
    if (slotEl) {
      slotEl.remove()
      this.recalculateInsertsCpu()
    }
  }

  addPluginSlot() {
    if (!this.hasInsertsListTarget) return
    const currentSlots = this.insertsListTarget.children.length
    if (currentSlots >= 8) return

    const presets = [
      { name: "Saanskara Comb...", full: "Saanskara Comb Delay", type: "Stock DSP", cpu: "0.9%" },
      { name: "Valhalla Vintage...", full: "Valhalla VintageVerb", type: "VST3", cpu: "1.8%" },
      { name: "Saanskara Clipper", full: "Saanskara Soft Clipper", type: "Stock DSP", cpu: "0.6%" }
    ]
    const pick = presets[currentSlots % presets.length]

    const row = document.createElement("div")
    row.className = "h-6 px-2 rounded bg-[#17191e] border border-[#242830] flex items-center justify-between gap-2 text-[10px] font-mono"
    row.setAttribute("data-mixer-target", "pluginSlot")
    row.innerHTML = `
      <div class="flex items-center gap-1.5 min-w-0">
        <button type="button"
                data-action="click->mixer#togglePluginSlot"
                aria-pressed="true"
                class="w-3.5 h-3.5 rounded-full bg-[#14b8a6]/20 border border-[#14b8a6] text-[#2dd4bf] flex items-center justify-center text-[8px] cursor-pointer shrink-0">
          ⏻
        </button>
        <span class="text-[#e5e2dc] truncate" title="${pick.full}">${pick.name}</span>
      </div>
      <div class="flex items-center gap-1.5 shrink-0">
        <span class="px-1.5 py-0.2 rounded ${
          pick.type === "Stock DSP"
            ? "bg-[#0f2926] border border-[#14b8a6]/50 text-[#2dd4bf]"
            : "bg-[#271b11] border border-[#d97706]/50 text-[#f59e0b]"
        } text-[9px]">${pick.type}</span>
        <span class="text-[#8e8a83] w-8 text-right">${pick.cpu}</span>
        <button type="button"
                data-action="click->mixer#removePluginSlot"
                class="text-[#8e8a83] hover:text-[#ef4444] cursor-pointer px-0.5">×</button>
      </div>
    `
    this.insertsListTarget.appendChild(row)
    this.recalculateInsertsCpu()
  }

  recalculateInsertsCpu() {
    if (!this.hasInsertsCpuSummaryTarget || !this.hasInsertsListTarget) return
    const count = this.insertsListTarget.children.length
    const cpu = (count * 1.45).toFixed(1)
    this.insertsCpuSummaryTarget.textContent = `${count}/8 · ${cpu}%`
  }
}


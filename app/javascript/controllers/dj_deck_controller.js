import { Controller } from "@hotwired/stimulus"

// Controls an individual DJ Deck Card (Decks A–F):
// Play, SYNC, SNAP, MASTER handoff, Hot Cues 1–4, Phase Nudge, L/THRU/R Crossfader routing,
// and 3-Band Isolator EQ + Tempo Pitch + Channel Volume with double-click-to-reset.
export default class extends Controller {
  static targets = [
    "progressBar",
    "statusDot",
    "harmonicBadge",
    "bpmReadout",
    "pitchReadout",
    "playButton",
    "syncButton",
    "snapButton",
    "masterButton",
    "cueButton",
    "xfadeButton",
    "lowLabel", "lowSlider",
    "midLabel", "midSlider",
    "highLabel", "highSlider",
    "tempoLabel", "tempoSlider",
    "volLabel", "volSlider"
  ]

  static values = {
    letter: { type: String, default: "A" },
    bpm: { type: Number, default: 128.0 },
    baseBpm: { type: Number, default: 128.0 },
    halftime: { type: Boolean, default: false },
    master: { type: Boolean, default: false },
    synced: { type: Boolean, default: false },
    playing: { type: Boolean, default: false },
    color: { type: String, default: "#c28e5c" },
    accent: { type: String, default: "#d97706" }
  }

  initialize() {
    this.isReady = false
    this.snapEnabled = true
  }

  connect() {
    this.isReady = true
    this.boundSyncToMaster = this.onSyncToMaster.bind(this)
    this.boundMasterUpdated = this.onMasterUpdated.bind(this)

    this.element.addEventListener("dj-beatgrid:sync-to-master", this.boundSyncToMaster)
    this.element.addEventListener("dj-beatgrid:master-updated", this.boundMasterUpdated)
  }

  disconnect() {
    this.isReady = false
    this.element.removeEventListener("dj-beatgrid:sync-to-master", this.boundSyncToMaster)
    this.element.removeEventListener("dj-beatgrid:master-updated", this.boundMasterUpdated)
  }

  // Row 2: Play / Pause Deck
  togglePlay() {
    this.playingValue = !this.playingValue
    if (this.hasPlayButtonTarget) {
      this.playButtonTarget.setAttribute("aria-pressed", String(this.playingValue))
      this.playButtonTarget.textContent = this.playingValue ? "⏸ Play" : "▷ Play"
      this.playButtonTarget.className = this.playingValue
        ? "border border-[#d97706] bg-[#291b0e] text-xs px-2.5 py-1 rounded text-[#f59e0b] font-mono font-semibold cursor-pointer transition-colors"
        : "border border-[#33312e] bg-[#1a1918] hover:border-[#5c3d1e] text-xs px-2.5 py-1 rounded text-white font-mono cursor-pointer transition-colors"
    }
    this.emitDeckState()
  }

  // Row 2: Toggle Beatgrid Phase Sync
  toggleSync() {
    this.syncedValue = !this.syncedValue
    this.renderSyncButton()
    this.emitDeckState()
  }

  renderSyncButton() {
    if (!this.hasSyncButtonTarget) return
    this.syncButtonTarget.setAttribute("aria-pressed", String(this.syncedValue))
    this.syncButtonTarget.className = this.syncedValue
      ? "text-[10px] font-mono px-2 py-1 rounded border cursor-pointer transition-colors border-[#14b8a6]/70 bg-[#0f2422] text-[#2dd4bf]"
      : "text-[10px] font-mono px-2 py-1 rounded border cursor-pointer transition-colors border-[#2a2826] bg-[#151413] text-[#8e8a83] hover:text-[#e5e2dc]"
  }

  // Row 2: Toggle Quantized Cue Snap
  toggleSnap() {
    this.snapEnabled = !this.snapEnabled
    if (this.hasSnapButtonTarget) {
      this.snapButtonTarget.setAttribute("aria-pressed", String(this.snapEnabled))
      this.snapButtonTarget.className = this.snapEnabled
        ? "text-[10px] font-mono px-2 py-1 rounded border border-[#5c3d1e] bg-[#1f160e] text-[#f59e0b] cursor-pointer transition-colors"
        : "text-[10px] font-mono px-2 py-1 rounded border border-[#2a2826] bg-[#151413] text-[#8e8a83] hover:text-[#e5e2dc] cursor-pointer transition-colors"
    }
  }

  // Row 2: Hand Off Master Clock to This Deck
  handOffMaster() {
    this.masterValue = true
    this.element.dispatchEvent(
      new CustomEvent("dj-deck:master-handoff", {
        bubbles: true,
        detail: {
          letter: this.letterValue,
          bpm: this.bpmValue,
          halftime: this.halftimeValue
        }
      })
    )
  }

  onMasterUpdated(event) {
    const { masterDeck } = event.detail || {}
    this.masterValue = masterDeck === this.letterValue
    if (this.hasMasterButtonTarget) {
      this.masterButtonTarget.setAttribute("aria-pressed", String(this.masterValue))
      this.masterButtonTarget.className = this.masterValue
        ? "text-[10px] font-mono px-2 py-1 rounded border cursor-pointer transition-colors border-[#d97706] bg-[#291b0e] text-[#f59e0b] font-semibold"
        : "text-[10px] font-mono px-2 py-1 rounded border cursor-pointer transition-colors border-[#2a2826] bg-[#151413] text-[#8e8a83] hover:text-[#f59e0b]"
    }
  }

  // Called when "⚡ Beatmatch Sync All to Master" is clicked in the Beatgrid Header
  onSyncToMaster(event) {
    const { masterBpm } = event.detail || {}
    if (!masterBpm) return

    const targetBpm = this.halftimeValue ? masterBpm / 2.0 : masterBpm
    this.syncedValue = true
    this.renderSyncButton()
    this.applyBpm(targetBpm)
  }

  // Row 2: Reset Pitch to 0.0% (Base Track BPM)
  resetPitch() {
    this.applyBpm(this.baseBpmValue)
    if (this.hasTempoSliderTarget) {
      this.tempoSliderTarget.value = "0"
    }
    this.emitDeckState()
  }

  // Row 3: Trigger Hot Cue 1–4
  triggerCue(event) {
    const selectedCue = event.currentTarget.dataset.cue
    this.cueButtonTargets.forEach((btn) => {
      const active = btn.dataset.cue === selectedCue
      btn.className = active
        ? "bg-[#ea580c] text-black font-mono font-bold text-[10px] px-2 py-0.5 rounded cursor-pointer"
        : "bg-[#18181a] border border-[#27272a] hover:border-[#4a3520] text-[#a1a1aa] text-[10px] font-mono px-2 py-0.5 rounded cursor-pointer"
    })

    this.element.dispatchEvent(
      new CustomEvent("dj-deck:cue", {
        bubbles: true,
        detail: { letter: this.letterValue, cue: Number(selectedCue) }
      })
    )
  }

  // Row 3: Temporary Phase Nudge (< NUDGE >)
  nudgePhase(event) {
    const dir = Number(event.currentTarget.dataset.dir || 1)
    this.element.dispatchEvent(
      new CustomEvent("dj-deck:nudge", {
        bubbles: true,
        detail: { letter: this.letterValue, direction: dir }
      })
    )
  }

  // Row 3: Crossfader Bus Assign (L | THRU | R)
  assignCrossfader(event) {
    const selectedSide = event.currentTarget.dataset.xfade
    this.xfadeButtonTargets.forEach((btn) => {
      const active = btn.dataset.xfade === selectedSide
      btn.className = `px-1.5 py-0.2 rounded-xs cursor-pointer transition-colors ${
        active
          ? "bg-[#272522] text-[#e5e2dc] font-semibold"
          : "text-[#8e8a83] hover:text-[#e5e2dc]"
      }`
    })
  }

  // Row 4: 3-Band EQ (LOW / MID / HIGH)
  updateEq(event) {
    const slider = event.currentTarget
    const param = slider.dataset.param
    const val = Number(slider.value)
    const formatted = `${param.toUpperCase()} (${val > 0 ? `+${val}` : val})`

    if (param === "low" && this.hasLowLabelTarget) this.lowLabelTarget.textContent = formatted
    if (param === "mid" && this.hasMidLabelTarget) this.midLabelTarget.textContent = formatted
    if (param === "high" && this.hasHighLabelTarget) this.highLabelTarget.textContent = formatted
  }

  // Row 4: Tempo Slider (-8% to +8%)
  updateTempo(event) {
    const pct = Number(event.currentTarget.value)
    const nextBpm = this.baseBpmValue * (1.0 + pct / 100.0)
    this.applyBpm(nextBpm)
    this.emitDeckState()
  }

  resetTempo() {
    this.resetPitch()
  }

  // Row 4: Volume Slider (0..100)
  updateVol(event) {
    const val = Number(event.currentTarget.value)
    if (this.hasVolLabelTarget) {
      this.volLabelTarget.textContent = `VOL (${val})`
    }
  }

  // Double-click any EQ or Volume slider to reset to default
  resetSlider(event) {
    const slider = event.currentTarget
    const defVal = slider.dataset.default || "0"
    slider.value = defVal
    const param = slider.dataset.param

    if (param === "vol") {
      if (this.hasVolLabelTarget) this.volLabelTarget.textContent = `VOL (${defVal})`
    } else if (param === "low" && this.hasLowLabelTarget) {
      this.lowLabelTarget.textContent = "LOW (0)"
    } else if (param === "mid" && this.hasMidLabelTarget) {
      this.midLabelTarget.textContent = "MID (0)"
    } else if (param === "high" && this.hasHighLabelTarget) {
      this.highLabelTarget.textContent = "HIGH (0)"
    }
  }

  applyBpm(nextBpm) {
    this.bpmValue = Number(nextBpm.toFixed(2))
    const pctDiff = ((this.bpmValue - this.baseBpmValue) / this.baseBpmValue) * 100.0
    const sign = pctDiff >= -0.02 ? "+" : ""

    if (this.hasBpmReadoutTarget) {
      this.bpmReadoutTarget.textContent = `${this.bpmValue.toFixed(2)} BPM`
    }
    if (this.hasPitchReadoutTarget) {
      this.pitchReadoutTarget.textContent = `Pitch: ${sign}${pctDiff.toFixed(1)}%`
    }
    if (this.hasTempoSliderTarget) {
      this.tempoSliderTarget.value = String(Math.max(-8, Math.min(8, pctDiff)).toFixed(2))
    }
  }

  emitDeckState() {
    this.element.dispatchEvent(
      new CustomEvent("dj-deck:state-changed", {
        bubbles: true,
        detail: {
          letter: this.letterValue,
          bpm: this.bpmValue,
          playing: this.playingValue,
          synced: this.syncedValue
        }
      })
    )
  }
}


import { Controller } from "@hotwired/stimulus"

// Hardware-accelerated 6-Lane Phase-Locked Parallel Beatgrid Renderer
// Renders Decks A–F in parallel swimlanes with beat-grid ticks, downbeat transient spikes,
// dashed zero-crossing centerlines, and smooth right-to-left scrolling across the center red playhead.
export default class extends Controller {
  static targets = [
    "canvas",
    "headerReadout",
    "quantizeButton",
    "syncAllButton",
    "syncAllLabel",
    "masterRingIndicator"
  ]

  static values = {
    masterDeck: { type: String, default: "A" },
    masterBpm: { type: Number, default: 128.0 },
    quantize: { type: Boolean, default: true },
    playing: { type: Boolean, default: false }
  }

  initialize() {
    this.isReady = false
    this.scrubbing = false
    this.lastScrubX = 0
    this.lanes = [
      { id: "A", baseBpm: 128.0, bpm: 128.0, targetBpm: 128.0, halftime: false, phase: 0.0, targetPhase: 0.0, playing: true, synced: true, master: true, color: "#c28e5c", spikeColor: "#e2b27e", seed: 1.1 },
      { id: "B", baseBpm: 126.0, bpm: 126.0, targetBpm: 126.0, halftime: false, phase: 18.0, targetPhase: 18.0, playing: false, synced: false, master: false, color: "#14b8a6", spikeColor: "#2dd4bf", seed: 2.3 },
      { id: "C", baseBpm: 124.0, bpm: 124.0, targetBpm: 124.0, halftime: false, phase: -24.0, targetPhase: -24.0, playing: false, synced: false, master: false, color: "#a86464", spikeColor: "#c98276", seed: 3.7 },
      { id: "D", baseBpm: 130.0, bpm: 130.0, targetBpm: 130.0, halftime: false, phase: 31.0, targetPhase: 31.0, playing: false, synced: false, master: false, color: "#c85a28", spikeColor: "#ea580c", seed: 4.9 },
      { id: "E", baseBpm: 132.0, bpm: 132.0, targetBpm: 132.0, halftime: false, phase: -42.0, targetPhase: -42.0, playing: false, synced: false, master: false, color: "#5c7a72", spikeColor: "#7a9e95", seed: 6.1 },
      { id: "F", baseBpm: 64.0, bpm: 64.0, targetBpm: 64.0, halftime: true, phase: 0.0, targetPhase: 0.0, playing: false, synced: false, master: false, color: "#b58952", spikeColor: "#d4a76a", seed: 7.4 }
    ]
    this.syncingAnimation = false
  }

  connect() {
    this.isReady = true
    this.boundResize = this.resizeAndRender.bind(this)
    this.boundDeckChange = this.onDeckStateChanged.bind(this)
    this.boundMasterHandoff = this.onMasterHandoff.bind(this)
    this.boundDeckNudge = this.onDeckNudge.bind(this)
    this.boundDeckCue = this.onDeckCue.bind(this)

    window.addEventListener("resize", this.boundResize)
    this.element.addEventListener("dj-deck:state-changed", this.boundDeckChange)
    this.element.addEventListener("dj-deck:master-handoff", this.boundMasterHandoff)
    this.element.addEventListener("dj-deck:nudge", this.boundDeckNudge)
    this.element.addEventListener("dj-deck:cue", this.boundDeckCue)

    if (typeof ResizeObserver !== "undefined" && this.hasCanvasTarget) {
      this.resizeObserver = new ResizeObserver(() => this.resizeAndRender())
      this.resizeObserver.observe(this.canvasTarget)
    }

    this.resizeAndRender()
    this.startLoop()
  }

  disconnect() {
    this.isReady = false
    window.removeEventListener("resize", this.boundResize)
    this.element.removeEventListener("dj-deck:state-changed", this.boundDeckChange)
    this.element.removeEventListener("dj-deck:master-handoff", this.boundMasterHandoff)
    this.element.removeEventListener("dj-deck:nudge", this.boundDeckNudge)
    this.element.removeEventListener("dj-deck:cue", this.boundDeckCue)
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.rafId) cancelAnimationFrame(this.rafId)
  }

  playingValueChanged() {
    if (!this.isReady) return
    this.lastTime = performance.now()
    this.renderFrame()
  }

  toggleQuantize() {
    this.quantizeValue = !this.quantizeValue
    if (this.hasQuantizeButtonTarget) {
      this.quantizeButtonTarget.setAttribute("aria-pressed", String(this.quantizeValue))
      this.quantizeButtonTarget.textContent = this.quantizeValue ? "QUANTIZE ON" : "QUANTIZE OFF"
      this.quantizeButtonTarget.className = this.quantizeValue
        ? "px-2.5 py-1 text-xs font-mono rounded border border-[#5c3d1e] bg-[#1f160e] text-[#e5a952] cursor-pointer transition-colors"
        : "px-2.5 py-1 text-xs font-mono rounded border border-[#2a2826] bg-[#141312] text-[#8e8a83] cursor-pointer transition-colors"
    }
  }

  // Smoothly beatmatches & phase-locks all 6 decks to Master Deck A (128.00 BPM, Deck F at 64.00 BPM half-time)
  syncAllToMaster() {
    const masterLane = this.lanes.find((l) => l.id === this.masterDeckValue) || this.lanes[0]
    const masterEffectiveBpm = masterLane.halftime ? masterLane.bpm * 2 : masterLane.bpm
    this.masterBpmValue = masterEffectiveBpm

    const masterGridInterval = 148
    const alignedPhase = Math.round(masterLane.phase / masterGridInterval) * masterGridInterval

    this.lanes.forEach((lane) => {
      lane.synced = true
      lane.targetBpm = lane.halftime ? masterEffectiveBpm / 2.0 : masterEffectiveBpm
      lane.targetPhase = alignedPhase
    })

    this.syncingAnimation = true
    if (this.hasSyncAllLabelTarget) {
      this.syncAllLabelTarget.textContent = "Phase-Locking Decks A–F..."
      setTimeout(() => {
        if (this.hasSyncAllLabelTarget) {
          this.syncAllLabelTarget.textContent = "Beatmatch Sync All to Master"
        }
      }, 900)
    }

    // Notify all 6 dj-deck controllers to update their BPM, Pitch %, and SYNC button states
    this.element.querySelectorAll("[data-controller='dj-deck']").forEach((deckEl) => {
      deckEl.dispatchEvent(
        new CustomEvent("dj-beatgrid:sync-to-master", {
          detail: { masterBpm: masterEffectiveBpm, masterDeck: this.masterDeckValue }
        })
      )
    })
  }

  onDeckStateChanged(event) {
    const { letter, bpm, playing, synced } = event.detail || {}
    const lane = this.lanes.find((l) => l.id === letter)
    if (!lane) return

    if (typeof bpm === "number") {
      lane.bpm = bpm
      lane.targetBpm = bpm
      if (lane.master) {
        this.masterBpmValue = lane.halftime ? bpm * 2 : bpm
        this.updateHeaderReadout()
      }
    }
    if (typeof playing === "boolean") lane.playing = playing
    if (typeof synced === "boolean") lane.synced = synced
    this.renderFrame()
  }

  onMasterHandoff(event) {
    const { letter, bpm, halftime } = event.detail || {}
    if (!letter) return

    this.masterDeckValue = letter
    this.masterBpmValue = halftime ? bpm * 2 : bpm

    this.lanes.forEach((lane) => {
      lane.master = lane.id === letter
    })

    // Update top-right ring indicator vertical position to match the new Master lane
    if (this.hasMasterRingIndicatorTarget) {
      const idx = this.lanes.findIndex((l) => l.id === letter)
      const topPct = ((idx + 0.5) / 6) * 100
      this.masterRingIndicatorTarget.style.top = `calc(${topPct}% - 10px)`
    }

    // Notify all deck cards so only the active master deck has the glowing amber 👑 MASTER button
    this.element.querySelectorAll("[data-controller='dj-deck']").forEach((deckEl) => {
      deckEl.dispatchEvent(
        new CustomEvent("dj-beatgrid:master-updated", { detail: { masterDeck: letter } })
      )
    })

    this.updateHeaderReadout()
    this.renderFrame()
  }

  onDeckNudge(event) {
    const { letter, direction } = event.detail || {}
    const lane = this.lanes.find((l) => l.id === letter)
    if (!lane) return
    lane.phase += (direction || 1) * 12
    lane.targetPhase = lane.phase
    this.renderFrame()
  }

  onDeckCue(event) {
    const { letter, cue } = event.detail || {}
    const lane = this.lanes.find((l) => l.id === letter)
    if (!lane) return
    lane.phase = (Number(cue) - 1) * 148
    lane.targetPhase = lane.phase
    this.renderFrame()
  }

  updateHeaderReadout() {
    if (!this.hasHeaderReadoutTarget) return
    this.headerReadoutTarget.textContent =
      `PHASE-LOCKED PARALLEL BEATGRID · MASTER ${this.masterDeckValue} · ${this.masterBpmValue.toFixed(2)} BPM`
  }

  scrubBeatgrid(event) {
    this.scrubbing = true
    this.lastScrubX = event.clientX
  }

  dragBeatgrid(event) {
    if (!this.scrubbing) return
    const dx = event.clientX - this.lastScrubX
    this.lastScrubX = event.clientX
    this.lanes.forEach((lane) => {
      lane.phase -= dx * 1.25
      lane.targetPhase = lane.phase
    })
    this.renderFrame()
  }

  endScrubBeatgrid() {
    this.scrubbing = false
  }

  resizeAndRender() {
    if (!this.hasCanvasTarget) return
    const canvas = this.canvasTarget
    const dpr = window.devicePixelRatio || 1
    const rect = canvas.getBoundingClientRect()
    const w = Math.max(1, Math.floor(rect.width * dpr))
    const h = Math.max(1, Math.floor(rect.height * dpr))
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w
      canvas.height = h
    }
    this.renderFrame()
  }

  startLoop() {
    this.lastTime = performance.now()
    const tick = (now) => {
      const dt = Math.min(0.05, (now - this.lastTime) / 1000)
      this.lastTime = now

      let needsRender = false

      // Smooth interpolation when Beatmatch Sync All to Master is triggered
      if (this.syncingAnimation) {
        let allSettled = true
        this.lanes.forEach((lane) => {
          const bpmDiff = lane.targetBpm - lane.bpm
          const phaseDiff = lane.targetPhase - lane.phase
          if (Math.abs(bpmDiff) > 0.01 || Math.abs(phaseDiff) > 0.25) {
            lane.bpm += bpmDiff * 0.18
            lane.phase += phaseDiff * 0.18
            allSettled = false
          } else {
            lane.bpm = lane.targetBpm
            lane.phase = lane.targetPhase
          }
        })
        needsRender = true
        if (allSettled) this.syncingAnimation = false
      }

      // Advance scrolling waveforms from right to left for playing decks or global transport
      this.lanes.forEach((lane) => {
        if (this.playingValue || lane.playing) {
          const effectiveBpm = lane.halftime ? lane.bpm * 2.0 : lane.bpm
          const pixelsPerSec = (effectiveBpm / 128.0) * 115.0
          lane.phase += pixelsPerSec * dt
          lane.targetPhase = lane.phase
          needsRender = true
        }
      })

      if (needsRender) {
        this.renderFrame()
      }

      this.rafId = requestAnimationFrame(tick)
    }
    this.rafId = requestAnimationFrame(tick)
  }

  renderFrame() {
    if (!this.hasCanvasTarget || !this.lanes) return
    const canvas = this.canvasTarget
    const ctx = canvas.getContext("2d")
    if (!ctx) return

    const dpr = window.devicePixelRatio || 1
    const width = canvas.width / dpr
    const height = canvas.height / dpr
    if (width <= 2 || height <= 2) return

    ctx.save()
    ctx.scale(dpr, dpr)

    // Deep Obsidian Backdrop
    ctx.fillStyle = "#0b0a09"
    ctx.fillRect(0, 0, width, height)

    const laneCount = this.lanes.length
    const laneHeight = height / laneCount
    const centerX = width * 0.5
    const barSpacing = 148 // Pixels per bar at 128 BPM

    this.lanes.forEach((lane, idx) => {
      const laneTop = idx * laneHeight
      const midY = laneTop + laneHeight * 0.5

      // Alternating subtle swimlane background
      ctx.fillStyle = idx % 2 === 0 ? "rgba(18, 17, 16, 0.55)" : "rgba(13, 12, 11, 0.55)"
      ctx.fillRect(0, laneTop, width, laneHeight)

      // Bottom lane separator line
      if (idx < laneCount - 1) {
        ctx.strokeStyle = "#1c1916"
        ctx.lineWidth = 1
        ctx.beginPath()
        ctx.moveTo(0, laneTop + laneHeight - 0.5)
        ctx.lineTo(width, laneTop + laneHeight - 0.5)
        ctx.stroke()
      }

      // Dashed horizontal zero-crossing centerline
      ctx.save()
      ctx.strokeStyle = "rgba(255, 255, 255, 0.08)"
      ctx.lineWidth = 1
      ctx.setLineDash([ 3, 4 ])
      ctx.beginPath()
      ctx.moveTo(0, midY)
      ctx.lineTo(width, midY)
      ctx.stroke()
      ctx.restore()

      // Scale beat-grid spacing by deck tempo ratio relative to 128 BPM
      const effectiveBpm = lane.halftime ? lane.bpm * 2.0 : lane.bpm
      const laneBarSpacing = barSpacing * (128.0 / effectiveBpm)
      const beatSpacing = laneBarSpacing / 4.0

      // Compute first visible beat tick from left edge relative to centerX and lane.phase
      const phaseOffset = lane.phase % laneBarSpacing
      const startBarX = (centerX - phaseOffset) % laneBarSpacing - laneBarSpacing

      // Minor beat grid ticks & major downbeat vertical bars
      for (let bx = startBarX; bx < width + laneBarSpacing; bx += laneBarSpacing) {
        // Major Bar Downbeat Line (Glowing vertical transient bar in deck signature color)
        if (bx >= 0 && bx <= width) {
          ctx.strokeStyle = lane.spikeColor
          ctx.globalAlpha = 0.65
          ctx.lineWidth = 1.6
          ctx.beginPath()
          ctx.moveTo(bx, laneTop + 5)
          ctx.lineTo(bx, laneTop + laneHeight - 5)
          ctx.stroke()
          ctx.globalAlpha = 1.0
        }

        // Sub-beat ticks (beats 2, 3, 4)
        ctx.strokeStyle = "rgba(255, 255, 255, 0.06)"
        ctx.lineWidth = 1
        for (let b = 1; b < 4; b++) {
          const subX = bx + b * beatSpacing
          if (subX >= 0 && subX <= width) {
            ctx.beginPath()
            ctx.moveTo(subX, laneTop + 10)
            ctx.lineTo(subX, laneTop + laneHeight - 10)
            ctx.stroke()
          }
        }
      }

      // Symmetrical High-Density Audio Transient Packets in Deck Signature Color
      ctx.strokeStyle = lane.color
      ctx.lineWidth = 1.35
      ctx.beginPath()

      const step = 2.5
      for (let x = 28; x < width; x += step) {
        const trackX = x + lane.phase - centerX
        const barPhase = ((trackX % laneBarSpacing) + laneBarSpacing) % laneBarSpacing
        const normBar = barPhase / laneBarSpacing // 0..1 across each bar

        // Downbeat transient spike at normBar near 0, plus rhythmic packets at 0.25, 0.5, 0.75
        const beatPos = (normBar * 4.0) % 1.0
        const transientBurst = Math.exp(-beatPos * 6.5)
        const packetMod = Math.abs(Math.sin(trackX * 0.075 + lane.seed) * Math.cos(trackX * 0.032 - lane.seed * 0.5))
        const hfTexture = 0.35 + 0.65 * Math.abs(Math.sin(trackX * 0.45 + lane.seed))

        // Create characteristic gaps & dubplate packet shapes matching the screenshot
        const gate = Math.sin(trackX * 0.042 + lane.seed * 1.7) > -0.35 ? 1.0 : 0.12
        const maxHalfH = laneHeight * 0.42
        const amp = Math.min(
          maxHalfH,
          (0.06 + (transientBurst * 0.62 + packetMod * 0.48) * hfTexture * gate) * maxHalfH
        )

        ctx.moveTo(x, midY - amp)
        ctx.lineTo(x, midY + amp)
      }
      ctx.stroke()

      // Left-Aligned Bold Monospace Lane Letter (A, B, C, D, E, F)
      ctx.font = "700 13px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
      ctx.fillStyle = lane.spikeColor
      ctx.textBaseline = "top"
      ctx.fillText(lane.id, 8, laneTop + 7)
    })

    ctx.restore()
  }
}


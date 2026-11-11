import { Controller } from "@hotwired/stimulus"
import { HybridLogicalClock } from "lib/crdt_clock"

export default class extends Controller {
  static targets = [
    "saveStatus",
    "projectName",
    "bpmInput",
    "bpmDisplay",
    "scaleSelect",
    "masterVolumeInput",
    "masterVolumeDisplay",
    "clockReadout",
    "playButton",
    "loopButton",
    "synthButton",
    "modeButton",
    "themeButton",
    "dawWorkspace",
    "djWorkspace",
    "trackList",
    "timelineStage",
    "timelineCanvas",
    "playheadLine",
    "tokenBg",
    "tokenAccent",
    "activeThemeLabel",
    "clipCountBadge",
    "trackCountBadge",
    "deckCanvas",
    "crossfaderInput",
    "hardwareTelemetryBadge",
    "audioOutputSelect",
    "routingBusBadge"
  ]

  static values = {
    project: Object
  }

  connect() {
    this.project = this.hasProjectValue ? structuredClone(this.projectValue) : {
      id: 1,
      name: "Saanskara Raga Session 01",
      bpm: 124.0,
      ppqn: 960,
      sample_rate: 48000,
      time_signature_numerator: 4,
      time_signature_denominator: 4,
      workspace_mode: "daw",
      theme_name: "midnight",
      tracks: [],
      automation_lanes: []
    }

    this.ppqn = this.project.ppqn || 960
    this.beatsPerBar = this.project.time_signature_numerator || 4
    this.ticksPerBar = this.ppqn * this.beatsPerBar
    this.totalBars = 8
    this.totalTicks = this.ticksPerBar * this.totalBars
    this.rulerHeight = 32
    this.laneHeight = 76

    this.isPlaying = true
    this.loopEnabled = true
    this.synthEnabled = false
    this.currentTick = 0
    this.lastFrameTime = performance.now()
    this.lastTriggeredStep = -1
    this.audioCtx = null
    this.masterMerger = null
    this.selectedSinkId = ""
    this.dragState = null
    this.debounceTimers = {}
    this.remotePeers = new Map()
    this.lastAssignedHlc = null
    this.clientNodeId = null

    this.boundRemoteDelta = (e) => this.onRemoteDelta(e.detail)
    this.boundRemoteTelemetry = (e) => this.onRemoteTelemetry(e.detail)
    this.boundPeerLeave = (e) => this.onPeerLeave(e.detail)
    this.boundDeviceChange = () => this.refreshAudioOutputDevices()
    this.element.addEventListener("crdt:remote-delta", this.boundRemoteDelta)
    this.element.addEventListener("crdt:remote-telemetry", this.boundRemoteTelemetry)
    this.element.addEventListener("crdt:peer-leave", this.boundPeerLeave)
    if (navigator.mediaDevices && typeof navigator.mediaDevices.addEventListener === "function") {
      navigator.mediaDevices.addEventListener("devicechange", this.boundDeviceChange)
    }

    this.applyThemeUI(this.project.theme_name || "midnight", false)
    this.applyWorkspaceModeUI(this.project.workspace_mode || "daw", false)
    this.updateClockReadout()
    this.refreshAudioOutputDevices()
    this.updateHardwareTelemetry()

    this.boundResize = () => this.resizeCanvases()
    window.addEventListener("resize", this.boundResize)
    this.resizeCanvases()

    this.startRenderLoop()
  }

  disconnect() {
    if (this.rafId) cancelAnimationFrame(this.rafId)
    if (this.boundResize) window.removeEventListener("resize", this.boundResize)
    if (this.boundRemoteDelta) this.element.removeEventListener("crdt:remote-delta", this.boundRemoteDelta)
    if (this.boundRemoteTelemetry) this.element.removeEventListener("crdt:remote-telemetry", this.boundRemoteTelemetry)
    if (this.boundPeerLeave) this.element.removeEventListener("crdt:peer-leave", this.boundPeerLeave)
    if (this.boundDeviceChange && navigator.mediaDevices && typeof navigator.mediaDevices.removeEventListener === "function") {
      navigator.mediaDevices.removeEventListener("devicechange", this.boundDeviceChange)
    }
    if (this.audioCtx && this.audioCtx.state !== "closed") {
      this.audioCtx.close().catch(() => {})
    }
  }

  // --- THEME ENGINE & CSS CUSTOM PROPERTIES ---

  switchTheme(event) {
    const theme = event.currentTarget.dataset.setTheme || event.currentTarget.dataset.themeParam
    if (!theme) return

    this.project.theme_name = theme
    this.applyThemeUI(theme, true)
  }

  applyThemeUI(themeName, persist = false) {
    const root = document.documentElement
    root.setAttribute("data-theme", themeName)
    this.element.setAttribute("data-theme", themeName)
    try {
      localStorage.setItem("jaku_studio_theme", themeName)
    } catch (_) {}

    this.themeButtonTargets.forEach((btn) => {
      const isMatch = btn.dataset.setTheme === themeName
      btn.setAttribute("aria-pressed", isMatch ? "true" : "false")
    })

    requestAnimationFrame(() => {
      this.updateTokenInspector(themeName)
      this.renderTimelineCanvas()
      this.renderDeckCanvases()
    })

    if (persist && this.project.id) {
      this.persistProject({ theme_name: themeName })
    }
  }

  getThemeToken(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(`--saanskara-${name}`).trim()
  }

  updateTokenInspector(themeName) {
    if (this.hasTokenBgTarget) {
      this.tokenBgTarget.textContent = this.getThemeToken("bg-canvas") || "#0b0a09"
    }
    if (this.hasTokenAccentTarget) {
      this.tokenAccentTarget.textContent = this.getThemeToken("accent-primary") || "#f59e0b"
    }
    if (this.hasActiveThemeLabelTarget) {
      this.activeThemeLabelTarget.textContent = themeName
    }
  }

  // --- WORKSPACE MODE SWITCHER (DAW TIMELINE vs 6-DECK DJ) ---

  switchWorkspaceMode(event) {
    const mode = event.currentTarget.dataset.workspaceMode
    if (!mode) return

    this.project.workspace_mode = mode
    this.applyWorkspaceModeUI(mode, true)
  }

  applyWorkspaceModeUI(mode, persist = false) {
    this.modeButtonTargets.forEach((btn) => {
      const active = btn.dataset.workspaceMode === mode
      btn.setAttribute("aria-pressed", active ? "true" : "false")
    })

    if (this.hasDawWorkspaceTarget && this.hasDjWorkspaceTarget) {
      if (mode === "dj_6deck") {
        this.dawWorkspaceTarget.classList.add("hidden")
        this.djWorkspaceTarget.classList.remove("hidden")
      } else if (mode === "hybrid") {
        this.dawWorkspaceTarget.classList.remove("hidden")
        this.djWorkspaceTarget.classList.remove("hidden")
      } else {
        this.dawWorkspaceTarget.classList.remove("hidden")
        this.djWorkspaceTarget.classList.add("hidden")
      }
    }

    requestAnimationFrame(() => {
      this.resizeCanvases()
    })

    if (persist && this.project.id) {
      this.persistProject({ workspace_mode: mode })
    }
  }

  // --- TRANSPORT & WEBAUDIO SYNTHESIZER ---

  togglePlay() {
    this.isPlaying = !this.isPlaying
    this.lastFrameTime = performance.now()
    if (this.hasPlayButtonTarget) {
      this.playButtonTarget.textContent = this.isPlaying ? "⏸ Pause" : "▶ Play"
      this.playButtonTarget.setAttribute("aria-pressed", this.isPlaying ? "true" : "false")
    }
  }

  stopTransport() {
    this.isPlaying = false
    this.currentTick = 0
    this.lastTriggeredStep = -1
    if (this.hasPlayButtonTarget) {
      this.playButtonTarget.textContent = "▶ Play"
      this.playButtonTarget.setAttribute("aria-pressed", "false")
    }
    this.updateClockReadout()
    this.renderTimelineCanvas()
  }

  toggleLoop() {
    this.loopEnabled = !this.loopEnabled
    if (this.hasLoopButtonTarget) {
      this.loopButtonTarget.setAttribute("aria-pressed", this.loopEnabled ? "true" : "false")
    }
  }

  initAudioEngine() {
    if (!this.audioCtx) {
      const AudioCtx = window.AudioContext || window.webkitAudioContext
      if (!AudioCtx) return null
      this.audioCtx = new AudioCtx({ latencyHint: "interactive", sampleRate: 48000 })
      this.configureDestinationRouting(this.audioCtx)
      if (this.selectedSinkId && typeof this.audioCtx.setSinkId === "function") {
        this.audioCtx.setSinkId(this.selectedSinkId).catch(() => {})
      }
    }
    this.updateHardwareTelemetry()
    return this.audioCtx
  }

  configureDestinationRouting(audioCtx) {
    if (!audioCtx || !audioCtx.destination) return
    const dest = audioCtx.destination
    const maxChannelCount = dest.maxChannelCount || 2

    if (maxChannelCount >= 4) {
      const targetChannels = Math.min(maxChannelCount, 8)
      dest.channelCount = targetChannels
      dest.channelCountMode = "explicit"
      dest.channelInterpretation = "discrete"

      // ChannelMergerNode routes Channels 1-2 (indices 0, 1) as Master Out
      // and Channels 3-4 (indices 2, 3) as DJ Headphone Cue Out
      this.masterMerger = audioCtx.createChannelMerger(targetChannels)
      this.masterMerger.channelCountMode = "explicit"
      this.masterMerger.channelInterpretation = "discrete"
      this.masterMerger.connect(dest)
    } else {
      this.masterMerger = null
    }
  }

  updateHardwareTelemetry() {
    const audioCtx = this.audioCtx
    const sampleRateKhz = audioCtx ? audioCtx.sampleRate / 1000 : (this.project.sample_rate || 48000) / 1000
    const baseLatencyMs = (audioCtx && typeof audioCtx.baseLatency === "number" ? audioCtx.baseLatency * 1000 : 2.7).toFixed(1)
    const channelCount = audioCtx && audioCtx.destination ? audioCtx.destination.channelCount : 2

    if (this.hasHardwareTelemetryBadgeTarget) {
      const text = audioCtx
        ? `${audioCtx.sampleRate / 1000}kHz • ${(audioCtx.baseLatency * 1000).toFixed(1)}ms • ${audioCtx.destination.channelCount}ch`
        : `${sampleRateKhz}kHz • ${baseLatencyMs}ms • ${channelCount}ch`
      this.hardwareTelemetryBadgeTarget.textContent = text
    }

    if (this.hasRoutingBusBadgeTarget) {
      this.routingBusBadgeTarget.textContent =
        channelCount >= 4 ? "Ch 1-2 Master • Ch 3-4 DJ Cue" : "Ch 1-2 Stereo Master"
    }
  }

  async refreshAudioOutputDevices() {
    if (!this.hasAudioOutputSelectTarget) return
    if (!navigator.mediaDevices || typeof navigator.mediaDevices.enumerateDevices !== "function") return

    try {
      const devices = await navigator.mediaDevices.enumerateDevices()
      const outputs = devices.filter((d) => d.kind === "audiooutput")
      const select = this.audioOutputSelectTarget
      const currentVal = this.selectedSinkId || select.value || ""

      select.innerHTML = ""
      const defaultOpt = document.createElement("option")
      defaultOpt.value = ""
      defaultOpt.textContent = "Default Audio Out (CoreAudio / WASAPI)"
      defaultOpt.style.backgroundColor = "#121110"
      select.appendChild(defaultOpt)

      outputs.forEach((device, idx) => {
        if (!device.deviceId || device.deviceId === "default") return
        const opt = document.createElement("option")
        opt.value = device.deviceId
        opt.textContent = device.label || `Pro Audio Output #${idx + 1}`
        opt.style.backgroundColor = "#121110"
        select.appendChild(opt)
      })

      select.value = currentVal
    } catch (_) {
      // Ignore permission or unsupported enumeration errors
    }
  }

  async changeAudioOutputDevice(event) {
    const deviceId = event.currentTarget.value || ""
    this.selectedSinkId = deviceId

    const audioCtx = this.initAudioEngine()
    if (audioCtx && typeof audioCtx.setSinkId === "function") {
      try {
        await audioCtx.setSinkId(deviceId)
        this.configureDestinationRouting(audioCtx)
        this.updateHardwareTelemetry()
        this.setSavingStatus("✓ Audio Sink Routed")
      } catch (_) {
        this.setSavingStatus("⚠ Sink Switch Unsupported")
      }
    }
  }

  toggleSynth() {
    this.synthEnabled = !this.synthEnabled
    if (this.synthEnabled && !this.audioCtx) {
      this.initAudioEngine()
    }
    if (this.audioCtx && this.audioCtx.state === "suspended") {
      this.audioCtx.resume().then(() => this.updateHardwareTelemetry()).catch(() => {})
    }
    this.updateHardwareTelemetry()
    if (this.hasSynthButtonTarget) {
      this.synthButtonTarget.setAttribute("aria-pressed", this.synthEnabled ? "true" : "false")
      this.synthButtonTarget.textContent = this.synthEnabled ? "🔊 Synth ON" : "🔈 Synth Mute"
    }
  }

  changeBpm(event) {
    const raw = parseFloat(event.currentTarget.value)
    if (Number.isNaN(raw) || raw < 30 || raw > 300) return

    this.project.bpm = raw
    if (this.hasBpmDisplayTarget) {
      this.bpmDisplayTarget.textContent = raw.toFixed(1)
    }
    if (this.hasBpmInputTarget && this.bpmInputTarget !== event.currentTarget) {
      this.bpmInputTarget.value = raw.toFixed(1)
    }

    this.debounce("project_bpm", 180, () => {
      this.persistProject({ bpm: raw })
    })
  }

  changeScale(event) {
    const scaleName = event.currentTarget.value
    if (!scaleName) return

    this.project.scale_name = scaleName
    this.persistProject({ scale_name: scaleName })
  }

  changeMasterVolume(event) {
    const db = parseFloat(event.currentTarget.value)
    if (Number.isNaN(db)) return

    this.project.master_volume_db = db
    if (this.hasMasterVolumeDisplayTarget) {
      this.masterVolumeDisplayTarget.textContent = `${db >= 0 ? "+" : ""}${db.toFixed(1)} dB`
    }

    this.debounce("master_vol", 180, () => {
      this.persistProject({ master_volume_db: db })
    })
  }

  updateClockReadout() {
    const tickInt = Math.max(0, Math.floor(this.currentTick))
    const bar = Math.floor(tickInt / this.ticksPerBar) + 1
    const beat = Math.floor((tickInt % this.ticksPerBar) / this.ppqn) + 1
    const subTick = tickInt % this.ppqn

    const formatted = `${String(bar).padStart(3, "0")} : ${String(beat).padStart(2, "0")} : ${String(subTick).padStart(3, "0")}`
    if (this.hasClockReadoutTarget) {
      this.clockReadoutTarget.textContent = formatted
    }
  }

  triggerSynthStepIfNeeded(prevTick, nextTick) {
    if (!this.synthEnabled || !this.audioCtx) return

    const stepSize = 240 // 16th-note resolution at 960 PPQN
    const currentStep = Math.floor(nextTick / stepSize)
    if (currentStep === this.lastTriggeredStep) return
    this.lastTriggeredStep = currentStep

    const tracks = this.project.tracks || []
    const anySoloed = tracks.some((t) => t.soloed)

    tracks.forEach((track) => {
      if (track.muted) return
      if (anySoloed && !track.soloed) return

      const clips = track.clips || []
      clips.forEach((clip) => {
        if (clip.muted) return
        if (nextTick < clip.start_tick || nextTick >= clip.start_tick + clip.duration_ticks) return

        const localTick = (nextTick - clip.start_tick) % (clip.loop_end_tick || 3840)
        const events = clip.midi_events || []

        events.forEach((ev) => {
          if (Math.abs(ev.t - (currentStep * stepSize) % 3840) < stepSize * 0.5 && Math.abs(ev.t - localTick) < stepSize) {
            this.playWebAudioNote(ev.n || 60, (ev.v || 100) / 127, track)
          }
        })
      })
    })
  }

  playWebAudioNote(midiNote, velocity, track) {
    if (!this.audioCtx) return
    const now = this.audioCtx.currentTime
    const freq = 440 * Math.pow(2, (midiNote - 69) / 12)

    const osc = this.audioCtx.createOscillator()
    const gain = this.audioCtx.createGain()
    const panner = this.audioCtx.createStereoPanner ? this.audioCtx.createStereoPanner() : null

    osc.type = track.track_type === "midi" ? "triangle" : "sine"
    osc.frequency.setValueAtTime(freq, now)

    const trackLinearGain = Math.pow(10, (track.volume_db || 0) / 20)
    const masterLinearGain = Math.pow(10, (this.project.master_volume_db || 0) / 20)
    const peakGain = Math.min(0.35, velocity * 0.15 * trackLinearGain * masterLinearGain)

    gain.gain.setValueAtTime(0.0001, now)
    gain.gain.exponentialRampToValueAtTime(Math.max(0.001, peakGain), now + 0.012)
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.22)

    if (panner) {
      panner.pan.setValueAtTime(Math.max(-1, Math.min(1, track.pan || 0)), now)
      osc.connect(gain)
      gain.connect(panner)
      this.connectNodeToHardwareOutput(panner, track)
    } else {
      osc.connect(gain)
      this.connectNodeToHardwareOutput(gain, track)
    }

    osc.start(now)
    osc.stop(now + 0.24)
  }

  connectNodeToHardwareOutput(sourceNode, track) {
    if (!this.audioCtx) return
    if (this.masterMerger && this.audioCtx.destination.channelCount >= 4) {
      const splitter = this.audioCtx.createChannelSplitter(2)
      sourceNode.connect(splitter)
      // Channels 1-2 (indices 0, 1): Master Out
      splitter.connect(this.masterMerger, 0, 0)
      splitter.connect(this.masterMerger, 1, 1)
      // Channels 3-4 (indices 2, 3): DJ Headphone Cue Out (when soloed/cued)
      if (track && (track.soloed || track.cued)) {
        splitter.connect(this.masterMerger, 0, 2)
        splitter.connect(this.masterMerger, 1, 3)
      }
    } else {
      sourceNode.connect(this.audioCtx.destination)
    }
  }

  // --- TRACK CONTROLS (MUTE / SOLO / ARM / VOLUME / PAN / ADD / DELETE) ---

  toggleTrackFlag(event) {
    const btn = event.currentTarget
    const trackId = parseInt(btn.dataset.trackId, 10)
    const field = btn.dataset.field
    const track = (this.project.tracks || []).find((t) => t.id === trackId)
    if (!track || !field) return

    const nextValue = !track[field]
    track[field] = nextValue
    btn.setAttribute("aria-pressed", nextValue ? "true" : "false")
    btn.classList.toggle("is-active", nextValue)

    const row = this.element.querySelector(`[data-track-row-id="${trackId}"]`)
    if (row && field === "armed") {
      row.classList.toggle("armed", nextValue)
    }

    this.renderTimelineCanvas()
    this.persistTrack(trackId, { [field]: nextValue })
  }

  changeTrackVolume(event) {
    const input = event.currentTarget
    const trackId = parseInt(input.dataset.trackId, 10)
    const volumeDb = parseFloat(input.value)
    const track = (this.project.tracks || []).find((t) => t.id === trackId)
    if (!track || Number.isNaN(volumeDb)) return

    track.volume_db = volumeDb
    this.element.querySelectorAll(`[data-track-volume-label="${trackId}"]`).forEach((el) => {
      el.textContent = `${volumeDb >= 0 ? "+" : ""}${volumeDb.toFixed(1)} dB`
    })
    this.element.querySelectorAll(`input[data-track-id="${trackId}"][data-action*="changeTrackVolume"]`).forEach((el) => {
      if (el !== input) el.value = volumeDb
    })

    this.emitLocalTelemetry({
      cursor_track_uuid: track.uuid,
      live_fader: { track_uuid: track.uuid, track_id: track.id, volume_db: volumeDb, pan: track.pan }
    })

    this.debounce(`track_vol_${trackId}`, 150, () => {
      this.persistTrack(trackId, { volume_db: volumeDb })
    })
  }

  changeTrackPan(event) {
    const input = event.currentTarget
    const trackId = parseInt(input.dataset.trackId, 10)
    const pan = parseFloat(input.value)
    const track = (this.project.tracks || []).find((t) => t.id === trackId)
    if (!track || Number.isNaN(pan)) return

    track.pan = pan
    const labelText = pan === 0 ? "C" : pan < 0 ? `L${Math.round(Math.abs(pan) * 100)}` : `R${Math.round(pan * 100)}`
    this.element.querySelectorAll(`[data-track-pan-label="${trackId}"]`).forEach((el) => {
      el.textContent = labelText
    })

    this.emitLocalTelemetry({
      cursor_track_uuid: track.uuid,
      live_fader: { track_uuid: track.uuid, track_id: track.id, volume_db: track.volume_db, pan }
    })

    this.debounce(`track_pan_${trackId}`, 150, () => {
      this.persistTrack(trackId, { pan })
    })
  }

  async addTrack(event) {
    const trackType = event.currentTarget.dataset.trackType || "audio"
    this.setSavingStatus("Adding track...")

    try {
      const response = await this.apiFetch(`/projects/${this.project.id}/tracks`, "POST", {
        track: { track_type: trackType }
      })
      if (response && response.ok && response.track) {
        this.project.tracks.push(response.track)
        this.appendTrackRowToDOM(response.track)
        this.updateCounts()
        this.resizeCanvases()
        this.setSavingStatus("✓ Track Added • 960 PPQN")
      }
    } catch (_) {
      this.setSavingStatus("⚠ Track Save Error")
    }
  }

  async deleteTrack(event) {
    const trackId = parseInt(event.currentTarget.dataset.trackId, 10)
    if (!trackId) return

    this.setSavingStatus("Removing track...")
    try {
      const response = await this.apiFetch(`/tracks/${trackId}`, "DELETE")
      if (response && response.ok) {
        this.project.tracks = (this.project.tracks || []).filter((t) => t.id !== trackId)
        this.element.querySelectorAll(`[data-track-row-id="${trackId}"]`).forEach((el) => el.remove())
        this.updateCounts()
        this.resizeCanvases()
        this.setSavingStatus("✓ Track Removed")
      }
    } catch (_) {
      this.setSavingStatus("⚠ Delete Failed")
    }
  }

  // --- 6-DECK DJ CONTROLS ---

  jumpToCuePoint(event) {
    const tick = parseInt(event.currentTarget.dataset.cueTick, 10)
    if (Number.isNaN(tick)) return

    this.currentTick = Math.max(0, Math.min(this.totalTicks - 1, tick))
    this.updateClockReadout()
    this.renderTimelineCanvas()
    this.renderDeckCanvases()
  }

  changeDeckPitch(event) {
    const input = event.currentTarget
    const trackId = parseInt(input.dataset.trackId, 10)
    const pct = parseFloat(input.value)
    if (Number.isNaN(pct)) return

    const baseBpm = this.project.bpm || 124.0
    const effectiveBpm = baseBpm * (1 + pct / 100)
    const badge = this.element.querySelector(`[data-deck-bpm-label="${trackId}"]`)
    if (badge) badge.textContent = `${effectiveBpm.toFixed(2)} BPM (${pct >= 0 ? "+" : ""}${pct.toFixed(1)}%)`
  }

  syncDeckToMaster(event) {
    const trackId = parseInt(event.currentTarget.dataset.trackId, 10)
    const pitchSlider = this.element.querySelector(`input[data-deck-pitch="${trackId}"]`)
    if (pitchSlider) {
      pitchSlider.value = 0
      const badge = this.element.querySelector(`[data-deck-bpm-label="${trackId}"]`)
      if (badge) badge.textContent = `${(this.project.bpm || 124.0).toFixed(2)} BPM (SYNC)`
    }
  }

  // --- MULTI-TRACK DAW CANVAS TIMELINE & INTERACTION ---

  resizeCanvases() {
    const dpr = window.devicePixelRatio || 1

    if (this.hasTimelineCanvasTarget) {
      const canvas = this.timelineCanvasTarget
      const trackCount = Math.max(6, (this.project.tracks || []).length)
      const desiredHeight = this.rulerHeight + trackCount * this.laneHeight
      canvas.style.height = `${desiredHeight}px`
      if (this.hasTimelineStageTarget) {
        this.timelineStageTarget.style.height = `${desiredHeight}px`
      }
      const width = canvas.clientWidth || 720
      canvas.width = width * dpr
      canvas.height = desiredHeight * dpr
    }

    this.deckCanvasTargets.forEach((deckCanvas) => {
      const w = deckCanvas.clientWidth || 260
      const h = deckCanvas.clientHeight || 56
      deckCanvas.width = w * dpr
      deckCanvas.height = h * dpr
    })

    this.renderTimelineCanvas()
    this.renderDeckCanvases()
  }

  startRenderLoop() {
    const loop = (now) => {
      const dtSec = Math.min(0.1, (now - this.lastFrameTime) / 1000)
      this.lastFrameTime = now

      if (this.isPlaying) {
        const bpm = this.project.bpm || 124.0
        const ticksPerSecond = (bpm / 60.0) * this.ppqn
        const prevTick = this.currentTick
        let nextTick = prevTick + dtSec * ticksPerSecond

        if (nextTick >= this.totalTicks) {
          nextTick = this.loopEnabled ? nextTick % this.totalTicks : 0
          if (!this.loopEnabled) this.isPlaying = false
        }

        this.currentTick = nextTick
        this.triggerSynthStepIfNeeded(prevTick, nextTick)
        this.updateClockReadout()
      }

      this.renderTimelineCanvas()
      if (this.project.workspace_mode !== "daw") {
        this.renderDeckCanvases()
      }

      this.rafId = requestAnimationFrame(loop)
    }

    this.rafId = requestAnimationFrame(loop)
  }

  renderTimelineCanvas() {
    if (!this.hasTimelineCanvasTarget) return
    const canvas = this.timelineCanvasTarget
    const ctx = canvas.getContext("2d")
    const dpr = window.devicePixelRatio || 1
    const width = canvas.width / dpr
    const height = canvas.height / dpr

    ctx.save()
    ctx.scale(dpr, dpr)
    ctx.clearRect(0, 0, width, height)

    const bgCanvas = this.getThemeToken("bg-canvas") || "#0b0a09"
    const gridBar = this.getThemeToken("grid-bar") || "#1e1b18"
    const gridBeat = this.getThemeToken("grid-beat") || "#141210"
    const textMuted = this.getThemeToken("text-muted") || "#8e8a83"
    const accentPrimary = this.getThemeToken("accent-primary") || "#f59e0b"

    ctx.fillStyle = bgCanvas
    ctx.fillRect(0, 0, width, height)

    // 1. Top Ruler Background
    ctx.fillStyle = "rgba(0, 0, 0, 0.35)"
    ctx.fillRect(0, 0, width, this.rulerHeight)
    ctx.strokeStyle = gridBar
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(0, this.rulerHeight)
    ctx.lineTo(width, this.rulerHeight)
    ctx.stroke()

    // 2. Vertical Bar & Beat Gridlines
    const totalBeats = this.totalBars * this.beatsPerBar
    for (let beat = 0; beat <= totalBeats; beat++) {
      const x = (beat / totalBeats) * width
      const isBar = beat % this.beatsPerBar === 0

      ctx.strokeStyle = isBar ? gridBar : gridBeat
      ctx.lineWidth = isBar ? 1.25 : 0.75
      ctx.beginPath()
      ctx.moveTo(x, isBar ? 0 : this.rulerHeight)
      ctx.lineTo(x, height)
      ctx.stroke()

      if (isBar && beat < totalBeats) {
        const barNumber = beat / this.beatsPerBar + 1
        ctx.fillStyle = textMuted
        ctx.font = "600 10px ui-monospace, SFMono-Regular, Menlo, monospace"
        ctx.fillText(`BAR ${barNumber}`, x + 6, 20)
      }
    }

    // 3. Horizontal Track Lanes & Clips
    const tracks = this.project.tracks || []
    tracks.forEach((track, idx) => {
      const laneTop = this.rulerHeight + idx * this.laneHeight
      const laneBottom = laneTop + this.laneHeight

      if (idx % 2 === 1) {
        ctx.fillStyle = "rgba(255, 255, 255, 0.015)"
        ctx.fillRect(0, laneTop, width, this.laneHeight)
      }

      ctx.strokeStyle = gridBar
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(0, laneBottom)
      ctx.lineTo(width, laneBottom)
      ctx.stroke()

      const clips = track.clips || []
      clips.forEach((clip) => {
        this.drawClipOnLane(ctx, clip, track, laneTop, width)
      })
    })

    // 4. Multi-User Ghost Cursors & Remote Clip Drag Previews
    this.drawRemoteCollaboratorGhosts(ctx, width, height)

    // 5. Playhead Position
    const playheadX = (this.currentTick / this.totalTicks) * width
    if (this.hasPlayheadLineTarget) {
      this.playheadLineTarget.style.left = `${playheadX}px`
    }

    // Ruler Playhead Triangle
    ctx.fillStyle = accentPrimary
    ctx.beginPath()
    ctx.moveTo(playheadX - 6, 0)
    ctx.lineTo(playheadX + 6, 0)
    ctx.lineTo(playheadX, 11)
    ctx.closePath()
    ctx.fill()

    ctx.restore()
  }

  drawRemoteCollaboratorGhosts(ctx, stageWidth, stageHeight) {
    if (!this.remotePeers || this.remotePeers.size === 0) return
    const now = performance.now()
    const tracks = this.project.tracks || []

    this.remotePeers.forEach((peer, nodeId) => {
      if (now - (peer.updatedAt || 0) > 30000) {
        this.remotePeers.delete(nodeId)
        return
      }

      const peerColor = peer.color_hex || "#38bdf8"
      const handle = peer.username || nodeId

      // 4A. Ghost Clip Drag Preview
      if (peer.dragging_clip_uuid && peer.preview_start_tick != null) {
        const trackIdx = tracks.findIndex((t) =>
          t.uuid === peer.cursor_track_uuid || (t.clips || []).some((c) => c.uuid === peer.dragging_clip_uuid)
        )
        if (trackIdx >= 0) {
          const laneTop = this.rulerHeight + trackIdx * this.laneHeight
          const gx = (peer.preview_start_tick / this.totalTicks) * stageWidth
          const dur = peer.preview_duration_ticks || 3840
          const gw = Math.max(18, (dur / this.totalTicks) * stageWidth)
          const gy = laneTop + 7
          const gh = this.laneHeight - 14

          ctx.save()
          ctx.setLineDash([ 5, 4 ])
          ctx.fillStyle = this.hexToRgba(peerColor, 0.22)
          ctx.strokeStyle = peerColor
          ctx.lineWidth = 2
          ctx.beginPath()
          ctx.roundRect(gx + 1, gy, Math.max(4, gw - 2), gh, 6)
          ctx.fill()
          ctx.stroke()

          ctx.setLineDash([])
          ctx.fillStyle = peerColor
          ctx.font = "600 9px ui-monospace, SFMono-Regular, Menlo, monospace"
          ctx.fillText(`👻 @${handle}`, gx + 6, gy + 13)
          ctx.restore()
        }
      }

      // 4B. Ghost Timeline Cursor & Flag
      if (peer.cursor_tick != null && !Number.isNaN(peer.cursor_tick)) {
        const cx = Math.max(0, Math.min(stageWidth, (peer.cursor_tick / this.totalTicks) * stageWidth))
        const bar = Math.floor(peer.cursor_tick / this.ticksPerBar) + 1
        const beat = Math.floor((peer.cursor_tick % this.ticksPerBar) / this.ppqn) + 1
        const flagText = `@${handle} • ${bar}.${beat}`

        ctx.save()
        ctx.strokeStyle = peerColor
        ctx.lineWidth = 1.5
        ctx.setLineDash([ 3, 3 ])
        ctx.beginPath()
        ctx.moveTo(cx, this.rulerHeight)
        ctx.lineTo(cx, stageHeight)
        ctx.stroke()

        ctx.setLineDash([])
        ctx.font = "600 9px ui-monospace, SFMono-Regular, Menlo, monospace"
        const labelWidth = ctx.measureText(flagText).width + 10
        const flagX = Math.min(stageWidth - labelWidth - 2, Math.max(2, cx))

        ctx.fillStyle = peerColor
        ctx.beginPath()
        ctx.roundRect(flagX, 2, labelWidth, 14, 3)
        ctx.fill()

        ctx.fillStyle = "#0b0a09"
        ctx.fillText(flagText, flagX + 5, 12)
        ctx.restore()
      }
    })
  }

  drawClipOnLane(ctx, clip, track, laneTop, stageWidth) {
    const x = (clip.start_tick / this.totalTicks) * stageWidth
    const w = Math.max(18, (clip.duration_ticks / this.totalTicks) * stageWidth)
    const y = laneTop + 7
    const h = this.laneHeight - 14
    const color = clip.color_hex || track.color_hex || "#f59e0b"
    const isMuted = track.muted || clip.muted

    ctx.save()
    ctx.globalAlpha = isMuted ? 0.35 : 0.92

    // Clip Box Fill & Border
    ctx.fillStyle = this.hexToRgba(color, 0.18)
    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.beginPath()
    ctx.roundRect(x + 1, y, Math.max(4, w - 2), h, 6)
    ctx.fill()
    ctx.stroke()

    // Top Header Banner inside Clip
    ctx.fillStyle = this.hexToRgba(color, 0.38)
    ctx.beginPath()
    ctx.roundRect(x + 1, y, Math.max(4, w - 2), 16, [ 6, 6, 0, 0 ])
    ctx.fill()

    // Clip Title
    ctx.fillStyle = "#f4f4f0"
    ctx.font = "600 10px ui-sans-serif, system-ui, sans-serif"
    ctx.save()
    ctx.beginPath()
    ctx.rect(x + 4, y, Math.max(0, w - 8), h)
    ctx.clip()
    ctx.fillText(clip.name || "Clip", x + 6, y + 11.5)

    // Render MIDI Note Blocks or Audio Waveform Peaks inside Clip Body
    const bodyTop = y + 19
    const bodyHeight = h - 23
    const bodyMid = bodyTop + bodyHeight / 2

    if (clip.clip_kind === "midi" && Array.isArray(clip.midi_events) && clip.midi_events.length > 0) {
      const patternLen = clip.loop_end_tick || 3840
      const repeats = Math.max(1, Math.ceil(clip.duration_ticks / patternLen))
      ctx.fillStyle = color

      for (let r = 0; r < repeats; r++) {
        const offsetTick = r * patternLen
        clip.midi_events.forEach((ev) => {
          const noteStart = offsetTick + (ev.t || 0)
          if (noteStart >= clip.duration_ticks) return
          const noteDur = Math.min(ev.d || 240, clip.duration_ticks - noteStart)
          const nx = x + 3 + (noteStart / clip.duration_ticks) * (w - 6)
          const nw = Math.max(3, (noteDur / clip.duration_ticks) * (w - 6))
          const pitchNorm = Math.max(0, Math.min(1, ((ev.n || 60) - 45) / 30))
          const ny = bodyTop + (1 - pitchNorm) * (bodyHeight - 6)
          ctx.fillRect(nx, ny, nw, 4.5)
        })
      }
    } else {
      const peaks = Array.isArray(clip.waveform_peaks) && clip.waveform_peaks.length > 0
        ? clip.waveform_peaks
        : [ 0.3, -0.4, 0.7, -0.6, 0.85, -0.75, 0.5, -0.45, 0.65, -0.55 ]

      ctx.strokeStyle = color
      ctx.lineWidth = 1.35
      ctx.beginPath()
      const step = (w - 8) / peaks.length
      peaks.forEach((peak, i) => {
        const px = x + 4 + i * step
        const amp = Math.abs(peak) * (bodyHeight * 0.46)
        ctx.moveTo(px, bodyMid - amp)
        ctx.lineTo(px, bodyMid + amp)
      })
      ctx.stroke()
    }

    ctx.restore()
    ctx.restore()
  }

  renderDeckCanvases() {
    const dpr = window.devicePixelRatio || 1
    const tracks = this.project.tracks || []

    this.deckCanvasTargets.forEach((canvas) => {
      const trackId = parseInt(canvas.dataset.trackId, 10)
      const track = tracks.find((t) => t.id === trackId) || tracks[0]
      if (!track) return

      const ctx = canvas.getContext("2d")
      const w = canvas.width / dpr
      const h = canvas.height / dpr

      ctx.save()
      ctx.scale(dpr, dpr)
      ctx.clearRect(0, 0, w, h)

      const peaks = track.waveform_peaks || [ 0.4, 0.7, 0.5, 0.9, 0.6, 0.8, 0.3, 0.75 ]
      const color = track.color_hex || "#f59e0b"
      const progressRatio = (this.currentTick % this.totalTicks) / this.totalTicks

      const barCount = peaks.length
      const barWidth = w / barCount

      peaks.forEach((peak, idx) => {
        const normX = idx / barCount
        const amp = Math.max(3, Math.abs(peak) * (h * 0.44))
        ctx.fillStyle = normX <= progressRatio ? color : this.hexToRgba(color, 0.32)
        ctx.fillRect(idx * barWidth + 1, h / 2 - amp, Math.max(1.5, barWidth - 2), amp * 2)
      })

      // Playhead Marker on Deck
      const playheadX = progressRatio * w
      ctx.fillStyle = "#ffffff"
      ctx.fillRect(playheadX - 1, 0, 2, h)

      ctx.restore()
    })
  }

  // --- CANVAS POINTER EVENTS (SCRUB PLAYHEAD, DRAG CLIP, DOUBLE-CLICK CREATE CLIP) ---

  onCanvasPointerDown(event) {
    if (!this.hasTimelineCanvasTarget) return
    const rect = this.timelineCanvasTarget.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    const width = rect.width

    // Click in top ruler -> scrub playhead immediately
    if (y <= this.rulerHeight) {
      const clickedTick = Math.round((x / width) * this.totalTicks)
      this.currentTick = Math.max(0, Math.min(this.totalTicks, clickedTick))
      this.updateClockReadout()
      this.renderTimelineCanvas()
      return
    }

    const trackIndex = Math.floor((y - this.rulerHeight) / this.laneHeight)
    const tracks = this.project.tracks || []
    const track = tracks[trackIndex]
    if (!track) return

    const clickedTick = (x / width) * this.totalTicks
    const hitClip = (track.clips || []).find(
      (c) => clickedTick >= c.start_tick && clickedTick <= c.start_tick + c.duration_ticks
    )

    if (hitClip) {
      const clipEndPx = ((hitClip.start_tick + hitClip.duration_ticks) / this.totalTicks) * width
      const isResizeEdge = Math.abs(x - clipEndPx) <= 10

      this.dragState = {
        mode: isResizeEdge ? "resize" : "move",
        clip: hitClip,
        track: track,
        startX: x,
        initialStartTick: hitClip.start_tick,
        initialDurationTicks: hitClip.duration_ticks,
        stageWidth: width
      }

      this.boundPointerMove = (e) => this.onCanvasPointerMove(e)
      this.boundPointerUp = (e) => this.onCanvasPointerUp(e)
      window.addEventListener("pointermove", this.boundPointerMove)
      window.addEventListener("pointerup", this.boundPointerUp)
    } else {
      // Clicking empty space moves playhead to snapped beat
      const snappedTick = Math.round(clickedTick / 480) * 480
      this.currentTick = Math.max(0, Math.min(this.totalTicks, snappedTick))
      this.updateClockReadout()
      this.renderTimelineCanvas()
    }
  }

  onCanvasPointerMove(event) {
    if (!this.dragState || !this.hasTimelineCanvasTarget) return
    const rect = this.timelineCanvasTarget.getBoundingClientRect()
    const x = event.clientX - rect.left
    const dx = x - this.dragState.startX
    const deltaTicks = (dx / this.dragState.stageWidth) * this.totalTicks
    const snap = 480 // Half-beat snap (960 / 2)

    if (this.dragState.mode === "resize") {
      const rawDuration = this.dragState.initialDurationTicks + deltaTicks
      const snappedDuration = Math.max(960, Math.round(rawDuration / snap) * snap)
      this.dragState.clip.duration_ticks = snappedDuration
    } else {
      const rawStart = this.dragState.initialStartTick + deltaTicks
      const maxStart = this.totalTicks - this.dragState.clip.duration_ticks
      const snappedStart = Math.max(0, Math.min(maxStart, Math.round(rawStart / snap) * snap))
      this.dragState.clip.start_tick = snappedStart
    }

    this.renderTimelineCanvas()

    this.emitLocalTelemetry({
      cursor_tick: this.dragState.clip.start_tick,
      cursor_track_uuid: this.dragState.track.uuid,
      dragging_clip_uuid: this.dragState.clip.uuid,
      preview_start_tick: this.dragState.clip.start_tick,
      preview_duration_ticks: this.dragState.clip.duration_ticks
    })
  }

  onCanvasHoverMove(event) {
    if (this.dragState || !this.hasTimelineCanvasTarget) return
    const rect = this.timelineCanvasTarget.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    if (rect.width <= 0) return

    const hoverTick = Math.max(0, Math.min(this.totalTicks, Math.round((x / rect.width) * this.totalTicks)))
    const trackIndex = Math.floor((y - this.rulerHeight) / this.laneHeight)
    const track = (this.project.tracks || [])[trackIndex]

    this.emitLocalTelemetry({
      cursor_tick: hoverTick,
      cursor_track_uuid: track ? track.uuid : null,
      dragging_clip_uuid: null
    })
  }

  onCanvasPointerUp() {
    if (!this.dragState) return
    const { clip, track } = this.dragState
    window.removeEventListener("pointermove", this.boundPointerMove)
    window.removeEventListener("pointerup", this.boundPointerUp)
    this.dragState = null

    this.emitLocalTelemetry({
      cursor_tick: clip.start_tick,
      cursor_track_uuid: track ? track.uuid : null,
      dragging_clip_uuid: null
    })

    this.persistTrackClip(clip.id, {
      start_tick: clip.start_tick,
      duration_ticks: clip.duration_ticks,
      track_id: clip.track_id
    })
  }

  async onCanvasDoubleClick(event) {
    if (!this.hasTimelineCanvasTarget) return
    const rect = this.timelineCanvasTarget.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top
    if (y <= this.rulerHeight) return

    const trackIndex = Math.floor((y - this.rulerHeight) / this.laneHeight)
    const track = (this.project.tracks || [])[trackIndex]
    if (!track) return

    const rawTick = (x / rect.width) * this.totalTicks
    const startTick = Math.max(0, Math.min(this.totalTicks - 3840, Math.floor(rawTick / 3840) * 3840))
    const clipKind = track.track_type === "midi" || track.track_type === "instrument" ? "midi" : "audio"

    this.setSavingStatus("Creating clip...")
    try {
      const response = await this.apiFetch(`/tracks/${track.id}/track_clips`, "POST", {
        track_clip: {
          clip_kind: clipKind,
          start_tick: startTick,
          duration_ticks: 3840
        }
      })
      if (response && response.ok && response.track_clip) {
        track.clips = track.clips || []
        track.clips.push(response.track_clip)
        this.updateCounts()
        this.renderTimelineCanvas()
        this.setSavingStatus("✓ Clip Saved • 960 PPQN")
      }
    } catch (_) {
      this.setSavingStatus("⚠ Clip Create Failed")
    }
  }

  // --- PERSISTENCE HELPERS (DUAL-PATH CRDT + FETCH TO RAILS 8 BACKEND) ---

  emitLocalDelta(entityType, entity, action, changes) {
    let assignedHlc = null
    let assignedNodeId = null

    this.element.dispatchEvent(
      new CustomEvent("crdt:local-change", {
        detail: {
          entity_type: entityType,
          entity_uuid: entity?.uuid,
          entity_id: entity?.id,
          action,
          changes,
          onHlcAssigned: (hlc, nodeId) => {
            assignedHlc = hlc
            assignedNodeId = nodeId
          }
        }
      })
    )

    if (assignedHlc && entity && action === "update") {
      Object.keys(changes || {}).forEach((field) => {
        HybridLogicalClock.recordFieldWatermark(entity, field, assignedHlc, assignedNodeId || "local")
      })
    }

    this.lastAssignedHlc = assignedHlc
    this.clientNodeId = assignedNodeId || this.clientNodeId
    return assignedHlc
  }

  emitLocalTelemetry(payload) {
    this.element.dispatchEvent(
      new CustomEvent("crdt:local-telemetry", {
        detail: payload
      })
    )
  }

  onRemoteTelemetry(data) {
    if (!data || !data.origin_node_id) return
    this.remotePeers.set(data.origin_node_id, {
      ...data,
      updatedAt: performance.now()
    })

    if (data.live_fader && data.live_fader.track_uuid) {
      const track = (this.project.tracks || []).find((t) => t.uuid === data.live_fader.track_uuid)
      if (track) {
        if (typeof data.live_fader.volume_db === "number") {
          track.volume_db = data.live_fader.volume_db
          this.syncTrackDOMControls(track)
        }
        if (typeof data.live_fader.pan === "number") {
          track.pan = data.live_fader.pan
          this.syncTrackDOMControls(track)
        }
      }
    }

    this.renderTimelineCanvas()
  }

  onPeerLeave(data) {
    if (!data || !data.node_id) return
    this.remotePeers.delete(data.node_id)
  }

  onRemoteDelta(data) {
    if (!data || !data.applied) return
    const { entity_type: entityType, entity_uuid: entityUuid, entity_id: entityId, action, applied_changes: changes, hlc, actor, serialized_entity: serialized } = data

    if (entityType === "Project") {
      Object.entries(changes || {}).forEach(([ field, value ]) => {
        if (HybridLogicalClock.shouldApplyField(this.project.state_jsonb, field, hlc)) {
          this.project[field] = value
          HybridLogicalClock.recordFieldWatermark(this.project, field, hlc, actor)
        }
      })
      this.syncProjectDOMControls()
    } else if (entityType === "Track") {
      if (action === "create" && serialized) {
        const exists = (this.project.tracks || []).some((t) => t.uuid === serialized.uuid || t.id === serialized.id)
        if (!exists) {
          this.project.tracks.push(serialized)
          this.appendTrackRowToDOM(serialized)
          this.updateCounts()
          this.resizeCanvases()
        }
      } else if (action === "delete") {
        this.project.tracks = (this.project.tracks || []).filter((t) => t.uuid !== entityUuid && t.id !== entityId)
        if (entityId) {
          this.element.querySelectorAll(`[data-track-row-id="${entityId}"]`).forEach((el) => el.remove())
        }
        this.updateCounts()
        this.resizeCanvases()
      } else {
        const track = (this.project.tracks || []).find((t) => t.uuid === entityUuid || t.id === entityId)
        if (track) {
          Object.entries(changes || {}).forEach(([ field, value ]) => {
            if (HybridLogicalClock.shouldApplyField(track.state_jsonb, field, hlc)) {
              track[field] = value
              HybridLogicalClock.recordFieldWatermark(track, field, hlc, actor)
            }
          })
          this.syncTrackDOMControls(track)
        }
      }
    } else if (entityType === "TrackClip") {
      if (action === "create" && serialized) {
        const track = (this.project.tracks || []).find((t) => t.id === serialized.track_id)
        if (track) {
          track.clips = track.clips || []
          const exists = track.clips.some((c) => c.uuid === serialized.uuid || c.id === serialized.id)
          if (!exists) {
            track.clips.push(serialized)
            this.updateCounts()
          }
        }
      } else if (action === "delete") {
        ;(this.project.tracks || []).forEach((track) => {
          track.clips = (track.clips || []).filter((c) => c.uuid !== entityUuid && c.id !== entityId)
        })
        this.updateCounts()
      } else {
        let targetClip = null
        ;(this.project.tracks || []).forEach((track) => {
          const found = (track.clips || []).find((c) => c.uuid === entityUuid || c.id === entityId)
          if (found) targetClip = found
        })
        if (targetClip) {
          Object.entries(changes || {}).forEach(([ field, value ]) => {
            if (HybridLogicalClock.shouldApplyField(targetClip.state_jsonb, field, hlc)) {
              targetClip[field] = value
              HybridLogicalClock.recordFieldWatermark(targetClip, field, hlc, actor)
            }
          })
        }
      }
    }

    this.renderTimelineCanvas()
    this.renderDeckCanvases()
    this.setSavingStatus(`⚡ Synced @${actor || "peer"}`)
  }

  syncProjectDOMControls() {
    if (this.hasBpmDisplayTarget && this.project.bpm) {
      this.bpmDisplayTarget.textContent = Number(this.project.bpm).toFixed(1)
    }
    if (this.hasBpmInputTarget && this.project.bpm) {
      this.bpmInputTarget.value = Number(this.project.bpm).toFixed(1)
    }
    if (this.hasScaleSelectTarget && this.project.scale_name) {
      this.scaleSelectTarget.value = this.project.scale_name
    }
    if (this.hasMasterVolumeInputTarget && this.project.master_volume_db != null) {
      this.masterVolumeInputTarget.value = this.project.master_volume_db
    }
    if (this.hasMasterVolumeDisplayTarget && this.project.master_volume_db != null) {
      const db = Number(this.project.master_volume_db)
      this.masterVolumeDisplayTarget.textContent = `${db >= 0 ? "+" : ""}${db.toFixed(1)} dB`
    }
    if (this.project.theme_name) {
      this.applyThemeUI(this.project.theme_name, false)
    }
    if (this.project.workspace_mode) {
      this.applyWorkspaceModeUI(this.project.workspace_mode, false)
    }
  }

  syncTrackDOMControls(track) {
    if (!track) return
    const trackId = track.id
    const volDb = Number(track.volume_db || 0)
    this.element.querySelectorAll(`[data-track-volume-label="${trackId}"]`).forEach((el) => {
      el.textContent = `${volDb >= 0 ? "+" : ""}${volDb.toFixed(1)} dB`
    })
    this.element.querySelectorAll(`input[data-track-id="${trackId}"][data-action*="changeTrackVolume"]`).forEach((el) => {
      el.value = volDb
    })

    const pan = Number(track.pan || 0)
    const panText = pan === 0 ? "C" : pan < 0 ? `L${Math.round(Math.abs(pan) * 100)}` : `R${Math.round(pan * 100)}`
    this.element.querySelectorAll(`[data-track-pan-label="${trackId}"]`).forEach((el) => {
      el.textContent = panText
    })
    this.element.querySelectorAll(`input[data-track-id="${trackId}"][data-action*="changeTrackPan"]`).forEach((el) => {
      el.value = pan
    })

    ;[ "muted", "soloed", "armed" ].forEach((flag) => {
      this.element.querySelectorAll(`button[data-track-id="${trackId}"][data-field="${flag}"]`).forEach((btn) => {
        const active = Boolean(track[flag])
        btn.setAttribute("aria-pressed", active ? "true" : "false")
        btn.classList.toggle("is-active", active)
      })
    })
  }

  async persistProject(attributes) {
    this.setSavingStatus("Syncing...")
    const hlc = this.emitLocalDelta("Project", this.project, "update", attributes)
    try {
      const res = await this.apiFetch(`/projects/${this.project.id}`, "PATCH", {
        project: attributes,
        hlc,
        client_node_id: this.clientNodeId
      })
      if (res && res.ok) {
        this.setSavingStatus("✓ Saved • 960 PPQN")
      }
    } catch (_) {
      this.setSavingStatus("⚠ Offline • Queued CRDT")
    }
  }

  async persistTrack(trackId, attributes) {
    this.setSavingStatus("Syncing track...")
    const track = (this.project.tracks || []).find((t) => t.id === trackId)
    const hlc = this.emitLocalDelta("Track", track || { id: trackId }, "update", attributes)
    try {
      const res = await this.apiFetch(`/tracks/${trackId}`, "PATCH", {
        track: attributes,
        hlc,
        client_node_id: this.clientNodeId
      })
      if (res && res.ok) {
        this.setSavingStatus("✓ Saved • 960 PPQN")
      }
    } catch (_) {
      this.setSavingStatus("⚠ Offline • Queued CRDT")
    }
  }

  async persistTrackClip(clipId, attributes) {
    this.setSavingStatus("Syncing clip...")
    let targetClip = { id: clipId }
    ;(this.project.tracks || []).forEach((t) => {
      const found = (t.clips || []).find((c) => c.id === clipId)
      if (found) targetClip = found
    })
    const hlc = this.emitLocalDelta("TrackClip", targetClip, "update", attributes)
    try {
      const res = await this.apiFetch(`/track_clips/${clipId}`, "PATCH", {
        track_clip: attributes,
        hlc,
        client_node_id: this.clientNodeId
      })
      if (res && res.ok) {
        this.setSavingStatus("✓ Saved • 960 PPQN")
      }
    } catch (_) {
      this.setSavingStatus("⚠ Offline • Queued CRDT")
    }
  }

  async apiFetch(url, method, bodyObj = null) {
    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    const headers = {
      Accept: "application/json",
      "Content-Type": "application/json"
    }
    if (csrfToken) headers["X-CSRF-Token"] = csrfToken
    if (this.lastAssignedHlc) headers["X-Saanskara-Hlc"] = this.lastAssignedHlc
    if (this.clientNodeId) headers["X-Saanskara-Node-Id"] = this.clientNodeId

    const options = { method, headers }
    if (bodyObj && method !== "GET") {
      options.body = JSON.stringify(bodyObj)
    }

    const response = await fetch(url, options)
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
    return response.json()
  }

  setSavingStatus(text) {
    if (this.hasSaveStatusTarget) {
      this.saveStatusTarget.textContent = text
    }
  }

  updateCounts() {
    const tracks = this.project.tracks || []
    const clipCount = tracks.reduce((sum, t) => sum + ((t.clips || []).length), 0)
    if (this.hasTrackCountBadgeTarget) {
      this.trackCountBadgeTarget.textContent = `${tracks.length} Tracks`
    }
    if (this.hasClipCountBadgeTarget) {
      this.clipCountBadgeTarget.textContent = `${clipCount} Clips`
    }
  }

  appendTrackRowToDOM(track) {
    if (!this.hasTrackListTarget) return
    const div = document.createElement("div")
    div.className = `track-row ${track.armed ? "armed" : ""}`
    div.dataset.trackRowId = track.id
    div.style.borderLeftColor = track.color_hex || "#f59e0b"

    div.innerHTML = `
      <div class="flex-1 min-w-0 pr-2">
        <div class="flex items-center gap-2">
          <span class="font-semibold truncate text-xs">${this.escapeHtml(track.name)}</span>
          <span class="text-[10px] uppercase px-1.5 py-0.5 rounded font-mono" style="background-color: var(--saanskara-bg-canvas); color: ${track.color_hex}">
            ${this.escapeHtml(track.track_type)}
          </span>
        </div>
        <div class="flex items-center gap-2 mt-1.5 text-[11px] font-mono">
          <label class="flex items-center gap-1">
            <span>Vol</span>
            <input type="range" min="-24" max="6" step="0.5" value="${track.volume_db}"
                   data-track-id="${track.id}"
                   data-action="input->studio#changeTrackVolume"
                   class="w-16 accent-amber-500 cursor-pointer" />
            <span data-track-volume-label="${track.id}">${track.volume_db >= 0 ? "+" : ""}${Number(track.volume_db).toFixed(1)} dB</span>
          </label>
        </div>
      </div>
      <div class="flex items-center gap-1">
        <button type="button" class="daw-msr-btn" data-track-id="${track.id}" data-field="muted" aria-pressed="false" data-action="click->studio#toggleTrackFlag">M</button>
        <button type="button" class="daw-msr-btn" data-track-id="${track.id}" data-field="soloed" aria-pressed="false" data-action="click->studio#toggleTrackFlag">S</button>
        <button type="button" class="daw-msr-btn" data-track-id="${track.id}" data-field="armed" aria-pressed="false" data-action="click->studio#toggleTrackFlag">R</button>
      </div>
    `
    this.trackListTarget.appendChild(div)
  }

  debounce(key, waitMs, fn) {
    if (this.debounceTimers[key]) clearTimeout(this.debounceTimers[key])
    this.debounceTimers[key] = setTimeout(fn, waitMs)
  }

  hexToRgba(hex, alpha) {
    const clean = (hex || "#f59e0b").replace("#", "")
    const num = parseInt(clean.length === 3 ? clean.split("").map((c) => c + c).join("") : clean, 16)
    const r = (num >> 16) & 255
    const g = (num >> 8) & 255
    const b = num & 255
    return `rgba(${r}, ${g}, ${b}, ${alpha})`
  }

  escapeHtml(str) {
    return String(str || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }
}

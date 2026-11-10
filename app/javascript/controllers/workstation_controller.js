import { Controller } from "@hotwired/stimulus"

// Manages the Jaku SPA shell: Create/DJ modes, Ideas/Song submodes,
// Transport clock, Master Meter oscilloscope, Sound Browser filtering,
// Renderer switcher, Timeline zoom, AI Lab, and Track creation without mutating URL.
export default class extends Controller {
  static targets = [
    "themeButton", "themeIcon", "themeLabel",
    "modeTab", "submodeTab", "createSubNav",
    "createWorkspace", "djWorkspace",
    "songView", "ideasView",
    "soundBrowser", "librarySearch", "libraryTabButton", "libraryList", "libraryCard",
    "playButton", "stopButton", "recordButton",
    "bpmDisplay", "positionDisplay",
    "sampleRateButton", "sampleRateLabel", "bitDepthButton", "bitDepthLabel",
    "lowLatencyButton", "lowLatencyLabel", "crdtBadge", "crdtLabel",
    "exportButton", "exportLabel",
    "autoLanesButton", "autoLanesLabel", "mixerToggleButton", "rendererButton",
    "zoomSlider", "zoomReadout",
    "trackHeadersColumn", "trackHeadersTitleLabel", "trackHeadersToggleBtn", "trackHeadersToggleIcon",
    "trackCreatorBox", "expandedTrackCreator", "collapsedTrackCreator", "collapsedTrackMenu",
    "collapsedTrackTrigger", "collapsedTrackTriggerIcon",
    "expandedTrackContent", "collapsedTrackContent", "trackHeadersList", "trackCount",
    "timelineCanvas", "playheadLine", "hudRendererLabel", "hudWasmStatus",
    "aiLabPanel", "aiRailButton", "aiModeButton", "aiPromptInput", "aiRunButton", "aiRunLabel", "aiResponseBox",
    "micStatusLabel", "micTranscribeButton", "micButtonLabel",
    "mixerDrawer",
    "masterMeterCanvas", "meterBarL", "meterBarR", "lufsReadout"
  ]

  static values = {
    theme: { type: String, default: "midnight" },
    mode: { type: String, default: "create" },
    submode: { type: String, default: "song" },
    libraryTab: { type: String, default: "library" },
    playing: { type: Boolean, default: false },
    recording: { type: Boolean, default: false },
    bpm: { type: Number, default: 128 },
    autoLanes: { type: Boolean, default: true },
    mixerOpen: { type: Boolean, default: true },
    trackHeadersOpen: { type: Boolean, default: true },
    aiLabOpen: { type: Boolean, default: true },
    renderer: { type: String, default: "webgpu" },
    zoom: { type: Number, default: 100 }
  }

  connect() {
    this.themes = [
      { id: "midnight", icon: "🌙", label: "Dark" },
      { id: "saffron", icon: "🔥", label: "Saffron" },
      { id: "frost", icon: "☀️", label: "Frost" }
    ]
    let savedTheme = null
    try {
      savedTheme = window.localStorage.getItem("jaku-studio-theme")
    } catch (_e) {
      // Ignore storage errors in restricted environments
    }
    const initialTheme = savedTheme || document.documentElement.getAttribute("data-theme") || this.themeValue || "midnight"
    const foundIndex = this.themes.findIndex((t) => t.id === initialTheme)
    this.themeIndex = foundIndex >= 0 ? foundIndex : 0

    this.sampleRates = ["48.0 kHz", "96.0 kHz", "192.0 kHz"]
    this.bitDepths = ["24-bit", "32-bit float", "64-bit DSP"]
    this.masterPhase = 0
    this.currentAiMode = "Mix Critic"
    this.micRecording = false

    this.boundTimelineTick = this.onTimelineTick.bind(this)
    this.boundRendererStatus = this.onRendererStatus.bind(this)
    this.element.addEventListener("daw-timeline:tick", this.boundTimelineTick)
    this.element.addEventListener("daw-timeline:renderer-changed", this.boundRendererStatus)

    this.applyTheme(this.themes[this.themeIndex].id, { persist: false })
    this.startMasterMeterLoop()
  }

  disconnect() {
    this.element.removeEventListener("daw-timeline:tick", this.boundTimelineTick)
    this.element.removeEventListener("daw-timeline:renderer-changed", this.boundRendererStatus)
    if (this.meterRafId) cancelAnimationFrame(this.meterRafId)
  }

  // Global keyboard shortcuts (Space = Play/Pause, R = Record)
  handleGlobalKeydown(event) {
    const tag = event.target.tagName
    if (tag === "INPUT" || tag === "TEXTAREA" || event.target.isContentEditable) return

    if (event.code === "Space") {
      event.preventDefault()
      this.togglePlay()
    } else if (event.key === "r" || event.key === "R") {
      event.preventDefault()
      this.toggleRecord()
    }
  }

  // ZONE A: Theme Switcher (Midnight Dark -> Saffron Dusk -> Ottawa Frost)
  toggleTheme() {
    this.themeIndex = (this.themeIndex + 1) % this.themes.length
    const nextTheme = this.themes[this.themeIndex]
    this.applyTheme(nextTheme.id, { persist: true })
    this.ensureRootUrlLocked()
  }

  applyTheme(themeId, { persist = true } = {}) {
    const theme = this.themes.find((t) => t.id === themeId) || this.themes[0]
    this.themeValue = theme.id

    const root = document.documentElement
    root.setAttribute("data-theme", theme.id)
    root.classList.remove("theme-midnight", "theme-saffron", "theme-frost", "dark", "light")
    root.classList.add(`theme-${theme.id}`, theme.id === "frost" ? "light" : "dark")

    if (document.body) {
      document.body.setAttribute("data-theme", theme.id)
    }
    this.element.setAttribute("data-theme", theme.id)

    if (this.hasThemeButtonTarget) {
      this.themeButtonTarget.setAttribute("data-theme-current", theme.id)
    }
    if (this.hasThemeIconTarget) this.themeIconTarget.textContent = theme.icon
    if (this.hasThemeLabelTarget) this.themeLabelTarget.textContent = theme.label

    if (persist) {
      try {
        window.localStorage.setItem("jaku-studio-theme", theme.id)
      } catch (_e) {
        // Ignore storage errors in restricted environments
      }
    }

    const detail = { theme: theme.id, label: theme.label }
    this.element.dispatchEvent(new CustomEvent("workstation:theme-changed", { bubbles: true, detail }))
    window.dispatchEvent(new CustomEvent("workstation:theme-changed", { detail }))
  }

  // ZONE A: Top-Level Mode Switcher (Create <-> DJ) without URL mutation
  switchMode(event) {
    const selectedMode = event.currentTarget.dataset.mode
    if (!selectedMode) return
    this.modeValue = selectedMode

    this.modeTabTargets.forEach((btn) => {
      const active = btn.dataset.mode === selectedMode
      btn.setAttribute("aria-selected", active ? "true" : "false")
      btn.className = active
        ? "h-6 px-3.5 rounded text-xs font-medium transition-all cursor-pointer bg-[#231911] text-[#f5a623] border border-[#5c3d1e] shadow-sm"
        : "h-6 px-3.5 rounded text-xs font-medium transition-all cursor-pointer text-zinc-400 hover:text-zinc-200 border border-transparent"
    })

    if (this.hasCreateWorkspaceTarget && this.hasDjWorkspaceTarget) {
      if (selectedMode === "dj") {
        this.createWorkspaceTarget.classList.add("hidden")
        this.djWorkspaceTarget.classList.remove("hidden")
        this.djWorkspaceTarget.classList.add("flex")
        if (this.hasCreateSubNavTarget) {
          this.createSubNavTarget.classList.add("invisible", "pointer-events-none")
        }
        if (this.hasMixerDrawerTarget) {
          this.mixerDrawerTarget.classList.add("hidden")
        }
        requestAnimationFrame(() => window.dispatchEvent(new Event("resize")))
      } else {
        this.djWorkspaceTarget.classList.add("hidden")
        this.djWorkspaceTarget.classList.remove("flex")
        this.createWorkspaceTarget.classList.remove("hidden")
        if (this.hasCreateSubNavTarget) {
          this.createSubNavTarget.classList.remove("invisible", "pointer-events-none")
        }
        if (this.hasMixerDrawerTarget) {
          this.mixerDrawerTarget.classList.toggle("hidden", !this.mixerOpenValue)
        }
        requestAnimationFrame(() => window.dispatchEvent(new Event("resize")))
      }
    }
    this.ensureRootUrlLocked()
  }

  // ZONE C: Sub-Mode Switcher (Ideas <-> Song) without URL mutation
  switchSubmode(event) {
    const selectedSubmode = event.currentTarget.dataset.submode
    if (!selectedSubmode) return
    this.submodeValue = selectedSubmode

    if (this.modeValue !== "create") {
      this.switchMode({ currentTarget: { dataset: { mode: "create" } } })
    }

    this.submodeTabTargets.forEach((btn) => {
      const active = btn.dataset.submode === selectedSubmode
      btn.setAttribute("aria-selected", active ? "true" : "false")
      btn.className = active
        ? "h-6 px-2.5 rounded-xs text-[11px] font-medium transition-colors cursor-pointer bg-[#231911] text-[#f5a623] border border-[#5c3d1e]"
        : "h-6 px-2.5 rounded-xs text-[11px] font-medium transition-colors cursor-pointer text-[#8e8a83] hover:text-[#f4f4f0] border border-transparent"
    })

    if (this.hasSongViewTarget && this.hasIdeasViewTarget) {
      if (selectedSubmode === "ideas") {
        this.songViewTarget.classList.add("hidden")
        this.ideasViewTarget.classList.remove("hidden")
        this.ideasViewTarget.classList.add("flex")
      } else {
        this.ideasViewTarget.classList.add("hidden")
        this.ideasViewTarget.classList.remove("flex")
        this.songViewTarget.classList.remove("hidden")
      }
    }
    this.ensureRootUrlLocked()
  }

  // ZONE C: Transport Play / Stop / Record
  togglePlay() {
    this.playingValue = !this.playingValue
    this.syncTransportUi()
    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dataset.dawTimelinePlayingValue = String(this.playingValue)
    }
    if (this.hasDjWorkspaceTarget) {
      this.djWorkspaceTarget.dataset.djBeatgridPlayingValue = String(this.playingValue)
    }
  }

  stopTransport() {
    this.playingValue = false
    this.recordingValue = false
    this.syncTransportUi()
    if (this.hasPositionDisplayTarget) this.positionDisplayTarget.textContent = "1.1"
    if (this.hasPlayheadLineTarget) this.playheadLineTarget.style.left = "0px"
    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dataset.dawTimelinePlayingValue = "false"
      this.timelineCanvasTarget.dispatchEvent(new CustomEvent("daw-timeline:reset-playhead"))
    }
    if (this.hasDjWorkspaceTarget) {
      this.djWorkspaceTarget.dataset.djBeatgridPlayingValue = "false"
    }
  }

  toggleRecord() {
    this.recordingValue = !this.recordingValue
    if (this.recordingValue && !this.playingValue) {
      this.playingValue = true
    }
    this.syncTransportUi()
    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dataset.dawTimelinePlayingValue = String(this.playingValue)
    }
  }

  syncTransportUi() {
    if (this.hasPlayButtonTarget) {
      this.playButtonTarget.textContent = this.playingValue ? "⏸" : "▷"
      this.playButtonTarget.className = this.playingValue
        ? "w-7 h-7 rounded bg-[#231911] border border-[#d97706] text-[#f59e0b] flex items-center justify-center text-xs cursor-pointer transition-colors shadow-[0_0_8px_rgba(217,119,6,0.35)]"
        : "w-7 h-7 rounded bg-[#161514] border border-[#262320] hover:border-[#4a3520] text-[#e5e2dc] flex items-center justify-center text-xs cursor-pointer transition-colors"
    }
    if (this.hasRecordButtonTarget) {
      this.recordButtonTarget.className = this.recordingValue
        ? "w-7 h-7 rounded bg-[#dc2626] border border-[#ef4444] text-white flex items-center justify-center text-xs cursor-pointer transition-all shadow-[0_0_12px_rgba(239,68,68,0.85)] animate-pulse"
        : "w-7 h-7 rounded bg-[#1b1111] border border-[#dc2626]/60 hover:border-[#ef4444] text-[#ef4444] flex items-center justify-center text-xs cursor-pointer transition-all shadow-[0_0_8px_rgba(220,38,38,0.25)]"
    }
    if (this.hasHudWasmStatusTarget) {
      this.hudWasmStatusTarget.textContent = this.playingValue ? "WASM · 60FPS" : "WASM · IDLE"
    }
  }

  nudgeBpm() {
    const presets = [120, 124, 128, 132, 140, 174]
    const idx = presets.indexOf(this.bpmValue)
    this.bpmValue = presets[(idx + 1) % presets.length]
    if (this.hasBpmDisplayTarget) this.bpmDisplayTarget.textContent = String(this.bpmValue)
    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dataset.dawTimelineBpmValue = String(this.bpmValue)
    }
  }

  cycleSampleRate() {
    if (!this.hasSampleRateLabelTarget) return
    const idx = this.sampleRates.indexOf(this.sampleRateLabelTarget.textContent.trim())
    this.sampleRateLabelTarget.textContent = this.sampleRates[(idx + 1) % this.sampleRates.length]
  }

  cycleBitDepth() {
    if (!this.hasBitDepthLabelTarget) return
    const idx = this.bitDepths.indexOf(this.bitDepthLabelTarget.textContent.trim())
    this.bitDepthLabelTarget.textContent = this.bitDepths[(idx + 1) % this.bitDepths.length]
  }

  toggleLowLatency() {
    if (!this.hasLowLatencyButtonTarget || !this.hasLowLatencyLabelTarget) return
    const enabled = this.lowLatencyButtonTarget.getAttribute("aria-pressed") !== "true"
    this.lowLatencyButtonTarget.setAttribute("aria-pressed", enabled ? "true" : "false")
    this.lowLatencyLabelTarget.textContent = enabled ? "Low-Lat ON" : "Low-Lat OFF"
    this.lowLatencyButtonTarget.className = enabled
      ? "h-7 px-2.5 rounded bg-[#1c150e] border border-[#5c3d1e] text-[#f59e0b] text-[11px] font-mono flex items-center gap-1.5 hover:border-[#d97706] cursor-pointer transition-colors"
      : "h-7 px-2.5 rounded bg-[#141312] border border-[#262320] text-[#8e8a83] text-[11px] font-mono flex items-center gap-1.5 cursor-pointer transition-colors"
  }

  pingCrdtSync() {
    if (!this.hasCrdtLabelTarget) return
    this.crdtLabelTarget.textContent = "CRDT Synced 0.4ms"
    setTimeout(() => {
      if (this.hasCrdtLabelTarget) this.crdtLabelTarget.textContent = "CRDT Ready"
    }, 1400)
  }

  triggerBatchExport() {
    if (!this.hasExportLabelTarget) return
    this.exportLabelTarget.textContent = "Rendering WAV/STEMS..."
    setTimeout(() => {
      if (this.hasExportLabelTarget) this.exportLabelTarget.textContent = "✓ Exported 24-bit"
      setTimeout(() => {
        if (this.hasExportLabelTarget) this.exportLabelTarget.textContent = "Batch & Export"
      }, 1500)
    }, 900)
  }

  // ZONE D Column 1: Sound Browser Tabs, Filtering & Drag-and-Drop
  toggleSoundBrowser() {
    if (!this.hasSoundBrowserTarget) return
    this.soundBrowserTarget.classList.toggle("hidden")
  }

  switchLibraryTab(event) {
    const selectedTab = event.currentTarget.dataset.libraryTab
    if (!selectedTab) return
    this.libraryTabValue = selectedTab

    this.libraryTabButtonTargets.forEach((btn) => {
      const active = btn.dataset.libraryTab === selectedTab
      btn.setAttribute("aria-selected", active ? "true" : "false")
      btn.className = active
        ? "h-6 rounded-xs text-[11px] font-medium transition-colors cursor-pointer bg-[#232220] text-[#f4f4f0] border border-[#3a3632]"
        : "h-6 rounded-xs text-[11px] font-medium transition-colors cursor-pointer text-[#8e8a83] hover:text-[#e5e2dc] border border-transparent"
    })

    this.filterLibrary()
    this.ensureRootUrlLocked()
  }

  filterLibrary() {
    const query = this.hasLibrarySearchTarget ? this.librarySearchTarget.value.trim().toLowerCase() : ""
    this.libraryCardTargets.forEach((card) => {
      const matchesTab = card.dataset.category === this.libraryTabValue
      const matchesQuery =
        !query ||
        (card.dataset.title && card.dataset.title.includes(query)) ||
        (card.dataset.subtitle && card.dataset.subtitle.includes(query))
      card.classList.toggle("hidden", !(matchesTab && matchesQuery))
    })
  }

  selectLibraryItem(event) {
    const selected = event.currentTarget
    this.libraryCardTargets.forEach((card) => {
      const isTarget = card === selected
      card.className = `${card.classList.contains("hidden") ? "hidden " : ""}p-2.5 rounded cursor-grab active:cursor-grabbing transition-all ${isTarget
          ? "bg-[#171411] border border-[#5c3d1e] shadow-[inset_0_0_0_1px_rgba(217,119,6,0.12)]"
          : "bg-[#121214] border border-[#22201e] hover:border-[#3d352e]"
        }`
    })
  }

  dragStartLibraryItem(event) {
    const card = event.currentTarget
    if (!event.dataTransfer) return
    event.dataTransfer.setData("text/plain", JSON.stringify({
      title: card.dataset.itemTitle,
      kind: card.dataset.itemKind || "audio"
    }))
  }

  allowTimelineDrop(event) {
    event.preventDefault()
  }

  dropLibraryItemOnTimeline(event) {
    event.preventDefault()
    if (!event.dataTransfer || !this.hasTimelineCanvasTarget) return
    try {
      const payload = JSON.parse(event.dataTransfer.getData("text/plain"))
      this.timelineCanvasTarget.dispatchEvent(new CustomEvent("daw-timeline:drop-clip", { detail: payload }))
    } catch (_e) {
      // Ignore invalid external drag payload
    }
  }

  // Workspace Sub-Bar Controls
  toggleAutoLanes() {
    this.autoLanesValue = !this.autoLanesValue
    if (this.hasAutoLanesButtonTarget && this.hasAutoLanesLabelTarget) {
      this.autoLanesButtonTarget.setAttribute("aria-pressed", String(this.autoLanesValue))
      this.autoLanesLabelTarget.textContent = this.autoLanesValue ? "Auto Lanes ON" : "Auto Lanes OFF"
      this.autoLanesButtonTarget.className = this.autoLanesValue
        ? "h-6 px-2.5 rounded bg-[#2b1911] border border-[#7c3f1c] text-[#f5a623] text-[11px] font-medium flex items-center gap-1 cursor-pointer transition-colors"
        : "h-6 px-2.5 rounded bg-[#161514] border border-[#262320] text-[#8e8a83] text-[11px] font-medium flex items-center gap-1 cursor-pointer transition-colors"
    }
    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dataset.dawTimelineAutoLanesValue = String(this.autoLanesValue)
    }
  }

  toggleMixerDrawer() {
    this.mixerOpenValue = !this.mixerOpenValue
    if (this.hasMixerDrawerTarget) {
      this.mixerDrawerTarget.classList.toggle("hidden", !this.mixerOpenValue)
    }
    if (this.hasMixerToggleButtonTarget) {
      this.mixerToggleButtonTarget.setAttribute("aria-pressed", String(this.mixerOpenValue))
    }
    window.dispatchEvent(new Event("resize"))
  }

  switchRenderer(event) {
    const mode = event.currentTarget.dataset.renderer
    if (!mode) return
    this.rendererValue = mode

    this.rendererButtonTargets.forEach((btn) => {
      const active = btn.dataset.renderer === mode
      btn.setAttribute("aria-checked", active ? "true" : "false")
      btn.className = active
        ? "h-5 px-2 rounded-xs font-mono text-[10px] font-semibold transition-all cursor-pointer bg-[#231911] text-[#f5a623] border border-[#5c3d1e]"
        : "h-5 px-2 rounded-xs font-mono text-[10px] transition-all cursor-pointer text-[#8e8a83] hover:text-[#e5e2dc] border border-transparent"
    })

    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dataset.dawTimelineRendererValue = mode
    }
  }

  onRendererStatus(event) {
    const { label } = event.detail || {}
    if (label && this.hasHudRendererLabelTarget) {
      this.hudRendererLabelTarget.textContent = label
    }
  }

  updateZoom() {
    if (!this.hasZoomSliderTarget) return
    this.applyZoom(Number(this.zoomSliderTarget.value))
  }

  zoomIn() {
    this.applyZoom(Math.min(250, this.zoomValue + 15))
  }

  zoomOut() {
    this.applyZoom(Math.max(50, this.zoomValue - 15))
  }

  applyZoom(val) {
    this.zoomValue = val
    if (this.hasZoomSliderTarget) this.zoomSliderTarget.value = String(val)
    if (this.hasZoomReadoutTarget) this.zoomReadoutTarget.textContent = `${val}%`
    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dataset.dawTimelineZoomValue = String(val)
    }
  }

  toggleTrackHeaders() {
    if (!this.hasTrackHeadersColumnTarget) return
    this.trackHeadersOpenValue = !this.trackHeadersOpenValue
    const isOpen = this.trackHeadersOpenValue

    this.trackHeadersColumnTarget.dataset.collapsed = isOpen ? "false" : "true"

    if (isOpen) {
      this.trackHeadersColumnTarget.classList.remove("w-14")
      this.trackHeadersColumnTarget.classList.add("w-60")

      if (this.hasTrackHeadersTitleLabelTarget) {
        this.trackHeadersTitleLabelTarget.classList.remove("hidden")
      }
      if (this.hasTrackHeadersToggleIconTarget) {
        this.trackHeadersToggleIconTarget.textContent = "|◁"
      }
      if (this.hasTrackHeadersToggleBtnTarget) {
        this.trackHeadersToggleBtnTarget.setAttribute("aria-expanded", "true")
      }
      if (this.hasTrackCreatorBoxTarget) {
        this.trackCreatorBoxTarget.classList.remove("p-1.5")
        this.trackCreatorBoxTarget.classList.add("p-2.5")
      }
      if (this.hasExpandedTrackCreatorTarget) {
        this.expandedTrackCreatorTarget.classList.remove("hidden")
        this.expandedTrackCreatorTarget.classList.add("block")
      }
      if (this.hasCollapsedTrackCreatorTarget) {
        this.collapsedTrackCreatorTarget.classList.remove("flex")
        this.collapsedTrackCreatorTarget.classList.add("hidden")
      }
      this.closeCollapsedTrackMenu()
    } else {
      this.trackHeadersColumnTarget.classList.remove("w-60")
      this.trackHeadersColumnTarget.classList.add("w-14")

      if (this.hasTrackHeadersTitleLabelTarget) {
        this.trackHeadersTitleLabelTarget.classList.add("hidden")
      }
      if (this.hasTrackHeadersToggleIconTarget) {
        this.trackHeadersToggleIconTarget.textContent = "▷|"
      }
      if (this.hasTrackHeadersToggleBtnTarget) {
        this.trackHeadersToggleBtnTarget.setAttribute("aria-expanded", "false")
      }
      if (this.hasTrackCreatorBoxTarget) {
        this.trackCreatorBoxTarget.classList.remove("p-2.5")
        this.trackCreatorBoxTarget.classList.add("p-1.5")
      }
      if (this.hasExpandedTrackCreatorTarget) {
        this.expandedTrackCreatorTarget.classList.remove("block")
        this.expandedTrackCreatorTarget.classList.add("hidden")
      }
      if (this.hasCollapsedTrackCreatorTarget) {
        this.collapsedTrackCreatorTarget.classList.remove("hidden")
        this.collapsedTrackCreatorTarget.classList.add("flex")
      }
    }

    this.syncTrackRowsCollapseState(isOpen)

    // Dispatch resize immediately and at the end of the 300ms slide transition
    window.dispatchEvent(new Event("resize"))
    setTimeout(() => {
      window.dispatchEvent(new Event("resize"))
    }, 310)
    this.ensureRootUrlLocked()
  }

  toggleCollapsedTrackMenu(event) {
    if (event) event.stopPropagation()
    if (!this.hasCollapsedTrackMenuTarget) return
    const isMenuHidden = this.collapsedTrackMenuTarget.classList.contains("hidden")
    if (isMenuHidden) {
      this.collapsedTrackMenuTarget.classList.remove("hidden")
      this.collapsedTrackMenuTarget.classList.add("flex")
      if (this.hasCollapsedTrackTriggerTarget) {
        this.collapsedTrackTriggerTarget.setAttribute("aria-expanded", "true")
      }
      if (this.hasCollapsedTrackTriggerIconTarget) {
        this.collapsedTrackTriggerIconTarget.textContent = "×"
      }
    } else {
      this.closeCollapsedTrackMenu()
    }
    this.ensureRootUrlLocked()
  }

  closeCollapsedTrackMenu() {
    if (this.hasCollapsedTrackMenuTarget) {
      this.collapsedTrackMenuTarget.classList.remove("flex")
      this.collapsedTrackMenuTarget.classList.add("hidden")
    }
    if (this.hasCollapsedTrackTriggerTarget) {
      this.collapsedTrackTriggerTarget.setAttribute("aria-expanded", "false")
    }
    if (this.hasCollapsedTrackTriggerIconTarget) {
      this.collapsedTrackTriggerIconTarget.textContent = "+"
    }
  }

  syncTrackRowsCollapseState(isOpen = this.trackHeadersOpenValue) {
    this.expandedTrackContentTargets.forEach((el) => {
      el.classList.toggle("hidden", !isOpen)
      el.classList.toggle("flex", isOpen)
    })
    this.collapsedTrackContentTargets.forEach((el) => {
      el.classList.toggle("hidden", isOpen)
      el.classList.toggle("flex", !isOpen)
    })
  }

  // Append Empty Track (Audio / MIDI / Bus) via Turbo Stream + Timeline Sync
  async addEmptyTrack(event) {
    const kind = event.currentTarget.dataset.trackKind || "audio"
    const existingIds = this.hasTrackHeadersListTarget
      ? Array.from(this.trackHeadersListTarget.children).map((el) => Number(el.dataset.trackId) || 0)
      : []
    const currentCount = existingIds.length > 0 ? Math.max(...existingIds) + 1 : 1

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      const response = await fetch("/workstation/tracks", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": csrfToken || ""
        },
        body: JSON.stringify({
          current_count: currentCount,
          collapsed: !this.trackHeadersOpenValue,
          track: { kind, name: "" }
        })
      })

      if (response.ok && window.Turbo) {
        const streamHtml = await response.text()
        window.Turbo.renderStreamMessage(streamHtml)
      }
    } catch (_e) {
      // Fallback if offline
    }

    // Ensure newly appended track row matches current expanded/collapsed state of the Tracks panel
    requestAnimationFrame(() => {
      this.syncTrackRowsCollapseState(this.trackHeadersOpenValue)
      if (this.hasTrackCountTarget && this.hasTrackHeadersListTarget) {
        this.trackCountTarget.textContent = String(this.trackHeadersListTarget.children.length)
      }
    })
    this.syncTrackRowsCollapseState(this.trackHeadersOpenValue)
    this.closeCollapsedTrackMenu()

    if (this.hasTrackCountTarget && this.hasTrackHeadersListTarget) {
      this.trackCountTarget.textContent = String(this.trackHeadersListTarget.children.length)
    }

    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dispatchEvent(
        new CustomEvent("daw-timeline:add-track", { detail: { kind, index: currentCount } })
      )
    }
    this.ensureRootUrlLocked()
  }

  // Delete Track via Turbo Stream + Timeline & Mixer Sync
  async deleteTrack(event) {
    event.stopPropagation()
    const trackId = Number(event.currentTarget.dataset.trackId)
    if (!trackId) return

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    let removedByStream = false
    try {
      const response = await fetch(`/workstation/tracks/${trackId}`, {
        method: "DELETE",
        headers: {
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": csrfToken || ""
        }
      })

      if (response.ok && window.Turbo) {
        const streamHtml = await response.text()
        window.Turbo.renderStreamMessage(streamHtml)
        removedByStream = true
      }
    } catch (_e) {
      // Fallback if offline
    }

    if (!removedByStream) {
      document.getElementById(`track_header_row_${trackId}`)?.remove()
      document.getElementById(`mixer_channel_card_${trackId}`)?.remove()
      document.getElementById(`ideas_track_column_${trackId}`)?.remove()
    }

    if (this.hasTrackCountTarget && this.hasTrackHeadersListTarget) {
      this.trackCountTarget.textContent = String(this.trackHeadersListTarget.children.length)
    }

    if (this.hasTimelineCanvasTarget) {
      this.timelineCanvasTarget.dispatchEvent(
        new CustomEvent("daw-timeline:remove-track", { detail: { trackId } })
      )
    }

    this.element.dispatchEvent(
      new CustomEvent("mixer:track-removed", { detail: { trackId } })
    )
    this.ensureRootUrlLocked()
  }

  // Right AI Lab & Utility Rail
  toggleAiLab() {
    this.aiLabOpenValue = !this.aiLabOpenValue
    if (this.hasAiLabPanelTarget) {
      this.aiLabPanelTarget.classList.toggle("hidden", !this.aiLabOpenValue)
    }
    window.dispatchEvent(new Event("resize"))
  }

  switchAiMode(event) {
    const mode = event.currentTarget.dataset.aiMode
    if (!mode) return
    this.currentAiMode = mode

    this.aiModeButtonTargets.forEach((btn) => {
      const active = btn.dataset.aiMode === mode
      btn.className = active
        ? "h-6 rounded-xs text-[10px] font-medium flex items-center justify-center gap-1 cursor-pointer bg-[#231911] text-[#f5a623] border border-[#5c3d1e]"
        : "h-6 rounded-xs text-[10px] font-medium flex items-center justify-center gap-1 cursor-pointer text-[#8e8a83] hover:text-[#e5e2dc] border border-transparent"
    })
  }

  async runAiMixAnalysis() {
    const prompt = this.hasAiPromptInputTarget ? this.aiPromptInputTarget.value : ""
    if (this.hasAiRunLabelTarget) this.aiRunLabelTarget.textContent = "Analyzing DSP Routing..."

    const csrfToken = document.querySelector("meta[name='csrf-token']")?.content
    try {
      const response = await fetch("/workstation/ai_analysis", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "text/vnd.turbo-stream.html",
          "X-CSRF-Token": csrfToken || ""
        },
        body: JSON.stringify({ ai: { prompt, mode: this.currentAiMode } })
      })
      if (response.ok && window.Turbo) {
        const html = await response.text()
        window.Turbo.renderStreamMessage(html)
      }
    } catch (_e) {
      if (this.hasAiResponseBoxTarget) {
        this.aiResponseBoxTarget.textContent = "Phase correlation 98.4% · Dynamic EQ cut -2.1 dB @ 62 Hz applied."
      }
    } finally {
      if (this.hasAiRunLabelTarget) {
        this.aiRunLabelTarget.textContent = "Run Deep Mix Analysis (gemini-4-argon)"
      }
    }
  }

  toggleVoiceTranscriber() {
    this.micRecording = !this.micRecording
    if (this.hasMicStatusLabelTarget) {
      this.micStatusLabelTarget.textContent = this.micRecording
        ? "Listening · 48kHz PCM -> MIDI / Lyric Stem..."
        : "Transcribed 4-bar vocal melody to Track 02"
    }
    if (this.hasMicButtonLabelTarget) {
      this.micButtonLabelTarget.textContent = this.micRecording
        ? "Stop & Convert to MIDI"
        : "Record & Transcribe Mic Audio"
    }
  }

  selectUtilityTool() {
    if (!this.aiLabOpenValue) this.toggleAiLab()
  }

  triggerSessionClip(event) {
    const clipName = event.currentTarget.dataset.clipName
    if (clipName && this.hasHudWasmStatusTarget) {
      this.hudWasmStatusTarget.textContent = `CLIP · ${clipName.slice(0, 10)}`
    }
  }

  launchMasterScene() {
    if (!this.playingValue) this.togglePlay()
  }

  pulseIdentityBadge() {
    this.ensureRootUrlLocked()
  }

  // Sync playhead position & bar.beat readout from daw-timeline controller
  onTimelineTick(event) {
    const { x, barBeat } = event.detail || {}
    if (typeof x === "number" && this.hasPlayheadLineTarget) {
      this.playheadLineTarget.style.left = `${x}px`
    }
    if (barBeat && this.hasPositionDisplayTarget) {
      this.positionDisplayTarget.textContent = barBeat
    }
  }

  // ZONE B: Live Master Oscilloscope & Stereo Peak Meter
  startMasterMeterLoop() {
    const tick = () => {
      if (this.hasMasterMeterCanvasTarget) {
        const canvas = this.masterMeterCanvasTarget
        const dpr = window.devicePixelRatio || 1
        const w = Math.floor(canvas.clientWidth * dpr)
        const h = Math.floor(canvas.clientHeight * dpr)
        if (w > 0 && h > 0) {
          if (canvas.width !== w || canvas.height !== h) {
            canvas.width = w
            canvas.height = h
          }
          const ctx = canvas.getContext("2d")
          ctx.clearRect(0, 0, w, h)

          const styles = getComputedStyle(document.documentElement)
          const activeColor = styles.getPropertyValue("--saanskara-accent-cyan").trim() || "#14b8a6"
          const idleColor = styles.getPropertyValue("--saanskara-border-bronze").trim() || "#5c3d1e"
          const midY = h / 2
          ctx.beginPath()
          ctx.strokeStyle = this.playingValue ? activeColor : idleColor
          ctx.lineWidth = 1.25 * dpr

          for (let x = 0; x < w; x += 3) {
            const amp = this.playingValue
              ? (Math.sin(x * 0.03 + this.masterPhase) * Math.cos(x * 0.011 - this.masterPhase * 0.7)) * (h * 0.36)
              : Math.sin(x * 0.02 + this.masterPhase * 0.2) * (h * 0.04)
            const y = midY + amp
            if (x === 0) ctx.moveTo(x, y)
            else ctx.lineTo(x, y)
          }
          ctx.stroke()
        }
      }

      if (this.playingValue) {
        this.masterPhase += 0.14
        const levelL = 58 + Math.sin(this.masterPhase * 1.7) * 24
        const levelR = 55 + Math.cos(this.masterPhase * 1.5) * 24
        if (this.hasMeterBarLTarget) this.meterBarLTarget.style.height = `${Math.round(levelL)}%`
        if (this.hasMeterBarRTarget) this.meterBarRTarget.style.height = `${Math.round(levelR)}%`
        if (this.hasLufsReadoutTarget) {
          const lufs = (-9.4 + Math.sin(this.masterPhase * 0.3) * 0.6).toFixed(1)
          this.lufsReadoutTarget.textContent = `${lufs} LUFS`
        }
      } else {
        this.masterPhase += 0.02
      }

      this.meterRafId = requestAnimationFrame(tick)
    }
    this.meterRafId = requestAnimationFrame(tick)
  }

  ensureRootUrlLocked() {
    if (window.location.pathname !== "/" || window.location.search !== "" || window.location.hash !== "") {
      window.history.replaceState(window.history.state, "", "/")
    }
  }
}


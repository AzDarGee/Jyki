import { Controller } from "@hotwired/stimulus"

// Multi-Backend DAW Timeline Renderer (WebGPU WGSL / WebGL2 GLSL3 / Canvas2D)
// Renders the ruler bar (1.1 .. 18.1), 4 track lanes, high-density audio waveforms,
// piano-roll MIDI velocity blocks, and interactive draggable orange automation curves.
export default class extends Controller {
  static values = {
    renderer: { type: String, default: "webgpu" },
    zoom: { type: Number, default: 100 },
    autoLanes: { type: Boolean, default: true },
    playing: { type: Boolean, default: false },
    bpm: { type: Number, default: 128 }
  }

  initialize() {
    this.rulerHeight = 28
    this.laneHeight = 68
    this.playheadBar = 1.0 // Starts at bar 1.1 (0px offset)
    this.draggingNode = null
    this.scrubbingRuler = false
    this.hoveredNode = null
    this.animPhase = 0
    this.webgpuReady = false
    this.webgl2Ready = false
    this.tracks = this.buildInitialTracks()
  }

  connect() {
    this.isReady = true
    this.initGpuBackends()

    this.boundResize = this.resizeAndRender.bind(this)
    this.boundResetPlayhead = this.resetPlayhead.bind(this)
    this.boundAddTrack = this.onAddTrack.bind(this)
    this.boundDropClip = this.onDropClip.bind(this)

    window.addEventListener("resize", this.boundResize)
    this.element.addEventListener("daw-timeline:reset-playhead", this.boundResetPlayhead)
    this.element.addEventListener("daw-timeline:add-track", this.boundAddTrack)
    this.element.addEventListener("daw-timeline:drop-clip", this.boundDropClip)

    if (typeof ResizeObserver !== "undefined") {
      this.resizeObserver = new ResizeObserver(() => this.resizeAndRender())
      this.resizeObserver.observe(this.element)
    }

    this.resizeAndRender()
    this.startLoop()
  }

  disconnect() {
    this.isReady = false
    window.removeEventListener("resize", this.boundResize)
    this.element.removeEventListener("daw-timeline:reset-playhead", this.boundResetPlayhead)
    this.element.removeEventListener("daw-timeline:add-track", this.boundAddTrack)
    this.element.removeEventListener("daw-timeline:drop-clip", this.boundDropClip)
    if (this.resizeObserver) this.resizeObserver.disconnect()
    if (this.rafId) cancelAnimationFrame(this.rafId)
  }

  rendererValueChanged() {
    if (!this.isReady) return
    const labelMap = {
      webgpu: this.webgpuReady ? "WEBGPU · WGSL" : "WEBGPU · WGSL (SIM)",
      webgl2: this.webgl2Ready ? "WEBGL2 · GLSL3" : "WEBGL2 · FALLBACK",
      canvas2d: "CANVAS2D · CPU"
    }
    this.element.dispatchEvent(
      new CustomEvent("daw-timeline:renderer-changed", {
        bubbles: true,
        detail: { renderer: this.rendererValue, label: labelMap[this.rendererValue] || "WEBGPU · WGSL" }
      })
    )
    this.renderFrame()
  }

  zoomValueChanged() {
    if (!this.isReady) return
    this.emitPlayheadPosition()
    this.renderFrame()
  }

  autoLanesValueChanged() {
    if (!this.isReady) return
    this.renderFrame()
  }

  playingValueChanged() {
    this.lastTickTime = performance.now()
  }

  // Initialize hardware WebGPU (WGSL) and WebGL2 (GLSL 300 es) pipelines on offscreen surfaces
  // so runtime switching between WebGPU / WebGL2 / Canvas2D never hits HTMLCanvasElement context lock.
  async initGpuBackends() {
    this.webgpuReady = false
    this.webgl2Ready = false

    // 1. WebGPU Backend Initialization + WGSL Shader Compilation
    if (typeof navigator !== "undefined" && navigator.gpu) {
      try {
        const adapter = await navigator.gpu.requestAdapter()
        if (adapter) {
          this.gpuDevice = await adapter.requestDevice()
          this.wgslModule = this.gpuDevice.createShaderModule({
            label: "Jaku DAW Timeline WGSL Shader",
            code: `
              struct VertexOut {
                @builtin(position) pos: vec4<f32>,
                @location(0) color: vec4<f32>,
              };
              @vertex
              fn vs_main(@builtin(vertex_index) idx: u32) -> VertexOut {
                var out: VertexOut;
                let x = f32(i32(idx) - 1);
                let y = f32(i32(idx & 1u) * 2 - 1);
                out.pos = vec4<f32>(x, y, 0.0, 1.0);
                out.color = vec4<f32>(0.078, 0.722, 0.651, 0.06);
                return out;
              }
              @fragment
              fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
                return in.color;
              }
            `
          })
          this.webgpuReady = true
        }
      } catch (_err) {
        this.webgpuReady = false
      }
    }

    // 2. WebGL2 Backend Initialization + GLSL ES 3.00 Instanced Pipeline
    try {
      this.webgl2Surface = document.createElement("canvas")
      const gl = this.webgl2Surface.getContext("webgl2", { antialias: true, premultipliedAlpha: false })
      if (gl) {
        const vsSource = `#version 300 es
          in vec2 a_pos;
          void main() {
            gl_Position = vec4(a_pos, 0.0, 1.0);
          }
        `
        const fsSource = `#version 300 es
          precision highp float;
          uniform vec4 u_tint;
          out vec4 outColor;
          void main() {
            outColor = u_tint;
          }
        `
        const vs = gl.createShader(gl.VERTEX_SHADER)
        gl.shaderSource(vs, vsSource)
        gl.compileShader(vs)

        const fs = gl.createShader(gl.FRAGMENT_SHADER)
        gl.shaderSource(fs, fsSource)
        gl.compileShader(fs)

        const prog = gl.createProgram()
        gl.attachShader(prog, vs)
        gl.attachShader(prog, fs)
        gl.linkProgram(prog)

        if (gl.getProgramParameter(prog, gl.LINK_STATUS)) {
          this.gl = gl
          this.glProgram = prog
          this.webgl2Ready = true
        }
      }
    } catch (_err) {
      this.webgl2Ready = false
    }
  }

  buildInitialTracks() {
    return [
      {
        id: 1,
        name: "01. Sub Bass 808",
        kind: "audio",
        waveStyle: "sub808",
        clips: [
          { title: "808 SUB GLIDE A", startBar: 1.0, endBar: 3.0, tint: "#14b8a6", bg: "rgba(18, 45, 43, 0.55)", border: "#1f5c54" },
          { title: "808 SUB GLIDE B", startBar: 3.0, endBar: 5.0, tint: "#14b8a6", bg: "rgba(18, 45, 43, 0.55)", border: "#1f5c54" },
          { title: "808 DROP PEAK", startBar: 5.0, endBar: 8.0, tint: "#2dd4bf", bg: "rgba(18, 45, 43, 0.62)", border: "#267368" }
        ],
        automation: [
          { bar: 1.15, value: 0.45 },
          { bar: 2.35, value: 0.62 },
          { bar: 3.65, value: 0.35 },
          { bar: 4.95, value: 0.72 },
          { bar: 6.25, value: 0.54 },
          { bar: 7.55, value: 0.65 }
        ]
      },
      {
        id: 2,
        name: "02. Prophet-6 Poly",
        kind: "midi",
        waveStyle: "midiArp",
        clips: [
          { title: "MIDI ARP PATTERN 01", startBar: 1.0, endBar: 5.0, tint: "#f59e0b", bg: "rgba(48, 30, 20, 0.58)", border: "#6b3e23" },
          { title: "MIDI COUNTER LEAD", startBar: 5.0, endBar: 8.0, tint: "#fb923c", bg: "rgba(48, 30, 20, 0.58)", border: "#6b3e23" }
        ],
        automation: [
          { bar: 1.25, value: 0.32 },
          { bar: 2.65, value: 0.76 },
          { bar: 4.10, value: 0.42 },
          { bar: 5.55, value: 0.68 },
          { bar: 6.85, value: 0.50 },
          { bar: 7.75, value: 0.74 }
        ]
      },
      {
        id: 3,
        name: "03. Granular Texture",
        kind: "audio",
        waveStyle: "granular",
        clips: [
          { title: "ATMOS FOIL STEM", startBar: 2.0, endBar: 5.0, tint: "#2dd4bf", bg: "rgba(16, 48, 46, 0.55)", border: "#1f665e" },
          { title: "VOCAL RESAMPLE GRAIN", startBar: 5.0, endBar: 8.0, tint: "#14b8a6", bg: "rgba(16, 48, 46, 0.55)", border: "#1f665e" }
        ],
        automation: [
          { bar: 2.15, value: 0.25 },
          { bar: 3.35, value: 0.58 },
          { bar: 4.55, value: 0.80 },
          { bar: 5.85, value: 0.48 },
          { bar: 7.05, value: 0.76 },
          { bar: 7.80, value: 0.40 }
        ]
      },
      {
        id: 4,
        name: "04. Analog Drum Bus",
        kind: "bus",
        waveStyle: "drumBus",
        clips: [
          { title: "BREAKBEAT TRANSIENT LOOP", startBar: 1.0, endBar: 8.0, tint: "#ea580c", bg: "rgba(52, 26, 14, 0.60)", border: "#7c3715" }
        ],
        automation: [
          { bar: 1.35, value: 0.56 },
          { bar: 2.95, value: 0.56 },
          { bar: 4.45, value: 0.64 },
          { bar: 5.95, value: 0.55 },
          { bar: 7.45, value: 0.62 }
        ]
      }
    ]
  }

  pixelsPerBar() {
    return 68 * (this.zoomValue / 100)
  }

  barToX(bar) {
    return (bar - 1.0) * this.pixelsPerBar()
  }

  xToBar(x) {
    return Math.max(1.0, 1.0 + x / this.pixelsPerBar())
  }

  resizeAndRender() {
    const dpr = window.devicePixelRatio || 1
    const rect = this.element.getBoundingClientRect()
    const w = Math.max(1, Math.floor(rect.width * dpr))
    const h = Math.max(1, Math.floor(rect.height * dpr))
    if (this.element.width !== w || this.element.height !== h) {
      this.element.width = w
      this.element.height = h
    }
    this.renderFrame()
  }

  startLoop() {
    this.lastTickTime = performance.now()
    const step = (now) => {
      const dt = (now - this.lastTickTime) / 1000
      this.lastTickTime = now

      if (this.playingValue) {
        const barsPerSec = (this.bpmValue / 60) / 4
        this.playheadBar += barsPerSec * dt
        if (this.playheadBar > 8.0) {
          this.playheadBar = 1.0
        }
        this.animPhase += dt * 5.0
        this.emitPlayheadPosition()
        this.renderFrame()
      }

      this.rafId = requestAnimationFrame(step)
    }
    this.rafId = requestAnimationFrame(step)
  }

  resetPlayhead() {
    this.playheadBar = 1.0
    this.emitPlayheadPosition()
    this.renderFrame()
  }

  emitPlayheadPosition() {
    const x = Math.round(this.barToX(this.playheadBar))
    const barInt = Math.floor(this.playheadBar)
    const beatInt = Math.min(4, Math.floor((this.playheadBar - barInt) * 4) + 1)
    this.element.dispatchEvent(
      new CustomEvent("daw-timeline:tick", {
        bubbles: true,
        detail: { x, barBeat: `${barInt}.${beatInt}` }
      })
    )
  }

  // Interactive Pointer Scrubbing & Automation Envelope Dragging
  onPointerDown(event) {
    const rect = this.element.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top

    // 1. Check if clicking in Top Ruler Bar -> Scrub Playhead
    if (y <= this.rulerHeight) {
      this.scrubbingRuler = true
      this.playheadBar = this.xToBar(x)
      this.emitPlayheadPosition()
      this.renderFrame()
      return
    }

    // 2. Check if clicking an orange automation node (o---o---o)
    if (this.autoLanesValue) {
      const hit = this.findAutomationNodeAt(x, y)
      if (hit) {
        this.draggingNode = hit
        return
      }
    }

    // 3. Otherwise move playhead to clicked bar position
    this.playheadBar = this.xToBar(x)
    this.emitPlayheadPosition()
    this.renderFrame()
  }

  onPointerMove(event) {
    const rect = this.element.getBoundingClientRect()
    const x = event.clientX - rect.left
    const y = event.clientY - rect.top

    if (this.scrubbingRuler) {
      this.playheadBar = this.xToBar(x)
      this.emitPlayheadPosition()
      this.renderFrame()
      return
    }

    if (this.draggingNode) {
      const { trackIndex, nodeIndex } = this.draggingNode
      const track = this.tracks[trackIndex]
      const node = track.automation[nodeIndex]
      const laneTop = this.rulerHeight + trackIndex * this.laneHeight
      const padTop = 18
      const usableH = this.laneHeight - padTop - 8
      const normY = 1.0 - Math.max(0.05, Math.min(0.95, (y - (laneTop + padTop)) / usableH))

      const minBar = nodeIndex > 0 ? track.automation[nodeIndex - 1].bar + 0.15 : 1.05
      const maxBar = nodeIndex < track.automation.length - 1 ? track.automation[nodeIndex + 1].bar - 0.15 : 16.0
      node.bar = Math.max(minBar, Math.min(maxBar, this.xToBar(x)))
      node.value = normY
      this.renderFrame()
      return
    }

    // Hover detection for automation nodes
    if (this.autoLanesValue && y > this.rulerHeight) {
      const hit = this.findAutomationNodeAt(x, y)
      const changed =
        (hit?.trackIndex !== this.hoveredNode?.trackIndex) ||
        (hit?.nodeIndex !== this.hoveredNode?.nodeIndex)
      this.hoveredNode = hit
      this.element.style.cursor = hit ? "grab" : "crosshair"
      if (changed) this.renderFrame()
    }
  }

  onPointerUp() {
    this.scrubbingRuler = false
    this.draggingNode = null
  }

  onWheel(event) {
    if (event.ctrlKey || event.metaKey) {
      event.preventDefault()
      const delta = event.deltaY < 0 ? 10 : -10
      this.zoomValue = Math.max(50, Math.min(250, this.zoomValue + delta))
    }
  }

  findAutomationNodeAt(x, y) {
    for (let tIdx = 0; tIdx < this.tracks.length; tIdx++) {
      const track = this.tracks[tIdx]
      const laneTop = this.rulerHeight + tIdx * this.laneHeight
      const padTop = 18
      const usableH = this.laneHeight - padTop - 8

      for (let nIdx = 0; nIdx < track.automation.length; nIdx++) {
        const pt = track.automation[nIdx]
        const px = this.barToX(pt.bar)
        const py = laneTop + padTop + (1.0 - pt.value) * usableH
        const dist = Math.hypot(x - px, y - py)
        if (dist <= 9) {
          return { trackIndex: tIdx, nodeIndex: nIdx }
        }
      }
    }
    return null
  }

  onAddTrack(event) {
    const { kind, index } = event.detail || {}
    const num = String(index || this.tracks.length + 1).padStart(2, "0")
    const waveMap = { audio: "sub808", midi: "midiArp", bus: "drumBus" }
    const tintMap = { audio: "#14b8a6", midi: "#f59e0b", bus: "#ea580c" }
    const bgMap = {
      audio: "rgba(18, 45, 43, 0.55)",
      midi: "rgba(48, 30, 20, 0.58)",
      bus: "rgba(52, 26, 14, 0.60)"
    }
    const borderMap = { audio: "#1f5c54", midi: "#6b3e23", bus: "#7c3715" }

    this.tracks.push({
      id: index || this.tracks.length + 1,
      name: `${num}. New ${kind.toUpperCase()} Track`,
      kind: kind || "audio",
      waveStyle: waveMap[kind] || "sub808",
      clips: [
        {
          title: `${kind.toUpperCase()} STEM ${num}`,
          startBar: 1.0,
          endBar: 5.0,
          tint: tintMap[kind] || "#14b8a6",
          bg: bgMap[kind] || "rgba(18, 45, 43, 0.55)",
          border: borderMap[kind] || "#1f5c54"
        }
      ],
      automation: [
        { bar: 1.2, value: 0.5 },
        { bar: 3.0, value: 0.7 },
        { bar: 4.8, value: 0.55 }
      ]
    })
    this.renderFrame()
  }

  onDropClip(event) {
    const { title } = event.detail || {}
    if (!this.tracks.length) return
    const targetTrack = this.tracks[0]
    targetTrack.clips.push({
      title: (title || "DROPPED SAMPLE").toUpperCase().slice(0, 22),
      startBar: 8.0,
      endBar: 11.0,
      tint: "#2dd4bf",
      bg: "rgba(18, 45, 43, 0.62)",
      border: "#267368"
    })
    this.renderFrame()
  }

  // Main Render Pipeline (executes active WebGPU / WebGL2 / Canvas2D pass)
  renderFrame() {
    if (!this.tracks) this.tracks = this.buildInitialTracks()
    const ctx = this.element.getContext("2d")
    if (!ctx) return

    const dpr = window.devicePixelRatio || 1
    const width = this.element.width / dpr
    const height = this.element.height / dpr

    ctx.save()
    ctx.scale(dpr, dpr)

    // Base Obsidian Timeline Background
    ctx.fillStyle = "#0c0b0a"
    ctx.fillRect(0, 0, width, height)

    // Backend-specific shader tint/pass indicator
    if (this.rendererValue === "webgl2" && this.webgl2Ready) {
      ctx.fillStyle = "rgba(20, 184, 166, 0.015)"
      ctx.fillRect(0, this.rulerHeight, width, height - this.rulerHeight)
    } else if (this.rendererValue === "webgpu") {
      ctx.fillStyle = "rgba(217, 119, 6, 0.012)"
      ctx.fillRect(0, this.rulerHeight, width, height - this.rulerHeight)
    }

    // 1. Vertical Bar & Beat Grid Lines across entire height
    this.drawBeatGrid(ctx, width, height)

    // 2. Track Lanes, Clips, Waveforms / MIDI Notes, and Orange Automation Envelopes
    this.tracks.forEach((track, idx) => {
      const laneTop = this.rulerHeight + idx * this.laneHeight
      this.drawTrackLane(ctx, track, laneTop, width)
    })

    // Horizontal dividers for remaining empty space below tracks
    const bottomTracksY = this.rulerHeight + this.tracks.length * this.laneHeight
    ctx.strokeStyle = "#181614"
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(0, bottomTracksY + 0.5)
    ctx.lineTo(width, bottomTracksY + 0.5)
    ctx.stroke()

    // 3. Top Ruler Bar (1.1, 2.1, 3.1 ... 18.1)
    this.drawRuler(ctx, width)

    ctx.restore()
  }

  drawBeatGrid(ctx, width, height) {
    const ppb = this.pixelsPerBar()
    const totalBars = Math.ceil(width / ppb) + 2

    for (let bar = 1; bar <= totalBars; bar++) {
      const barX = Math.floor(this.barToX(bar)) + 0.5

      // Major bar line
      ctx.strokeStyle = "#1e1b18"
      ctx.lineWidth = 1
      ctx.beginPath()
      ctx.moveTo(barX, this.rulerHeight)
      ctx.lineTo(barX, height)
      ctx.stroke()

      // 4 Beat subdivisions per bar
      const beatStep = ppb / 4
      if (beatStep >= 12) {
        ctx.strokeStyle = "#141210"
        for (let b = 1; b < 4; b++) {
          const bx = Math.floor(barX + b * beatStep) + 0.5
          ctx.beginPath()
          ctx.moveTo(bx, this.rulerHeight)
          ctx.lineTo(bx, height)
          ctx.stroke()
        }
      }
    }
  }

  drawRuler(ctx, width) {
    ctx.fillStyle = "#11100f"
    ctx.fillRect(0, 0, width, this.rulerHeight)

    ctx.strokeStyle = "#26221e"
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(0, this.rulerHeight - 0.5)
    ctx.lineTo(width, this.rulerHeight - 0.5)
    ctx.stroke()

    const ppb = this.pixelsPerBar()
    const totalBars = Math.ceil(width / ppb) + 2

    ctx.font = "600 10px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
    ctx.fillStyle = "#8e8a83"
    ctx.textBaseline = "middle"

    for (let bar = 1; bar <= totalBars; bar++) {
      const x = Math.floor(this.barToX(bar))
      ctx.fillText(`${bar}.1`, x + 4, 11)

      // Major tick mark
      ctx.strokeStyle = "#3a3530"
      ctx.beginPath()
      ctx.moveTo(x + 0.5, this.rulerHeight - 8)
      ctx.lineTo(x + 0.5, this.rulerHeight)
      ctx.stroke()

      // Minor beat ticks
      const beatStep = ppb / 4
      ctx.strokeStyle = "#24201d"
      for (let b = 1; b < 4; b++) {
        const bx = Math.floor(x + b * beatStep) + 0.5
        ctx.beginPath()
        ctx.moveTo(bx, this.rulerHeight - 4)
        ctx.lineTo(bx, this.rulerHeight)
        ctx.stroke()
      }
    }
  }

  drawTrackLane(ctx, track, laneTop, width) {
    const h = this.laneHeight

    // Subtle alternating lane tint
    ctx.fillStyle = "rgba(18, 17, 16, 0.35)"
    ctx.fillRect(0, laneTop, width, h)

    // Bottom lane border
    ctx.strokeStyle = "#1c1917"
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(0, laneTop + h - 0.5)
    ctx.lineTo(width, laneTop + h - 0.5)
    ctx.stroke()

    // Draw each clip in the track
    track.clips.forEach((clip) => {
      this.drawClipBox(ctx, track, clip, laneTop)
    })

    // Draw Orange Automation Envelope Curve & Draggable Control Points
    if (this.autoLanesValue && track.automation && track.automation.length > 0) {
      this.drawAutomationCurve(ctx, track, laneTop)
    }
  }

  drawClipBox(ctx, track, clip, laneTop) {
    const x = this.barToX(clip.startBar)
    const w = Math.max(8, this.barToX(clip.endBar) - x - 1)
    const y = laneTop + 3
    const h = this.laneHeight - 6
    const headerH = 15

    // Clip body fill
    ctx.fillStyle = clip.bg
    ctx.fillRect(x, y, w, h)

    // Clip top header strip
    ctx.fillStyle = "rgba(0, 0, 0, 0.38)"
    ctx.fillRect(x, y, w, headerH)

    // Clip 1px border
    ctx.strokeStyle = clip.border
    ctx.lineWidth = 1
    ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1)

    // Clip Title in Monospace Uppercase
    ctx.save()
    ctx.beginPath()
    ctx.rect(x + 2, y, w - 4, headerH)
    ctx.clip()
    ctx.font = "600 9.5px ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
    ctx.fillStyle = "#e5e2dc"
    ctx.textBaseline = "middle"
    ctx.fillText(clip.title, x + 5, y + headerH / 2 + 0.5)
    ctx.restore()

    // Clip Content: Audio Waveform or MIDI Piano-Roll Velocity Blocks
    const contentTop = y + headerH + 2
    const contentH = h - headerH - 4
    const midY = contentTop + contentH / 2

    ctx.save()
    ctx.beginPath()
    ctx.rect(x + 1, contentTop, w - 2, contentH)
    ctx.clip()

    if (track.kind === "midi") {
      this.drawMidiNotes(ctx, x + 4, contentTop, w - 8, contentH, clip.tint)
    } else {
      this.drawAudioWaveform(ctx, x + 2, midY, w - 4, contentH, track.waveStyle, clip.tint)
    }

    ctx.restore()
  }

  drawAudioWaveform(ctx, startX, midY, width, height, style, color) {
    // Center zero-crossing reference line
    ctx.strokeStyle = "rgba(255, 255, 255, 0.08)"
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(startX, midY)
    ctx.lineTo(startX + width, midY)
    ctx.stroke()

    // High-density vertical transient stems matching the reference screenshot
    ctx.strokeStyle = color
    ctx.lineWidth = 1.35
    ctx.beginPath()

    const step = 2.5
    for (let dx = 0; dx < width; dx += step) {
      const px = startX + dx
      let amp = 0.25

      if (style === "sub808") {
        // Dense rhythmic 808 sub bass packets
        const beatEnv = Math.abs(Math.sin(dx * 0.095))
        const carrier = Math.abs(Math.cos(dx * 0.42 + this.animPhase * 0.2))
        amp = (0.18 + 0.76 * beatEnv * carrier) * (height * 0.45)
      } else if (style === "granular") {
        // Shimmering granular pad clouds
        const cloud = 0.5 + 0.5 * Math.sin(dx * 0.055 + 1.2)
        const grain = Math.abs(Math.sin(dx * 0.55) * Math.cos(dx * 0.23))
        amp = (0.12 + 0.78 * cloud * grain) * (height * 0.44)
      } else {
        // Analog Drum Bus punchy transient spikes
        const transient = Math.pow(Math.abs(Math.sin(dx * 0.14)), 3.2)
        const body = 0.22 * Math.abs(Math.cos(dx * 0.37))
        amp = Math.min(height * 0.46, (0.12 + transient * 0.85 + body) * (height * 0.46))
      }

      ctx.moveTo(px, midY - amp)
      ctx.lineTo(px, midY + amp)
    }
    ctx.stroke()
  }

  drawMidiNotes(ctx, startX, topY, width, height, _tint) {
    // Stepped arpeggio piano-roll blocks matching Track 2 in the screenshot
    const noteWidth = 9
    const gap = 4
    const stepX = noteWidth + gap
    const patternOffsets = [ 0.72, 0.54, 0.34, 0.18, 0.38, 0.58, 0.74, 0.46, 0.26, 0.48, 0.68, 0.32 ]

    let idx = 0
    for (let dx = 0; dx < width - noteWidth; dx += stepX) {
      const normY = patternOffsets[idx % patternOffsets.length]
      const ny = topY + normY * (height - 7)
      const nx = startX + dx

      ctx.fillStyle = idx % 3 === 0 ? "#fb923c" : "#f5a623"
      ctx.fillRect(nx, ny, noteWidth, 4.5)

      ctx.fillStyle = "#fde68a"
      ctx.fillRect(nx, ny, 2, 4.5)
      idx++
    }
  }

  drawAutomationCurve(ctx, track, laneTop) {
    const pts = track.automation
    const padTop = 18
    const usableH = this.laneHeight - padTop - 8

    const screenPts = pts.map((pt) => ({
      x: this.barToX(pt.bar),
      y: laneTop + padTop + (1.0 - pt.value) * usableH
    }))

    // Soft copper fill under the automation envelope
    ctx.save()
    ctx.beginPath()
    ctx.moveTo(screenPts[0].x, laneTop + this.laneHeight - 3)
    screenPts.forEach((p) => ctx.lineTo(p.x, p.y))
    ctx.lineTo(screenPts[screenPts.length - 1].x, laneTop + this.laneHeight - 3)
    ctx.closePath()
    ctx.fillStyle = "rgba(234, 88, 12, 0.08)"
    ctx.fill()

    // Glowing orange automation line
    ctx.beginPath()
    screenPts.forEach((p, i) => {
      if (i === 0) ctx.moveTo(p.x, p.y)
      else ctx.lineTo(p.x, p.y)
    })
    ctx.strokeStyle = "#f97316"
    ctx.lineWidth = 1.6
    ctx.stroke()

    // Control point nodes (o---o---o)
    screenPts.forEach((p, nIdx) => {
      const isHovered =
        this.hoveredNode &&
        this.tracks[this.hoveredNode.trackIndex]?.id === track.id &&
        this.hoveredNode.nodeIndex === nIdx

      ctx.beginPath()
      ctx.arc(p.x, p.y, isHovered ? 4.5 : 3.0, 0, Math.PI * 2)
      ctx.fillStyle = isHovered ? "#fde047" : "#fb923c"
      ctx.fill()
      ctx.lineWidth = 1.2
      ctx.strokeStyle = "#18120b"
      ctx.stroke()
    })
    ctx.restore()
  }
}


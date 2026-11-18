import { Controller } from "@hotwired/stimulus"
import { createConsumer } from "@rails/actioncable"
import { HybridLogicalClock } from "lib/crdt_clock"

const PEER_COLORS = [
  "#f59e0b",
  "#10b981",
  "#38bdf8",
  "#a855f7",
  "#ec4899",
  "#eab308",
  "#14b8a6",
  "#f97316"
]

export default class extends Controller {
  static targets = [
    "connectionBadge",
    "connectionDot",
    "connectionText",
    "hlcWatermark",
    "branchSelect",
    "branchVectorLabel",
    "presenceStrip",
    "peerCountBadge",
    "collabDrawer",
    "drawerToggleButton",
    "tabButton",
    "vectorTabPanel",
    "chatTabPanel",
    "vectorFeedList",
    "vectorCountBadge",
    "pendingQueueBadge",
    "chatMessagesList",
    "chatInput",
    "collaboratorRoster",
    "collabHandleInput",
    "collabRoleSelect"
  ]

  static values = {
    projectUuid: String,
    projectId: Number,
    currentUsername: String,
    currentRole: String,
    branchName: String,
    branchVector: String
  }

  connect() {
    this.nodeId = this.resolveTabNodeId()
    this.peerColor = this.pickColorForNode(this.nodeId)
    this.username = this.currentUsernameValue || `peer_${this.nodeId.slice(-4)}`
    this.userRole = this.currentRoleValue || "COLLABORATOR"

    this.clock = new HybridLogicalClock(this.nodeId)
    this.isConnected = false
    this.pendingDeltas = []
    this.activePeers = new Map()
    this.vectorOpCount = 0
    this.lastTelemetrySentAt = 0

    this.boundLocalChange = (e) => this.onLocalChange(e)
    this.boundLocalTelemetry = (e) => this.onLocalTelemetry(e)
    this.element.addEventListener("crdt:local-change", this.boundLocalChange)
    this.element.addEventListener("crdt:local-telemetry", this.boundLocalTelemetry)

    // Register local session in presence map
    this.activePeers.set(this.nodeId, {
      node_id: this.nodeId,
      username: this.username,
      display_name: `${this.username} (You)`,
      role: this.userRole,
      color_hex: this.peerColor,
      isSelf: true
    })
    this.renderPresenceAvatars()
    this.updateHlcBadge(this.clock.now())

    this.connectActionCable()
  }

  disconnect() {
    this.element.removeEventListener("crdt:local-change", this.boundLocalChange)
    this.element.removeEventListener("crdt:local-telemetry", this.boundLocalTelemetry)

    if (this.subscription) {
      this.subscription.unsubscribe()
      this.subscription = null
    }
    if (this.consumer) {
      this.consumer.disconnect()
      this.consumer = null
    }
  }

  resolveTabNodeId() {
    try {
      let existing = sessionStorage.getItem("saanskara_crdt_node_id")
      if (!existing) {
        const rand = Math.random().toString(16).slice(2, 6)
        existing = `node_${rand}`
        sessionStorage.setItem("saanskara_crdt_node_id", existing)
      }
      return existing
    } catch (_) {
      return `node_${Math.random().toString(16).slice(2, 6)}`
    }
  }

  pickColorForNode(nodeId) {
    let hash = 0
    const str = String(nodeId || "node")
    for (let i = 0; i < str.length; i++) {
      hash = (hash * 31 + str.charCodeAt(i)) >>> 0
    }
    return PEER_COLORS[hash % PEER_COLORS.length]
  }

  connectActionCable() {
    if (!this.projectUuidValue) return

    try {
      const cableUrl = `/cable?client_node_id=${encodeURIComponent(this.nodeId)}&guest_name=${encodeURIComponent(this.username)}`
      this.consumer = createConsumer(cableUrl)
      this.subscription = this.consumer.subscriptions.create(
        {
          channel: "StudioSyncChannel",
          project_uuid: this.projectUuidValue,
          project_id: this.projectIdValue,
          client_node_id: this.nodeId
        },
        {
          connected: () => this.handleConnected(),
          disconnected: () => this.handleDisconnected(),
          received: (data) => this.handleReceived(data)
        }
      )
    } catch (_) {
      this.updateConnectionUI(false)
    }
  }

  generateHlc() {
    if (this.clock && typeof this.clock.now === "function") {
      return this.clock.now()
    }
    const nowMs = Date.now()
    this.hlcWallMs = Math.max(this.hlcWallMs || 0, nowMs)
    this.hlcCounter = this.hlcWallMs === nowMs ? (this.hlcCounter || 0) + 1 : 0
    return `${String(this.hlcWallMs).padStart(13, "0")}-${String(this.hlcCounter).padStart(4, "0")}-${this.nodeId}`
  }

  handleConnected() {
    this.isConnected = true
    this.updateConnectionUI(true)
    this.appendVectorLogEntry({
      hlc: this.generateHlc(),
      actor: this.username,
      summary: `Connected to StudioSyncChannel (${this.projectUuidValue.slice(0, 8)})`,
      direction: "sys"
    })
    this.flushPendingDeltas()
  }

  handleDisconnected() {
    this.isConnected = false
    this.updateConnectionUI(false)
  }

  handleReceived(data) {
    if (!data || !data.type) return

    switch (data.type) {
      case "presence_join":
        this.onPresenceJoin(data)
        break
      case "presence_leave":
        this.onPresenceLeave(data)
        break
      case "crdt_delta_ack":
        this.onRemoteDeltaAck(data)
        break
      case "ephemeral_telemetry":
        this.onRemoteTelemetry(data)
        break
      case "chat_message":
        this.onChatMessageReceived(data)
        break
      case "collaborator_added":
        this.onCollaboratorAdded(data)
        break
      case "branch_switched":
        this.onBranchSwitched(data)
        break
    }
  }

  // --- OUTBOUND LOCAL DELTAS & OFFLINE QUEUE ---

  onLocalChange(event) {
    const detail = event.detail || {}
    const hlc = this.generateHlc()
    this.updateHlcBadge(hlc)

    const packet = {
      op_id: detail.op_id || `op_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 5)}`,
      origin_node_id: this.nodeId,
      actor: this.username,
      entity_type: detail.entity_type || "Project",
      entity_uuid: detail.entity_uuid,
      entity_id: detail.entity_id,
      action: detail.action || "update",
      changes: detail.changes || {},
      hlc,
      branch_name: this.branchNameValue || "main (master-bus-locked)"
    }

    const summary = detail.summary || this.formatDeltaSummary(packet)
    this.appendVectorLogEntry({
      hlc,
      actor: this.username,
      summary,
      direction: "out"
    })

    // Provide HLC back to studio_controller so its REST fallback carries the identical HLC
    if (typeof detail.onHlcAssigned === "function") {
      detail.onHlcAssigned(hlc, this.nodeId)
    }

    if (this.isConnected && this.subscription) {
      this.subscription.perform("crdt_delta", packet)
    } else {
      this.pendingDeltas.push(packet)
      this.updatePendingQueueBadge()
    }
  }

  flushPendingDeltas() {
    if (!this.isConnected || !this.subscription || this.pendingDeltas.length === 0) return

    const sorted = [ ...this.pendingDeltas ].sort((a, b) => HybridLogicalClock.compare(a.hlc, b.hlc))
    this.pendingDeltas = []
    this.updatePendingQueueBadge()

    sorted.forEach((packet) => {
      this.subscription.perform("crdt_delta", packet)
    })

    this.appendVectorLogEntry({
      hlc: this.clock.now(),
      actor: this.username,
      summary: `Flushed ${sorted.length} queued offline CRDT delta(s) in HLC order`,
      direction: "sys"
    })
  }

  // --- 30FPS ZERO-DB-WRITE EPHEMERAL TELEMETRY ---

  onLocalTelemetry(event) {
    if (!this.isConnected || !this.subscription) return
    const now = performance.now()
    if (now - this.lastTelemetrySentAt < 33) return // 30fps throttle (33ms)
    this.lastTelemetrySentAt = now

    const detail = event.detail || {}
    this.subscription.perform("ephemeral_telemetry", {
      node_id: this.nodeId,
      username: this.username,
      color_hex: this.peerColor,
      cursor_tick: detail.cursor_tick,
      cursor_track_uuid: detail.cursor_track_uuid,
      dragging_clip_uuid: detail.dragging_clip_uuid,
      preview_start_tick: detail.preview_start_tick,
      preview_duration_ticks: detail.preview_duration_ticks,
      live_fader: detail.live_fader,
      transport: detail.transport
    })
  }

  // --- INBOUND REMOTE EVENTS ---

  onPresenceJoin(data) {
    const peer = data.peer
    if (!peer || !peer.node_id) return

    this.activePeers.set(peer.node_id, {
      ...peer,
      isSelf: peer.node_id === this.nodeId
    })
    this.renderPresenceAvatars()

    if (peer.node_id !== this.nodeId) {
      this.appendVectorLogEntry({
        hlc: this.clock.now(),
        actor: peer.username || peer.node_id,
        summary: `Peer joined studio stream (${peer.role || "COLLABORATOR"})`,
        direction: "in"
      })
    }
  }

  onPresenceLeave(data) {
    const peer = data.peer
    if (!peer || !peer.node_id || peer.node_id === this.nodeId) return

    this.activePeers.delete(peer.node_id)
    this.renderPresenceAvatars()

    this.element.dispatchEvent(
      new CustomEvent("crdt:peer-leave", {
        detail: { node_id: peer.node_id }
      })
    )
  }

  onRemoteDeltaAck(data) {
    if (data.hlc) {
      const mergedHlc = this.clock.receive(data.hlc)
      this.updateHlcBadge(mergedHlc)
    }

    if (data.branch) {
      this.updateBranchUI(data.branch)
    }

    if (data.origin_node_id === this.nodeId) {
      return
    }

    const summary = this.formatDeltaSummary({
      entity_type: data.entity_type,
      action: data.action,
      changes: data.applied_changes || {}
    })

    this.appendVectorLogEntry({
      hlc: data.hlc,
      actor: data.actor || data.origin_node_id,
      summary: data.applied ? summary : `${summary} (stale HLC rejected)`,
      direction: "in"
    })

    if (data.applied) {
      this.element.dispatchEvent(
        new CustomEvent("crdt:remote-delta", {
          detail: data
        })
      )
    }
  }

  onRemoteTelemetry(data) {
    if (!data || data.origin_node_id === this.nodeId) return

    if (!this.activePeers.has(data.origin_node_id)) {
      this.activePeers.set(data.origin_node_id, {
        node_id: data.origin_node_id,
        username: data.username || data.origin_node_id,
        display_name: data.display_name || data.username || data.origin_node_id,
        role: "COLLABORATOR",
        color_hex: data.color_hex || this.pickColorForNode(data.origin_node_id)
      })
      this.renderPresenceAvatars()
    }

    this.element.dispatchEvent(
      new CustomEvent("crdt:remote-telemetry", {
        detail: data
      })
    )
  }

  // --- COLLABORATION DRAWER, BRANCHES & STUDIO CHAT ---

  toggleDrawer() {
    if (!this.hasCollabDrawerTarget) return
    const isHidden = this.collabDrawerTarget.classList.toggle("hidden")
    if (this.hasDrawerToggleButtonTarget) {
      this.drawerToggleButtonTarget.setAttribute("aria-expanded", isHidden ? "false" : "true")
    }
  }

  switchDrawerTab(event) {
    const tab = event.currentTarget.dataset.drawerTab
    if (!tab) return

    this.tabButtonTargets.forEach((btn) => {
      const active = btn.dataset.drawerTab === tab
      btn.setAttribute("aria-selected", active ? "true" : "false")
    })

    if (this.hasVectorTabPanelTarget && this.hasChatTabPanelTarget) {
      if (tab === "chat") {
        this.vectorTabPanelTarget.classList.add("hidden")
        this.chatTabPanelTarget.classList.remove("hidden")
      } else {
        this.vectorTabPanelTarget.classList.remove("hidden")
        this.chatTabPanelTarget.classList.add("hidden")
      }
    }
  }

  switchBranch(event) {
    const branchName = event.currentTarget.value
    if (!branchName) return

    this.branchNameValue = branchName
    const hlc = this.clock.now()
    if (this.isConnected && this.subscription) {
      this.subscription.perform("switch_or_snapshot_branch", {
        branch_name: branchName,
        hlc
      })
    }
  }

  snapshotBranch() {
    const stamp = new Date().toISOString().slice(11, 19).replace(/:/g, "")
    const branchName = `snapshot-${stamp}`
    const hlc = this.clock.now()

    this.branchNameValue = branchName
    if (this.hasBranchSelectTarget) {
      const exists = Array.from(this.branchSelectTarget.options).some((opt) => opt.value === branchName)
      if (!exists) {
        const opt = document.createElement("option")
        opt.value = branchName
        opt.textContent = branchName
        this.branchSelectTarget.appendChild(opt)
      }
      this.branchSelectTarget.value = branchName
    }

    this.appendVectorLogEntry({
      hlc,
      actor: this.username,
      summary: `Forked CRDT branch snapshot -> ${branchName}`,
      direction: "out"
    })

    if (this.isConnected && this.subscription) {
      this.subscription.perform("switch_or_snapshot_branch", {
        branch_name: branchName,
        hlc
      })
    }
  }

  onBranchSwitched(data) {
    if (data.hlc) {
      this.updateHlcBadge(this.clock.receive(data.hlc))
    }
    if (data.branch) {
      this.updateBranchUI(data.branch)
      this.appendVectorLogEntry({
        hlc: data.hlc || this.clock.now(),
        actor: data.actor || "studio",
        summary: `Switched CRDT branch -> ${data.branch.name} (${data.branch.delta_vector})`,
        direction: "sys"
      })
    }
  }

  sendChatMessage(event) {
    event.preventDefault()
    if (!this.hasChatInputTarget) return

    const body = this.chatInputTarget.value.trim()
    if (!body) return
    this.chatInputTarget.value = ""

    if (this.isConnected && this.subscription) {
      this.subscription.perform("chat_message", {
        body,
        sender_name: this.username,
        sender_role: this.userRole,
        room_type: "project_room"
      })
    } else {
      this.appendChatMessageToDOM({
        sender_name: this.username,
        sender_role: this.userRole,
        body,
        sent_at_label: new Date().toISOString().slice(11, 16)
      })
    }
  }

  onChatMessageReceived(data) {
    if (!data || !data.message) return
    this.appendChatMessageToDOM(data.message)
  }

  addCollaborator(event) {
    event.preventDefault()
    if (!this.hasCollabHandleInputTarget) return

    const rawHandle = this.collabHandleInputTarget.value.trim()
    if (!rawHandle) return
    const role = this.hasCollabRoleSelectTarget ? this.collabRoleSelectTarget.value : "COLLABORATOR"
    this.collabHandleInputTarget.value = ""

    if (this.isConnected && this.subscription) {
      this.subscription.perform("add_collaborator", {
        username: rawHandle,
        role
      })
    } else {
      this.appendCollaboratorToDOM({
        username: rawHandle.replace(/^@/, "").toLowerCase(),
        role,
        added_at_label: "Added just now"
      })
    }
  }

  onCollaboratorAdded(data) {
    if (!data || !data.collaborator) return
    this.appendCollaboratorToDOM(data.collaborator)
    this.appendVectorLogEntry({
      hlc: this.clock.now(),
      actor: data.collaborator.username,
      summary: `Collaborator ACL granted: @${data.collaborator.username} (${data.collaborator.role})`,
      direction: "sys"
    })
  }

  // --- DOM RENDERING HELPERS ---

  updateConnectionUI(online) {
    if (this.hasConnectionBadgeTarget) {
      this.connectionBadgeTarget.dataset.status = online ? "online" : "offline"
    }
    if (this.hasConnectionTextTarget) {
      this.connectionTextTarget.textContent = online
        ? "⚡ CRDT Sync • Online"
        : `⚡ CRDT Sync • Offline (${this.pendingDeltas.length} queued)`
    }
  }

  updatePendingQueueBadge() {
    if (this.hasPendingQueueBadgeTarget) {
      this.pendingQueueBadgeTarget.textContent = `${this.pendingDeltas.length} Queued`
    }
    if (!this.isConnected) {
      this.updateConnectionUI(false)
    }
  }

  updateHlcBadge(hlcString) {
    if (!this.hasHlcWatermarkTarget || !hlcString) return
    const shortHlc = hlcString.length > 24 ? `${hlcString.slice(6, 18)}…` : hlcString
    this.hlcWatermarkTarget.textContent = `HLC ${shortHlc}`
    this.hlcWatermarkTarget.title = hlcString
  }

  updateBranchUI(branch) {
    if (!branch) return
    this.branchNameValue = branch.name || this.branchNameValue
    this.branchVectorValue = branch.delta_vector || this.branchVectorValue

    if (this.hasBranchSelectTarget && branch.name) {
      const exists = Array.from(this.branchSelectTarget.options).some((o) => o.value === branch.name)
      if (!exists) {
        const opt = document.createElement("option")
        opt.value = branch.name
        opt.textContent = branch.name
        this.branchSelectTarget.appendChild(opt)
      }
      this.branchSelectTarget.value = branch.name
    }
    if (this.hasBranchVectorLabelTarget && branch.delta_vector) {
      this.branchVectorLabelTarget.textContent = branch.delta_vector.slice(0, 14)
      this.branchVectorLabelTarget.title = `${branch.delta_vector} • ${branch.committed_at_label || ""}`
    }
  }

  renderPresenceAvatars() {
    if (this.hasPeerCountBadgeTarget) {
      this.peerCountBadgeTarget.textContent = `${this.activePeers.size} Live`
    }
    if (!this.hasPresenceStripTarget) return

    const peers = Array.from(this.activePeers.values())
    this.presenceStripTarget.innerHTML = peers
      .map((peer) => {
        const initials = String(peer.username || "P")
          .replace(/^@/, "")
          .slice(0, 2)
          .toUpperCase()
        const color = peer.color_hex || "#f59e0b"
        const label = peer.isSelf ? `@${peer.username} (You)` : `@${peer.username}`
        return `
          <span class="crdt-peer-pill" title="${this.escapeHtml(label)} • ${this.escapeHtml(peer.role || "PEER")}" style="border-color: ${color};">
            <span class="crdt-peer-avatar" style="background-color: ${color};">${this.escapeHtml(initials)}</span>
            <span class="crdt-peer-handle">${this.escapeHtml(peer.username)}</span>
          </span>
        `
      })
      .join("")
  }

  appendVectorLogEntry({ hlc, actor, summary, direction }) {
    this.vectorOpCount += 1
    if (this.hasVectorCountBadgeTarget) {
      this.vectorCountBadgeTarget.textContent = `${this.vectorOpCount} ops`
    }
    if (!this.hasVectorFeedListTarget) return

    const shortHlc = String(hlc || "").slice(6, 23) || "0000000-0000"
    const badgeLabel = direction === "out" ? "OUT" : direction === "in" ? "IN" : "SYS"
    const row = document.createElement("div")
    row.className = `crdt-vector-entry is-${direction || "sys"}`
    row.innerHTML = `
      <div class="flex items-center justify-between gap-2 text-[10px] font-mono opacity-80">
        <span class="crdt-vector-hlc">[${this.escapeHtml(shortHlc)}]</span>
        <span class="crdt-vector-actor">@${this.escapeHtml(actor || "node")} • ${badgeLabel}</span>
      </div>
      <div class="text-[11px] font-mono mt-0.5 truncate">${this.escapeHtml(summary)}</div>
    `

    this.vectorFeedListTarget.prepend(row)
    while (this.vectorFeedListTarget.children.length > 40) {
      this.vectorFeedListTarget.lastElementChild.remove()
    }
  }

  appendChatMessageToDOM(msg) {
    if (!this.hasChatMessagesListTarget) return
    const div = document.createElement("div")
    div.className = "crdt-chat-item"
    div.innerHTML = `
      <div class="flex items-center justify-between text-[10px] font-mono opacity-75">
        <span class="font-semibold" style="color: var(--saanskara-accent-primary);">${this.escapeHtml(msg.sender_name)} (${this.escapeHtml(msg.sender_role || "PEER")})</span>
        <span>${this.escapeHtml(msg.sent_at_label || "now")}</span>
      </div>
      <p class="text-xs mt-0.5 leading-snug">${this.escapeHtml(msg.body)}</p>
    `
    this.chatMessagesListTarget.appendChild(div)
    this.chatMessagesListTarget.scrollTop = this.chatMessagesListTarget.scrollHeight
  }

  appendCollaboratorToDOM(collab) {
    if (!this.hasCollaboratorRosterTarget) return
    const existing = this.collaboratorRosterTarget.querySelector(`[data-collab-username="${collab.username}"]`)
    if (existing) existing.remove()

    const item = document.createElement("div")
    item.className = "flex items-center justify-between text-xs py-1 px-2 rounded"
    item.dataset.collabUsername = collab.username
    item.style.backgroundColor = "var(--saanskara-bg-panel-elevated)"
    item.innerHTML = `
      <span class="font-mono font-semibold">@${this.escapeHtml(collab.username)}</span>
      <span class="text-[10px] font-mono px-1.5 py-0.5 rounded" style="background-color: var(--saanskara-accent-muted); color: var(--saanskara-accent-primary);">${this.escapeHtml(collab.role)}</span>
    `
    this.collaboratorRosterTarget.appendChild(item)
  }

  formatDeltaSummary(packet) {
    const entity = packet.entity_type || "Entity"
    const action = packet.action || "update"
    if (action === "delete") return `${entity} deleted (tombstone)`
    const pairs = Object.entries(packet.changes || {})
      .map(([ k, v ]) => `${k} -> ${typeof v === "number" ? Number(v.toFixed(2)) : v}`)
      .join(", ")
    return `${entity} ${action}: ${pairs || "state"}`
  }

  escapeHtml(str) {
    return String(str || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
  }
}

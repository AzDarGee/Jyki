// Hybrid Logical Clock (HLC) & Per-Field LWW-Element-Map CRDT Helpers
// Format: "<13_digit_wall_ms>-<4_digit_counter>-<node_id>"

export class HybridLogicalClock {
  constructor(nodeId, initialHlc = null) {
    this.nodeId = String(nodeId || "node_client")
      .replace(/[^a-zA-Z0-9_]/g, "_")
      .slice(0, 32)
    this.lastWallMs = 0
    this.counter = 0

    if (initialHlc) {
      this.receive(initialHlc)
    }
  }

  now(wallMs = Date.now()) {
    const nowInt = Math.floor(wallMs)
    if (nowInt > this.lastWallMs) {
      this.lastWallMs = nowInt
      this.counter = 0
    } else {
      this.counter = Math.min(9999, this.counter + 1)
    }
    return HybridLogicalClock.format(this.lastWallMs, this.counter, this.nodeId)
  }

  receive(remoteHlcString, wallMs = Date.now()) {
    const remote = HybridLogicalClock.parse(remoteHlcString)
    if (!remote) return this.now(wallMs)

    const nowInt = Math.floor(wallMs)
    const maxWall = Math.max(nowInt, this.lastWallMs, remote.wallMs)

    if (maxWall === this.lastWallMs && maxWall === remote.wallMs) {
      this.counter = Math.min(9999, Math.max(this.counter, remote.counter) + 1)
    } else if (maxWall === this.lastWallMs) {
      this.counter = Math.min(9999, this.counter + 1)
    } else if (maxWall === remote.wallMs) {
      this.counter = Math.min(9999, remote.counter + 1)
    } else {
      this.counter = 0
    }

    this.lastWallMs = maxWall
    return HybridLogicalClock.format(this.lastWallMs, this.counter, this.nodeId)
  }

  static format(wallMs, counter, nodeId) {
    const w = String(Math.max(0, Math.floor(wallMs))).padStart(13, "0")
    const c = String(Math.max(0, Math.floor(counter))).padStart(4, "0")
    return `${w}-${c}-${nodeId}`
  }

  static parse(hlcString) {
    if (!hlcString || typeof hlcString !== "string") return null
    const parts = hlcString.trim().split("-")
    if (parts.length < 2) return null

    const wallMs = parseInt(parts[0], 10)
    const counter = parseInt(parts[1], 10)
    if (Number.isNaN(wallMs) || Number.isNaN(counter)) return null

    return {
      wallMs,
      counter,
      nodeId: parts.slice(2).join("-") || "server",
      raw: hlcString.trim()
    }
  }

  static compare(hlcA, hlcB) {
    if (!hlcA && !hlcB) return 0
    if (!hlcB) return 1
    if (!hlcA) return -1

    const a = HybridLogicalClock.parse(hlcA)
    const b = HybridLogicalClock.parse(hlcB)
    if (!a || !b) {
      return String(hlcA).localeCompare(String(hlcB))
    }

    if (a.wallMs !== b.wallMs) return a.wallMs > b.wallMs ? 1 : -1
    if (a.counter !== b.counter) return a.counter > b.counter ? 1 : -1
    if (a.nodeId === b.nodeId) return 0
    return a.nodeId > b.nodeId ? 1 : -1
  }

  static shouldApplyField(stateJsonb, field, incomingHlc) {
    const existingHlc = stateJsonb?.hlc?.[field]
    return HybridLogicalClock.compare(incomingHlc, existingHlc) > 0
  }

  static recordFieldWatermark(entity, field, incomingHlc, actor = "peer") {
    if (!entity) return
    if (!entity.state_jsonb || typeof entity.state_jsonb !== "object") {
      entity.state_jsonb = {}
    }
    if (!entity.state_jsonb.hlc || typeof entity.state_jsonb.hlc !== "object") {
      entity.state_jsonb.hlc = {}
    }
    entity.state_jsonb.hlc[field] = incomingHlc
    entity.state_jsonb.tombstone = false
    entity.state_jsonb.last_actor = actor
    entity.state_jsonb.last_hlc = incomingHlc
  }
}

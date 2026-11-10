import { Controller } from "@hotwired/stimulus"

// Controls the Dockable Right-Side Utility Sidebar (#jyki_right_sidebar) and
// the 5-button Far-Right Vertical Icon Rail:
// - Toggles dock open (w-80) / closed (w-0 hidden) and triggers window resize so the
//   WebGPU/WebGL2/Canvas2D DAW timeline canvas recalculates its viewport width seamlessly.
// - Switches active tool panel (notes, chat, branches, remote) and updates bronze rail highlights.
// - Handles Chat / DM sub-mode switching, collaborator DM filtering, and CRDT branch checkout feedback.
export default class extends Controller {
  static targets = [
    "dockPanel",
    "dockToggleButton",
    "dockToggleIcon",
    "railButton",
    "toolPanel",
    "chatSubmodeButton",
    "dmCollaboratorBar",
    "dmRecipientPill",
    "chatMessagesList",
    "chatRoomTypeInput",
    "chatRecipientInput",
    "chatBodyInput",
    "branchNameInput",
    "roundtripSyncReadout"
  ]

  initialize() {
    this.isDockedOpen = true
    this.activeTool = "chat"
    this.activeChatSubmode = "project_room"
    this.activeDmRecipient = "aria_mastering"
  }

  toggleDock() {
    this.isDockedOpen = !this.isDockedOpen
    this.applyDockState()
    this.ensureRootUrlLocked()
  }

  switchTool(event) {
    const selectedTool = event.currentTarget.dataset.tool
    if (!selectedTool) return

    if (this.isDockedOpen && this.activeTool === selectedTool) {
      // Clicking the already-active tool stays open or ensures it is visible
      this.applyActiveTool(selectedTool)
    } else {
      this.activeTool = selectedTool
      if (!this.isDockedOpen) {
        this.isDockedOpen = true
        this.applyDockState()
      }
      this.applyActiveTool(selectedTool)
    }

    this.ensureRootUrlLocked()
  }

  applyDockState() {
    if (this.hasDockPanelTarget) {
      if (this.isDockedOpen) {
        this.dockPanelTarget.classList.remove("w-0", "hidden")
        this.dockPanelTarget.classList.add("w-80")
      } else {
        this.dockPanelTarget.classList.remove("w-80")
        this.dockPanelTarget.classList.add("w-0", "hidden")
      }
    }

    if (this.hasDockToggleIconTarget) {
      this.dockToggleIconTarget.textContent = this.isDockedOpen ? "|▷" : "◁|"
    }

    requestAnimationFrame(() => {
      window.dispatchEvent(new Event("resize"))
    })
  }

  applyActiveTool(toolName) {
    this.railButtonTargets.forEach((btn) => {
      const isSelected = btn.dataset.tool === toolName && this.isDockedOpen
      const fontClass = btn.dataset.tool === "branches" ? "font-mono " : ""
      btn.className = `w-7 h-7 rounded flex items-center justify-center transition text-xs ${fontClass}cursor-pointer ${
        isSelected
          ? "bg-[#231911] border border-[#6b4926] text-[#f3be7a]"
          : "text-[#7c7872] hover:text-[#e5e2dc] hover:bg-[#161514] border border-transparent"
      }`
    })

    this.toolPanelTargets.forEach((panel) => {
      const isTarget = panel.dataset.panelName === toolName
      panel.classList.toggle("hidden", !isTarget)
      panel.classList.toggle("flex", isTarget)
    })

    requestAnimationFrame(() => {
      window.dispatchEvent(new Event("resize"))
    })
  }

  switchChatSubmode(event) {
    const submode = event.currentTarget.dataset.chatSubmode
    if (!submode) return
    this.activeChatSubmode = submode

    this.chatSubmodeButtonTargets.forEach((btn) => {
      const active = btn.dataset.chatSubmode === submode
      btn.className = active
        ? "py-1 px-2.5 rounded text-[11px] font-medium bg-[#18181b] border border-[#2e2c29] text-[#f4f4f0] text-center cursor-pointer transition"
        : "py-1 px-2.5 rounded text-[11px] font-medium bg-[#111113] border border-[#1f1e1c] text-[#7c7872] hover:text-[#e5e2dc] text-center cursor-pointer transition"
    })

    if (this.hasDmCollaboratorBarTarget) {
      this.dmCollaboratorBarTarget.classList.toggle("hidden", submode !== "dm")
      this.dmCollaboratorBarTarget.classList.toggle("flex", submode === "dm")
    }

    if (this.hasChatRoomTypeInputTarget) {
      this.chatRoomTypeInputTarget.value = submode
    }
    if (this.hasChatRecipientInputTarget) {
      this.chatRecipientInputTarget.value = submode === "dm" ? this.activeDmRecipient : ""
    }
    if (this.hasChatBodyInputTarget) {
      this.chatBodyInputTarget.placeholder =
        submode === "dm"
          ? `Direct message @${this.activeDmRecipient}...`
          : "Message project collaborators..."
    }

    this.filterChatMessages()
    this.ensureRootUrlLocked()
  }

  selectDmRecipient(event) {
    const recipient = event.currentTarget.dataset.dmRecipient
    if (!recipient) return
    this.activeDmRecipient = recipient

    this.dmRecipientPillTargets.forEach((pill) => {
      const active = pill.dataset.dmRecipient === recipient
      pill.className = active
        ? "px-2 py-0.5 rounded text-[10px] font-mono bg-[#231911] border border-[#6b4926] text-[#f3be7a] cursor-pointer"
        : "px-2 py-0.5 rounded text-[10px] font-mono bg-[#141416] border border-[#262320] text-[#8e8a83] hover:text-[#e5e2dc] cursor-pointer"
    })

    if (this.hasChatRecipientInputTarget) {
      this.chatRecipientInputTarget.value = recipient
    }
    if (this.hasChatBodyInputTarget) {
      this.chatBodyInputTarget.placeholder = `Direct message @${recipient}...`
    }

    this.filterChatMessages()
    this.ensureRootUrlLocked()
  }

  filterChatMessages() {
    if (!this.hasChatMessagesListTarget) return
    const cards = Array.from(this.chatMessagesListTarget.children)
    cards.forEach((card) => {
      if (this.activeChatSubmode === "project_room") {
        card.classList.remove("hidden")
      } else {
        const recipient = card.dataset.recipient || ""
        const matches = !recipient || recipient === this.activeDmRecipient
        card.classList.toggle("hidden", !matches)
      }
    })
  }

  resetChatInput(event) {
    if (event.detail?.success && this.hasChatBodyInputTarget) {
      this.chatBodyInputTarget.value = ""
      if (this.hasChatMessagesListTarget) {
        this.chatMessagesListTarget.scrollTop = this.chatMessagesListTarget.scrollHeight
      }
    }
    this.ensureRootUrlLocked()
  }

  resetBranchInput(event) {
    if (event.detail?.success && this.hasBranchNameInputTarget) {
      this.branchNameInputTarget.value = ""
    }
    this.ensureRootUrlLocked()
  }

  pulseCrdtCheckout() {
    const badge = document.getElementById("top_bar_crdt_status_label")?.closest("button")
    if (badge) {
      badge.classList.add("border-[#14b8a6]", "text-[#2dd4bf]")
      setTimeout(() => {
        badge.classList.remove("border-[#14b8a6]", "text-[#2dd4bf]")
      }, 1400)
    }
    this.ensureRootUrlLocked()
  }

  ensureRootUrlLocked() {
    if (window.location.pathname !== "/" || window.location.search !== "" || window.location.hash !== "") {
      window.history.replaceState(window.history.state, "", "/")
    }
  }
}


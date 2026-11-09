import { Controller } from "@hotwired/stimulus"

// Controls the Right-Side "Studio Auth" Slide-Over Drawer:
// Slide-in / slide-out animation + dark translucent backdrop dimming,
// Esc key dismissal, Sign Up <-> Sign In tab switching, and password visibility toggle.
export default class extends Controller {
  static targets = [
    "backdrop",
    "panel",
    "tabButton",
    "googleButtonLabel",
    "signupPanel",
    "signinPanel",
    "signupPasswordInput",
    "signupConfirmInput",
    "signinPasswordInput"
  ]

  initialize() {
    this.isOpen = false
    this.activeTab = "signup"
  }

  open() {
    this.isOpen = true
    if (this.hasBackdropTarget) {
      this.backdropTarget.classList.remove("hidden", "opacity-0", "pointer-events-none")
      this.backdropTarget.classList.add("opacity-100", "pointer-events-auto")
    }
    if (this.hasPanelTarget) {
      this.panelTarget.classList.remove("hidden", "translate-x-full")
      this.panelTarget.classList.add("translate-x-0")
    }
    this.ensureRootUrlLocked()
  }

  close() {
    this.isOpen = false
    if (this.hasBackdropTarget) {
      this.backdropTarget.classList.remove("opacity-100", "pointer-events-auto")
      this.backdropTarget.classList.add("opacity-0", "pointer-events-none", "hidden")
    }
    if (this.hasPanelTarget) {
      this.panelTarget.classList.remove("translate-x-0")
      this.panelTarget.classList.add("translate-x-full", "hidden")
    }
    this.ensureRootUrlLocked()
  }

  switchTab(event) {
    const selectedTab = event.currentTarget.dataset.tab
    if (!selectedTab) return
    this.activeTab = selectedTab

    this.tabButtonTargets.forEach((btn) => {
      const active = btn.dataset.tab === selectedTab
      btn.setAttribute("aria-selected", active ? "true" : "false")
      btn.className = `py-1.5 px-3 rounded-md text-xs font-medium transition cursor-pointer ${
        active
          ? "bg-[#211811] border border-[#6b4926] text-[#f3be7a] shadow-sm"
          : "text-[#8e8a83] hover:text-white border border-transparent"
      }`
    })

    if (this.hasGoogleButtonLabelTarget) {
      this.googleButtonLabelTarget.textContent =
        selectedTab === "signin" ? "Sign In with Google" : "Sign Up with Google"
    }

    if (this.hasSignupPanelTarget && this.hasSigninPanelTarget) {
      if (selectedTab === "signin") {
        this.signupPanelTarget.classList.add("hidden")
        this.signinPanelTarget.classList.remove("hidden")
      } else {
        this.signinPanelTarget.classList.add("hidden")
        this.signupPanelTarget.classList.remove("hidden")
      }
    }

    this.ensureRootUrlLocked()
  }

  togglePassword(event) {
    const targetName = event.currentTarget.dataset.targetInput
    let inputEl = null
    if (targetName === "signupPasswordInput" && this.hasSignupPasswordInputTarget) {
      inputEl = this.signupPasswordInputTarget
    } else if (targetName === "signinPasswordInput" && this.hasSigninPasswordInputTarget) {
      inputEl = this.signinPasswordInputTarget
    }

    if (!inputEl) return
    const nextType = inputEl.type === "password" ? "text" : "password"
    inputEl.type = nextType
    event.currentTarget.classList.toggle("text-[#f59e0b]", nextType === "text")
  }

  triggerGoogleOauth() {
    // Focuses username/login field if local Google OAuth client credentials are not configured
    if (this.activeTab === "signin" && this.hasSigninPanelTarget) {
      this.signinPanelTarget.querySelector("input")?.focus()
    } else if (this.hasSignupPanelTarget) {
      this.signupPanelTarget.querySelector("input")?.focus()
    }
  }

  ensureRootUrlLocked() {
    if (window.location.pathname !== "/" || window.location.search !== "" || window.location.hash !== "") {
      window.history.replaceState(window.history.state, "", "/")
    }
  }
}


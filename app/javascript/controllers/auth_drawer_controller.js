import { Controller } from "@hotwired/stimulus"

// Controls the Right-Side "Studio Auth" Slide-Over Drawer:
// Slide-in / slide-out animation + dark translucent backdrop dimming,
// Esc key dismissal, Guest Sign Up <-> Sign In tab switching,
// Authenticated Identity <-> Roles & ACL tab switching, inline @username editing,
// auto-submitting RBAC role/tier selectors, and password visibility toggle.
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
    "signinPasswordInput",
    "authTabButton",
    "identityTabPanel",
    "rolesAclTabPanel",
    "usernameDisplay",
    "usernameEditForm",
    "usernameInput",
    "roleTierForm",
    "syncAclIcon",
    "syncAclLabel"
  ]

  initialize() {
    this.isOpen = false
    this.activeTab = "signup"
    this.activeAuthTab = "identity"
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

  switchAuthTab(event) {
    const selectedAuthTab = event.currentTarget.dataset.authTab
    if (!selectedAuthTab) return
    this.activeAuthTab = selectedAuthTab

    this.authTabButtonTargets.forEach((btn) => {
      const active = btn.dataset.authTab === selectedAuthTab
      btn.setAttribute("aria-selected", active ? "true" : "false")
      btn.className = `py-1.5 px-3 rounded-md text-xs font-medium flex items-center justify-center gap-1.5 transition cursor-pointer ${
        active
          ? "bg-[#211811] border border-[#6b4926] text-[#f3be7a] shadow-sm"
          : "text-[#8e8a83] hover:text-white border border-transparent"
      }`
    })

    if (this.hasIdentityTabPanelTarget && this.hasRolesAclTabPanelTarget) {
      if (selectedAuthTab === "roles_acl") {
        this.identityTabPanelTarget.classList.add("hidden")
        this.rolesAclTabPanelTarget.classList.remove("hidden")
      } else {
        this.rolesAclTabPanelTarget.classList.add("hidden")
        this.identityTabPanelTarget.classList.remove("hidden")
      }
    }

    this.ensureRootUrlLocked()
  }

  toggleUsernameEdit() {
    if (!this.hasUsernameEditFormTarget) return
    const isHidden = this.usernameEditFormTarget.classList.contains("hidden")
    if (isHidden) {
      this.usernameEditFormTarget.classList.remove("hidden")
      this.usernameEditFormTarget.classList.add("flex")
      if (this.hasUsernameInputTarget) {
        this.usernameInputTarget.focus()
        this.usernameInputTarget.select()
      }
    } else {
      this.usernameEditFormTarget.classList.remove("flex")
      this.usernameEditFormTarget.classList.add("hidden")
    }
    this.ensureRootUrlLocked()
  }

  submitRoleTier(event) {
    const form = event.currentTarget.closest("form")
    if (form && typeof form.requestSubmit === "function") {
      form.requestSubmit()
    }
    this.ensureRootUrlLocked()
  }

  syncAcl() {
    if (this.hasSyncAclLabelTarget) {
      this.syncAclLabelTarget.textContent = "Synced"
      setTimeout(() => {
        if (this.hasSyncAclLabelTarget) {
          this.syncAclLabelTarget.textContent = "Sync ACL"
        }
      }, 1200)
    }
    this.ensureRootUrlLocked()
  }

  resetCollaboratorForm(event) {
    if (event.detail?.success && event.target && typeof event.target.reset === "function") {
      event.target.reset()
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

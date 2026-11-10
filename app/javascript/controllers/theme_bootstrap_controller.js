import { Controller } from "@hotwired/stimulus"

const VALID_THEMES = ["midnight", "saffron", "frost"]

// Studio Theme Bootstrap & SPA URL Cloaking Guard
export default class extends Controller {
  connect() {
    this.applySavedTheme()
  }

  applySavedTheme() {
    let saved = "midnight"
    try {
      const stored = window.localStorage.getItem("jaku-studio-theme")
      if (stored && VALID_THEMES.includes(stored)) saved = stored
    } catch (_e) {
      // Ignore storage errors in restricted environments
    }

    const root = document.documentElement
    root.setAttribute("data-theme", saved)
    root.classList.remove("theme-midnight", "theme-saffron", "theme-frost", "dark", "light")
    root.classList.add(`theme-${saved}`, saved === "frost" ? "light" : "dark")

    if (document.body) {
      document.body.setAttribute("data-theme", saved)
    }
    const frame = document.getElementById("jaku_workstation")
    if (frame) {
      frame.setAttribute("data-theme", saved)
      frame.setAttribute("data-workstation-theme-value", saved)
    }
  }

  lockRootUrl() {
    this.applySavedTheme()
    if (window.location.pathname !== "/" || window.location.search !== "" || window.location.hash !== "") {
      window.history.replaceState(window.history.state, "", "/")
    }
  }

  injectSpaHeader(event) {
    if (event.detail?.fetchOptions?.headers) {
      event.detail.fetchOptions.headers["X-Jaku-SPA"] = "true"
    }
  }
}

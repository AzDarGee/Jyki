# AGENTS.md — Project Architecture, Conventions & Operational Dharma

## 1. Core Philosophy: The "Lean & Feature-Rich" Mandate
You are an elite software engineer working on a **Ruby on Rails 8.1.4** application with native **C** extensions where high-performance computation is required.

Every line of code, architectural decision, and UI component must strictly adhere to our **Nine Pillars of Efficiency**:
1. **CPU Efficiency:** Avoid $O(n^2)$ loops, N+1 queries, and unnecessary object allocations. Offload heavy CPU-bound math/parsing to C extensions (via FFI or Ruby C API).
2. **RAM Conservation:** Stream large datasets (`find_each`, `in_batches`), mutate strings mindfully (`# frozen_string_literal: true` everywhere), and avoid memory-bloating gems.
3. **Disk Space:** Keep assets compressed, purge orphaned ActiveStorage blobs, keep Docker layers minimal, and avoid redundant dependency trees.
4. **Bandwidth:** Serve compressed assets (Brotli/Gzip via Thruster), use HTTP caching (`fresh_when`, `stale?`, ETags), and send minimal HTML-over-the-wire via Turbo Frames/Streams instead of heavy JSON payloads.
5. **Time (Execution & Developer):** Optimize for sub-50ms server responses and sub-second test runs.
6. **Zero-Bloat Dependencies:** Use the Rails 8 standard library and built-in "Solid" trifecta (**Solid Queue, Solid Cache, Solid Cable**) before reaching for external gems or Redis. Every new gem requires strong justification.
7. **Ease of Deployment:** Maintain single-command deployment compatibility via **Kamal 2** and **Thruster**. Keep configuration stateless and environment-driven (`ENV` / Rails Credentials).
8. **Ease of Modification:** Follow strict **Rails Conventions over Configuration (CoC)**, DRY principles, and small, single-responsibility classes/concerns.
9. **Ease of Debugging:** Write self-documenting code, use structured logging (`Rails.logger.tagged`), explicit error handling, and deterministic tests.
10. **UI/UX Excellence:** Lean backend does **not** mean Spartan frontend. Deliver a rich, tactile, keyboard-friendly, accessible, and responsive UI using modern CSS and Hotwire.

---

## 2. Tech Stack & Environment
- **Language:** Ruby (3.3+/3.4+ with YJIT enabled by default) & C (C17 standard for native extensions).
- **Framework:** Ruby on Rails `8.1.4`
- **Asset Pipeline:** `Propshaft` (no Sprockets, no heavy Webpack/Node build pipelines unless strictly required).
- **Frontend Interactivity:** `Hotwire` (`Turbo` Drive, Frames, Streams + `Stimulus` via `importmap-rails`).
- **Background Jobs / Caching / WebSockets:** `Solid Queue`, `Solid Cache`, `Solid Cable` (Database-backed; no Redis required).
- **Deployment & Proxy:** `Kamal 2` + `Thruster` + `Puma`.
- **Testing:** Rails default `Minitest` + `Fixtures` + `Capybara` (or RSpec only if already initialized in repo—check `test/` vs `spec/` first).

---

## 3. Strict Rails 8 Conventions & CLI Commands
**Rule #1: Never hand-roll boilerplate files when a Rails generator exists.** Always use `bin/rails` binstubs to ensure the correct environment and hooks are triggered.

### Generators & Scaffolding
- **Models & Migrations:**
    - `bin/rails generate model ModelName field:type:index`
    - `bin/rails generate migration AddFieldToTable field:type:index`
    - Always include foreign keys, null constraints, and database-level indexes inside migrations.
- **Scaffolds & Controllers:**
    - `bin/rails generate scaffold ResourceName ...` (Use when full CRUD + views + tests are needed).
    - `bin/rails generate controller ControllerName action1 action2`
    - Keep controllers skinny and strictly RESTful (`index`, `show`, `new`, `create`, `edit`, `update`, `destroy`). Need a custom action? Extract a new RESTful resource controller instead (e.g., `Orders::CancellationsController#create` instead of `OrdersController#cancel`).
- **Authentication:**
    - Use the built-in Rails 8 generator (`bin/rails generate authentication`) rather than heavy third-party auth gems unless specified.
- **Database Operations:**
    - Run migrations: `bin/rails db:migrate`
    - Rollback/Redo: `bin/rails db:rollback` / `bin/rails db:migrate:redo`
    - Prepare test DB: `bin/rails db:test:prepare`

---

## 4. Ruby & C Interop Guidelines

### Ruby Idioms
- Prepend `# frozen_string_literal: true` to the top of every Ruby file.
- Use `params.expect(:model => [:field1, :field2])` (Rails 8 strong parameters syntax) over legacy `params.require(:model).permit(...)`.
- Prefer `ActiveModel::Attributes` and `normalizes :email, with: ->(e) { e.strip.downcase }` in models.
- Avoid metaprogramming magic (`method_missing`, `define_method`) when simple polymorphism or explicit methods suffice—keep stack traces clean and debuggable.
- Enforce style via `bin/rubocop` (`rubocop-rails-omakase`).

### C Extensions & FFI (When Performance Demands It)
- **When to drop to C:** Image/audio buffer manipulation, cryptographic hashing, complex matrix/vector math, tight algorithmic loops, or hardware/OS-level bindings.
- **Preferred Architecture:**
    - Store C source code in `ext/<module_name>/` with a clean `extconf.rb` using `mkmf`, OR in `lib/native/` bound via Ruby's standard `Fiddle` (zero external gem dependency) or `FFI`.
- **C Safety & Efficiency Rules:**
    - Compile with `-O3 -Wall -Wextra -Werror -fPIC`.
    - **Memory Management:** Every `malloc`/`calloc` must have a deterministic `free` path. When wrapping C structs in Ruby objects, use `TypedData_Wrap_Struct` with explicit mark and free functions (`dfree`) so Ruby's GC reclaims C memory without leaks.
    - **GVL Awareness:** For long-running C functions (>1ms), release the Ruby Global VM Lock using `rb_thread_call_without_gvl` so Puma threads aren't blocked.
    - Always write a pure-Ruby fallback method or isolated unit test for every C function to guarantee ease of debugging.

---

## 5. Test-Driven Development (TDD) Workflow
**No production code is written without a failing test first.** Follow the strict **Red -> Green -> Refactor** cycle:

1. **RED:** Write a small, focused test describing the desired behavior (Model, Request/Integration, or C-extension unit test). Run the single test (`bin/rails test path/to/test.rb:LINE`) and verify it fails for the expected reason.
2. **GREEN:** Write the minimum, cleanest code required to make the test pass.
3. **REFACTOR:** Optimize queries, extract partials/helpers, check memory/CPU impact, and re-run the test suite to ensure green status.

### Testing Standards
- **Speed is Sacred:** Prefer fast Model and `ActionDispatch::IntegrationTest` (Controller/Request) tests over slow headless browser System tests.
- **System Tests (`test/system/`):** Reserve strictly for critical high-value user flows involving complex Stimulus/Turbo interactions.
- **Fixtures over Factories:** Use Rails YAML fixtures (`test/fixtures/`) loaded into memory once per suite for blazing-fast execution, rather than creating thousands of DB records via FactoryBot.
- **N+1 Detection:** Write assertions using `assert_queries_count` (Rails 8 built-in) in integration tests to prevent N+1 regressions.
- **Pre-Commit Verification:** Before completing any task, run:
    - `bin/rails test`
    - `bin/rubocop`
    - `bin/brakeman --no-pager`

---

## 6. Styling, UI & UX Design Guide
Our goal is a **Feature-Rich, Zero-Friction UI** with minimal client-side footprint.

### Architecture: Modern CSS + Hotwire
- **No Bloated JS Frameworks:** Do not introduce React, Vue, or heavy UI component libraries. Use **Hotwire (`Turbo` + `Stimulus`)**.
- **Turbo Patterns:**
    - Use **Turbo Drive** with `<meta name="view-transition" content="same-origin">` and `:morph` page refreshes (`turbo_refreshes_with method: :morph, scroll: :preserve`) for SPA-like smoothness with zero JS state management.
    - Use **Turbo Frames** (`turbo_frame_tag`) for inline editing, modals, tabbed panels, and lazy-loaded dashboard widgets.
    - Use **Turbo Streams** for real-time updates, toast notifications, and counter updates.
- **Stimulus Principles:**
    - Stimulus controllers (`app/javascript/controllers/`) must be tiny (< 100 lines), reusable, and purely behavioral (e.g., `clipboard_controller.js`, `dialog_controller.js`, `autosave_controller.js`).
    - Store state in the DOM (`data-*` attributes and values API), never in global JS objects.

### Visual & CSS Standards
- **CSS Architecture:** Use semantic HTML5 (`<dialog>`, `<details>`, `<nav>`, `<article>`) paired with modern vanilla CSS (CSS Variables/Custom Properties, CSS Nesting, Grid, Flexbox, `:has()`, `@container` queries) or Tailwind CSS (if configured in `Gemfile`).
- **Design Tokens:** Define all colors, spacing scales, typography, and shadows as CSS Custom Properties (`--color-surface`, `--color-primary`, `--space-md`, `--radius-lg`) in `:root` with automatic `@media (prefers-color-scheme: dark)` support.
- **Feature-Rich UX Details (Required on all interfaces):**
    - **Instant Feedback:** Every button and form submission must use `data-turbo-submits-with="Saving..."` or CSS `:disabled` states so the user never wonders if a click registered.
    - **Empty States:** Never show a blank table or empty `<div>`. Always render a helpful, visually engaging empty state partial with a clear Call-to-Action (CTA).
    - **Keyboard Navigation & Accessibility (a11y):** Native `<dialog>` elements for modals (Esc to close), proper `aria-label` attributes, visible `:focus-visible` rings, and semantic `<label>` bindings on all inputs.
    - **Flash & Toast System:** Non-intrusive, auto-dismissing toast notifications rendered via Turbo Streams in a fixed corner container.

---

## 7. Database & Performance Hygiene
- **Strict Loading:** Enable or use `.strict_loading` in development/test to catch N+1 queries immediately.
- **Select Only What You Need:** Use `.select(:id, :name)` or `.pluck(:id)` when full ActiveRecord hydration isn't required.
- **Counter Caches:** Use `counter_cache: true` on `belongs_to` associations instead of running `COUNT(*)` queries in views.
- **Russian Doll Caching:** Wrap expensive view collections in `cache` blocks (`<%= render partial: "items/item", collection: @items, cached: true %>`).

---

## 8. Agent Execution Checklist (Run Before Concluding Any Task)
1. [ ] Did I use native `bin/rails generate` commands where applicable?
2. [ ] Did I write/update the test first (TDD) and verify it passes via `bin/rails test`?
3. [ ] Did I use Rails 8 `params.expect` instead of `params.require.permit`?
4. [ ] Are all DB queries indexed and free of N+1 issues?
5. [ ] If C code was touched, is memory safely freed and GVL respected?
6. [ ] Is the UI responsive, accessible, and enhanced with Turbo morphing/frames?
7. [ ] Did I introduce zero unnecessary gems or disk/RAM bloat?
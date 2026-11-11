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
- **Language:** Ruby `4.0.9` (`.ruby-version`, with YJIT/PRISM enabled) & C (C23 standard for native extensions and Wasm32 DSP kernels).
- **Framework:** Ruby on Rails `8.1.4` (`8.1.4.1` in `Gemfile.lock`).
- **Database:** PostgreSQL (`pg ~> 1.1`). Single-database setup in `development` (`jyki_development`) and `test` (`jyki_test`) hosting both primary application tables (`users`) and the Solid trifecta schemas (`db/schema.rb`, `db/queue_schema.rb`, `db/cache_schema.rb`, `db/cable_schema.rb`).
- **Authentication:** `Devise ~> 5.0.4` + `OmniAuth` (`omniauth-google-oauth2`, `omniauth-rails_csrf_protection`) configured on `User` (`app/models/user.rb`).
- **Asset & Styling Pipeline:** `Propshaft` + two-stage **Saanskara CSS Pipeline** (`bin/css-pipeline`): Rust Cargo `grass` compiles `app/assets/scss/application.scss` -> `app/assets/tailwind/scss_compiled.css` (gitignored), then `tailwindcss-rails` (Tailwind v4) compiles `app/assets/tailwind/application.css` -> `app/assets/builds/tailwind.css` (gitignored).
- **Frontend Interactivity:** `Hotwire` (`Turbo` + `Stimulus` via `importmap-rails`, plus `hotwire-spark` in development) and HTML5 `<canvas>` 2D rendering reading live `--saanskara-*` CSS Custom Properties (`app/views/home/index.html.erb`).
- **Background Jobs / Caching / WebSockets:** `Solid Queue`, `Solid Cache`, `Solid Cable` (PostgreSQL-backed; no Redis required). Note: `config/environments/development.rb` overrides `config.cache_store = :memory_store` later in the file, and `config/environments/test.rb` uses `:null_store`.
- **Deployment & Proxy:** `Kamal 2` + `Thruster` + `Puma`.
- **Testing:** Rails default `Minitest` (`test/`) + `Fixtures` + `Capybara` / `selenium-webdriver`.

### Implemented Repository State vs. Aspirational `ARCHITECTURE.md`
Always prioritize actual repository code over `ARCHITECTURE.md`. `ARCHITECTURE.md` is a long-term design vision for the **Jæku / Saanskara Studio DAW**; many items in it are **not yet implemented** in the Rails app:
- **Implemented in `app/`, `config/`, `db/`, `lib/`:**
  - Rails 8.1 app shell with `HomeController#index` (`root "home#index"`) rendering the Saanskara Studio DAW UI shell (`app/views/home/index.html.erb`), Raga theme switcher (`midnight`, `saffron`, `frost` via `[data-theme]` and `--saanskara-*` tokens), and a 60fps HTML5 `<canvas>` waveform visualizer.
  - Devise `User` model (`confirmable`, `lockable`, `timeoutable`, `trackable`, `omniauthable`, `stretches: 8` in `app/models/user.rb`) and views under `app/views/devise/`. The model-level option overrides the initializer's global `stretches: 1` in every environment, including test; test hashing uses cost 8 unless the model option is removed or made environment-conditional.
  - Custom SCSS (`app/assets/scss/{abstracts,themes,base,components}/`) + Tailwind v4 build pipeline (`bin/css-pipeline`, `bin/scss-new`, `lib/tasks/css_pipeline.rake`).
  - `Middleware::ChromeDevTools` (`lib/middleware/chrome_devtools.rb`) serving `/.well-known/appspecific/com.chrome.devtools.json` in development.
- **Standalone Prototypes in `research/` (Not wired into Rails `app/`):**
  - `research/dsp/dsp_pipeline.rb`: Self-compiling Ruby + inline C23 DSP arena pipeline (HPF, LPF, gain, soft-clip saturation, power-of-two ring-buffer comb delay, peak/RMS/DC telemetry) bound via Ruby stdlib `Fiddle` (`@handle.free = SaanskaraDSP['dsp_destroy']`).
  - `research/dsp/dsp_forge.rb` & `research/dsp/build_dsp.rb`: Compile C23 DSP kernels to native `.so` (`clang/gcc -std=c23 -O3 -ffast-math -shared -fPIC`) for Ruby `Fiddle` and `.wasm` (`clang -std=c23 --target=wasm32 ... -nostdlib -Wl,--no-entry -Wl,--export-dynamic`) with 16-byte binary delta packets (`pack("CCs<fff")`) and `AudioWorkletProcessor` JS glue.
  - `research/benchmark.rb` & `research/multi_core.rb`: 128-sample Web Audio render quantum and pthreads benchmarks.
- **Aspirational Only in `ARCHITECTURE.md` (Do NOT assume present):**
  - React, Zustand, Framer Motion (`motion/react`), Yjs / Automerge CRDTs, `y-webrtc`, `y-indexeddb`, OPFS storage, Firebase/Firestore, BullMQ, Redis, WebGPU shaders, and native Swift/Kotlin/Windows clients are design notes only and do not exist in the codebase.

---

## 2A. Build, Setup & Configuration Instructions

### Initial Setup & Database Preparation
1. **Prerequisites:**
   - Ruby `4.0.9` (via `rbenv`), Bundler, PostgreSQL running locally on port 5432.
   - Rust/Cargo `grass` CLI (`~/.cargo/bin/grass` or `cargo install grass_cli`) for SCSS compilation.
   - `gcc` (and optionally `clang` + `wasm-ld` / `lld` for WebAssembly targets in `research/dsp/`).
2. **Bootstrap Command:**
   ```bash
   bin/setup --skip-server
   ```
   This checks/installs gems (`bundle check || bundle install`), prepares PostgreSQL databases (`bin/rails db:prepare`), and clears `log/` and `tmp/`.
3. **Solid Trifecta Schema Loading (if setting up fresh DBs manually):**
   `config/database.yml` maps `primary`, `cache`, `queue`, and `cable` to `jyki_development` (and `jyki_test` in test). All tables are already consolidated in `db/schema.rb`, or can be loaded individually via:
   ```bash
   bin/rails runner "load 'db/queue_schema.rb'"
   bin/rails runner "load 'db/cache_schema.rb'"
   bin/rails runner "load 'db/cable_schema.rb'"
   ```

### Running the Development Environment & CSS Pipeline
- **Start Web + CSS Watchers (`Procfile.dev`):**
  ```bash
  bin/dev
  ```
  Runs `bin/rails server` and `bin/css-pipeline --watch` via Foreman.
- **One-off Production/Minified CSS Build:**
  ```bash
  bin/css-pipeline
  ```
  1. Runs `grass` (`~/.cargo/bin/grass`, auto-installing `grass_cli` via Cargo if missing) on `app/assets/scss/application.scss` -> `app/assets/tailwind/scss_compiled.css` (~4–18ms).
  2. Runs `bundle exec tailwindcss -i app/assets/tailwind/application.css -o app/assets/builds/tailwind.css --minify` (~95ms).
  3. `lib/tasks/css_pipeline.rake` overrides `tailwindcss:build` to invoke `bin/css-pipeline` and enhances `assets:precompile`.
- **Scaffold a New SCSS Partial:**
  ```bash
  bin/scss-new [component|theme|base] <name>
  ```
  Creates `app/assets/scss/<type>s/_<name>.scss` with the appropriate `@use` header (`@use "theme_engine" as *;` for themes, `@use "../abstracts" as *;` for components/base) and appends `@forward "<name>";` to `app/assets/scss/<type>s/_index.scss`.
- **WSL2 / Cross-Platform Binstub Line Endings:**
  If creating or editing files in `bin/`, strip `\r` line endings so `/usr/bin/env` does not fail:
  ```bash
  ruby -i -pe 'gsub(/\r$/, "")' bin/* && chmod +x bin/*
  ```

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
    - **Repository Note:** While Rails 8 offers `bin/rails generate authentication`, this project is already configured with **Devise (`~> 5.0.4`)** + **OmniAuth (`omniauth-google-oauth2`)** on `User` (`app/models/user.rb`, `config/initializers/devise.rb`, `app/views/devise/`). Do not run `bin/rails generate authentication` unless migrating away from Devise.
- **Database Operations:**
    - Run migrations: `bin/rails db:migrate`
    - Rollback/Redo: `bin/rails db:rollback` / `bin/rails db:migrate:redo`
    - Prepare test DB: `bin/rails db:test:prepare`

---

## 4. Ruby & C Interop Guidelines

### Ruby Idioms & RuboCop (`rubocop-rails-omakase`)
- Prepend `# frozen_string_literal: true` to the top of every Ruby file.
- Use `params.expect(:model => [ :field1, :field2 ])` (Rails 8 strong parameters syntax) over legacy `params.require(:model).permit(...)`.
- Prefer `ActiveModel::Attributes` and `normalizes :email, with: ->(e) { e.strip.downcase }` in models.
- Avoid metaprogramming magic (`method_missing`, `define_method`) when simple polymorphism or explicit methods suffice—keep stack traces clean and debuggable.
- Enforce style via `bin/rubocop` (inherits `rubocop-rails-omakase` in `.rubocop.yml`):
    - **Array Literal Brackets (`Layout/SpaceInsideArrayLiteralBrackets`):** Non-empty array literals MUST have spaces inside brackets (`[ a, b ]`, NOT `[a, b]`). Empty arrays have no space (`[]`).
    - **String Literals (`Style/StringLiterals`):** Use double-quoted strings (`"..."`) unless single quotes avoid escaping.
    - **Final Newline (`Layout/TrailingEmptyLines`):** Every file must end with a single trailing newline.

### C Extensions & FFI (When Performance Demands It)
- **When to drop to C:** Image/audio buffer manipulation, cryptographic hashing, complex matrix/vector math, tight algorithmic loops, or hardware/OS-level bindings.
- **Preferred Architecture:**
    - Store C source code in `ext/<module_name>/` with a clean `extconf.rb` using `mkmf`, OR in `lib/native/` bound via Ruby's standard `Fiddle` (zero external gem dependency, as demonstrated in `research/dsp/dsp_pipeline.rb`) or `FFI`.
    - When using `Fiddle` with heap-allocated C structs/arenas, bind the C destructor directly to `Fiddle::Pointer#free=` (e.g., `@handle.free = NativeLib["dsp_destroy"]`) so Ruby's GC reclaims C memory automatically.
- **C Safety & Efficiency Rules:**
    - Compile with `-std=c23 -O3 -Wall -Wextra -Werror -fPIC` (and `-ffast-math` for non-NaN DSP audio kernels; use `clang -std=c23 --target=wasm32 -O3 -ffast-math -nostdlib -Wl,--no-entry -Wl,--export-dynamic` when dual-targeting Browser `AudioWorklet` WebAssembly).
    - **Memory Management:** Prefer static/arena buffers (`zero-malloc` in real-time audio callbacks) or ensure every `malloc`/`calloc` has a deterministic `free` path (`TypedData_Wrap_Struct` with `dfree` or `Fiddle::Pointer#free`).
    - **GVL Awareness:** For long-running C functions (>1ms), release the Ruby Global VM Lock using `rb_thread_call_without_gvl` so Puma threads aren't blocked.
    - Always write a pure-Ruby fallback method or isolated unit test for every C function to guarantee ease of debugging.

---

## 5. Test-Driven Development (TDD) Workflow & Repository Test Harness
**No production code is written without a failing test first.** Follow the strict **Red -> Green -> Refactor** cycle:

1. **RED:** Write a small, focused test describing the desired behavior (Model, Request/Integration, or C-extension unit test). Run the single test (`CI= bin/rails test path/to/test.rb:LINE`) and verify it fails for the expected reason.
2. **GREEN:** Write the minimum, cleanest code required to make the test pass.
3. **REFACTOR:** Optimize queries, extract partials/helpers, check memory/CPU impact, and re-run the test suite to ensure green status.

### Configuring & Running Tests
- **Prepare Test Database (`jyki_test`):**
  ```bash
  CI= bin/rails db:test:prepare
  ```
- **Run a Single Test File or Line (Fastest Feedback Loop, <0.25s):**
  ```bash
  CI= bin/rails test test/controllers/home_controller_test.rb
  CI= bin/rails test test/controllers/home_controller_test.rb:8
  ```
- **Run Full Test Suite:**
  ```bash
  CI= bin/rails test
  ```

### Critical Repository Test Harness Gotchas
1. **`CI` Environment Variable & Zeitwerk Eager-Loading (`Middleware::ChromeDevTools`):**
   - `config/environments/test.rb` sets `config.eager_load = ENV["CI"].present?`.
   - `config/application.rb` sets `config.autoload_lib(ignore: %w[assets tasks])` (note `middleware` is not ignored) and manually requires `../lib/middleware/chrome_devtools`.
   - `lib/middleware/chrome_devtools.rb` defines `Middleware::ChromeDevTools` (capital `T` in `DevTools`), while Zeitwerk's default inflector expects `Middleware::ChromeDevtools` (lowercase `t`).
   - **Impact:** Whenever `CI` is set in the environment (including automated agent shells or CI runners), `bin/rails test` triggers `Zeitwerk::Loader.eager_load_all` and aborts before running any tests with:
     `NameError: uninitialized constant Middleware::ChromeDevtools (Did you mean? Middleware::ChromeDevTools)`.
   - **Workaround / Fix:** Prefix test commands with `CI=` (e.g., `CI= bin/rails test ...`) when not modifying autoload config, or add `"middleware"` to `config.autoload_lib(ignore: %w[assets tasks middleware])` in `config/application.rb` (or register `"devtools" => "DevTools"` in `config/initializers/inflections.rb`) if tasked with fixing CI eager loading.
2. **Default `test/fixtures/users.yml` Unique Index Collision:**
   - `test/test_helper.rb` enables `fixtures :all` across all `ActiveSupport::TestCase` subclasses.
   - `test/fixtures/users.yml` currently contains two empty scaffold records (`one: {}` and `two: {}`).
   - Because `users.email` has `default: "", null: false` and a unique index (`index_users_on_email` in `db/schema.rb`), loading `users.yml` inserts two rows with `email = ""` and fails during `before_setup` with:
     `ActiveRecord::RecordNotUnique: PG::UniqueViolation: ERROR: duplicate key value violates unique constraint "index_users_on_email"`.
   - **Workaround / Fix:** Until `test/fixtures/users.yml` is updated with distinct `email` attributes (e.g., `one: { email: "one@example.com" }`, `two: { email: "two@example.com" }`), set `self.fixture_table_names = []` inside test classes when `test/fixtures/users.yml` is unmodified, or update `test/fixtures/users.yml` with unique emails when adding User fixtures.

### Verified Red -> Green Test Walkthrough
Use the existing test scaffolds and keep request and model behavior in separate tests. The temporary test files used to verify this walkthrough were removed; no additional test file is intended to remain in the project.

For `test/controllers/home_controller_test.rb`, add a single request test. Keep `self.fixture_table_names = []` while the empty `test/fixtures/users.yml` records still collide on their unique email index.
```ruby
# frozen_string_literal: true

require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  self.fixture_table_names = []

  test "renders Saanskara Studio DAW shell" do
    get root_url
    assert_response :success
    assert_select "#saanskara-daw .daw-transport-bar", /Saanskara Studio DAW/
  end
end
```

For the RED step, temporarily use an assertion for content that does not exist:
```ruby
assert_select "#saanskara-daw .daw-transport-bar", /NonExistentHeaderText/
```
Run the request test at the assertion line (`11` in the example above):
```bash
CI= bin/rails test test/controllers/home_controller_test.rb:11
# => failure: expected /NonExistentHeaderText/, got the rendered “Saanskara Studio DAW ...” text
#    1 runs, 3 assertions, 1 failures, 0 errors, 0 skips
```
The failure confirms the request renders a different header than the intentionally incorrect expectation. For GREEN, change that assertion to `/Saanskara Studio DAW/` as shown in the request-test example above:
```bash
CI= bin/rails test test/controllers/home_controller_test.rb
# => 1 run, 3 assertions, 0 failures, 0 errors, 0 skips
```

For `test/models/user_test.rb`, use `ActiveSupport::TestCase` and keep the same fixture workaround if the class does not need fixtures:
```ruby
# frozen_string_literal: true

require "test_helper"

class UserTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  test "validates Devise user email presence" do
    user = User.new(email: "", password: "password123")
    assert_not user.valid?
    assert_includes user.errors[:email], "can't be blank"
  end
end
```
Run the model test independently:
```bash
CI= bin/rails test test/models/user_test.rb
# => 1 run, 3 assertions, 0 failures, 0 errors, 0 skips
```

### Testing Standards
- **Speed is Sacred:** Prefer fast Model and `ActionDispatch::IntegrationTest` (Controller/Request) tests over slow headless browser System tests. Note that `test/test_helper.rb` configures `parallelize(workers: :number_of_processors)` (default threshold is 50 tests).
- **System Tests (`test/system/`):** Reserve strictly for critical high-value user flows involving complex Stimulus/Turbo interactions.
- **Fixtures over Factories:** Use Rails YAML fixtures (`test/fixtures/`) loaded into memory once per suite for blazing-fast execution, rather than creating thousands of DB records via FactoryBot. Ensure every `users.yml` entry has a unique `email`.
- **N+1 Detection:** Write assertions using `assert_queries_count` (Rails 8 built-in) in integration tests to prevent N+1 regressions.
- **Pre-Commit Verification:** Before completing any task, run:
    - `CI= bin/rails test`
    - `bin/rubocop` (or `bin/rubocop path/to/changed_files.rb`—see Section 9 regarding pre-existing repo offenses)
    - `bin/brakeman --no-pager` (or `bin/brakeman --no-pager --skip-files research/`—see Section 9)
    - `bin/bundler-audit` & `bin/importmap audit`

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

### Visual & CSS Standards (Saanskara Theme Engine)
- **SCSS + Tailwind v4 Pipeline:**
    - Author modular styles in `app/assets/scss/` (`abstracts/`, `themes/`, `base/`, `components/`). `app/assets/scss/application.scss` is the manifest (`@use "themes"; @use "base"; @use "components";`).
    - Never edit `app/assets/tailwind/scss_compiled.css` or `app/assets/builds/tailwind.css` directly; both are generated artifacts of `bin/css-pipeline` and are gitignored.
    - `app/views/layouts/application.html.erb` uses `<%= stylesheet_link_tag :app, "data-turbo-track": "reload" %>` which via Propshaft serves `app/assets/builds/tailwind.css`.
- **Design Tokens (`--saanskara-*`):**
    - Themes are registered via `@include register-theme($name, $palette, $is-default)` in `app/assets/scss/themes/_theme_engine.scss`, emitting `--saanskara-<key>` custom properties on `:root` (`midnight` default) and `[data-theme='<name>']` (`midnight`, `saffron`, `frost`).
    - Canvas/WebGL visualizers read live tokens from `getComputedStyle(document.documentElement).getPropertyValue("--saanskara-...")` so theme switches have 0ms latency.
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
2. [ ] Did I write/update the test first (TDD) and verify it passes via `CI= bin/rails test`?
3. [ ] Did I use Rails 8 `params.expect` instead of `params.require.permit`?
4. [ ] Are all DB queries indexed and free of N+1 issues?
5. [ ] If C code was touched, is memory safely freed and GVL respected?
6. [ ] Is the UI responsive, accessible, and enhanced with Turbo morphing/frames?
7. [ ] Did I introduce zero unnecessary gems or disk/RAM bloat?

---

## 9. Additional Development, Linting & Debugging Information

### Pre-Existing Repository Lint & Security Scan Baseline
When running full-repo verification commands (`bin/ci`, `bin/rubocop`, `bin/brakeman`), be aware of the baseline state so you can distinguish pre-existing issues from your changes:
- **`bin/rubocop`:** Currently reports **41 pre-existing offenses** across untouched files (`Gemfile`, `app/controllers/home_controller.rb`, `config/application.rb`, `config/initializers/devise.rb`, `lib/middleware/chrome_devtools.rb`, `lib/tasks/css_pipeline.rake`, and `research/**/*.rb`), primarily `Layout/SpaceInsideArrayLiteralBrackets`, `Style/StringLiterals`, and `Layout/TrailingEmptyLines`. Always run `bin/rubocop <changed_files>` to ensure 0 offenses in files you touch.
- **`bin/brakeman --no-pager`:** Exits with code `3` (5 medium-confidence `Execute` / Command Injection warnings) solely due to `system(...)` C/Wasm compiler invocations inside `research/dsp/build_dsp.rb`, `research/dsp/dsp_forge.rb`, and `research/dsp/dsp_pipeline.rb`. Application code (`app/`, `config/`, `lib/`) has **0 warnings**, verifiable via:
  ```bash
  bin/brakeman --no-pager --skip-files research/
  ```
- **`bin/bundler-audit` & `bin/importmap audit`:** Both pass with 0 vulnerabilities.
- **`bin/ci` (`config/ci.rb`):** Runs `bin/setup --skip-server`, `bin/rubocop`, `bin/bundler-audit`, `bin/importmap audit`, `bin/brakeman`, `bin/rails test`, and `env RAILS_ENV=test bin/rails db:seed:replant`.

### Debugging & Middleware Notes
- **Interactive Debugging:** Both `debug` (`require: "debug/prelude"`) and `pry-rails` are installed in `:development, :test`, plus `web-console` and `hotwire-spark` in `:development`.
- **Browser Restriction:** `ApplicationController` enforces `allow_browser versions: :modern` and `stale_when_importmap_changes`. Custom user-agent strings in integration tests must either omit `User-Agent` (allowed by default) or supply a modern browser UA.
- **Chrome DevTools Workspace Integration:** `Middleware::ChromeDevTools` (`lib/middleware/chrome_devtools.rb`) is mounted in `config/environments/development.rb` and intercepts `GET /.well-known/appspecific/com.chrome.devtools.json`, returning a deterministic UUIDv5 (`Digest::UUID.uuid_v5`) for `Rails.root.to_s`.
- **SharedArrayBuffer / AudioWorklet COOP/COEP Headers:** When wiring `AudioWorklet` + `SharedArrayBuffer` into Rails controllers (per `README.md`), set:
  ```ruby
  response.set_header("Cross-Origin-Opener-Policy", "same-origin")
  response.set_header("Cross-Origin-Embedder-Policy", "credentialless")
  response.set_header("Cross-Origin-Resource-Policy", "same-origin")
  ```
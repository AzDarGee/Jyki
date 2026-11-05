# README

#### Install Dependencies
##### Time Estimate - 10 Hours [i7 Quad Core + GPU Card MacPro15]

0. Install Zsh + Rbenv + Ruby + Install Gemfile + Rust/Crate

1. Install Homebrew LLVM (for C -> Wasm32), LLD linker, and PostgreSQL 18
```bash
brew install llvm lld postgresql@18

# WSL2
sudo apt install llvm lld postgresql@18
```

2. Start PostgreSQL 18 in the background
```bash
brew services start postgresql@18

# WSL2
sudo service postgresql start
sudo service postgresql status
sudo service postgresql stop
```

3. Put Homebrew's LLVM (which has wasm32 support!) & Postgres in your PATH
```bash
echo 'export PATH="$(brew --prefix llvm)/bin:$(brew --prefix lld)/bin:$(brew --prefix postgresql@17)/bin:$PATH"' >> ~/.zshrc
exec zsh
```

4. Audio Worklet - Shared Array Buffer
```ruby
def enable_shared_array_buffer_headers!
    response.set_header("Cross-Origin-Opener-Policy", "same-origin")
    response.set_header("Cross-Origin-Embedder-Policy", "credentialless")
    response.set_header("Cross-Origin-Resource-Policy", "same-origin")
end
```


# Helpers

Login to postgres18
```
psql postgres
```

List db's
```
\l+
```

Create SOLID DBs
```bash
bin/rails runner "load 'db/queue_schema.rb'"
bin/rails runner "load 'db/cable_schema.rb'"
bin/rails runner "load 'db/cache_schema.rb'"
```

When making bin/<file_name> files, make sure to run:
```bash
ruby -i -pe 'gsub(/\r$/, "")' bin/*

# Example
ruby -i -pe 'gsub(/\r$/, "")' bin/css-pipeline
chmod +x bin/css-pipeline
```



# Example Styling Hierarchy
```aiignore
app/assets/scss/
├── application.scss          # The Sutradhara (Entry point — ONLY contains @use statements!)
│
├── abstracts/                # Zero CSS output! Pure SCSS variables, maps, functions, mixins
│   ├── _index.scss           # @forward barrel file so any component only needs `@use "../abstracts" as *;`
│   ├── _tokens.scss          # Core design tokens (spacing, z-indices, DAW grid math, easing curves)
│   ├── _mixins.scss          # Reusable layout/hardware-acceleration/glassmorphism mixins
│   └── _functions.scss       # Custom SCSS math/color functions
│
├── themes/                   # Your Ragas / Visual Moods (Navarasa of the UI)
│   ├── _index.scss           # Forwards all themes
│   ├── _theme_engine.scss    # Mixin that turns an SCSS theme map into CSS custom properties
│   ├── _midnight_studio.scss # Default Dark DAW theme
│   ├── _saffron_dusk.scss    # High-contrast warm creative theme
│   └── _ottawa_frost.scss    # Crisp daylight / studio light theme
│
├── base/                     # PWA shell, viewport locking, scrollbars, typography
│   ├── _index.scss
│   ├── _pwa_shell.scss       # overscroll-behavior: none, user-select: none, touch-action rules
│   └── _scrollbars.scss      # Ultra-thin custom DAW scrollbars
│
└── components/               # Your SPA / DAW UI modules
    ├── _index.scss
    ├── _daw_canvas.scss      # Timeline, grid, playhead, waveform containers
    ├── _transport_bar.scss   # Play, stop, BPM, time signature HUD
    ├── _mixer_rack.scss      # Channel strips, meters, faders, rotary knobs
    └── _floating_modals.scss # Command palette, synth patches, settings drawers
```












#### Lyrix Ideas

C assumes the programmer is an enlightened Rishi who never makes mistakes, never forgets a byte, and desires total liberation (Moksha) from training wheels.

Rust enforces Ahimsa (non-violence) toward memory at compile time.

Let Ruby handle memory management, C never calls malloc or free, elimiting 90% of C bugs.


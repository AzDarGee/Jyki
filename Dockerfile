# syntax=docker/dockerfile:1
# check=error=true

# Global ARGs used in FROM lines MUST be declared before the very first FROM!
ARG RUBY_VERSION=4.0.9

# ============================================================================
# STAGE 1: Universal C++ WebAssembly Builder (Auto-builds ALL synth modules!)
# ============================================================================
FROM emscripten/emsdk:3.1.73 AS wasm-build

WORKDIR /app
ENV IMGUI_VENDOR_DIR="/vendor_imgui" \
    WASM_OUT_DIR="/out"

# 1. Pre-fetch & pre-compile Dear ImGui + ImPlot + imgui-knobs into /vendor_imgui/libimgui_core.a
#    (This Docker layer is cached forever — never re-runs when you add new synths!)
RUN mkdir -p /vendor_imgui /out && \
    git clone --depth 1 -b v1.91.5 https://github.com/ocornut/imgui.git /vendor_imgui/imgui && \
    git clone --depth 1 -b v0.16 https://github.com/epezent/implot.git /vendor_imgui/implot && \
    git clone --depth 1 -b main https://github.com/altschuler/imgui-knobs.git /vendor_imgui/imgui-knobs && \
    for src in \
      /vendor_imgui/imgui/imgui.cpp \
      /vendor_imgui/imgui/imgui_draw.cpp \
      /vendor_imgui/imgui/imgui_tables.cpp \
      /vendor_imgui/imgui/imgui_widgets.cpp \
      /vendor_imgui/imgui/backends/imgui_impl_opengl3.cpp \
      /vendor_imgui/implot/implot.cpp \
      /vendor_imgui/implot/implot_items.cpp \
      /vendor_imgui/imgui-knobs/imgui-knobs.cpp; do \
      em++ -O3 -c "$src" -I/vendor_imgui/imgui -I/vendor_imgui/imgui/backends -I/vendor_imgui/implot -I/vendor_imgui/imgui-knobs -o "${src}.o"; \
    done && \
    emar rcs /vendor_imgui/libimgui_core.a /vendor_imgui/*/*.o /vendor_imgui/imgui/backends/*.o

# 2. Copy ext/ and auto-compile EVERY .cpp module in ext/imgui_synth/ and ext/wasm_modules/!
COPY ext/ ./ext/
RUN for cpp in ext/jyki_synths/*.cpp; do \
      [ -f "$cpp" ] || continue; \
      base=$(basename "$cpp" .cpp | sed 's/^saanskara_imgui_/saanskara_/'); \
      camel=$(echo "$base" | awk -F_ '{for(i=1;i<=NF;i++) printf "%s", toupper(substr($i,1,1)) substr($i,2)}'); \
      echo "🦀 Compiling $cpp -> /out/${base}.wasm (create${camel}Module)..."; \
      em++ -O3 "$cpp" /vendor_imgui/libimgui_core.a \
        -I/vendor_imgui/imgui -I/vendor_imgui/imgui/backends -I/vendor_imgui/implot -I/vendor_imgui/imgui-knobs \
        -s USE_WEBGL2=1 -s FULL_ES3=1 -s ALLOW_MEMORY_GROWTH=1 -s MODULARIZE=1 \
        -s EXPORT_NAME="create${camel}Module" \
        -s EXPORTED_RUNTIME_METHODS='["ccall","cwrap","UTF8ToString"]' \
        -o "/out/${base}.js"; \
    done

# ============================================================================
# STAGE 2: Rails Base Image
# ============================================================================
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips libffi8 postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# ============================================================================
# STAGE 3: Throw-away Build Stage
# ============================================================================
FROM base AS build

# Install packages needed to build gems and download prebuilt grass SCSS compiler binary
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libffi-dev libpq-dev libvips libyaml-dev pkg-config && \
    ARCH="$(uname -m)" && \
    case "$ARCH" in \
      x86_64|amd64) GRASS_TARGET="x86_64-unknown-linux-musl" ;; \
      aarch64|arm64) GRASS_TARGET="aarch64-unknown-linux-musl" ;; \
      *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
    esac && \
    curl -fsSL "https://github.com/cargo-bins/cargo-quickinstall/releases/download/grass-0.13.4/grass-0.13.4-${GRASS_TARGET}.tar.gz" | tar -xzf - -C /usr/local/bin grass && \
    chmod +x /usr/local/bin/grass && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/* ./vendor/
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code & all compiled WASM synth modules
COPY . .
COPY --from=wasm-build /out/* ./public/wasm/

# Precompile bootsnap code for faster boot times.
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# Precompiling assets for production without requiring secret RAILS_MASTER_KEY
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile && \
    rm -rf public/assets/*.scss public/assets/*/*.scss

# ============================================================================
# STAGE 4: Final Ultra-Lean App Image
# ============================================================================
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
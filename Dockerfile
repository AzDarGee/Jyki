# syntax=docker/dockerfile:1
# check=error=true

# Global ARGs used in FROM lines MUST be declared before the very first FROM!
ARG RUBY_VERSION=4.0.9

# ============================================================================
# STAGE 1: Pure C99 Clay + NanoVG WebAssembly Builder (Auto-builds ALL .c synths!)
# ============================================================================
FROM emscripten/emsdk:3.1.73 AS wasm-build

WORKDIR /app
ENV VENDOR_DIR="/vendor_clay_nvg" \
    WASM_OUT_DIR="/out"

# 1. Pre-fetch Clay (clay.h) & NanoVG and pre-compile /vendor_clay_nvg/libnvg.a
#    (Cached forever by Docker — builds in ~1 second!)
RUN mkdir -p "$VENDOR_DIR" "$WASM_OUT_DIR" && \
    curl -fsSL https://raw.githubusercontent.com/nicbarker/clay/main/clay.h -o "$VENDOR_DIR/clay.h" && \
    git clone --depth 1 https://github.com/memononen/nanovg.git "$VENDOR_DIR/nanovg" && \
    emcc -O3 -c "$VENDOR_DIR/nanovg/src/nanovg.c" -I"$VENDOR_DIR/nanovg/src" -o "$VENDOR_DIR/nanovg.o" && \
    emar rcs "$VENDOR_DIR/libnvg.a" "$VENDOR_DIR/nanovg.o"

# 2. Copy ext/ and auto-compile EVERY .c synth module in ext/jyki_synths/ (and ext/wasm_modules/)!
COPY ext/ ./ext/
RUN for src in ext/jyki_synths/*.c ext/jyki_synths/*.c; do \
      [ -f "$src" ] || continue; \
      base=$(basename "$src" .c); \
      camel=$(echo "$base" | awk -F_ '{for(i=1;i<=NF;i++) printf "%s", toupper(substr($i,1,1)) substr($i,2)}'); \
      echo "🌿 Compiling Pure C99 Clay + NanoVG: $src -> $WASM_OUT_DIR/${base}.wasm (create${camel}Module)..."; \
      emcc -O3 "$src" "$VENDOR_DIR/libnvg.a" \
        -I"$VENDOR_DIR" -I"$VENDOR_DIR/nanovg/src" \
        -s USE_WEBGL2=1 -s FULL_ES3=1 -s ALLOW_MEMORY_GROWTH=1 -s MODULARIZE=1 \
        -s EXPORT_NAME="create${camel}Module" \
        -s EXPORTED_RUNTIME_METHODS='["ccall","cwrap","UTF8ToString"]' \
        -o "$WASM_OUT_DIR/${base}.js"; \
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
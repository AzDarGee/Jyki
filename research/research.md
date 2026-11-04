# Tools
All on the same server for app speed. Won't be bottlenecked by the speed of the internet connection.

## Front-end
- UI (tailwind + components + state management)
- API integration
- Ruby on Rails (HTML-over-the-wire)
- SPA (Single Page App)

## Back-end
- API
- AI / ML integration 
- Database integration
- Rust (for readability and safety)

### Frameworks
- Ruby on Rails

## Database
- PostGreSQL 18
- PgVector
- Prisma ORM

## Deployment
- Coolify - S.Server

## AI / ML / Data Science
- RAG (Retrieval-Augmented Generation)
- LangChain

## DevOps
- Coolify
- Git
- Docker

### Languages
- Ruby
- C 
- Python (math libraries)
- HTML/CSS/JS
- Swift
- Kotlin


# Findings

The audio engine and interactive canvas do not want HTML, nor do they want serialized Virtual DOM trees. They want Binary-Deltas-over-the-wire (Uint8Array Yjs CRDTs + WebSockets/WebRTC) fed directly into WebGPU and your C Wasm AudioWorklet.

Modern web browsers have a DOM engine written in C++ (or Rust in newer layout engines).


## Advantages of Web over Native
- Multiple instances run in the same browser or different browsers. Not possible with native apps.
- Same UI/UX for different operating systems.
- No installation required. (Just a link).
- Collaborative
- Same speed as native apps - if I develop it the right way.
- Clout check: Web beats native
- Can make a desktop / mobile - responsive interface

## How it works
1. Your web browser is a DOM engine written in C++
2. It has a layout engine (a "browser engine") that understands CSS box models and HTML semantics.
3. When you write HTML/CSS/JS, the browser translates those instructions into low-level layout and rendering commands.


┌────────────────────────────────────────────────────────────────────────┐
│                   THE MANDAPA (The Outer Courtyard)                    │
│                 Driven by: RAILS HTML-OVER-THE-WIRE                    │
│                                                                        │
│  • User Authentication & Profiles      • Preset & Sample Library       │
│  • Studio Chat & Collaborator Lists    • Cloud AI Job Progress (LUFS)  │
│  • Admin Dashboard & Billing           • Export Modal (.saan / WAV)    │
│                                                                        │
│  [Cost: ~15 KB JS. Zero V-DOM. Zero Garbage Collection dropouts.]      │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │ Embeds cleanly into
                                    ▼
┌────────────────────────────────────────────────────────────────────────┐
│                   THE GARBHAGRIHA (The Inner Sanctum)                  │
│             Driven by: BINARY-DELTAS + WEBGPU + C WASM                 │
│                                                                        │
│  • 120fps Waveform Timeline & Piano Roll (WebGPU / PixiJS Canvas)      │
│  • Real-Time Collaborative Sync (Yjs Uint8Array CRDTs via WebRTC)      │
│  • 16-Band Parametric EQ & 4-Deck DJ Stems (C Wasm inside AudioWorklet)│
│                                                                        │
│  [Cost: Pure linear memory. Deterministic 2.6ms audio block cycles.]   │
└────────────────────────────────────────────────────────────────────────┘

# HTML-over-the-wire does something brilliant for a DAW: It gets out of the way.

## Near-Zero Main Thread CPU Usage:
When Rails sends a <turbo-stream> snippet to update the Studio Chat, toggle an armed track, or refresh the sample library, Turbo does no Virtual DOM diffing. It hands the raw HTML string straight to the browser's native C++ DOM engine (innerHTML / replaceWith). The browser engine updates the screen in microseconds using optimized C++, without creating heaps of JavaScript garbage.

## Leaves the JavaScript Thread 100% Free for Sound & Graphics:
Because Hotwire requires almost zero client-side JavaScript (~15 KB total), nearly 100% of the browser’s JavaScript heap and CPU cycles are reserved for your high-speed tasks:
- Pumping y-webrtc MIDI deltas.
- Sending 128-sample buffers to the C WebAssembly AudioWorklet.
- Driving PixiJS/WebGPU draw calls.

## Zero Reconciliation Clashes:
Your high-performance DAW canvas (the Creation Tab & DJ Tab) lives inside a dedicated <canvas> element or custom element container. Rails Hotwire swaps surrounding panels (presets, track info, chat, library) without ever touching or re-rendering the canvas!


# Web Audio API - 128 Samples
Depending on the driver of your audio interface, you can set the buffer size anywhere from 32 to 8192 samples. 


# ROR
- MVC
- jsbundling-rails
- postgresql
- DSP in C + WebAssembly
- tailwind


### Why Rust Frustrates DSP Engineers:
DSP pipelines are fundamentally directed graphs (often with feedback loops, like a delay line, IIR filter, or reverb routing back into a mixer) operating on shared, pre-allocated ring buffers.
- In Rust, a graph where Node A feeds Node B and Node B feeds back into Node A is the mortal enemy of the Borrow Checker (which demands a strict tree of single ownership).
- Furthermore, passing raw float buffers from Ruby across FFI into Rust requires wrapping your hot DSP loops in unsafe {} blocks anyway! Once you are inside unsafe in Rust to manipulate raw pointers from Ruby, you lose half of Rust's safety guarantees while still paying 100% of its slow compile times and toolchain weight.
- Also, in DSP, you often want the compiler flag -ffast-math (allowing the CPU to reorder floating-point math for massive SIMD vectorization speedups). In C, it's a single flag. In Rust, floating-point fast-math intrinsics are still awkward or require nightly/external crates.

### When you write C this way — Arena Allocation + Flat Structs + Zero Dynamic Allocation in the Loop + Ruby Owning the Lifecycle
- it is virtually impossible to have a memory leak or use-after-free, and you get:
- 0.1-second compile times (edit a filter equation in C, hit run in Ruby, hear/see the result in 100ms).
- Zero dependencies (just cc and libm).
- Tiny 20KB binaries that deploy anywhere (Linux, macOS, Windows, Raspberry Pi, embedded DSP).
- Effortless debugging (inspect any node's state directly from Ruby or gdb).



- Account for speaker health, no pops, clicks.

# DSP
When that wave enters a microphone and hits your computer, the computer cannot store "air." So it takes a photograph of the air's position 48,000 times every single second (48kHz)—or up to 192,000 times per second (192kHz) in your DAW spec!

Each "photograph" is called a Sample, and it is nothing more than a single decimal number (float) between -1.0 (the speaker cone pulled all the way back) and +1.0 (the speaker cone pushed all the way forward), with 0.0 being complete silence.

DSP is simply doing high-speed math (+, -, *, /) on that list of numbers before sending them to the speaker!

Every single $500 VST plugin, every $10,000 Abbey Road mixing console, every synthesizer, and every DJ effect in your DAW spec is literally just a for loop in C doing basic arithmetic on those numbers between -1.0 and +1.0.

DSP Engine (dsp/dsp_engine_v2.c) is simply the muscle-bound C workhorse that takes the raw array of sound numbers (audio_io[128]), runs them through your Volume, EQ Filters, DJ Deck Stems, and Reverb math in a few microseconds, and hands the finished numbers to your Mac's speakers.
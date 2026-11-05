# System Architecture


## DSP
- Written for multiple platforms
- How do I create a DSP to be used for different clients?

## Web 
What's after the browser?

### Frontend 
- HTML/CSS/JS
- ImportMaps

### Backend
- ActiveRecord
- Ruby to C to WebAssembly (Wasm) to AudioWorklet

## Windows
- C

## Mac
- Swift

## iOS
- Swift

## Android
- Kotlin

## Linux
- C


# Summary for MVP
- DSP in Ruby + C (C Wasm inside AudioWorklet)
- Database - PostgreSQL
- In Memory store - Redis - CRDTs - Yjs/Automerge - Branches - Real-time collaborative sync
  - It stores your DAW’s tracks, MIDI notes, modulation curves, and mixer faders inside shared CRDT data structures
- WebGPU / WebGL / Canvas2d
- Offline support
- Binary-Deltas-over-the-wire (Uint8Array Yjs CRDTs + WebSockets/WebRTC) fed directly into WebGPU and your C Wasm AudioWorklet
  - Every knob turn or MIDI note move emits a tiny binary delta (update event). Any peer that receives those bytes calls applyUpdate and stays in lockstep within milliseconds—even if packets arrive out of order!
  - Collaborative environment

# System Architecture from Docs

Next Gen DAW - Software Design & System Architecture Document
Web/Windows/Mac/Android/iOS
Jæku | Ashish Darji Music Production Workstation
Executive Summary

## Pain Points for normal DAWs:
- Album (Project folder)
- Shared Recorded Folder
- Shared Samples Folder
- Trax 1 (Track folder)
Trax 2
Trax 3
- Voxas Organization
- Plugin use - too many useless knobs
- Collabing with the right artists
- Creative blockages
- Learning instruments
- Voxing
- Writing lyrics
- Rehearsal
- Creating beats/melodies by dragging and dropping, clicking on the piano roll
  - Fucks up the DANCE.
  - Good for ideas.

## Unique Differentiators (Jæku Exclusives)
Features that push Jæku beyond contemporary DAWs.
Timeline Branching (Git for Audio): A UI visualization showing parallel arrangements. Switch the entire project state between Drop A and Drop B instantly.
Spatial Composition Canvas: A 3D view where tracks are spheres orbiting a listener. Move a track further away to decrease volume, increase reverb, and apply low-pass filtering instinctively.
Mood-Reactive Mixing: Define an overarching “Mood Contour” curve over the timeline. The master bus subtly brightens/compresses automatically as energy increases.
Neural Groove Extraction: Analyze the micro-rhythm (swing/push/pull) of an audio loop and apply exactly that human feel to your quantized MIDI data.
Visual Design & UX
Aesthetic Philosophy: Minimal, technical, and unobtrusive. "Saanskara Slate" default theme using dark charcoals (Tailwind zinc-900) contrasting with vibrant parameter highlights (e.g., teal-400, fuchsia-500).
Typography: Inter for UI legibility, JetBrains Mono for numeric inputs and technical readouts.
Rendering Pipeline: UI in Rails, timeline, waveforms, and piano roll strictly in Canvas/WebGPU to ensure native-like 24-30-60-120fps scrolling.
Animation: Framer Motion (motion/react) handles layout transitions, panel un-docking, and modal popups. Audio metering relies on requestAnimationFrame manipulating DOM nodes directly for efficiency.

Advanced + 2yo Mode

## AI Studio Implementation Plan (4 Tiers)
How to build this iteratively using Google AI Studio and modern web technologies:
Tier 1: Visual Prototype & Fundamental Web Audio (Immediate). Build the Rails UI shell using Tailwind and Framer Motion. Implement basic Web Audio API playback involving simple oscillators and a rudimentary sequencer step-grid. Establish the Context/Store for state.
Tier 2: DSP Expansion & Generative AI (Short-term). Integrate the Gemini API to act as the “Smart Assistant” (e.g., sending it data about a MIDI chord progression to get back a suggested melody array). Implement WASM modules for more advanced audio processing (reverb, compression) beyond standard Web Audio nodes.
Tier 3: Multiplayer CRDTs & Cloud Sync (Mid-term). Implement Yjs or a similar Conflict-Free Replicated Data Type engine over WebSockets to allow two browser instances to concurrently edit the sequence/timeline data.
Tier 4: [Getting_To]

## Engineering & Technical Architecture

### Frontend (The DAW Engine):
UI in Rails + Turbo & Canvas/WebGL (for the timeline and waveforms).
Audio Graph Orchestration: A custom React hook layer translates the Yjs state into Web Audio API AudioNode connections transparently.
Real-Time Sync Pattern:
User drags a MIDI note.
React UI updates locally (optimistic).
Yjs applies the delta.
The y-webrtc provider broadcasts the delta to peers instantly.
A debounced y-indexeddb saves it locally.
A batched Firestore write saves the binary Yjs document state to the cloud.
DSP Engine in C compiled to WebAssembly running inside an AudioWorklet.
Local caching via IndexedDB / OPFS (Origin Private File System) so users don't re-download gigabytes of audio stems every time they refresh.
Zustand manages local UI state (modals, active tabs). Yjs manages the collaborative project document (tracks, clips, notes).
Serverless / API Layer (The App Shell):


### Server / Worker Layer (The Heavy Lifters):
Job Queue (e.g., BullMQ + Redis OR Solid Cache) + Dedicated Worker Containers: Whenever a user uploads a file or requests a server-side master/stem-split, a persistent server pulls the job from the queue, processes the audio with no timeout limits, uploads the result to Firebase Storage, and notifies the client.
Stateful Sync Server (if collaborative): A dedicated WebSocket server on GCP

### Timeline Implementation
Put the entire timeline and transport state machine inside an AudioWorklet (written in Rust/C++ compiled to Wasm). That way, your timeline advances sample-by-sample inside the real-time audio thread, completely immune to UI lag.

### State Sync
#### Browser Storage - DAW must be local - first.
SharedArrayBuffer / Wasm Linear Memory (RAM): For real-time DSP state (playhead position, audio buffers, synth parameters), state must live in shared memory between the UI thread and the AudioWorklet thread.
IndexedDB: Great for storing structured project metadata, undo/redo history trees, and CRDT (Conflict-free Replicated Data Type) state logs locally.
OPFS (Origin Private File System): The secret weapon of modern web apps. It gives the browser near-native, byte-level read/write speed to a virtual local disk. Perfect for caching heavy .wav stems, frozen tracks, and local autosaves without crashing RAM.


#### Redis - In - memory data store
Ephemeral Session State: Who is currently in the project? Where is Collaborator B's cursor? Which track is locked or armed for recording?
Real-Time Delta Broadcasting: When User A tweaks a reverb decay knob, you don't send the whole 50MB project file. You send a tiny state delta (or Yjs/Automerge CRDT binary update) over WebSockets, backed by Redis Pub/Sub or Redis Streams.
Hot Checkpointing: Acting as a lightning-fast staging ground before flushing heavy changes to permanent disk storage.


## Schema Example:
/users/{userId} -> { name, plan, settings }
/projects/{projectId} -> { name, tempo, ownerId, CRDT_state_binary }
/tracks/{trackId} -> { name, color, type, volume, routing }
/clips/{clipId} -> { start, duration, offset, type }
/events/{eventId} -> { notes, automation_blobs } (For offline/large data)
/branches/{branchId} -> { Yjs_delta_vectors }
/chat/{messageId} -> { sender, timestamp, text }




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
  - 

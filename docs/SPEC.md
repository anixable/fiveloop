# FiveLoop – Technical Specification (Phase 1)

Functional reference: BOSS RC-505mkII Owner's Manual and Parameter Guide (eng02). The app is an
independent implementation of the *workflow*; it contains no BOSS/Roland code, firmware, samples
or artwork, and it does not use the BOSS/RC-505 trademarks as its name.

## 1. Architecture

```
┌──────────────────────── iPad app (App/Sources, SwiftUI) ────────────────────────┐
│ Views ──► AppModel (main thread) ──► SPSC command queue ──┐                       │
│   ▲            ▲   │                                      ▼                       │
│   │ 30 Hz poll │   └─ MemoryStore / WAV / OfflineRenderer (background queue)     │
│ StatusBoard (atomics) ◄──── LooperEngine.process() ◄──── AudioIO (RemoteIO RT)    │
│                              │  events / MIDI clock (SPSC) ──► MIDIIO (CoreMIDI)  │
└──────────────────────────────┴────────────────────────────────────────────────────┘
LooperCore (Swift package, no UIKit/AVFoundation → unit-tested on Linux/macOS)
  Engine/  LooperEngine, LoopTrack, TrackSettings, StatusBoard
  FX/      FXCore, FXRack (4 banks × 4 slots), FXCatalog, Effects (original DSP)
  Rhythm/  DrumSynth (16 synthesised kits), Patterns (original), RhythmEngine
  MIDI/    MIDIParser, ClockFollower, AssignmentMap, TapTempo
  Memory/  MemoryModel, MemoryStore (99 memories + recovery), WAV, OfflineRenderer
```

Real-time rules (enforced by design, checked by review):
* The UI never touches audio buffers. All changes travel as `EngineCommand`s through a lock-free
  single-producer/single-consumer ring (`SPSCQueue`, swift-atomics). Only the main thread produces.
* The audio thread never allocates, locks, logs or does file I/O. Track buffers (2× for undo),
  FX delay lines, scratch buffers and drum samples are allocated up front.
* FX processors are created on the main thread and swapped in by command; the replaced object is
  returned through the event queue and released on the main thread.
* Engine → UI state is a set of atomics (`StatusBoard`) read at 30 Hz.

## 2. Timing model (synchronisation without drift)

* One master clock: `songPos` (Double, in *reference frames*). It advances by `ratio = tempo /
  refTempo` per output frame. With an unchanged tempo `ratio == 1` exactly, so positions stay
  integer and playback is sample-exact.
* The measure length `refMeasure` is an integer number of frames. When the first loop is recorded
  freely, the tempo is *derived* from the loop (1, 2, 4… measures chosen so tempo lands in
  70–140 BPM) and the loop is trimmed by < 1 frame per measure to make it exact.
* Every synced track computes its read position from `songPos` at the start of every audio block
  (`(songPos − anchor) · scale · speed mod length`) → no accumulated drift. Verified by a
  30-minute simulated playback test with an odd loop length.
* Rhythm steps and MIDI clock ticks (24 PPQN) are derived from the same `songPos`.
* Tempo change after recording (TEMPO SYNC = ON, MODE = PITCH): tracks are resampled
  (linear interpolation) and remain locked to the grid.

## 3. Track behaviour (Parameter Guide → implementation)

| Parameter | Values | Status |
|---|---|---|
| REVERSE, 1SHOT (with retrigger), PAN L50–R50, PLAY LEVEL 0–200 | as manual | ✅ |
| START MODE IMMEDIATE/FADE, STOP MODE IMMEDIATE/FADE/LOOP, FADE TIME IN/OUT | as manual (fade in measures) | ✅ |
| DUB MODE OVERDUB / REPLACE1 / REPLACE2 | as manual | ✅ |
| FX ON/OFF per track | as manual | ✅ |
| PLAY MODE MULTI/SINGLE, S.TRK CHANGE IMMEDIATE/LOOP END | as manual | ✅ |
| MEASURE AUTO/FREE/manual (1/4, 1/2, 1–16) | as manual | ✅ |
| LOOP SYNC ON/OFF | as manual | ✅ |
| TEMPO SYNC SW, MODE PITCH | ✅ — MODE XFADE (time-stretch) | ⏳ not yet |
| SPEED HALF/NORMAL/DOUBLE | ✅ (SPEED CHANGE = immediate) | ✅ |
| BOUNCE IN | ✅ (other tracks' output, one audio block late) | ✅ |
| INPUT: mic/inst on/off, RHYTHM → track | ✅ | ✅ |
| REC ACTION REC→DUB / REC→PLAY, QUANTIZE OFF/MEASURE, AUTO REC + SENS | ✅ | ✅ |
| ALL START/STOP target tracks, MIDI start/stop target tracks | ✅ | ✅ |
| UNDO/REDO (last recording or overdub) | one level, sample-exact, glitch-free swap | ✅ |

Additional engineering details:
* **Loop seam**: the last 256 frames of a take are equal-power cross-faded into the audio that
  preceded the take (pre-roll from an 8192-frame input history), so the wrap end→start is
  continuous and the downbeat keeps its attack.
* **Latency compensation**: recordings and overdubs made against a grid are shifted by the
  measured round-trip latency (input + output + 2 × buffer) + a user offset (Audio screen).
* **Overdub/Undo**: copy-on-first-write backup of exactly the samples touched; undo/redo swaps
  that range back in ≤ 32 768-frame slices per block, starting at the play head.

## 4. Audio engine

* RemoteIO, 44.1 kHz, 32-bit float non-interleaved, stereo out, 1–2 inputs (built-in mic, wired
  headset, USB class-compliant interfaces). The client format is always 44.1 kHz; iOS converts if
  the hardware runs at 48 kHz.
* Preferred I/O buffer 256 frames (≈5.8 ms), selectable 128–1024.
* Handles interruptions (restart after phone call/Siri), route changes (rebuilds the unit if the
  input channel count changes, updates latency), media-services reset (full rebuild).
* Master section: COMP (OFF, 1–40), REVERB (0–40), master level, transparent safety limiter
  above −0.9 dBFS.
* Measured performance (release build, Linux x86 Xeon 2.3 GHz, worst case: 5 tracks + overdub +
  8 FX + rhythm + master FX): see `docs/TEST_RESULTS.md`.

## 5. Effects

4 banks (A–D) × 4 slots (A–D) for INPUT FX and TRACK FX, bank SW, SINGLE/MULTI mode, TOGGLE/MOMENT
switch mode, Track-FX INSERT ALL or TRACK1–5, click-free 8 ms on/off crossfade, tempo-synced
rates (4MEAS … 1/32). 26 types implemented with original DSP (see `FXType`); the remaining
hardware types are listed in the app's SYSTEM screen as not implemented. FX SEQUENCE and
per-step automation are not implemented yet.

## 6. Rhythm

61 original patterns in the 20 hardware genres, each with variations A–D (244 playable
rhythms), 16 synthesised kits, time signatures 2/4–7/4 and 5/8–15/8 (patterns adapt), swing,
fills on variation change, count-in (1–2 measures), START TRIG LOOP START/BEFORE LOOP,
STOP TRIG LOOP STOP, level 0–200, live pads and MIDI notes (GM mapping, RX channel 10).

## 7. Memory / project management

99 memories (`Documents/Memories/M001…M099`), each with `memory.json` (all settings, grid,
FX, rhythm, mixer, assignments) and `T1–T5.wav` (32-bit float). Save is atomic (temp folder →
move). Load suspends the engine, copies audio, resumes. Rename, duplicate, delete, single-file
export/import (`.floop`), full backup/restore (`.flbk`), crash recovery (autosave slot + session
lock file). Exports: track WAV, offline mix-down, stems (16/24-bit or float).

## 8. MIDI

CoreMIDI client with auto-connection to all sources, virtual “FiveLoop” in/out port.
Clock in (median-filtered tempo follower), clock out (sample-accurate, host-time stamped),
Start/Stop/Continue (SYNC START OFF/ALL/RHYTHM), Program Change → memory, notes on the rhythm
channel → drum voices, CC/note assignments with MIDI learn (stored per memory).

## 9. Not reproduced / limitations

See README “Περιορισμοί”.

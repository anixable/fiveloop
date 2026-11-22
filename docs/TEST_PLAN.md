# Test plan

## A. Automated (every push, GitHub Actions + locally)
`swift test --package-path Packages/LooperCore` – 31 tests: loop recording/playback exactness,
tempo derivation, quantize/auto-measure, sync of multiple tracks, 30-minute drift test,
overdub/undo/redo exactness, reverse/half speed, stop modes, one-shot, single mode,
bounce, count-in, latency compensation, tempo change sync, all 26 FX at parameter extremes,
click-free FX switching, tempo-synced delay timing, rhythm library/kits/downbeat, MIDI parser,
clock follower, assignments/learn, tap tempo, MIDI clock output, WAV 16/24/float round trip,
memory save/load/rename/duplicate/delete/backup/restore/bundle, offline mix-down, performance.

## B. Manual on the iPad (record results in this table)

Use headphones. Open DIAG in a second pass to watch CPU/overloads.

| # | Test | Expected | Result |
|---|---|---|---|
| 1 | First launch | Mic permission prompt; AUDIO not "OFF"; input meter moves | |
| 2 | TRACK 1 REC/PLAY, play 4 beats, REC/PLAY | Loop plays, tempo appears (70–140), REC→DUB: track goes to DUB (yellow) | |
| 3 | REC/PLAY again | PLAY (green), position ring turns | |
| 4 | TRACK 2 REC/PLAY mid-loop | Blinks red (standby) until bar start, records exactly as long as track 1 (AUTO) | |
| 5 | Listen 5 minutes | No drift between tracks, no clicks at the loop point | |
| 6 | UNDO/REDO on track 2 after an overdub | Overdub disappears/reappears without glitch | |
| 7 | STOP with STOP MODE = LOOP / FADE | Stops at loop end / fades | |
| 8 | ALL START/STOP twice | All stop, all restart from bar 1 | |
| 9 | RHYTHM START (START TRIG = BEFORE LOOP) then record | Recording starts on the next bar, in time with drums | |
| 10 | Count-in 1 MEAS, rhythm armed, record on empty memory | 4 clicks then recording | |
| 11 | Input FX A (LPF) on while singing | Filter sweep heard and recorded | |
| 12 | Track FX with INSERT TRACK2 | Affects only track 2 | |
| 13 | Tempo +20 BPM after recording | Loops speed up (pitch up), stay in sync with drums | |
| 14 | Faders / pan / mute on MIXER | Level changes without zipper noise | |
| 15 | WRITE to M01, load M02, load M01 | Audio and settings return exactly | |
| 16 | Kill the app from the app switcher during play, reopen | "Recover last session?" → Restore works | |
| 17 | EXPORT MIX / STEMS / track WAV | Share sheet, files play in Files app | |
| 18 | IMPORT WAV into empty memory | Loop plays, tempo derived | |
| 19 | Phone call / Siri interruption | Audio resumes afterwards | |
| 20 | Plug/unplug headphones, USB interface | Audio continues; input channels shown in AUDIO | |
| 21 | MIDI controller: LEARN TRACK1 REC/PLAY on a pad | Pad controls track 1 | |
| 22 | External MIDI clock (e.g. DAW/drum machine) + Start | Tempo follows, tracks with MIDI START start | |
| 23 | MIDI clock out to another app/device | Follows FiveLoop tempo | |
| 24 | 30-minute session with all 5 tracks + FX | DIAG overloads stay 0, no crash, memory stable | |
| 25 | LATENCY ADJ calibration: record a click from the rhythm with the mic | Recorded click aligns with drums (adjust ± ms) | |

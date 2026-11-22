# Test results – LooperCore (automated)

Environment: Swift 6.0.3 (Swift 5 language mode), Linux x86_64 (Intel Xeon 2.3 GHz, 2 cores), 2026-11-22.
Command: `swift test --package-path Packages/LooperCore` (debug) — the same suite runs on macOS in CI.

```
'FXTests.testAllEffectsStableAcrossParameterExtremes' passed (2.731 seconds)
'FXTests.testRackCrossfadeIsClickFree' passed (0.107 seconds)
'FXTests.testTempoSyncedDelayEchoLandsOnTheBeat' passed (0.026 seconds)
'LoopEngineTests.testAllStartStopAndClearUnlocks' passed (1.424 seconds)
'LoopEngineTests.testBounceAndRhythmToTrack' passed (1.212 seconds)
'LoopEngineTests.testCountInDelaysRecording' passed (1.126 seconds)
'LoopEngineTests.testFreeMeasureQuantizesToNearestMeasure' passed (1.299 seconds)
'LoopEngineTests.testFreeRecordingDefinesTempoAndPlaysBackExactly' passed (1.125 seconds)
'LoopEngineTests.testLatencyCompensationShiftsRecording' passed (1.033 seconds)
'LoopEngineTests.testNoDriftOverLongPlayback' passed (45.548 seconds)
'LoopEngineTests.testOneShotPlaysOnceAndRetriggers' passed (0.916 seconds)
'LoopEngineTests.testOverdubUndoRedoAreExact' passed (1.024 seconds)
'LoopEngineTests.testQuantizedSecondTrackAutoLengthAndSync' passed (1.742 seconds)
'LoopEngineTests.testReverseAndHalfSpeed' passed (1.1 seconds)
'LoopEngineTests.testSingleModeSwitchesTracks' passed (0.93 seconds)
'LoopEngineTests.testStopModes' passed (0.923 seconds)
'LoopEngineTests.testTempoChangeKeepsSync' passed (1.075 seconds)
'LoopEngineTests.testTempoGuessForLongLoop' passed (1.113 seconds)
'LoopEngineTests.testUndoFirstRecordingThenRedo' passed (0.914 seconds)
'MIDITests.testAssignmentsAndLearn' passed (0.0 seconds)
'MIDITests.testClockFollowerFindsTempo' passed (0.003 seconds)
'MIDITests.testEngineEmitsMIDIClock' passed (0.91 seconds)
'MIDITests.testParserRunningStatusAndRealtime' passed (0.0 seconds)
'MIDITests.testTapTempo' passed (0.0 seconds)
'PerformanceTests.testRealtimeFactor' passed (22.282 seconds)
'RhythmTests.testAllKitsRender' passed (0.94 seconds)
'RhythmTests.testKickLandsOnDownbeat' passed (0.883 seconds)
'RhythmTests.testPatternLibrarySize' passed (0.0 seconds)
'StorageTests.testEngineMemoryRoundTripAndOfflineMix' passed (1.927 seconds)
'StorageTests.testMemoryStoreLifecycle' passed (0.223 seconds)
'StorageTests.testWAVRoundTrip' passed (0.002 seconds)
	 Executed 31 tests, with 0 failures (0 unexpected) in 92.539 (92.539) seconds
	 Executed 31 tests, with 0 failures (0 unexpected) in 92.539 (92.539) seconds
```

Release-build performance (worst case: 5 tracks playing, 1 overdubbing, 4 input FX + 4 track FX incl. 2 reverbs, rhythm, master COMP + REVERB, 256-frame blocks):

```
PERF: 30.2× real time, ≈3.3 % of one Xeon core
```

Expectation on an A9/A10 iPad (iPadOS 15): roughly 3–6× slower per core than this server → ~10–20 % of one core. **Must be confirmed on the real iPad** (DIAG screen shows the live callback load).

Not tested here (needs macOS/iPad): compilation of the iOS app target, RemoteIO/CoreMIDI behaviour, UI. These are covered by the GitHub Actions build and the manual test plan (TEST_PLAN.md).

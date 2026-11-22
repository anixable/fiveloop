import SwiftUI
import UniformTypeIdentifiers
import LooperCore

// MARK: - Memory manager / project browser

struct MemoryView: View {
    @EnvironmentObject var app: AppModel
    @State private var selected = 1
    @State private var confirmLoad = false
    @State private var confirmOverwrite = false
    @State private var confirmDelete = false
    @State private var renaming = false
    @State private var newName = ""
    @State private var duplicateTo = 2
    enum ImportKind { case bundle, backup }
    @State private var importKind: ImportKind? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PanelBox(title: "MEMORIES (1–99)") {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                        ForEach(app.memoryList) { m in
                            Button(action: { selected = m.index }) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(String(format: "%02d", m.index)).font(.system(size: 13, weight: .heavy, design: .monospaced))
                                        Spacer()
                                        if m.index == app.memoryIndex { Image(systemName: "play.circle.fill").foregroundColor(Theme.play) }
                                        if m.hasAudio { Image(systemName: "waveform").foregroundColor(Theme.lcd) }
                                    }
                                    Text(m.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                                }
                                .padding(8).frame(maxWidth: .infinity, minHeight: 54)
                                .foregroundColor(.white)
                                .background(RoundedRectangle(cornerRadius: 6).fill(selected == m.index ? Theme.panelHi : Theme.bg))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected == m.index ? Theme.lcd : Color.clear))
                            }
                        }
                    }
                }
            }
            VStack(spacing: 10) {
                PanelBox(title: "MEMORY \(selected)") {
                    let sum = app.memoryList.first { $0.index == selected }
                    Text(sum?.name ?? "").font(.system(size: 20, weight: .heavy, design: .monospaced))
                    if let d = sum?.modified { Text(d, style: .date).font(.caption).foregroundColor(Theme.dim) }
                    HStack {
                        HWButton(title: "LOAD", height: 44) { if app.dirty { confirmLoad = true } else { app.loadMemory(selected) } }
                        HWButton(title: "WRITE", subtitle: "save current", height: 44) {
                            if sum?.hasAudio == true && selected != app.memoryIndex { confirmOverwrite = true } else { app.saveMemory(selected) }
                        }
                    }
                    HStack {
                        HWButton(title: "RENAME", height: 44) { newName = sum?.name ?? ""; renaming = true }
                        HWButton(title: "DELETE", height: 44) { confirmDelete = true }
                    }
                    HStack {
                        Stepper("Copy to \(duplicateTo)", value: $duplicateTo, in: 1...99).font(.caption.monospaced())
                        Button("DUPLICATE") { app.duplicateMemory(selected, to: duplicateTo) }.buttonStyle(.bordered)
                    }
                    HStack {
                        Button("EXPORT .floop") { app.exportMemoryBundle(selected) }.buttonStyle(.bordered)
                        Button("IMPORT .floop…") { importKind = .bundle }.buttonStyle(.bordered)
                    }
                }
                PanelBox(title: "CURRENT SESSION") {
                    HStack {
                        Button("NEW (INIT)") { app.newMemory() }.buttonStyle(.bordered)
                        Button("EXPORT MIX") { app.exportMix(stems: false) }.buttonStyle(.bordered)
                        Button("EXPORT STEMS") { app.exportMix(stems: true) }.buttonStyle(.bordered)
                    }
                    HStack {
                        Button("BACKUP ALL") { app.backupAll() }.buttonStyle(.bordered)
                        Button("RESTORE BACKUP…") { importKind = .backup }.buttonStyle(.bordered)
                    }
                    Text("Files are also visible in the Files app → On My iPad → FiveLoop.").font(.caption).foregroundColor(Theme.dim)
                }
            }.frame(width: 380)
        }
        .padding(8)
        .onAppear { selected = app.memoryIndex; duplicateTo = min(99, app.memoryIndex + 1) }
        .alert("Discard unsaved changes?", isPresented: $confirmLoad) {
            Button("Load memory \(selected)", role: .destructive) { app.loadMemory(selected) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Overwrite memory \(selected)?", isPresented: $confirmOverwrite) {
            Button("Overwrite", role: .destructive) { app.saveMemory(selected) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its recordings will be replaced.") }
        .alert("Delete memory \(selected)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { app.deleteMemory(selected) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Recordings and settings of this memory will be permanently removed.") }
        .sheet(isPresented: $renaming) {
            VStack(spacing: 16) {
                Text("RENAME MEMORY \(selected)").font(.headline.monospaced())
                TextField("NAME (12 characters)", text: $newName)
                    .textFieldStyle(.roundedBorder).font(.title2.monospaced()).frame(width: 360)
                    .autocapitalization(.allCharacters).disableAutocorrection(true)
                HStack {
                    Button("Cancel") { renaming = false }.buttonStyle(.bordered)
                    Button("OK") { app.renameMemory(selected, newName); renaming = false }.buttonStyle(.borderedProminent)
                }
            }
            .padding(30)
            .preferredColorScheme(.dark)
        }
        .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
                      allowedContentTypes: [.floop, .flbk, .data]) { r in
            guard case .success(let u) = r else { return }
            if importKind == .backup || u.pathExtension.lowercased() == "flbk" { app.restoreBackup(u) }
            else { app.importMemoryBundle(u, to: selected) }
            importKind = nil
        }
    }
}

// MARK: - MIDI

struct MIDISettingsView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                PanelBox(title: "MIDI SETTINGS") {
                    Stepper("RX CH (CTL): \(app.midiSettings.rxControlChannel)", value: $app.midiSettings.rxControlChannel, in: 1...16)
                    Stepper("RX CH (RHYTHM): \(app.midiSettings.rxRhythmChannel)", value: $app.midiSettings.rxRhythmChannel, in: 1...16)
                    Stepper("TX CH: \(app.midiSettings.txChannel)", value: $app.midiSettings.txChannel, in: 1...16)
                    OptionRow(title: "CLOCK SYNC", options: [(ClockSyncMode.auto, "AUTO"), (.internal, "INTERNAL")], selection: $app.midiSettings.clockSync)
                    OptionRow(title: "SYNC START", options: [(MIDIStartMode.off, "OFF"), (.all, "ALL"), (.rhythm, "RHYTHM")], selection: $app.midiSettings.startMode)
                    Toggle("CLOCK OUT", isOn: $app.midiSettings.clockOut)
                    Toggle("PROGRAM CHANGE → MEMORY", isOn: $app.midiSettings.programChangeIn)
                }
                PanelBox(title: "DEVICES") {
                    Text("Inputs: " + (app.midi.sources.isEmpty ? "none" : app.midi.sources.map { $0.name }.joined(separator: ", ")))
                    Text("Outputs: " + (app.midi.destinations.isEmpty ? "none" : app.midi.destinations.map { $0.name }.joined(separator: ", ")))
                    Text("Virtual port: FiveLoop (in/out)").foregroundColor(Theme.dim)
                    Text("Last message: \(app.lastMIDI)").font(.caption.monospaced()).foregroundColor(Theme.lcd)
                    Button("Rescan") { app.midi.connectAllSources(); app.objectWillChange.send() }.buttonStyle(.bordered)
                }
            }
            .frame(width: 420)
            .font(.system(size: 14, design: .monospaced))
            .onChange(of: app.midiSettings) { _ in app.saveMIDISettings() }
            AssignmentsView()
        }
        .toggleStyle(SwitchToggleStyle(tint: Theme.play))
        .padding(8)
    }
}

struct AssignmentsView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        PanelBox(title: "CONTROL ASSIGN (MIDI LEARN)") {
            if let t = app.learnTarget {
                HStack {
                    Text("Move a knob / press a pad for: \(t.label)").foregroundColor(Theme.dub)
                    Spacer()
                    Button("Cancel") { app.learnTarget = nil }
                }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(AssignTarget.all, id: \.self) { target in
                        let current = app.memory.assignments.items.filter { $0.target == target }
                        HStack {
                            Text(target.label).font(.system(size: 13, weight: .semibold, design: .monospaced)).frame(width: 220, alignment: .leading)
                            Text(current.map { $0.source.label }.joined(separator: ", ")).font(.system(size: 12, design: .monospaced))
                                .foregroundColor(Theme.lcd)
                            Spacer()
                            Button(app.learnTarget == target ? "…" : "LEARN") { app.learnTarget = target }.buttonStyle(.bordered)
                            if !current.isEmpty {
                                Button(action: { app.memory.assignments.items.removeAll { $0.target == target }; app.dirty = true }) {
                                    Image(systemName: "xmark.circle")
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            Text("Assignments are stored per memory. Default: CC#80–84 → TRACK1–5 REC/PLAY, CC#85 ALL START/STOP, CC#86 UNDO/REDO, CC#87 RHYTHM.")
                .font(.caption).foregroundColor(Theme.dim)
        }
    }
}

// MARK: - Audio & loop settings

struct AudioSettingsView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let g = app.memory.global
        HStack(alignment: .top, spacing: 10) {
            PanelBox(title: "AUDIO") {
                OptionRow(title: "BUFFER", options: [(128, "128"), (256, "256"), (512, "512"), (1024, "1024")],
                          selection: Binding(get: { app.bufferFrames }, set: { app.applyBufferFrames($0) }))
                ParamSlider(name: "LATENCY ADJ", value: Binding(get: { Float(app.latencyOffsetMs) }, set: { app.applyLatencyOffset(Double($0)) }),
                            range: -30...30, display: { String(format: "%+.0f ms", $0) })
                if let d = app.diag {
                    Text(String(format: "Measured round-trip: %.1f ms (compensated automatically)", d.latencyMs + app.latencyOffsetMs))
                    Text("Route: \(d.route)").lineLimit(2)
                    Text("Input channels: \(d.inputChannels)   Hardware rate: \(Int(d.hardwareRate)) Hz   Engine: 44100 Hz / 32-bit float")
                }
                OptionRow(title: "TRACK MEMORY", options: [(30, "30 s"), (60, "60 s"), (120, "120 s"), (180, "180 s")],
                          selection: Binding(get: { app.maxLoopSeconds }, set: { app.applyMaxLoopSeconds($0) }))
                Text("Per track (×2 for UNDO). Longer limits need more RAM: 60 s ≈ 210 MB for 5 tracks.").font(.caption).foregroundColor(Theme.dim)
                Toggle("INPUT MONITOR", isOn: Binding(get: { app.memory.mixer.monitor }, set: { v in app.updateMixer { $0.monitor = v } }))
                if !app.micGranted { Text("Microphone access denied – enable it in Settings → Privacy → Microphone.").foregroundColor(Theme.rec) }
            }
            PanelBox(title: "LOOP (REC / PLAY)") {
                OptionRow(title: "REC ACTION", options: [(RecAction.recDub, "REC→DUB"), (.recPlay, "REC→PLAY")],
                          selection: Binding(get: { g.recAction }, set: { v in app.updateGlobal { $0.recAction = v } }))
                OptionRow(title: "QUANTIZE", options: [(Quantize.off, "OFF"), (.measure, "MEASURE")],
                          selection: Binding(get: { g.quantize }, set: { v in app.updateGlobal { $0.quantize = v } }))
                OptionRow(title: "PLAY MODE", options: [(PlayMode.multi, "MULTI"), (.single, "SINGLE")],
                          selection: Binding(get: { g.playMode }, set: { v in app.updateGlobal { $0.playMode = v } }))
                OptionRow(title: "S.TRK CHANGE", options: [(SingleTrackChange.immediate, "IMMEDIATE"), (.loopEnd, "LOOP END")],
                          selection: Binding(get: { g.singleTrackChange }, set: { v in app.updateGlobal { $0.singleTrackChange = v } }))
                Toggle("AUTO REC", isOn: Binding(get: { g.autoRec }, set: { v in app.updateGlobal { $0.autoRec = v } }))
                ParamSlider(name: "AUTO REC SENS", value: Binding(get: { g.autoRecSensitivity }, set: { v in app.updateGlobal { $0.autoRecSensitivity = v } }), range: 1...100)
                Button("Reset tempo to loop tempo") { app.resetTempoToLoop() }.buttonStyle(.bordered)
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .toggleStyle(SwitchToggleStyle(tint: Theme.play))
        .padding(8)
    }
}

// MARK: - System / about

struct SystemView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            PanelBox(title: "TRACK COLORS") {
                ForEach(0..<5) { t in
                    ColorPicker("TRACK \(t + 1)", selection: $app.trackColors[t]).font(.system(size: 14, design: .monospaced))
                }
            }.frame(width: 300)
            PanelBox(title: "ABOUT") {
                ScrollView {
                    Text("""
                    FiveLoop \(looperCoreVersion) – five-track live looper for iPad.

                    Inspired by the workflow of the BOSS RC-505mkII Loop Station. Not affiliated with, endorsed by or \
                    containing code, samples or firmware from Roland/BOSS. All DSP effects, drum sounds and rhythm \
                    patterns are original.

                    Implemented effect types (\(FXType.allCases.count) of the hardware's \(referenceFXNames.count)):
                    \(FXType.allCases.map { $0.displayName }.joined(separator: ", "))

                    Not yet implemented: \(referenceFXNames.filter { n in !FXType.allCases.contains { n.hasPrefix($0.displayName) } }.joined(separator: ", "))

                    Rhythm: \(patternDefs.count) patterns × 4 variations, 16 synthesised kits.
                    """)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let s = app.snap
        PanelBox(title: "AUDIO ENGINE STATUS") {
            if let d = app.diag {
                Group {
                    row("Engine", app.audioRunning ? "RUNNING" : "STOPPED")
                    row("CPU (audio callback)", String(format: "%.1f %%", d.cpu * 100))
                    row("Overloads (>90 %)", "\(d.overloads)")
                    row("Buffer", "\(d.bufferFrames) frames (\(String(format: "%.1f", Double(d.bufferFrames) / 44.1)) ms)")
                    row("Sample rate", "\(Int(d.sampleRate)) Hz engine / \(Int(d.hardwareRate)) Hz hardware")
                    row("Latency (round trip)", String(format: "%.1f ms", d.latencyMs))
                    row("Input", "\(d.inputChannels) ch, errors \(d.inputErrors)")
                    row("Route", d.route)
                }
            }
            row("Active tracks", "\(s.tracks.filter { $0.state != .empty && $0.state != .stopped }.count) / 5")
            row("Transport", s.running ? String(format: "running, song pos %.0f", s.songPos) : "stopped")
            row("Grid", s.locked ? String(format: "locked, measure = %.0f frames", s.refMeasure) : "free")
            row("Engine blocks processed", "\(s.blocks)")
            row("Memory per track", "\(app.engine.tracks[0].capacity / 44100) s")
            ForEach(0..<5) { t in
                row("Track \(t + 1)", "\(s.tracks[t].state.label)  len \(s.tracks[t].length)  peak \(String(format: "%.2f", s.tracks[t].peak))")
            }
        }
        .padding(8)
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundColor(Theme.dim).frame(width: 240, alignment: .leading); Text(v).foregroundColor(Theme.lcd); Spacer() }
            .font(.system(size: 14, design: .monospaced))
    }
}

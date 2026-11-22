import SwiftUI
import UniformTypeIdentifiers
import LooperCore

// MARK: - FX slot editor

struct FXEditView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.presentationMode) var presentation
    let rack: RackID
    let bank: Int
    let slot: Int

    var body: some View {
        let sm = app.rackModel(rack).banks[bank][slot]
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(rack == .input ? "INPUT" : "TRACK") FX  BANK \(["A", "B", "C", "D"][bank])  [\(["A", "B", "C", "D"][slot])]")
                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                Spacer()
                Button("Done") { presentation.wrappedValue.dismiss() }.font(.headline)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    typeChip(nil, sm.type == nil)
                    ForEach(FXType.available(forTrackFX: rack == .track)) { t in typeChip(t, sm.type == t) }
                }
            }
            if let type = sm.type {
                HStack(spacing: 16) {
                    Toggle("ON", isOn: Binding(get: { sm.on }, set: { v in
                        guard v != sm.on else { return }
                        app.setFXSwitchMode(rack, bank: bank, slot: slot, .toggle)
                        app.fxButton(rack, slot, down: true, bank: bank)
                        app.setFXSwitchMode(rack, bank: bank, slot: slot, sm.switchMode)
                    }))
                        .frame(width: 120)
                    OptionRow(title: "SW MODE", options: [(SwitchMode.toggle, "TOGGLE"), (.momentary, "MOMENT")],
                              selection: Binding(get: { sm.switchMode }, set: { app.setFXSwitchMode(rack, bank: bank, slot: slot, $0) }))
                }
                if rack == .track {
                    OptionRow(title: "INSERT", options: [(-1, "ALL"), (0, "TR1"), (1, "TR2"), (2, "TR3"), (3, "TR4"), (4, "TR5")],
                              selection: Binding(get: { sm.insert }, set: { app.setFXInsert(rack, bank: bank, slot: slot, $0) }))
                }
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(type.params.enumerated()), id: \.offset) { i, spec in
                            paramRow(spec, index: i, value: i < sm.params.count ? sm.params[i] : spec.defaultValue)
                        }
                    }
                }
                Text("Original DSP – comparable behaviour, not a reproduction of the hardware algorithm.")
                    .font(.footnote).foregroundColor(Theme.dim)
            } else {
                Text("No effect assigned to this button.").foregroundColor(Theme.dim)
                Spacer()
            }
        }
        .padding(20)
        .background(Theme.bg.edgesIgnoringSafeArea(.all))
        .foregroundColor(.white)
        .preferredColorScheme(.dark)
    }

    private func typeChip(_ t: FXType?, _ selected: Bool) -> some View {
        Button(action: { app.setFXType(rack, bank: bank, slot: slot, t) }) {
            Text(t?.displayName ?? "OFF").font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundColor(selected ? .black : .white)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.lcd : Theme.panelHi))
        }
    }

    @ViewBuilder private func paramRow(_ spec: FXParamSpec, index i: Int, value: Float) -> some View {
        switch spec.kind {
        case .choice(let opts):
            HStack {
                Text(spec.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(Theme.label).frame(width: 120, alignment: .leading)
                Picker(spec.name, selection: Binding(get: { Int(value.rounded()) }, set: { app.setFXParam(rack, bank: bank, slot: slot, i, Float($0)) })) {
                    ForEach(opts.indices, id: \.self) { Text(opts[$0]).tag($0) }
                }.pickerStyle(.segmented)
            }
        case .range(let lo, let hi):
            ParamSlider(name: spec.name, value: Binding(get: { value }, set: { app.setFXParam(rack, bank: bank, slot: slot, i, $0) }),
                        range: lo...hi, display: { spec.display($0) })
        }
    }
}

// MARK: - Track settings (TRACK button)

struct TrackSettingsView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.presentationMode) var presentation
    let track: Int
    @State private var confirmClear = false
    @State private var importing = false

    var body: some View {
        let s = app.memory.tracks[track]
        let b = { (f: @escaping (inout TrackSettings, Bool) -> Void, get: @escaping (TrackSettings) -> Bool) -> Binding<Bool> in
            Binding(get: { get(app.memory.tracks[track]) }, set: { v in app.updateTrack(track) { f(&$0, v) } })
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TRACK \(track + 1)").font(.system(size: 22, weight: .heavy, design: .monospaced))
                Text(app.snap.tracks[track].state.label).foregroundColor(app.snap.tracks[track].state.color ?? Theme.dim)
                Spacer()
                Button("Done") { presentation.wrappedValue.dismiss() }.font(.headline)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 30) {
                        Toggle("REVERSE", isOn: b({ $0.reverse = $1 }, { $0.reverse }))
                        Toggle("1SHOT", isOn: b({ $0.oneShot = $1 }, { $0.oneShot }))
                        Toggle("LOOP SYNC", isOn: b({ $0.loopSync = $1 }, { $0.loopSync }))
                        Toggle("TEMPO SYNC", isOn: b({ $0.tempoSync = $1 }, { $0.tempoSync }))
                    }
                    HStack(spacing: 30) {
                        Toggle("FX", isOn: b({ $0.fxOn = $1 }, { $0.fxOn }))
                        Toggle("BOUNCE IN", isOn: b({ $0.bounceIn = $1 }, { $0.bounceIn }))
                        Toggle("INPUT", isOn: b({ $0.inputOn = $1 }, { $0.inputOn }))
                        Toggle("RHYTHM→TRACK", isOn: b({ $0.rhythmToTrack = $1 }, { $0.rhythmToTrack }))
                    }
                    Group {
                    ParamSlider(name: "PLAY LEVEL", value: Binding(get: { s.playLevel }, set: { app.setLevel(track, $0) }), range: 0...200)
                    ParamSlider(name: "PAN", value: Binding(get: { s.pan }, set: { app.setPan(track, $0) }), range: -50...50,
                                display: { $0 == 0 ? "CENTER" : ($0 < 0 ? "L\(Int(-$0))" : "R\(Int($0))") })
                    OptionRow(title: "START MODE", options: StartMode.allCases.map { ($0, $0.rawValue.uppercased()) },
                              selection: Binding(get: { s.startMode }, set: { v in app.updateTrack(track) { $0.startMode = v } }))
                    OptionRow(title: "STOP MODE", options: StopMode.allCases.map { ($0, $0.rawValue.uppercased()) },
                              selection: Binding(get: { s.stopMode }, set: { v in app.updateTrack(track) { $0.stopMode = v } }))
                    OptionRow(title: "DUB MODE", options: [(DubMode.overdub, "OVERDUB"), (.replace1, "REPLACE1"), (.replace2, "REPLACE2")],
                              selection: Binding(get: { s.dubMode }, set: { v in app.updateTrack(track) { $0.dubMode = v } }))
                    OptionRow(title: "SPEED", options: PlaySpeed.allCases.map { ($0, $0.rawValue.uppercased()) },
                              selection: Binding(get: { s.speed }, set: { v in app.updateTrack(track) { $0.speed = v } }))
                    OptionRow(title: "MEASURE", options: [(MeasureSetting.auto, "AUTO"), (.free, "FREE"), (.measures(0.25), "1/4"), (.measures(0.5), "1/2"),
                                                          (.measures(1), "1"), (.measures(2), "2"), (.measures(4), "4"), (.measures(8), "8"), (.measures(16), "16")],
                              selection: Binding(get: { s.measure }, set: { v in app.updateTrack(track) { $0.measure = v } }))
                    }
                    ParamSlider(name: "FADE IN", value: Binding(get: { Float(s.fadeInMeasures) }, set: { v in app.updateTrack(track) { $0.fadeInMeasures = Double(v) } }),
                                range: 1...64, display: { "\(Int($0))MEAS" })
                    ParamSlider(name: "FADE OUT", value: Binding(get: { Float(s.fadeOutMeasures) }, set: { v in app.updateTrack(track) { $0.fadeOutMeasures = Double(v) } }),
                                range: 1...64, display: { "\(Int($0))MEAS" })
                    HStack(spacing: 30) {
                        Toggle("ALL START", isOn: b({ $0.allStartTarget = $1 }, { $0.allStartTarget }))
                        Toggle("ALL STOP", isOn: b({ $0.allStopTarget = $1 }, { $0.allStopTarget }))
                        Toggle("MIDI START", isOn: b({ $0.midiStartTarget = $1 }, { $0.midiStartTarget }))
                        Toggle("MIDI STOP", isOn: b({ $0.midiStopTarget = $1 }, { $0.midiStopTarget }))
                    }
                    HStack(spacing: 12) {
                        Button(app.snap.tracks[track].muted ? "UNMUTE" : "MUTE") { app.toggleMute(track) }.buttonStyle(.bordered)
                        Button("EXPORT WAV") { app.exportTrack(track) }.buttonStyle(.bordered)
                        Button("IMPORT WAV…") { importing = true }.buttonStyle(.bordered)
                        Spacer()
                        Button("CLEAR TRACK…") { confirmClear = true }.buttonStyle(.bordered).tint(.red)
                    }
                }
            }
        }
        .padding(20)
        .toggleStyle(SwitchToggleStyle(tint: Theme.play))
        .background(Theme.bg.edgesIgnoringSafeArea(.all))
        .foregroundColor(.white)
        .preferredColorScheme(.dark)
        .alert("Clear track \(track + 1)?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { app.clear(track) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The recording on this track will be erased (UNDO still possible until the next recording).") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.wav, .audio]) { result in
            if case .success(let url) = result { app.importWAV(url, track: track) }
        }
    }
}

// MARK: - Rhythm

struct RhythmView: View {
    @EnvironmentObject var app: AppModel
    @State private var genre = "ROCK"

    var body: some View {
        let r = app.memory.rhythm
        HStack(alignment: .top, spacing: 10) {
            PanelBox(title: "GENRE") {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(rhythmGenres, id: \.self) { g in
                            Button(action: { genre = g }) {
                                Text(g).font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .frame(maxWidth: .infinity, minHeight: 34)
                                    .foregroundColor(genre == g ? .black : .white)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(genre == g ? Theme.lcd : Theme.panelHi))
                            }
                        }
                    }
                }
            }.frame(width: 170)
            PanelBox(title: "PATTERN") {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(patternDefs.indices.filter { patternDefs[$0].genre == genre }, id: \.self) { i in
                            Button(action: { app.updateRhythm { $0.patternIndex = i } }) {
                                HStack {
                                    Text(patternDefs[i].name).font(.system(size: 14, weight: .bold, design: .monospaced))
                                    Spacer()
                                    Text(patternDefs[i].stepsPerQuarter == 3 ? "TRIPLET" : "STRAIGHT").font(.caption2).foregroundColor(Theme.dim)
                                }
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40)
                                .foregroundColor(r.patternIndex == i ? .black : .white)
                                .background(RoundedRectangle(cornerRadius: 5).fill(r.patternIndex == i ? Theme.play : Theme.panelHi))
                            }
                        }
                    }
                }
            }.frame(width: 260)
            VStack(spacing: 10) {
                PanelBox(title: "RHYTHM") {
                    HStack {
                        HWButton(title: app.snap.rhythmPlaying ? "STOP" : "START", led: app.snap.rhythmPlaying ? Theme.play : (app.snap.rhythmArmed ? Theme.dub : nil)) { app.rhythmStartStop() }
                        HWButton(title: "TAP") { app.tapTempo() }
                    }
                    OptionRow(title: "VARIATION", options: [(0, "A"), (1, "B"), (2, "C"), (3, "D")],
                              selection: Binding(get: { r.variation }, set: { v in app.updateRhythm { $0.variation = v } }))
                    OptionRow(title: "KIT", options: kitRecipes.indices.prefix(8).map { ($0, kitRecipes[$0].name) },
                              selection: Binding(get: { r.kitIndex }, set: { v in app.updateRhythm { $0.kitIndex = v } }))
                    OptionRow(title: "", options: kitRecipes.indices.dropFirst(8).map { ($0, kitRecipes[$0].name) },
                              selection: Binding(get: { r.kitIndex }, set: { v in app.updateRhythm { $0.kitIndex = v } }))
                    ParamSlider(name: "TEMPO", value: Binding(get: { Float(app.snap.tempo) }, set: { app.setTempo(Double($0)) }), range: 40...250,
                                display: { String(format: "%.1f", $0) })
                    ParamSlider(name: "LEVEL", value: Binding(get: { r.level }, set: { v in app.updateRhythm { $0.level = v } }), range: 0...200)
                    OptionRow(title: "BEAT", options: [(4, "4/4"), (3, "3/4"), (2, "2/4"), (5, "5/4"), (6, "6/8"), (7, "7/8"), (12, "12/8")],
                              selection: Binding(get: { app.snap.beatsPerMeasure }, set: { v in app.setBeat(v, [6, 7, 12].contains(v) ? 8 : 4) }))
                    OptionRow(title: "START TRIG", options: [(RhythmStartTrigger.loopStart, "LOOP START"), (.beforeLoop, "BEFORE LOOP")],
                              selection: Binding(get: { r.startTrigger }, set: { v in app.updateRhythm { $0.startTrigger = v } }))
                    OptionRow(title: "COUNT-IN", options: [(0, "OFF"), (1, "1 MEAS"), (2, "2 MEAS")],
                              selection: Binding(get: { r.countInMeasures }, set: { v in app.updateRhythm { $0.countInMeasures = v } }))
                    HStack(spacing: 30) {
                        Toggle("FILL", isOn: Binding(get: { r.fill }, set: { v in app.updateRhythm { $0.fill = v } }))
                        Toggle("STOP WITH LOOPS", isOn: Binding(get: { r.stopWithLoops }, set: { v in app.updateRhythm { $0.stopWithLoops = v } }))
                    }
                }
                PanelBox(title: "PADS (also MIDI notes on the rhythm channel)") {
                    HStack(spacing: 6) {
                        ForEach(DrumVoice.allCases, id: \.rawValue) { v in
                            Button(action: { app.engine.send(.drumHit(v.rawValue, 0.9)) }) {
                                Text(String(describing: v).uppercased().prefix(5)).font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.panelHi))
                            }
                        }
                    }
                }
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: Theme.play))
        .padding(8)
        .onAppear { genre = patternDefs[min(app.memory.rhythm.patternIndex, patternDefs.count - 1)].genre }
    }
}

// MARK: - Mixer & Master

struct MixerView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        HStack(spacing: 10) {
            ForEach(0..<5) { t in
                let s = app.memory.tracks[t]
                PanelBox(title: "TRACK \(t + 1)") {
                    Fader(value: Binding(get: { s.playLevel }, set: { app.setLevel(t, $0) }), color: app.trackColors[t]).frame(maxHeight: .infinity)
                    Text(String(format: "%.0f", s.playLevel)).font(.system(size: 13, design: .monospaced)).frame(maxWidth: .infinity)
                    Slider(value: Binding(get: { s.pan }, set: { app.setPan(t, $0) }), in: -50...50, step: 1)
                    Text(s.pan == 0 ? "C" : (s.pan < 0 ? "L\(Int(-s.pan))" : "R\(Int(s.pan))")).font(.caption.monospaced()).frame(maxWidth: .infinity)
                    HWButton(title: app.snap.tracks[t].muted ? "MUTED" : "MUTE", led: app.snap.tracks[t].muted ? Theme.rec : nil, height: 40) { app.toggleMute(t) }
                }
            }
            PanelBox(title: "INPUT") {
                Fader(value: Binding(get: { app.memory.mixer.inputLevel }, set: { v in app.updateMixer { $0.inputLevel = v } })).frame(maxHeight: .infinity)
                Text(String(format: "%.0f", app.memory.mixer.inputLevel)).font(.system(size: 13, design: .monospaced)).frame(maxWidth: .infinity)
                HWButton(title: "MONITOR", led: app.memory.mixer.monitor ? Theme.play : nil, height: 40) { app.updateMixer { $0.monitor.toggle() } }
            }
            PanelBox(title: "RHYTHM") {
                Fader(value: Binding(get: { app.memory.rhythm.level }, set: { v in app.updateRhythm { $0.level = v } })).frame(maxHeight: .infinity)
                Text(String(format: "%.0f", app.memory.rhythm.level)).font(.system(size: 13, design: .monospaced)).frame(maxWidth: .infinity)
            }
            PanelBox(title: "MASTER") {
                HStack {
                    Fader(value: Binding(get: { app.memory.mixer.masterLevel }, set: { v in app.updateMixer { $0.masterLevel = v } }))
                    Meter(level: app.snap.outputPeak)
                }.frame(maxHeight: .infinity)
                Text(String(format: "%.0f", app.memory.mixer.masterLevel)).font(.system(size: 13, design: .monospaced)).frame(maxWidth: .infinity)
            }
        }
        .padding(8)
    }
}

struct MasterFXView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(spacing: 12) {
            PanelBox(title: "MASTER FX") {
                ParamSlider(name: "COMP", value: Binding(get: { app.memory.mixer.masterComp }, set: { v in app.updateMixer { $0.masterComp = v } }),
                            range: 0...40, display: { $0 == 0 ? "OFF" : "\(Int($0))" })
                ParamSlider(name: "REVERB", value: Binding(get: { app.memory.mixer.masterReverb }, set: { v in app.updateMixer { $0.masterReverb = v } }),
                            range: 0...40)
                Text("Applied to the main stereo output (the hardware's INSERT routing to MAIN/SUB outputs is not applicable on iPad).")
                    .font(.footnote).foregroundColor(Theme.dim)
            }
            Spacer()
        }.padding(8)
    }
}

/// Full-screen view of one FX rack: all four banks with every slot.
struct FXRackScreen: View {
    @EnvironmentObject var app: AppModel
    let rack: RackID
    @State private var edit: (Int, Int)? = nil
    var body: some View {
        let m = app.rackModel(rack)
        VStack(spacing: 10) {
            HStack {
                OptionRow(title: "MODE", options: [(FXBankMode.single, "SINGLE"), (.multi, "MULTI")],
                          selection: Binding(get: { m.mode }, set: { app.setBankMode(rack, $0) })).frame(width: 420)
                Spacer()
                HWButton(title: m.bankOn ? "BANK SW ON" : "BANK SW OFF", led: m.bankOn ? Theme.play : nil, width: 160) { app.setBankOn(rack, !m.bankOn) }
            }
            ForEach(0..<4) { b in
                HStack(spacing: 8) {
                    Button(action: { app.selectBank(rack, b) }) {
                        Text("BANK\n\(["A", "B", "C", "D"][b])").font(.system(size: 14, weight: .heavy, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .frame(width: 80, height: 70)
                            .foregroundColor(m.activeBank == b ? .black : .white)
                            .background(RoundedRectangle(cornerRadius: 8).fill(m.activeBank == b ? Theme.lcd : Theme.panelHi))
                    }
                    ForEach(0..<4) { s in
                        let sm = m.banks[b][s]
                        Button(action: { edit = (b, s) }) {
                            VStack(spacing: 4) {
                                Text(["A", "B", "C", "D"][s]).font(.headline)
                                Text(sm.type?.displayName ?? "—").font(.system(size: 12, weight: .bold, design: .monospaced))
                                if rack == .track && sm.type != nil { Text(sm.insert < 0 ? "ALL" : "TRACK \(sm.insert + 1)").font(.caption2).foregroundColor(Theme.dim) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 70)
                            .foregroundColor(.white)
                            .background(RoundedRectangle(cornerRadius: 8).fill(sm.on && m.activeBank == b ? Theme.rec.opacity(0.35) : Theme.panel))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08)))
                        }
                    }
                }
            }
            Text("Tap a slot to edit its effect type and parameters. Switch effects on/off with the [A]–[D] keys on the LOOP screen.")
                .font(.footnote).foregroundColor(Theme.dim)
        }
        .padding(8)
        .sheet(item: Binding(get: { edit.map { TrackID(id: $0.0 * 4 + $0.1) } }, set: { edit = $0.map { ($0.id / 4, $0.id % 4) } })) { id in
            FXEditView(rack: rack, bank: id.id / 4, slot: id.id % 4).environmentObject(app)
        }
    }
}

extension UTType {
    static let floop = UTType(exportedAs: "com.fiveloop.memory", conformingTo: .data)
    static let flbk = UTType(exportedAs: "com.fiveloop.backup", conformingTo: .data)
}

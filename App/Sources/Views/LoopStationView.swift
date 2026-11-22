import SwiftUI
import LooperCore

/// Main performance screen: FX banks, central display, transport keys and five track strips.
struct LoopStationView: View {
    @EnvironmentObject var app: AppModel
    @State private var settingsTrack: Int? = nil

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                FXBankPanel(rack: .input).frame(maxWidth: .infinity)
                CentralDisplay().frame(width: 330)
                FXBankPanel(rack: .track).frame(maxWidth: .infinity)
            }
            .frame(height: 190)
            ControlRow()
            HStack(spacing: 8) {
                ForEach(0..<5) { t in
                    TrackStrip(track: t, openSettings: { settingsTrack = t })
                }
            }
        }
        .padding(8)
        .sheet(item: Binding(get: { settingsTrack.map { TrackID(id: $0) } }, set: { settingsTrack = $0?.id })) { tid in
            TrackSettingsView(track: tid.id).environmentObject(app)
        }
    }
}

struct TrackID: Identifiable { let id: Int }

struct CentralDisplay: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let s = app.snap
        let (measure, beat) = s.measureAndBeat
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "M%02d", app.memoryIndex)).foregroundColor(Theme.dim)
                Text(app.memory.name + (app.dirty ? " *" : "")).lineLimit(1)
                Spacer()
                if s.gridActive { Text(s.locked ? "SYNC" : "GRID").foregroundColor(Theme.play) }
            }
            .font(.system(size: 15, weight: .bold, design: .monospaced))
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.1f", s.tempo)).font(.system(size: 46, weight: .heavy, design: .monospaced))
                Text("BPM").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundColor(Theme.dim)
                Spacer()
                Text("\(s.beatsPerMeasure)/\(s.beatUnit)").font(.system(size: 18, weight: .bold, design: .monospaced))
            }
            HStack(spacing: 5) {
                ForEach(0..<max(1, s.beatsPerMeasure), id: \.self) { b in
                    Circle().fill(s.running && b == beat && s.songPos >= 0 ? (b == 0 ? Theme.rec : Theme.lcd) : Color.white.opacity(0.1))
                        .frame(width: 14, height: 14)
                }
                Spacer()
                Text(s.running ? (s.songPos < 0 ? "COUNT-IN" : "MEAS \(measure + 1)") : "STOP")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            HStack(spacing: 4) {
                ForEach(0..<5) { t in
                    let ts = s.tracks[t]
                    VStack(spacing: 2) {
                        Text("\(t + 1)").font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(t == app.currentTrack ? .white : Theme.dim)
                        Text(ts.state.label).font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(ts.state.color ?? Theme.dim).lineLimit(1).minimumScaleFactor(0.6)
                        Text(ts.measures > 0 ? String(format: ts.measures < 1 ? "%.2fM" : "%.0fM", ts.measures) : "--")
                            .font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.dim)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            HStack {
                Text(s.rhythmPlaying ? "RHYTHM ▶︎" : (s.rhythmArmed ? "RHYTHM ARMED" : "RHYTHM OFF"))
                    .foregroundColor(s.rhythmPlaying ? Theme.play : (s.rhythmArmed ? Theme.dub : Theme.dim))
                Spacer()
                Text(patternDefs[min(app.memory.rhythm.patternIndex, patternDefs.count - 1)].name + " " + ["A", "B", "C", "D"][app.memory.rhythm.variation])
                    .foregroundColor(Theme.dim)
            }
            .font(.system(size: 11, weight: .bold, design: .monospaced))
        }
        .foregroundColor(Theme.lcd)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.lcdBg))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.lcd.opacity(0.25)))
    }
}

struct ControlRow: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let s = app.snap
        let cur = s.tracks[app.currentTrack]
        HStack(spacing: 8) {
            HWButton(title: "UNDO/REDO", subtitle: "TRACK \(app.currentTrack + 1)",
                     led: cur.canUndo ? Theme.dub : (cur.canRedo ? Theme.lcd : nil)) { app.undoRedo() }
            HWButton(title: "TAP", subtitle: "TEMPO", led: s.running ? Theme.rec.opacity(0.7) : nil) { app.tapTempo() }
            HWButton(title: "RHYTHM", subtitle: s.rhythmPlaying ? "STOP" : "START",
                     led: s.rhythmPlaying ? Theme.play : (s.rhythmArmed ? Theme.dub : nil), blink: s.rhythmArmed && !s.rhythmPlaying) { app.rhythmStartStop() }
            HWButton(title: "EDIT", subtitle: "RHYTHM") { app.screen = .rhythm }
            HWButton(title: "ALL START/STOP", led: s.running ? Theme.play : nil) { app.allStartStop() }
            HWButton(title: "◀︎ MEM", subtitle: nil) { app.loadMemory(max(1, app.memoryIndex - 1)) }
            HWButton(title: "MEM ▶︎", subtitle: nil) { app.loadMemory(min(99, app.memoryIndex + 1)) }
            HWButton(title: "WRITE", subtitle: "SAVE M\(app.memoryIndex)", led: app.dirty ? Theme.rec : nil) { app.saveMemory() }
        }
        .frame(height: 58)
    }
}

/// One loop track: REC/PLAY pad with loop-position ring, STOP, TRACK, FX keys, level fader.
struct TrackStrip: View {
    @EnvironmentObject var app: AppModel
    let track: Int
    var openSettings: () -> Void
    @State private var blink = false

    var body: some View {
        let ts = app.snap.tracks[track]
        let settings = app.memory.tracks[track]
        let color = app.trackColors[track]
        VStack(spacing: 6) {
            HStack {
                Text("TRACK \(track + 1)").font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundColor(track == app.currentTrack ? color : Theme.label)
                Spacer()
                if ts.muted { Text("MUTE").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.rec) }
                Text(ts.state.label).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(ts.state.color ?? Theme.dim)
            }
            HStack(spacing: 6) {
                HWButton(title: "TRACK", led: track == app.currentTrack ? color : nil, height: 44) {
                    app.currentTrack = track; openSettings()
                }
                HWButton(title: "FX", led: settings.fxOn ? Theme.lcd : nil, height: 44) { app.toggleTrackFX(track) }
            }
            HStack(spacing: 6) {
                Fader(value: Binding(get: { settings.playLevel }, set: { app.setLevel(track, $0) }), color: color)
                    .frame(width: 46)
                Meter(level: ts.peak)
                VStack(spacing: 8) {
                    RecPlayPad(state: ts.state, position: ts.position, color: color, blink: blink) { app.recPlay(track) }
                    Text(String(format: "LEVEL %.0f", settings.playLevel)).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim)
                    StopPad(active: ts.state == .stopping, blink: blink) { app.stop(track) }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(track == app.currentTrack ? color.opacity(0.6) : Color.white.opacity(0.05), lineWidth: 1.5))
        .onAppear { withAnimation(.easeInOut(duration: 0.3).repeatForever()) { blink.toggle() } }
    }
}

struct RecPlayPad: View {
    let state: TrackState
    let position: Float
    let color: Color
    let blink: Bool
    var action: () -> Void
    var body: some View {
        let led = state.color
        let blinking = state == .recStandby || state == .stopping
        Button(action: action) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                Circle().stroke(Color.black, lineWidth: 10)
                if let l = led {
                    Circle().stroke(l.opacity(blinking && blink ? 0.25 : 0.9), lineWidth: 6).shadow(color: l, radius: 6)
                }
                if state == .playing || state == .overdubbing || state == .stopping {
                    Circle().trim(from: 0, to: CGFloat(position)).rotation(.degrees(-90))
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round)).padding(9)
                }
                VStack(spacing: 2) {
                    Image(systemName: icon).font(.system(size: 26, weight: .bold))
                    Text("REC/PLAY").font(.system(size: 9, weight: .heavy, design: .rounded))
                }
                .foregroundColor(.white)
            }
            .frame(maxWidth: 120, maxHeight: 120)
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(PressStyle())
    }
    var icon: String {
        switch state {
        case .empty, .recStandby: return "record.circle"
        case .recording: return "waveform"
        case .overdubbing: return "plus.circle"
        case .playing, .stopping: return "play.fill"
        case .stopped: return "play"
        }
    }
}

struct StopPad: View {
    let active: Bool
    let blink: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { Image(systemName: "stop.fill"); Text("STOP").font(.system(size: 12, weight: .heavy, design: .rounded)) }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 8).fill(active && blink ? Theme.rec.opacity(0.35) : Theme.panelHi))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.6)))
        }
        .buttonStyle(PressStyle())
    }
}

/// Four [A]–[D] keys of the active bank + bank selector. Long-press a key to edit it.
struct FXBankPanel: View {
    @EnvironmentObject var app: AppModel
    let rack: RackID
    @State private var editSlot: Int? = nil

    var body: some View {
        let model = app.rackModel(rack)
        PanelBox(title: rack == .input ? "INPUT FX" : "TRACK FX") {
            HStack(spacing: 4) {
                ForEach(0..<4) { b in
                    Button(action: { app.selectBank(rack, b) }) {
                        Text("BANK \(["A", "B", "C", "D"][b])").font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(model.activeBank == b ? .black : Theme.label)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(RoundedRectangle(cornerRadius: 5).fill(model.activeBank == b ? Theme.lcd : Theme.panelHi))
                    }
                }
                Button(action: { app.setBankOn(rack, !model.bankOn) }) {
                    Text(model.bankOn ? "ON" : "OFF").font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(model.bankOn ? Theme.play : Theme.rec).frame(width: 40, height: 28)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelHi))
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<4) { s in
                    let slot = model.banks[model.activeBank][s]
                    VStack(spacing: 3) {
                        FXKey(letter: ["A", "B", "C", "D"][s], slot: slot, rack: rack, slotIndex: s)
                        Button(action: { editSlot = s }) {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                                .foregroundColor(Theme.label).frame(maxWidth: .infinity, minHeight: 22)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panelHi.opacity(0.6)))
                        }
                    }
                }
            }
        }
        .sheet(item: Binding(get: { editSlot.map { TrackID(id: $0) } }, set: { editSlot = $0?.id })) { sid in
            FXEditView(rack: rack, bank: app.rackModel(rack).activeBank, slot: sid.id).environmentObject(app)
        }
    }
}

struct FXKey: View {
    @EnvironmentObject var app: AppModel
    let letter: String
    let slot: FXSlotModel
    let rack: RackID
    let slotIndex: Int
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 4) {
            Capsule().fill(slot.on ? Theme.rec : Color.black.opacity(0.5)).frame(height: 5)
                .shadow(color: slot.on ? Theme.rec : .clear, radius: 4)
            Text(letter).font(.system(size: 20, weight: .heavy, design: .rounded))
            Text(slot.type?.displayName ?? "—").font(.system(size: 9, weight: .semibold, design: .monospaced))
                .lineLimit(2).multilineTextAlignment(.center).minimumScaleFactor(0.6)
            if rack == .track, slot.type != nil {
                Text(slot.insert < 0 ? "ALL" : "TR\(slot.insert + 1)").font(.system(size: 8, design: .monospaced)).foregroundColor(Theme.dim)
            }
        }
        .foregroundColor(.white)
        .padding(6)
        .frame(maxWidth: .infinity, minHeight: 84)
        .background(RoundedRectangle(cornerRadius: 8).fill(pressed ? Theme.panelHi.opacity(1.4) : Theme.panelHi))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.6)))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true; app.fxButton(rack, slotIndex, down: true) } }
                .onEnded { _ in pressed = false; app.fxButton(rack, slotIndex, down: false) }
        )
    }
}

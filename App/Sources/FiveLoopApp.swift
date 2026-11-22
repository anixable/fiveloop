import SwiftUI
import UIKit
import LooperCore

@main
struct FiveLoopApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .onAppear {
                    app.startAudio()
                    let model = app
                    delegate.onTerminate = { [weak model] in model?.appWillTerminate() }
                }
        }
        .onChange(of: phase) { p in if p == .background { app.enterBackground() } }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    var onTerminate: (() -> Void)?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UIApplication.shared.isIdleTimerDisabled = true   // never dim the screen during a performance
        return true
    }
    func applicationWillTerminate(_ application: UIApplication) { onTerminate?() }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavBar()
            Group {
                switch app.screen {
                case .loop: LoopStationView()
                case .mixer: MixerView()
                case .inputFX: FXRackScreen(rack: .input)
                case .trackFX: FXRackScreen(rack: .track)
                case .master: MasterFXView()
                case .rhythm: RhythmView()
                case .memory: MemoryView()
                case .midi: MIDISettingsView()
                case .audio: AudioSettingsView()
                case .system: SystemView()
                case .diagnostics: DiagnosticsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg.edgesIgnoringSafeArea(.all))
        .foregroundColor(.white)
        .overlay(busyOverlay)
        .alert("FiveLoop", isPresented: Binding(get: { app.message != nil }, set: { if !$0 { app.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(app.message ?? "") }
        .alert("Recover last session?", isPresented: $app.recoveryAvailable) {
            Button("Restore") { app.restoreRecovery() }
            Button("Discard", role: .destructive) { app.recoveryAvailable = false; app.loadMemory(app.memoryIndex) }
        } message: { Text("FiveLoop did not close normally. The automatic backup of your last session can be restored.") }
        .sheet(isPresented: Binding(get: { !app.shareItems.isEmpty }, set: { if !$0 { app.shareItems = [] } })) {
            ShareSheet(items: app.shareItems)
        }
        .statusBar(hidden: true)
    }

    @ViewBuilder private var busyOverlay: some View {
        if let b = app.busy {
            ZStack {
                Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                VStack(spacing: 12) { ProgressView(); Text(b).font(.headline.monospaced()) }
                    .padding(30).background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            }
        }
    }
}

struct NavBar: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Screen.allCases) { s in
                Button(action: { app.screen = s }) {
                    Text(s.rawValue).font(.system(size: 12, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 10).frame(minHeight: 36)
                        .foregroundColor(app.screen == s ? .black : Theme.label)
                        .background(RoundedRectangle(cornerRadius: 6).fill(app.screen == s ? Theme.lcd : Theme.panel))
                }
            }
            Spacer()
            if !app.audioRunning { Text("AUDIO OFF").font(.caption.bold()).foregroundColor(Theme.rec) }
            Text(String(format: "IN %@", app.snap.inputPeak > 0.9 ? "CLIP" : "")).font(.caption.monospaced())
                .foregroundColor(app.snap.inputPeak > 0.9 ? Theme.rec : Theme.dim)
            Meter(level: app.snap.inputPeak).frame(height: 30)
            Meter(level: app.snap.outputPeak).frame(height: 30)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.black)
    }
}

import SwiftUI
import UIKit
import LooperCore

// Original "hardware" look: dark anodised panel, rubber pads with LED rings.
enum Theme {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let panel = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let panelHi = Color(red: 0.19, green: 0.19, blue: 0.22)
    static let label = Color(white: 0.75)
    static let dim = Color(white: 0.4)
    static let rec = Color(red: 1, green: 0.18, blue: 0.15)
    static let dub = Color(red: 1, green: 0.75, blue: 0.1)
    static let play = Color(red: 0.2, green: 0.95, blue: 0.35)
    static let lcd = Color(red: 0.55, green: 0.85, blue: 1.0)
    static let lcdBg = Color(red: 0.02, green: 0.05, blue: 0.08)
}

struct PanelBox<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let t = title { Text(t).font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundColor(Theme.dim) }
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
    }
}

/// Rectangular hardware-style key with an LED strip.
struct HWButton: View {
    let title: String
    var subtitle: String? = nil
    var led: Color? = nil
    var blink = false
    var width: CGFloat? = nil
    var height: CGFloat = 54
    var action: () -> Void
    @State private var phase = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Capsule().fill(ledColor).frame(height: 4).padding(.horizontal, 8)
                    .shadow(color: (led ?? .clear).opacity(0.8), radius: led == nil ? 0 : 4)
                Text(title).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let s = subtitle { Text(s).font(.system(size: 9, design: .monospaced)).foregroundColor(Theme.label).lineLimit(1) }
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
            .frame(maxWidth: width ?? .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: [Theme.panelHi, Theme.panel], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .onAppear { if blink { withAnimation(.easeInOut(duration: 0.25).repeatForever()) { phase.toggle() } } }
    }
    private var ledColor: Color {
        guard let l = led else { return Color.black.opacity(0.5) }
        return blink && phase ? l.opacity(0.2) : l
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1).brightness(configuration.isPressed ? 0.08 : 0)
    }
}

/// Vertical fader 0…max with a unity mark. Large touch area for live use.
struct Fader: View {
    @Binding var value: Float
    var maxValue: Float = 200
    var unity: Float = 100
    var color: Color = .white
    var body: some View {
        GeometryReader { g in
            let h = g.size.height, w = g.size.width
            let y = h - CGFloat(value / maxValue) * h
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 3).fill(Color.black).frame(width: 6).frame(maxWidth: .infinity)
                Rectangle().fill(Theme.dim).frame(width: w * 0.6, height: 1)
                    .offset(y: h - CGFloat(unity / maxValue) * h)
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Color(white: 0.85), Color(white: 0.5)], startPoint: .top, endPoint: .bottom))
                    .overlay(Rectangle().fill(color).frame(height: 2))
                    .frame(width: min(w, 46), height: 26)
                    .offset(y: max(0, min(h - 26, y - 13)))
                    .shadow(radius: 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let f = Float(1 - v.location.y / h) * maxValue
                value = (abs(f - unity) < maxValue * 0.02 ? unity : min(maxValue, max(0, f))).rounded()
            })
            .onTapGesture(count: 2) { value = unity }
        }
    }
}

struct Meter: View {
    var level: Float
    var body: some View {
        GeometryReader { g in
            let db = max(-60, 20 * log10(max(level, 1e-6)))
            let f = CGFloat((db + 60) / 60)
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.black)
                Rectangle().fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(height: g.size.height * f)
            }
        }
        .frame(width: 5)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

/// Labeled slider for parameter editing.
struct ParamSlider: View {
    let name: String
    @Binding var value: Float
    var range: ClosedRange<Float>
    var display: (Float) -> String = { String(format: "%.0f", $0) }
    var body: some View {
        HStack {
            Text(name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(Theme.label).frame(width: 120, alignment: .leading)
            Slider(value: $value, in: range, step: range.upperBound - range.lowerBound > 20 ? 1 : 0.5)
            Text(display(value)).font(.system(size: 13, design: .monospaced)).foregroundColor(Theme.lcd).frame(width: 70, alignment: .trailing)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension TrackState {
    var color: Color? {
        switch self {
        case .recording, .recStandby: return Theme.rec
        case .overdubbing: return Theme.dub
        case .playing, .stopping: return Theme.play
        case .stopped: return Color.green.opacity(0.25)
        case .empty: return nil
        }
    }
    var label: String {
        switch self {
        case .empty: return "EMPTY"; case .recStandby: return "STANDBY"; case .recording: return "REC"
        case .playing: return "PLAY"; case .overdubbing: return "DUB"; case .stopped: return "STOP"; case .stopping: return "STOPPING"
        }
    }
}

/// Picker with a fixed list of labelled options, compact for settings screens.
struct OptionRow<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(Theme.label).frame(width: 150, alignment: .leading)
            Picker(title, selection: $selection) {
                ForEach(options.indices, id: \.self) { i in Text(options[i].1).tag(options[i].0) }
            }
                .pickerStyle(.segmented)
        }
    }
}

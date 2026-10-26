import QuartzCore
import SwiftUI

/// Everything Air Control draws over one display. Positions come in global top-left points and are
/// converted to this display's local space.
struct OverlayView: View {
    @Environment(AppModel.self) private var app
    /// This display's frame in global top-left points.
    let display: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let r = app.flashRect, r.intersects(display) {
                FlashHighlight(rect: local(r))
            }
            if app.windowMenu.isOpen, display.contains(app.windowMenu.center) {
                WindowMenuView(display: display)
                    .transition(.opacity)
            }
            if app.cursor.phase != .hidden, display.contains(app.pointer) {
                CursorView(display: display)
            }
            if app.focusDisplay == display {
                VStack(spacing: 10) {
                    Spacer()
                    VoiceBar()
                    CaptionBar()
                    ToastView()
                }
                .padding(.bottom, 110)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: display.width, height: display.height)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func local(_ r: CGRect) -> CGRect {
        r.offsetBy(dx: -display.minX, dy: -display.minY)
    }
}

/// The pointer: a drop of clear liquid glass.
///
/// It's drawn rather than made with `glassEffect`, because system Liquid Glass always samples and
/// frosts whatever is behind it. This lens only bends light at its rim — a bright edge, a soft
/// refraction band, a specular glint — so the text and controls under it stay perfectly sharp.
///
/// Spring physics make it feel alive: it pops in when your palm goes up, stretches along fast moves
/// and settles with a little overshoot, squishes as you pinch and springs back when you let go,
/// wobbles as it morphs onto a button, and breathes very slightly while idle.
struct CursorView: View {
    @Environment(AppModel.self) private var app
    let display: CGRect
    @State private var blob = GlassBlob()

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let s = blob.advance(to: target(at: t), at: t)
            ZStack(alignment: .topLeading) {
                Color.clear
                LiquidGlass(size: s.size, radius: s.radius, tint: s.tint, lifted: app.cursor.phase == .dragging)
                    .rotationEffect(.radians(-s.angle))
                    .scaleEffect(x: 1 + s.stretch, y: 1 / (1 + s.stretch * 0.6))
                    .rotationEffect(.radians(s.angle))
                    .position(s.center)
                decorations(s)
            }
            .frame(width: display.width, height: display.height, alignment: .topLeading)
        }
        .opacity(app.cursor.phase == .coasting ? 0.45 : 1)
        .animation(.easeOut(duration: 0.2), value: app.cursor.phase == .coasting)
    }

    private func local(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - display.minX, y: p.y - display.minY)
    }

    /// The shape the glass is springing toward right now.
    private func target(at t: TimeInterval) -> GlassBlob.Target {
        let cursor = app.cursor
        if let s = snapFrame, let snap = app.snap {
            let pressed = cursor.phase == .pressed
            let f = pressed ? s.insetBy(dx: s.width * 0.025, dy: s.height * 0.05) : s
            return .init(center: f.center, size: f.size, radius: min(snap.cornerRadius + 2, f.height / 2),
                         tint: pressed ? 0.3 : 0.1, stretchy: false, snapped: true, pulse: app.clickPulse)
        }
        var d: CGFloat
        var tint = 0.1
        switch cursor.phase {
        case .acquiring(let progress):
            d = 6 + 20 * CGFloat(progress)
        case .pressed, .holding:
            d = 16
            tint = 0.4
        case .dragging:
            d = 30
            tint = 0.28
        case .scrolling:
            d = 30
            tint = 0.22
        case .twoHand:
            d = 22
            tint = 0.22
        case .gesture:
            d = 20
            tint = 0.32
        default:
            // Shrinks as the fingers close, and breathes a hair while you're just pointing.
            d = 26 - 10 * cursor.pinchAmount + CGFloat(sin(t * 2.4)) * 0.6
        }
        if !app.systemPointerHidden { d += 10 }   // leave room for the arrow's tip
        return .init(center: local(app.pointer), size: CGSize(width: d, height: d), radius: d / 2,
                     tint: tint, stretchy: true, snapped: false, pulse: app.clickPulse)
    }

    /// Snap target in local coordinates, a little larger than the control and nudged toward the
    /// hand (parallax) like the iPadOS pointer.
    private var snapFrame: CGRect? {
        guard let snap = app.snap, app.snapping else { return nil }
        switch app.cursor.phase {
        case .free, .pressed: break
        default: return nil
        }
        let f = snap.frame.insetBy(dx: -6, dy: -4).offsetBy(dx: -display.minX, dy: -display.minY)
        let hand = app.cursor.point
        let nx = max(-1, min(1, (hand.x - snap.frame.midX) / max(snap.frame.width, 1)))
        let ny = max(-1, min(1, (hand.y - snap.frame.midY) / max(snap.frame.height, 1)))
        return f.offsetBy(dx: nx * 3, dy: ny * 2)
    }

    @ViewBuilder private func decorations(_ s: GlassBlob.State) -> some View {
        let cursor = app.cursor
        let ring = max(s.size.width, s.size.height) + 14

        // A ripple when a click lands.
        if let p = s.pulse {
            let base = max(min(s.size.width, s.size.height), 20)
            let fade = Double(1 - p)
            Circle()
                .strokeBorder(Color.white.opacity(0.7 * fade), lineWidth: 1.5)
                .frame(width: base * (1 + 1.3 * p), height: base * (1 + 1.3 * p))
                .shadow(color: .black.opacity(0.25 * fade), radius: 2)
                .position(s.center)
        }

        switch cursor.phase {
        case .acquiring(let progress):
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 34, height: 34)
                .position(s.center)
        case .holding, .pressed:
            if !s.snapped {
                Circle()
                    .trim(from: 0, to: cursor.holdProgress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: ring, height: ring)
                    .position(s.center)
            }
        case .scrolling:
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .position(s.center)
        case .twoHand:
            TwoHandIndicator(center: s.center, gestures: app.twoHands)
        case .gesture(let pose):
            HintPill(text: pose == .victory ? "✌️  ← Back · Forward →  ·  hold still to talk"
                                            : "Three fingers  ← → Spaces  ·  ↑ Mission Control  ·  ↓ Windows")
                .position(x: s.center.x, y: s.center.y + 34)
        default:
            EmptyView()
        }

        if app.twoHands.phase == .modifier {
            Text("⇧")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.accentColor))
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                .position(x: s.center.x + s.size.width / 2 + 8, y: s.center.y + s.size.height / 2 + 6)
                .transition(.scale.combined(with: .opacity))
        }
    }
}

/// A small label under the pointer explaining what the current pose can do.
private struct HintPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .fixedSize()
    }
}

/// ☝️ held still: a ring of glass buttons for the window under the pointer, which is outlined.
/// The control in the direction of the pointer swells; pinch to do it.
struct WindowMenuView: View {
    @Environment(AppModel.self) private var app
    let display: CGRect
    @State private var shown = false

    var body: some View {
        let menu = app.windowMenu
        let c = CGPoint(x: menu.center.x - display.minX, y: menu.center.y - display.minY)
        ZStack(alignment: .topLeading) {
            Color.clear
            if let f = menu.windowFrame {
                let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
                shape
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(shape.strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 3))
                    .frame(width: f.width, height: f.height)
                    .position(x: f.midX - display.minX, y: f.midY - display.minY)
                    .transition(.opacity)
            }
            ForEach(WindowAction.allCases) { action in
                let selected = menu.selection == action
                let a = Double(action.angle) * .pi / 180
                let r = WindowMenu.radius * (shown ? 1 : 0.35)
                ZStack {
                    LiquidGlass(size: CGSize(width: 50, height: 50), radius: 25, tint: selected ? 0.5 : 0.14,
                                lifted: selected)
                    Image(systemName: action.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.55), radius: 1.5)
                }
                .scaleEffect(selected ? 1.22 : 1)
                .position(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: selected)
            }
            HintPill(text: menu.selection?.title ?? "Point at an action, then pinch")
                .position(x: c.x, y: c.y + WindowMenu.radius + 50)
        }
        .frame(width: display.width, height: display.height, alignment: .topLeading)
        .opacity(shown ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: menu.windowFrame)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.6)) { shown = true }
        }
    }
}

/// While both hands are pinched: a glass bead for each hand, spread the way your hands are, and a
/// readout of what the gesture is doing.
private struct TwoHandIndicator: View {
    let center: CGPoint
    let gestures: TwoHandGestures

    var body: some View {
        let v = gestures.spread
        let len = hypot(v.x, v.y)
        // Keep the beads on screen and readable: between 40 and 360 points apart.
        let k = len > 0 ? min(max(len, 40), 360) / len / 2 : 0
        let a = CGPoint(x: center.x - v.x * k, y: center.y - v.y * k)
        let b = CGPoint(x: center.x + v.x * k, y: center.y + v.y * k)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: a)
                p.addLine(to: b)
            }
            .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 5]))
            .shadow(color: .black.opacity(0.3), radius: 1)
            LiquidGlass(size: CGSize(width: 16, height: 16), radius: 8, tint: 0.25).position(a)
            LiquidGlass(size: CGSize(width: 16, height: 16), radius: 8, tint: 0.25).position(b)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .position(center)
            if gestures.zooming || gestures.rotating {
                Text(readout)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .position(x: center.x, y: center.y + 30)
            }
        }
    }

    private var symbol: String {
        if gestures.zooming { return gestures.scale >= 1 ? "plus.magnifyingglass" : "minus.magnifyingglass" }
        if gestures.rotating { return "arrow.clockwise" }
        if gestures.panning { return "arrow.up.and.down.and.arrow.left.and.right" }
        return "arrow.left.and.right"
    }

    private var readout: String {
        var parts: [String] = []
        if gestures.zooming { parts.append("\(Int((gestures.scale * 100).rounded()))%") }
        if gestures.rotating { parts.append("\(Int(gestures.rotation.rounded()))°") }
        return parts.joined(separator: "  ")
    }
}

/// Clear liquid glass, drawn by hand: a faint tint, a rim that's brightest where light would catch
/// it, a soft refraction band just inside the edge, and a specular glint. Nothing here samples or
/// blurs the screen behind it — the only blurs are on the lens's own highlights.
struct LiquidGlass: View {
    var size: CGSize
    var radius: CGFloat
    var tint: Double = 0.1
    var lifted = false

    var body: some View {
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        let short = min(w, h)
        let shape = RoundedRectangle(cornerRadius: max(0, min(radius, short / 2)), style: .continuous)
        ZStack {
            // Body: barely tinted, so what's underneath reads clearly.
            shape.fill(LinearGradient(colors: [Color.accentColor.opacity(tint * 0.45), Color.accentColor.opacity(tint)],
                                      startPoint: .top, endPoint: .bottom))
            // Light bending at the edge: a soft bright band inside the rim, strongest top and bottom.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06), .white.opacity(0.38)],
                                              startPoint: .top, endPoint: .bottom),
                               lineWidth: min(5, max(2, short * 0.18)))
                .blur(radius: min(2.5, short * 0.08))
            // Depth: a whisper of shade along the lower inside edge.
            shape.strokeBorder(LinearGradient(colors: [.clear, .black.opacity(0.18)], startPoint: .center, endPoint: .bottom),
                               lineWidth: 1.5)
                .blur(radius: 0.8)
            // Specular glint, upper left.
            Ellipse()
                .fill(RadialGradient(colors: [.white.opacity(0.9), .white.opacity(0)], center: .center,
                                     startRadius: 0, endRadius: short * 0.32))
                .frame(width: min(w * 0.55, short * 0.7), height: short * 0.34)
                .offset(x: -w * 0.16, y: -h * 0.24)
                .blendMode(.plusLighter)
            // Rim.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.95), .white.opacity(0.3), .white.opacity(0.75)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing),
                               lineWidth: 1.2)
        }
        .frame(width: w, height: h)
        .clipShape(shape)
        // A hairline outside the rim so the lens still reads on a white page.
        .overlay(shape.stroke(Color.black.opacity(0.25), lineWidth: 0.75))
        .compositingGroup()
        .shadow(color: .black.opacity(lifted ? 0.32 : 0.2), radius: lifted ? 10 : 5, y: lifted ? 6 : 2)
    }
}

/// A few damped springs that give the glass weight. Under-damped on purpose: it overshoots a
/// little and settles, which is what makes it feel bouncy rather than mechanical.
final class GlassBlob {
    struct Target {
        var center: CGPoint
        var size: CGSize
        var radius: CGFloat
        var tint: Double
        /// Stretch along the direction of travel (off while morphed onto a control).
        var stretchy: Bool
        var snapped: Bool
        /// `AppModel.clickPulse`; a change makes the glass pop and ripple.
        var pulse: Int
    }

    struct State {
        var center: CGPoint
        var size: CGSize
        var radius: CGFloat
        var tint: Double
        var stretch: CGFloat
        /// Direction of travel, radians.
        var angle: Double
        var snapped: Bool
        /// 0…1 while a click ripple plays.
        var pulse: CGFloat?
    }

    private struct Spring {
        var value: Double = 0
        var velocity: Double = 0

        mutating func step(to target: Double, stiffness k: Double, damping zeta: Double, dt: Double) {
            let c = 2 * zeta * k.squareRoot()
            velocity += (k * (target - value) - c * velocity) * dt
            value += velocity * dt
        }
    }

    private var x = Spring(), y = Spring(), w = Spring(), h = Spring(), r = Spring(), tint = Spring(), stretch = Spring()
    private var angle: Double = 0
    private var last: TimeInterval?
    private var lastPulse: Int?
    private var pulseAt: TimeInterval?

    func advance(to target: Target, at t: TimeInterval) -> State {
        if lastPulse == nil { lastPulse = target.pulse }
        if target.pulse != lastPulse {
            lastPulse = target.pulse
            pulseAt = t
            // Pop: the glass swells past its size and bounces back.
            w.velocity += 240
            h.velocity += 240
        }

        if let last {
            let dt = min(max(t - last, 0), 1.0 / 20.0)
            // Snapping onto a control is a softer, bouncier spring than following the hand.
            let (kc, zc) = target.snapped ? (420.0, 0.6) : (2600.0, 0.78)
            let (ks, zs) = (560.0, 0.42)
            // Small fixed substeps keep the stiff springs stable at any frame rate.
            let steps = max(1, Int((dt * 480).rounded(.up)))
            let sub = dt / Double(steps)
            for _ in 0..<steps {
                x.step(to: Double(target.center.x), stiffness: kc, damping: zc, dt: sub)
                y.step(to: Double(target.center.y), stiffness: kc, damping: zc, dt: sub)
                w.step(to: Double(target.size.width), stiffness: ks, damping: zs, dt: sub)
                h.step(to: Double(target.size.height), stiffness: ks, damping: zs, dt: sub)
                r.step(to: Double(target.radius), stiffness: ks, damping: zs, dt: sub)
                tint.step(to: target.tint, stiffness: 300, damping: 1, dt: sub)
                let speed = hypot(x.velocity, y.velocity)
                let want = target.stretchy ? min(speed / 2600, 0.42) : 0
                stretch.step(to: want, stiffness: 420, damping: 0.5, dt: sub)
            }
            let speed = hypot(x.velocity, y.velocity)
            if speed > 80 { angle = atan2(y.velocity, x.velocity) }
        } else {
            // First frame: appear right at the pointer, small, and pop up to size.
            x = Spring(value: Double(target.center.x))
            y = Spring(value: Double(target.center.y))
            w = Spring(value: Double(target.size.width) * 0.3)
            h = Spring(value: Double(target.size.height) * 0.3)
            r = Spring(value: Double(target.radius) * 0.3)
            tint = Spring(value: target.tint)
        }
        last = t

        var pulse: CGFloat?
        if let at = pulseAt {
            let p = (t - at) / 0.4
            if p >= 1 { pulseAt = nil } else { pulse = CGFloat(p) }
        }
        return State(center: CGPoint(x: x.value, y: y.value),
                     size: CGSize(width: max(w.value, 2), height: max(h.value, 2)),
                     radius: CGFloat(max(r.value, 0)),
                     tint: min(max(tint.value, 0), 1),
                     stretch: CGFloat(max(stretch.value, -0.15)),
                     angle: angle,
                     snapped: target.snapped,
                     pulse: pulse)
    }
}

/// Outlines the control a voice command is about to click.
struct FlashHighlight: View {
    let rect: CGRect
    @State private var shown = false

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.15)))
            .frame(width: rect.width + 12, height: rect.height + 8)
            .scaleEffect(shown ? 1 : 1.25)
            .opacity(shown ? 1 : 0)
            .position(x: rect.midX, y: rect.midY)
            .onAppear { withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { shown = true } }
    }
}

/// Live transcript after "Hey Mac", progress while the on-device model thinks, and the
/// dictation banner.
struct VoiceBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let voice = app.voice
        let awake = voice.phase == .awake && voice.heardWake
        Group {
            if voice.dictating {
                bar(icon: "text.cursor", title: "Dictating", detail: "Say “stop dictation” when you’re done", tint: true)
            } else if app.interpreting {
                HStack(spacing: 14) {
                    ProgressView().controlSize(.small)
                    Text("“\(app.interpretingText)”").font(.title3.weight(.semibold)).lineLimit(1)
                }
                .padding(.horizontal, 22)
                .frame(height: 56)
                .glassEffect(.regular, in: .capsule)
            } else if awake {
                HStack(spacing: 16) {
                    Waveform(levels: voice.levels).frame(width: 90, height: 30)
                    Text(voice.transcript.isEmpty ? "Listening…" : voice.transcript)
                        .font(.title2.weight(.semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 24)
                .frame(height: 62)
                .frame(maxWidth: 760)
                .glassEffect(.regular.tint(Color.accentColor.opacity(0.18)), in: .capsule)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: awake)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: voice.dictating)
    }

    private func bar(icon: String, title: String, detail: String, tint: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .frame(height: 54)
        .glassEffect(.regular.tint(tint ? Color.accentColor.opacity(0.12) : .clear), in: .capsule)
    }
}

/// Live captions of what the mic hears: bright while it's being taken as a command, dim for
/// background talk; afterwards, what happened with it.
struct CaptionBar: View {
    @Environment(AppModel.self) private var app

    private enum Line: Equatable {
        case live(String, isCommand: Bool)
        case result(HeardPhrase)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let line = currentLine(now: CACurrentMediaTime())
            ZStack {
                if let line { content(line).transition(.opacity) }
            }
            .animation(.easeOut(duration: 0.2), value: line)
        }
    }

    private func currentLine(now: TimeInterval) -> Line? {
        guard app.showCaptions, app.voiceEnabled else { return nil }
        let voice = app.voice
        if voice.phase == .awake && voice.heardWake { return nil }   // the voice bar shows it
        if !voice.live.isEmpty, now - voice.liveUpdated < 3 {
            let isCommand = voice.phase == .awake && (voice.openMic || voice.dictating)
            return .live(Self.tail(voice.live), isCommand: isCommand)
        }
        if let heard = app.heard, now - heard.at < 4 { return .result(heard) }
        return nil
    }

    @ViewBuilder private func content(_ line: Line) -> some View {
        HStack(spacing: 10) {
            Image(systemName: app.voice.openMic || app.voice.dictating ? "mic.fill" : "mic")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(app.voice.openMic || app.voice.dictating ? Color.white : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(app.voice.openMic || app.voice.dictating ? Color.accentColor : Color.white.opacity(0.12)))
            switch line {
            case .live(let words, let isCommand):
                Text(words)
                    .font(.system(size: 15, weight: isCommand ? .semibold : .regular))
                    .foregroundStyle(isCommand ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            case .result(let heard):
                Text("“\(heard.text)”")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(heard.outcome == .done ? .primary : .secondary)
                    .lineLimit(1)
                switch heard.outcome {
                case .done:
                    Label("Done", systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                case .ignored(let reason):
                    Text("Ignored · \(reason)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .frame(height: 38)
        .frame(maxWidth: 720)
        .glassEffect(.regular, in: .capsule)
    }

    static func tail(_ text: String, words: Int = 16) -> String {
        let all = text.split(separator: " ")
        guard all.count > words else { return text }
        return "… " + all.suffix(words).joined(separator: " ")
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            if let toast = app.toast {
                Text(toast)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: app.toast)
    }
}

struct Waveform: View {
    let levels: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.suffix(14).enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: max(4, CGFloat(level) * 30))
            }
        }
        .animation(.easeOut(duration: 0.08), value: levels)
    }
}

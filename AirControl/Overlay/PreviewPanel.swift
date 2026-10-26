import AppKit
import AVFoundation
import SwiftUI

/// A small floating camera view with calm tracking feedback. Drag it anywhere.
final class PreviewPanelController {
    private var panel: NSPanel?
    private weak var model: AppModel?

    func start(model: AppModel) {
        self.model = model
        let size = CGSize(width: 300, height: 188)
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = CGPoint(x: screen.maxX - size.width - 20, y: screen.maxY - size.height - 20)
        let panel = NSPanel(contentRect: CGRect(origin: origin, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSHostingView(rootView: PreviewView().frame(width: size.width, height: size.height).environment(model))
        view.frame = CGRect(origin: .zero, size: size)
        panel.contentView = view
        self.panel = panel
        update()
    }

    func update() {
        guard let panel, let model else { return }
        let show = model.shouldShowPreview
        if show, !panel.isVisible {
            panel.orderFrontRegardless()
        } else if !show, panel.isVisible {
            panel.orderOut(nil)
        }
    }
}

struct PreviewView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        ZStack(alignment: .topLeading) {
            CameraPreview(session: app.camera.session)
            SensingOverlay(hand: app.handFrame, partner: app.partnerFrame, ignored: app.ignoredHands, face: app.face,
                           attentive: app.isAttentive, speaking: app.isSpeaking, aspect: app.frameAspect)
            HStack(spacing: 6) {
                Circle().fill(app.isAttentive ? Color.green : Color.gray).frame(width: 6, height: 6)
                Text(caption).font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Color.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
        }
        .background(Color.black)
        .clipShape(shape)
        .overlay(shape.strokeBorder(app.cursor.isActive ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.2), lineWidth: 1.5))
    }

    private var caption: String {
        if let hand = app.handFrame {
            let pose = hand.pinch < app.cursor.pinchOn ? "Pinch" : hand.pose.title
            if app.cursor.phase == .twoHand { return "Both hands" }
            if app.partnerFrame != nil { return "\(pose) + other hand" }
            if !app.ignoredHands.isEmpty { return "\(pose) · ignoring \(app.ignoredHands.count) other" }
            return pose
        }
        if app.face != nil {
            if app.isSpeaking { return "Speaking" }
            return app.isAttentive ? "Looking" : "Not looking"
        }
        return "On this Mac · nothing uploaded"
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewHostView, context: Context) {}

    final class PreviewHostView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            previewLayer.videoGravity = .resizeAspectFill
            // Mirror like a selfie view so it matches the (mirrored) hand overlay and pointer motion.
            // Flipping the layer works before the session has a connection, unlike connection mirroring.
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}

/// Calm tracking feedback instead of a skeleton: the tracked hand is a soft glow in its own shape,
/// a ring between thumb and index fills as you pinch, the face gets camera-style corner brackets
/// (green when looking), and other people's hands are a faint dashed outline.
struct SensingOverlay: View {
    let hand: HandFrame?
    var partner: HandFrame? = nil
    let ignored: [HandFrame]
    let face: FaceInfo?
    let attentive: Bool
    var speaking: Bool = false
    let aspect: CGFloat

    var body: some View {
        Canvas { ctx, size in
            var w = size.width
            var h = size.height
            if size.width / size.height > aspect { h = size.width / aspect } else { w = size.height * aspect }
            let ox = (size.width - w) / 2
            let oy = (size.height - h) / 2
            func map(_ n: CGPoint) -> CGPoint { CGPoint(x: ox + n.x * w, y: oy + n.y * h) }

            if let face {
                let r = CGRect(x: ox + face.bounds.minX * w, y: oy + face.bounds.minY * h,
                               width: face.bounds.width * w, height: face.bounds.height * h).insetBy(dx: -4, dy: -4)
                ctx.stroke(Self.brackets(r), with: .color(attentive ? .green : .white.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if speaking {
                    let bar = CGRect(x: r.midX - r.width * 0.2, y: r.maxY + 5, width: r.width * 0.4, height: 3)
                    ctx.fill(Path(roundedRect: bar, cornerRadius: 1.5), with: .color(.accentColor))
                }
            }

            for other in ignored {
                ctx.stroke(Self.handShape(other.joints.values.map(map)), with: .color(.white.opacity(0.3)),
                           style: StrokeStyle(lineWidth: 1.5, lineJoin: .round, dash: [4, 4]))
            }

            for (f, strength) in [(partner, 0.6), (hand, 1.0)] {
                guard let f else { continue }
                let shape = Self.handShape(f.joints.values.map(map))
                ctx.drawLayer { layer in
                    layer.addFilter(.blur(radius: 10))
                    layer.fill(shape, with: .color(.accentColor.opacity(0.55 * strength)))
                }
                ctx.fill(shape, with: .color(.white.opacity(0.12)))
                ctx.stroke(shape, with: .color(.white.opacity(0.85 * strength)), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                Self.pinchRing(f, in: ctx, map: map)
            }
        }
    }

    private static func pinchRing(_ f: HandFrame, in ctx: GraphicsContext, map: (CGPoint) -> CGPoint) {
        if let t = f.joints[.thumbTip], let i = f.joints[.indexTip] {
            let a = map(t), b = map(i)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let closeness = max(0, min(1, (0.9 - f.pinch) / 0.75))
            let radius: CGFloat = 7
            ctx.stroke(Path(ellipseIn: CGRect(x: mid.x - radius, y: mid.y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(.white.opacity(0.9)), lineWidth: 2)
            let inner = radius * CGFloat(closeness)
            if inner > 0.5 {
                ctx.fill(Path(ellipseIn: CGRect(x: mid.x - inner, y: mid.y - inner, width: inner * 2, height: inner * 2)),
                         with: .color(.white))
            }
        }
    }

    static func brackets(_ r: CGRect) -> Path {
        let len = min(r.width, r.height) * 0.28
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + len)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + len, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - len, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + len))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - len)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - len, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + len, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - len))
        return p
    }

    /// A smooth blob around the hand: the convex hull of its landmarks, pushed out and rounded.
    static func handShape(_ points: [CGPoint]) -> Path {
        let hull = convexHull(points)
        guard hull.count >= 3 else { return Path() }
        let cx = hull.map(\.x).reduce(0, +) / CGFloat(hull.count)
        let cy = hull.map(\.y).reduce(0, +) / CGFloat(hull.count)
        let grown = hull.map { p -> CGPoint in
            let dx = p.x - cx, dy = p.y - cy
            let d = max(hypot(dx, dy), 0.001)
            return CGPoint(x: p.x + dx / d * 6, y: p.y + dy / d * 6)
        }
        var path = Path()
        let n = grown.count
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(grown[n - 1], grown[0]))
        for k in 0..<n { path.addQuadCurve(to: mid(grown[k], grown[(k + 1) % n]), control: grown[k]) }
        path.closeSubpath()
        return path
    }

    /// Andrew's monotone chain.
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let pts = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count >= 3 else { return pts }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}

extension HandPose {
    var title: String {
        switch self {
        case .none: return "No hand"
        case .openPalm: return "Open palm"
        case .fist: return "Fist"
        case .thumbsUp: return "Thumbs up"
        case .victory: return "Victory"
        case .pointing: return "Pointing"
        case .other: return "Hand"
        }
    }
}

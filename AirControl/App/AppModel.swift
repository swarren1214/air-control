import AppKit
import AVFoundation
import Observation
import QuartzCore
import Speech
import SwiftUI

enum PreviewMode: String, CaseIterable, Identifiable {
    case whileTracking, always, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .whileTracking: return "While your hand is up"
        case .always: return "Always"
        case .never: return "Never"
        }
    }
}

/// One finished phrase in the live captions, and what Air Control did with it.
struct HeardPhrase: Equatable {
    enum Outcome: Equatable {
        case done
        case ignored(String)
    }
    let text: String
    let outcome: Outcome
    let at: TimeInterval
}

/// Wires camera → hand cursor → real pointer, and microphone → commands. One instance for the app.
@Observable
final class AppModel {
    static let shared = AppModel()

    let camera = CameraService()
    let cursor = HandCursor()
    let twoHands = TwoHandGestures()
    let voice = VoiceController()
    let driver: PointerDriver
    let runner: CommandRunner
    let snapper = Snapper()
    let interpreter = MacIntentInterpreter()
    private let overlay = OverlayController()
    private let preview = PreviewPanelController()

    // MARK: Sensing state
    private(set) var handFrame: HandFrame?
    private(set) var ignoredHands: [HandFrame] = []
    /// The cursor owner's other hand, when two-hand gestures are on.
    private(set) var partnerFrame: HandFrame?
    private(set) var face: FaceInfo?
    private(set) var isAttentive = false
    private(set) var handVisible = false
    private(set) var isSpeaking = false
    private(set) var frameAspect: CGFloat = 16.0 / 9.0
    private(set) var cameraStatus: String?

    // MARK: Pointer state
    /// Where Air Control has put the pointer (global, top-left origin).
    private(set) var pointer: CGPoint = .zero
    private(set) var snap: SnapTarget?
    /// The display the overlay's captions and toasts show on.
    private(set) var focusDisplay: CGRect = CGDisplayBounds(CGMainDisplayID())
    /// A control outlined briefly before a voice click.
    private(set) var flashRect: CGRect?
    private(set) var systemPointerHidden = false
    /// Bumped on every hand click, so the pointer can pop.
    private(set) var clickPulse = 0

    // MARK: Voice state
    private(set) var toast: String?
    private(set) var heard: HeardPhrase?
    private(set) var interpreting = false
    private(set) var interpretingText = ""
    /// ✌️ opens the mic for a few seconds even without the hand cursor.
    private(set) var listenUntil: TimeInterval = 0

    // MARK: Permissions
    private(set) var accessibilityGranted = AX.isTrusted
    /// Bumped to ask the menu bar scene to open the Settings window.
    private(set) var settingsRequest = 0

    // MARK: Settings
    private(set) var cameraEnabled = true
    private(set) var voiceEnabled = true
    private(set) var trackingSpeed: Double = TrackingSpeed.defaultValue
    private(set) var twoHanded = true
    private(set) var twoHandSwipes = true
    private(set) var zoomMode: TwoHandZoomMode = .trackpad
    private(set) var requireLooking = true
    private(set) var snapping = true
    private(set) var hideSystemPointer = true
    private(set) var reverseScroll = false
    private(set) var previewMode: PreviewMode = .whileTracking
    private(set) var showCaptions = true
    private(set) var matchSpeaker = true
    private(set) var noiseReduction = true
    private(set) var cameraID: String?

    // MARK: Private
    @ObservationIgnored private var attention = AttentionFilter()
    @ObservationIgnored private var selector = HandSelector()
    @ObservationIgnored private var speaking = SpeakingDetector()
    @ObservationIgnored private var frameTimer: Timer?
    @ObservationIgnored private var slowTimer: Timer?
    @ObservationIgnored private var lastTick: TimeInterval = 0
    @ObservationIgnored private var lastSnapQuery: TimeInterval = 0
    @ObservationIgnored private var lastClick: (t: TimeInterval, p: CGPoint, count: Int)?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored private var flashWork: DispatchWorkItem?
    @ObservationIgnored private var mouseMonitor: Any?
    @ObservationIgnored private var dictationTyped = false
    /// Pointer minus hand position when a drag starts, so the dragged thing doesn't lurch.
    @ObservationIgnored private var dragOffset: CGPoint = .zero
    @ObservationIgnored private var started = false

    private init() {
        let d = PointerDriver()
        driver = d
        runner = CommandRunner(driver: d)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        loadSettings()
        AX.configureTimeouts()

        camera.onFrame = { [weak self] frame in self?.receive(frame) }
        camera.onStatus = { [weak self] status in self?.cameraStatus = status }
        voice.onInput = { [weak self] input in self?.handle(input) }
        voice.noiseReduction = noiseReduction
        snapper.onResult = { [weak self] p, target in self?.snapResult(at: p, target) }
        wireCursor()
        wireTwoHands()
        wireRunner()

        overlay.start(model: self)
        preview.start(model: self)

        if cameraEnabled { camera.start(cameraID: cameraID) }
        if voiceEnabled { voice.start() }

        // The pointer is driven at display rate; the camera only delivers ~30 frames a second.
        frameTimer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(frameTimer!, forMode: .common)
        slowTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.slowTick() }
        RunLoop.main.add(slowTimer!, forMode: .common)

        // The real mouse always wins: touching it puts the hand cursor away.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
            self?.physicalInput(event)
        }

        if !accessibilityGranted { requestSettings() }
    }

    func shutdown() {
        twoHands.cancel(cursor: cursor)
        driver.setShiftHeld(false)
        SystemCursor.setHidden(false)
        driver.mouseUp(at: pointer)
        camera.stop()
        voice.stop()
    }

    func requestSettings() {
        settingsRequest += 1
    }

    // MARK: Camera → attention → cursor

    private func receive(_ frame: VisionFrame) {
        let t = CACurrentMediaTime()
        if abs(frame.aspect - frameAspect) > 0.01 {
            frameAspect = frame.aspect
            cursor.frameAspect = frame.aspect
        }
        let pick = selector.select(hands: frame.hands, faces: frame.faces, requireFacing: requireLooking, at: t)
        handFrame = pick.hand
        ignoredHands = pick.ignored
        partnerFrame = pick.partner
        face = pick.face

        let watched = pick.face?.isFacingScreen == true ? pick.face
            : frame.faces.filter { $0.isFacingScreen }.max { $0.bounds.width < $1.bounds.width }
        speaking.update(face: watched, at: t)
        if speaking.isSpeaking != isSpeaking { isSpeaking = speaking.isSpeaking }

        let facing = requireLooking ? (pick.face?.isFacingScreen ?? false) : (pick.hand != nil || pick.face != nil)
        let attentive = attention.update(facing: facing, at: t)
        if attentive != isAttentive { isAttentive = attentive }
        let visible = pick.hand != nil
        if visible != handVisible { handVisible = visible }

        // Looking away drops the cursor (after the attention filter's grace period).
        let owner = attentive && accessibilityGranted ? pick.hand : nil
        cursor.ingest(owner, at: t)
        twoHands.update(owner: owner, partner: twoHanded ? pick.partner : nil, aspect: frame.aspect, cursor: cursor, at: t)
    }

    // MARK: Cursor → pointer

    private func wireCursor() {
        cursor.pointerLocation = { [weak self] in self?.pointer ?? .zero }
        cursor.onActivate = { [weak self] in
            let mouse = Displays.mouseLocation
            let display = Displays.display(containing: mouse)
            self?.pointer = mouse
            self?.focusDisplay = display
            self?.driver.stopMomentum()
            return (display, mouse)
        }
        cursor.onDeactivate = { [weak self] in
            guard let self else { return }
            self.snap = nil
            self.twoHands.cancel(cursor: self.cursor)
            if self.driver.buttonDown { self.driver.mouseUp(at: self.pointer) }
            self.setPointerHidden(false)
        }
        cursor.onTap = { [weak self] p in self?.click(at: p) }
        cursor.onRightClick = { [weak self] p in
            self?.clickPulse += 1
            self?.driver.rightClick(at: p)
        }
        cursor.onDragBegan = { [weak self] p in
            guard let self else { return }
            self.snap = nil
            self.dragOffset = CGPoint(x: p.x - self.cursor.point.x, y: p.y - self.cursor.point.y)
            self.driver.mouseDown(at: p)
        }
        cursor.onDragEnded = { [weak self] _ in
            guard let self else { return }
            self.driver.mouseUp(at: self.pointer)
        }
        cursor.onScrollBegan = { [weak self] in
            guard let self else { return }
            self.driver.direction = self.reverseScroll ? -1 : 1
            self.driver.scrollBegan(at: self.pointer)
        }
        cursor.onScroll = { [weak self] dx, dy in self?.driver.scroll(dx: dx, dy: dy) }
        cursor.onScrollEnded = { [weak self] vx, vy in self?.driver.scrollEnded(vx: vx, vy: vy) }
        cursor.onPose = { [weak self] pose in
            guard let self else { return }
            if pose == .victory, self.voiceEnabled {
                self.listenUntil = CACurrentMediaTime() + 6
                self.showToast("Listening…")
            }
        }
    }

    private func click(at p: CGPoint) {
        let now = CACurrentMediaTime()
        var count = 1
        if let last = lastClick, now - last.t < NSEvent.doubleClickInterval, last.p.distance(to: p) < 8 {
            count = min(last.count + 1, 3)
        }
        lastClick = (now, p, count)
        clickPulse += 1
        driver.click(at: p, count: count)
    }

    /// Where the pointer should be right now.
    private var pointerTarget: CGPoint {
        switch cursor.phase {
        case .free:
            if let snap { return Self.clamp(cursor.point, toCenterOf: snap) }
            return cursor.point
        case .pressed, .holding, .scrolling, .twoHand:
            return cursor.pinchLocation
        case .dragging:
            return CGPoint(x: cursor.point.x + dragOffset.x, y: cursor.point.y + dragOffset.y)
        default:
            return pointer
        }
    }

    /// Snapped: sit at the control's center, nudged slightly toward the hand (iPadOS parallax),
    /// but never off the control, so a click always lands on it.
    private static func clamp(_ hand: CGPoint, toCenterOf snap: SnapTarget) -> CGPoint {
        let c = snap.center
        let f = snap.frame.insetBy(dx: min(4, snap.frame.width / 3), dy: min(3, snap.frame.height / 3))
        let x = min(max(c.x + (hand.x - c.x) * 0.08, f.minX), f.maxX)
        let y = min(max(c.y + (hand.y - c.y) * 0.08, f.minY), f.maxY)
        return CGPoint(x: x, y: y)
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 1.0 / 120.0 : min(now - lastTick, 0.05)
        lastTick = now
        driver.tick(dt: CGFloat(dt))
        updateListening(now: now)

        guard cursor.isActive else { return }
        setPointerHidden(hideSystemPointer && accessibilityGranted)

        // Ease toward the target so 30 fps camera input becomes smooth display-rate motion.
        let target = pointerTarget
        let k = CGFloat(1 - exp(-dt / 0.03))
        let next = CGPoint(x: pointer.x + (target.x - pointer.x) * k, y: pointer.y + (target.y - pointer.y) * k)
        if next.distance(to: pointer) > 0.25 {
            pointer = next
            if cursor.phase != .scrolling && cursor.phase != .twoHand { driver.move(to: next) }
        }

        // Snapping: ask what's under the hand ~20 times a second; drop a stale snap right away.
        if snapping, accessibilityGranted, cursor.phase == .free {
            if let s = snap, Snapper.distance(from: cursor.point, to: s.frame) > 30 { snap = nil }
            if now - lastSnapQuery > 0.05 {
                lastSnapQuery = now
                snapper.query(cursor.point)
            }
        } else if snap != nil, cursor.phase == .dragging || !snapping {
            snap = nil
        }
    }

    // MARK: Two hands → zoom, rotate, pan, Shift, Spaces

    private func wireTwoHands() {
        twoHands.onZoomBegan = { [weak self] in
            guard let self else { return }
            self.snap = nil
            self.driver.resetZoom()
            if self.zoomMode == .trackpad { self.driver.magnify(0, phase: .began, at: self.pointer) }
        }
        twoHands.onZoom = { [weak self] amount in
            guard let self else { return }
            switch self.zoomMode {
            case .trackpad: self.driver.magnify(amount, phase: .changed, at: self.pointer)
            case .commandScroll: self.driver.commandScrollZoom(amount, at: self.pointer)
            case .keyboard: self.driver.keyboardZoom(amount)
            }
        }
        twoHands.onZoomEnded = { [weak self] in
            guard let self else { return }
            if self.zoomMode == .trackpad { self.driver.magnify(0, phase: .ended, at: self.pointer) }
            self.driver.resetZoom()
        }
        // Rotation only exists as a trackpad gesture; the fallbacks skip it.
        twoHands.onRotateBegan = { [weak self] in
            guard let self, self.zoomMode == .trackpad else { return }
            self.driver.rotate(0, phase: .began, at: self.pointer)
        }
        twoHands.onRotate = { [weak self] degrees in
            guard let self, self.zoomMode == .trackpad else { return }
            self.driver.rotate(degrees, phase: .changed, at: self.pointer)
        }
        twoHands.onRotateEnded = { [weak self] in
            guard let self, self.zoomMode == .trackpad else { return }
            self.driver.rotate(0, phase: .ended, at: self.pointer)
        }
        twoHands.onPanBegan = { [weak self] in
            guard let self else { return }
            self.driver.direction = self.reverseScroll ? -1 : 1
            self.driver.scrollBegan(at: self.pointer)
        }
        twoHands.onPan = { [weak self] dx, dy in self?.driver.scroll(dx: dx, dy: dy) }
        twoHands.onPanEnded = { [weak self] vx, vy in self?.driver.scrollEnded(vx: vx, vy: vy) }
        twoHands.onModifier = { [weak self] on in
            self?.driver.setShiftHeld(on)
            if on { self?.showToast("⇧ Shift held — let go with your other hand to release") }
        }
        twoHands.onSwipe = { [weak self] direction in
            guard let self else { return }
            let shortcut: Shortcut
            switch direction {
            case .left: shortcut = .nextSpace
            case .right: shortcut = .previousSpace
            case .up: shortcut = .missionControl
            case .down: shortcut = .appWindows
            }
            self.runner.run(.shortcut(shortcut))
        }
    }

    private func snapResult(at p: CGPoint, _ target: SnapTarget?) {
        guard cursor.phase == .free, snapping else { return }
        // Hysteresis: keep the current control until the hand clearly leaves it.
        if let current = snap, current != target,
           current.frame.insetBy(dx: -12, dy: -10).contains(cursor.point) {
            return
        }
        if target != snap {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { snap = target }
        }
    }

    private func setPointerHidden(_ hidden: Bool) {
        let want = hidden && SystemCursor.canHide
        guard want != systemPointerHidden else { return }
        SystemCursor.setHidden(want)
        systemPointerHidden = want
    }

    private func physicalInput(_ event: NSEvent) {
        guard cursor.isActive else { return }
        if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == PointerDriver.eventTag { return }
        let moved = abs(event.deltaX) + abs(event.deltaY)
        if event.type == .scrollWheel || moved > 2 {
            cursor.reset()
            showToast("Mouse in use — raise your hand again to take over")
        }
    }

    private func slowTick() {
        let trusted = AX.isTrusted
        if trusted != accessibilityGranted {
            accessibilityGranted = trusted
            if trusted { AX.configureTimeouts() }
        }
        let display = cursor.isActive ? cursor.display : Displays.display(containing: Displays.mouseLocation)
        if display != focusDisplay { focusDisplay = display }
        preview.update()
    }

    // MARK: Voice

    private func updateListening(now: TimeInterval) {
        guard voiceEnabled else { return }
        let handUp = cursor.isActive && (isAttentive || !requireLooking)
        voice.setOpenMic(handUp || now < listenUntil)
    }

    private func handle(_ input: VoiceInput) {
        let text = input.text
        let tokens = MacCommandParser.tokens(text)
        let ruled = MacCommandParser.parse(text)

        // Cross-talk check: was the person at the screen the one talking?
        if matchSpeaker, cameraEnabled {
            switch speaking.verdict(from: input.span.lowerBound, to: input.span.upperBound + 0.2) {
            case .notSpeaking:
                noteHeard(text, .ignored("someone else talking"))
                return
            case .noFace:
                if !input.wake && !voice.dictating {
                    noteHeard(text, .ignored("no one at the screen"))
                    return
                }
            case .speaking, .unknown:
                break
            }
        }

        if voice.dictating && !input.wake {
            dictate(input, ruled: ruled)
            return
        }

        if !input.wake {
            // Open mic (hand up, or ✌️): short commands the rules know go straight through.
            if ruled != .unknown, tokens.count <= 6, !Self.needsModel(ruled) {
                perform(ruled, raw: input.raw, heard: text)
                return
            }
            if tokens.count <= 20, Self.soundsLikeRequest(tokens), interpreter.isAvailable {
                interpret(text, raw: input.raw, fallback: ruled, openMic: true)
            } else if ruled != .unknown {
                perform(ruled, raw: input.raw, heard: text)
            }
            return
        }

        // "Hey Mac …"
        if ruled != .unknown, (tokens.count <= 6 && !Self.needsModel(ruled)) || !interpreter.isAvailable {
            perform(ruled, raw: input.raw, heard: text)
            return
        }
        guard interpreter.isAvailable else {
            showToast("Didn’t catch “\(text)”")
            noteHeard(text, .ignored("didn’t understand"))
            return
        }
        interpret(text, raw: input.raw, fallback: ruled, openMic: false)
    }

    /// "click the blue button at the bottom" parses as a click on "blue button at the bottom";
    /// the model, which sees the real labels on screen, does better with descriptions like that.
    private static func needsModel(_ command: MacCommand) -> Bool {
        if case .clickNamed(let target) = command { return target.split(separator: " ").count >= 3 }
        return false
    }

    private func dictate(_ input: VoiceInput, ruled: MacCommand) {
        let words = MacCommandParser.tokens(input.text).joined(separator: " ")
        switch words {
        case "new line":
            driver.press(KeyCode.returnKey)
        case "new paragraph":
            driver.press(KeyCode.returnKey)
            driver.press(KeyCode.returnKey)
        case "scratch that", "delete that", "undo that":
            driver.press(6, flags: .maskCommand)
        default:
            if ruled == .stopDictation || ruled == .cancel {
                setDictating(false)
                noteHeard(input.text, .done)
                return
            }
            var text = input.raw.isEmpty ? input.text : input.raw
            if dictationTyped, let first = text.first, !",.;:!?)".contains(first) { text = " " + text }
            driver.type(text)
            dictationTyped = true
        }
        noteHeard(input.text, .done)
    }

    private func setDictating(_ on: Bool) {
        voice.setDictating(on)
        dictationTyped = false
        showToast(on ? "Dictation on — say “stop dictation” when you’re done" : "Dictation off")
    }

    private func perform(_ command: MacCommand, raw: String, heard text: String) {
        noteHeard(text, .done)
        runner.run(command, raw: raw)
    }

    /// Runs the on-device model with what's on screen. In open-mic mode a miss is silent.
    private func interpret(_ text: String, raw: String, fallback ruled: MacCommand, openMic: Bool) {
        interpreting = true
        interpretingText = text
        let target = ScreenReader.Target.current()
        AX.queue.async { [weak self] in
            let snapshot = ScreenReader.snapshot(of: target, limit: 1500)
            let context = Self.context(from: snapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                Task { @MainActor in
                    let result = await self.interpreter.interpret(text, context: context, openMic: openMic)
                    self.interpreting = false
                    if let result, result != .unknown {
                        self.perform(result, raw: raw, heard: text)
                    } else if ruled != .unknown {
                        self.perform(ruled, raw: raw, heard: text)
                    } else if openMic {
                        self.noteHeard(text, .ignored("not a command"))
                    } else {
                        self.showToast("Didn’t catch “\(text)”")
                        self.noteHeard(text, .ignored("didn’t understand"))
                    }
                }
            }
        }
    }

    private static func context(from snapshot: ScreenReader.Snapshot?) -> String {
        var lines: [String] = []
        if let s = snapshot {
            lines.append("Frontmost app: \(s.appName)")
            if let title = s.windowTitle, !title.isEmpty { lines.append("Window: \(title)") }
            var seen = Set<String>()
            let labels = s.controls.map(\.label).filter { seen.insert($0.lowercased()).inserted }.prefix(60)
            lines.append("Buttons and links on screen: " + labels.joined(separator: " | "))
        }
        lines.append("Running apps: " + AppDirectory.runningNames.prefix(25).joined(separator: ", "))
        return lines.joined(separator: "\n")
    }

    private static let requestWords: Set<String> = [
        "click", "tap", "press", "hit", "open", "close", "quit", "switch", "scroll", "go", "show", "type", "write",
        "search", "find", "new", "tab", "window", "copy", "paste", "undo", "redo", "select", "save", "back",
        "forward", "reload", "refresh", "minimize", "zoom", "app", "button", "link", "launch", "enter", "return",
        "desktop", "space", "dictation", "bring", "take", "put", "hide", "full", "screen", "page", "top", "bottom"
    ]

    static func soundsLikeRequest(_ tokens: [String]) -> Bool {
        tokens.contains { requestWords.contains($0) }
    }

    private func wireRunner() {
        runner.pointer = { [weak self] in
            guard let self else { return Displays.mouseLocation }
            return self.cursor.isActive ? self.pointer : Displays.mouseLocation
        }
        runner.toast = { [weak self] text in self?.showToast(text) }
        runner.flash = { [weak self] rect in self?.flash(rect) }
        runner.setDictating = { [weak self] on in self?.setDictating(on) }
        runner.hideCursor = { [weak self] in self?.cursor.reset() }
    }

    private func noteHeard(_ text: String, _ outcome: HeardPhrase.Outcome) {
        heard = HeardPhrase(text: text, outcome: outcome, at: CACurrentMediaTime())
    }

    func showToast(_ text: String) {
        toast = text
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func flash(_ rect: CGRect) {
        flashRect = rect
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flashRect = nil }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: Settings

    private func loadSettings() {
        let d = UserDefaults.standard
        if d.object(forKey: "cameraEnabled") != nil { cameraEnabled = d.bool(forKey: "cameraEnabled") }
        if d.object(forKey: "voiceEnabled") != nil { voiceEnabled = d.bool(forKey: "voiceEnabled") }
        if d.object(forKey: "trackingSpeed") != nil {
            trackingSpeed = min(max(d.double(forKey: "trackingSpeed"), 0), 1)
        } else if let s = d.string(forKey: "cursorSpeed"), let v = TrackingSpeed.migrate(preset: s) {
            trackingSpeed = v
        }
        if d.object(forKey: "twoHanded") != nil { twoHanded = d.bool(forKey: "twoHanded") }
        if d.object(forKey: "twoHandSwipes") != nil { twoHandSwipes = d.bool(forKey: "twoHandSwipes") }
        if let s = d.string(forKey: "zoomMode"), let v = TwoHandZoomMode(rawValue: s) { zoomMode = v }
        if d.object(forKey: "requireLooking") != nil { requireLooking = d.bool(forKey: "requireLooking") }
        if d.object(forKey: "snapping") != nil { snapping = d.bool(forKey: "snapping") }
        if d.object(forKey: "hideSystemPointer") != nil { hideSystemPointer = d.bool(forKey: "hideSystemPointer") }
        reverseScroll = d.bool(forKey: "reverseScroll")
        if let s = d.string(forKey: "previewMode"), let v = PreviewMode(rawValue: s) { previewMode = v }
        if d.object(forKey: "showCaptions") != nil { showCaptions = d.bool(forKey: "showCaptions") }
        if d.object(forKey: "matchSpeaker") != nil { matchSpeaker = d.bool(forKey: "matchSpeaker") }
        if d.object(forKey: "noiseReduction") != nil { noiseReduction = d.bool(forKey: "noiseReduction") }
        cameraID = d.string(forKey: "cameraID")
        cursor.setPalmsPerScreen(TrackingSpeed.palmsPerScreen(trackingSpeed))
        selector.twoHanded = twoHanded
        twoHands.swipesEnabled = twoHandSwipes
    }

    private func save(_ value: Any?, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    func setCameraEnabled(_ on: Bool) {
        cameraEnabled = on
        save(on, "cameraEnabled")
        if on {
            camera.start(cameraID: cameraID)
        } else {
            camera.stop()
            cursor.reset()
            handFrame = nil
            handVisible = false
            face = nil
        }
        preview.update()
    }

    func setVoiceEnabled(_ on: Bool) {
        voiceEnabled = on
        save(on, "voiceEnabled")
        if on { voice.start() } else { voice.stop() }
    }

    func setTrackingSpeed(_ value: Double) {
        trackingSpeed = min(max(value, 0), 1)
        cursor.setPalmsPerScreen(TrackingSpeed.palmsPerScreen(trackingSpeed))
        save(trackingSpeed, "trackingSpeed")
    }

    func setTwoHanded(_ on: Bool) {
        twoHanded = on
        selector.twoHanded = on
        save(on, "twoHanded")
        if !on {
            twoHands.cancel(cursor: cursor)
            partnerFrame = nil
        }
    }

    func setTwoHandSwipes(_ on: Bool) {
        twoHandSwipes = on
        twoHands.swipesEnabled = on
        save(on, "twoHandSwipes")
    }

    func setZoomMode(_ mode: TwoHandZoomMode) {
        zoomMode = mode
        save(mode.rawValue, "zoomMode")
    }

    func setRequireLooking(_ on: Bool) { requireLooking = on; save(on, "requireLooking") }
    func setSnapping(_ on: Bool) { snapping = on; save(on, "snapping"); if !on { snap = nil } }
    func setReverseScroll(_ on: Bool) { reverseScroll = on; save(on, "reverseScroll") }
    func setShowCaptions(_ on: Bool) { showCaptions = on; save(on, "showCaptions") }
    func setMatchSpeaker(_ on: Bool) { matchSpeaker = on; save(on, "matchSpeaker") }

    func setHideSystemPointer(_ on: Bool) {
        hideSystemPointer = on
        save(on, "hideSystemPointer")
        if !on { setPointerHidden(false) }
    }

    func setPreviewMode(_ mode: PreviewMode) {
        previewMode = mode
        save(mode.rawValue, "previewMode")
        preview.update()
    }

    func setNoiseReduction(_ on: Bool) {
        noiseReduction = on
        save(on, "noiseReduction")
        voice.noiseReduction = on
        if voiceEnabled {
            voice.stop()
            voice.start()
        }
    }

    func setCamera(_ id: String?) {
        cameraID = id
        save(id, "cameraID")
        camera.switchCamera(to: id)
    }

    var shouldShowPreview: Bool {
        guard cameraEnabled else { return false }
        switch previewMode {
        case .always: return true
        case .never: return false
        case .whileTracking: return cursor.isActive || handVisible
        }
    }

    /// One-line status for the menu bar.
    var statusLine: String {
        if !accessibilityGranted { return "Needs Accessibility permission" }
        if let cameraStatus { return cameraStatus }
        if !cameraEnabled { return voiceEnabled ? "Voice only" : "Paused" }
        if voice.dictating { return "Dictating" }
        switch cursor.phase {
        case .dragging: return "Dragging"
        case .scrolling: return "Scrolling"
        case .twoHand: return twoHands.statusText
        case .holding: return "Let go to right-click, or move to drag"
        case .acquiring: return "Hold your palm open…"
        case .hidden: return isAttentive ? "Raise an open palm to take control" : (face == nil ? "No one in view" : "Look at the screen")
        default:
            if twoHands.phase == .modifier { return "Shift held by your other hand" }
            return snap?.label.map { "On “\($0)”" } ?? "Tracking your hand"
        }
    }
}

import AppKit
import CoreGraphics

/// Carries out a `MacCommand` with real input events, Accessibility and NSWorkspace.
final class CommandRunner {
    let driver: PointerDriver
    /// Where the pointer is now (global, top-left origin).
    var pointer: () -> CGPoint = { Displays.mouseLocation }
    var toast: (String) -> Void = { _ in }
    /// Briefly outline a control before it's clicked, so you can see what voice picked.
    var flash: (CGRect) -> Void = { _ in }
    var setDictating: (Bool) -> Void = { _ in }
    var hideCursor: () -> Void = {}

    init(driver: PointerDriver) {
        self.driver = driver
    }

    /// `raw` is the utterance as recognized (capitals, punctuation), used when typing.
    func run(_ command: MacCommand, raw: String = "") {
        switch command {
        case .click:
            driver.click(at: pointer())
        case .doubleClick:
            let p = pointer()
            driver.click(at: p, count: 1)
            driver.click(at: p, count: 2)
        case .rightClick:
            driver.rightClick(at: pointer())
        case .clickNamed(let name):
            clickControl(named: name)
        case .scroll(let direction, let pages):
            scroll(direction, pages: pages)
        case .openApp(let name):
            open(name, preferRunning: false)
        case .switchApp(let name):
            open(name, preferRunning: true)
        case .quitApp(let name):
            if let app = AppDirectory.running(named: name) {
                app.terminate()
                toast("Quit \(app.localizedName ?? name)")
            } else {
                toast("“\(name)” isn’t running")
            }
        case .shortcut(let sc):
            let (key, flags) = sc.keys
            driver.press(key, flags: flags)
            toast(sc.title)
        case .typeText(let text):
            let typed = Self.textToType(spoken: text, raw: raw)
            driver.type(typed)
            toast("Typed “\(typed.count > 40 ? String(typed.prefix(40)) + "…" : typed)”")
        case .pressKey(let key, let flags, let name):
            driver.press(key, flags: flags)
            toast("Pressed \(name)")
        case .search(let query):
            driver.press(KeyCode.space, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [driver] in driver.type(query) }
            toast("Searching for “\(query)”")
        case .findText(let text):
            driver.press(3, flags: .maskCommand)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [driver] in driver.type(text) }
            toast("Finding “\(text)”")
        case .startDictation:
            setDictating(true)
        case .stopDictation:
            setDictating(false)
        case .hideCursor:
            hideCursor()
        case .system(let action):
            perform(action)
        case .cancel:
            driver.stopMomentum()
            toast("Cancelled")
        case .unknown:
            break
        }
    }

    /// Uses the recognized text after "type"/"write" so capitals and punctuation survive.
    static func textToType(spoken: String, raw: String) -> String {
        let lower = raw.lowercased()
        for verb in ["type ", "write ", "enter text "] {
            if let r = lower.range(of: verb) {
                let offset = lower.distance(from: lower.startIndex, to: r.upperBound)
                let text = String(raw.dropFirst(offset)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
            }
        }
        return spoken
    }

    private func scroll(_ direction: ScrollDirection, pages: Int) {
        let p = pointer()
        let display = Displays.display(containing: p)
        let amount = pages == 0 ? 120 : display.height * 0.7 * CGFloat(pages)
        switch direction {
        case .top:
            driver.press(KeyCode.up, flags: .maskCommand)
            toast("Top")
        case .bottom:
            driver.press(KeyCode.down, flags: .maskCommand)
            toast("Bottom")
        // Wheel deltas reveal content above/left when positive; "scroll down" means reveal below.
        case .down: driver.scrollBy(dx: 0, dy: -amount, at: p); toast("Scrolled down")
        case .up: driver.scrollBy(dx: 0, dy: amount, at: p); toast("Scrolled up")
        case .right: driver.scrollBy(dx: -amount, dy: 0, at: p); toast("Scrolled right")
        case .left: driver.scrollBy(dx: amount, dy: 0, at: p); toast("Scrolled left")
        }
    }

    private func open(_ spoken: String, preferRunning: Bool) {
        if let app = AppDirectory.running(named: spoken) {
            app.unhide()
            app.activate()
            toast(app.localizedName ?? spoken)
            return
        }
        guard let url = AppDirectory.installedURL(named: spoken) else {
            toast("Couldn’t find an app called “\(spoken)”")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        toast("Opening \(url.deletingPathExtension().lastPathComponent)")
    }

    private func clickControl(named name: String) {
        let target = ScreenReader.Target.current()
        AX.queue.async { [weak self] in
            let snapshot = ScreenReader.snapshot(of: target)
            let found = snapshot.flatMap { ScreenReader.find(name, in: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                guard let control = found else {
                    self.toast("Couldn’t find “\(name)” in \(snapshot?.appName ?? "this window")")
                    return
                }
                let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
                self.flash(control.frame)
                self.driver.move(to: center)
                // A beat so you can see what's about to be clicked.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.driver.click(at: center)
                }
                self.toast("Clicked “\(control.label)”")
            }
        }
    }
}

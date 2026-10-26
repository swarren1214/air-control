import CoreGraphics
import Foundation

enum ScrollDirection: String, Equatable {
    case up, down, left, right, top, bottom
}

/// Named keyboard shortcuts voice can trigger.
enum Shortcut: String, CaseIterable, Equatable {
    case closeWindow, closeTab, newWindow, newTab, nextTab, previousTab, reopenTab
    case goBack, goForward, reload
    case copy, paste, cut, undo, redo, selectAll, save, find, print
    case missionControl, appWindows, showDesktop, nextSpace, previousSpace, spotlight
    case minimize, fullScreen, zoomIn, zoomOut, actualSize, hideApp, quitApp, switchApp

    var title: String {
        switch self {
        case .closeWindow: return "Closed window"
        case .closeTab: return "Closed tab"
        case .newWindow: return "New window"
        case .newTab: return "New tab"
        case .nextTab: return "Next tab"
        case .previousTab: return "Previous tab"
        case .reopenTab: return "Reopened tab"
        case .goBack: return "Back"
        case .goForward: return "Forward"
        case .reload: return "Reloaded"
        case .copy: return "Copied"
        case .paste: return "Pasted"
        case .cut: return "Cut"
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .selectAll: return "Selected all"
        case .save: return "Saved"
        case .find: return "Find"
        case .print: return "Print"
        case .missionControl: return "Mission Control"
        case .appWindows: return "App windows"
        case .showDesktop: return "Desktop"
        case .nextSpace: return "Next space"
        case .previousSpace: return "Previous space"
        case .spotlight: return "Spotlight"
        case .minimize: return "Minimized"
        case .fullScreen: return "Full screen"
        case .zoomIn: return "Zoomed in"
        case .zoomOut: return "Zoomed out"
        case .actualSize: return "Actual size"
        case .hideApp: return "Hidden"
        case .quitApp: return "Quit"
        case .switchApp: return "Switched app"
        }
    }

    var keys: (CGKeyCode, CGEventFlags) {
        switch self {
        case .closeWindow: return (13, .maskCommand)                       // ⌘W
        case .closeTab: return (13, .maskCommand)
        case .newWindow: return (45, .maskCommand)                         // ⌘N
        case .newTab: return (17, .maskCommand)                            // ⌘T
        case .nextTab: return (30, [.maskCommand, .maskShift])             // ⌘⇧]
        case .previousTab: return (33, [.maskCommand, .maskShift])         // ⌘⇧[
        case .reopenTab: return (17, [.maskCommand, .maskShift])           // ⌘⇧T
        case .goBack: return (33, .maskCommand)                            // ⌘[
        case .goForward: return (30, .maskCommand)                         // ⌘]
        case .reload: return (15, .maskCommand)                            // ⌘R
        case .copy: return (8, .maskCommand)
        case .paste: return (9, .maskCommand)
        case .cut: return (7, .maskCommand)
        case .undo: return (6, .maskCommand)
        case .redo: return (6, [.maskCommand, .maskShift])
        case .selectAll: return (0, .maskCommand)
        case .save: return (1, .maskCommand)
        case .find: return (3, .maskCommand)
        case .print: return (35, .maskCommand)
        case .missionControl: return (KeyCode.up, .maskControl)            // ⌃↑
        case .appWindows: return (KeyCode.down, .maskControl)              // ⌃↓
        case .showDesktop: return (103, [])                                // F11
        case .nextSpace: return (KeyCode.right, .maskControl)              // ⌃→
        case .previousSpace: return (KeyCode.left, .maskControl)           // ⌃←
        case .spotlight: return (KeyCode.space, .maskCommand)              // ⌘Space
        case .minimize: return (46, .maskCommand)                          // ⌘M
        case .fullScreen: return (3, [.maskCommand, .maskControl])         // ⌃⌘F
        case .zoomIn: return (24, .maskCommand)                            // ⌘=
        case .zoomOut: return (27, .maskCommand)                           // ⌘-
        case .actualSize: return (29, .maskCommand)                        // ⌘0
        case .hideApp: return (4, .maskCommand)                            // ⌘H
        case .quitApp: return (12, .maskCommand)                           // ⌘Q
        case .switchApp: return (KeyCode.tab, .maskCommand)                // ⌘Tab
        }
    }
}

enum MacCommand: Equatable {
    case click
    case doubleClick
    case rightClick
    /// "click Send", "press Save" — a control in the front window, found by its label.
    case clickNamed(String)
    case scroll(ScrollDirection, pages: Int)
    case openApp(String)
    case switchApp(String)
    case quitApp(String)
    case shortcut(Shortcut)
    case typeText(String)
    case pressKey(CGKeyCode, CGEventFlags, name: String)
    case search(String)
    /// ⌘F, then the text.
    case findText(String)
    case startDictation
    case stopDictation
    case hideCursor
    /// Swipes, Look Up, window tiling… (see `SystemAction`).
    case system(SystemAction)
    case cancel
    case unknown

    static func == (a: MacCommand, b: MacCommand) -> Bool {
        switch (a, b) {
        case (.click, .click), (.doubleClick, .doubleClick), (.rightClick, .rightClick),
             (.startDictation, .startDictation), (.stopDictation, .stopDictation),
             (.hideCursor, .hideCursor), (.cancel, .cancel), (.unknown, .unknown):
            return true
        case let (.clickNamed(x), .clickNamed(y)), let (.openApp(x), .openApp(y)), let (.switchApp(x), .switchApp(y)),
             let (.quitApp(x), .quitApp(y)), let (.typeText(x), .typeText(y)), let (.search(x), .search(y)),
             let (.findText(x), .findText(y)):
            return x == y
        case let (.scroll(d1, p1), .scroll(d2, p2)):
            return d1 == d2 && p1 == p2
        case let (.shortcut(x), .shortcut(y)):
            return x == y
        case let (.system(x), .system(y)):
            return x == y
        case let (.pressKey(k1, f1, _), .pressKey(k2, f2, _)):
            return k1 == k2 && f1 == f2
        default:
            return false
        }
    }
}

/// A small closed grammar for the commands people say most. Anything it doesn't cover goes to the
/// on-device model.
enum MacCommandParser {
    static func tokens(_ text: String) -> [String] {
        VoiceController.normalize(text).split(separator: " ").map(String.init)
    }

    static func parse(_ text: String) -> MacCommand {
        var t = tokens(text)
        // Politeness and filler at the front: "please", "can you", "could you".
        let filler: Set<String> = ["please", "can", "could", "would", "you", "now", "just", "hey", "okay", "ok", "and"]
        while let first = t.first, filler.contains(first) { t.removeFirst() }
        if t.last == "please" { t.removeLast() }
        guard !t.isEmpty else { return .unknown }
        let s = t.joined(separator: " ")
        func rest(after count: Int) -> String { t.dropFirst(count).joined(separator: " ") }
        func starts(_ p: String) -> Bool { s == p || s.hasPrefix(p + " ") }

        // Control of Air Control itself.
        if ["cancel", "stop", "never mind", "nevermind"].contains(s) { return .cancel }
        if ["stop dictation", "stop typing", "end dictation", "done typing", "stop dictating"].contains(s) { return .stopDictation }
        if ["start dictation", "dictation", "dictate", "take dictation", "start typing", "dictation mode"].contains(s) { return .startDictation }
        if ["hide cursor", "hide the cursor", "stop tracking", "put the cursor away"].contains(s) { return .hideCursor }

        // Shortcuts.
        let shortcuts: [String: Shortcut] = [
            "close window": .closeWindow, "close the window": .closeWindow, "close this window": .closeWindow,
            "close": .closeWindow, "close this": .closeWindow, "close it": .closeWindow,
            "close tab": .closeTab, "close the tab": .closeTab, "close this tab": .closeTab,
            "new window": .newWindow, "open a new window": .newWindow, "new tab": .newTab, "open a new tab": .newTab,
            "next tab": .nextTab, "previous tab": .previousTab, "last tab": .previousTab,
            "reopen tab": .reopenTab, "reopen closed tab": .reopenTab, "reopen the last tab": .reopenTab,
            "go back": .goBack, "back": .goBack, "go forward": .goForward, "forward": .goForward,
            "reload": .reload, "refresh": .reload, "reload the page": .reload, "refresh the page": .reload,
            "copy": .copy, "copy that": .copy, "copy this": .copy, "paste": .paste, "paste it": .paste,
            "cut": .cut, "cut that": .cut, "undo": .undo, "undo that": .undo, "redo": .redo, "redo that": .redo,
            "select all": .selectAll, "save": .save, "save it": .save, "save this": .save, "find": .find,
            "print": .print, "mission control": .missionControl, "show all windows": .missionControl,
            "app windows": .appWindows, "show desktop": .showDesktop, "desktop": .showDesktop,
            "next space": .nextSpace, "next desktop": .nextSpace, "previous space": .previousSpace,
            "previous desktop": .previousSpace, "spotlight": .spotlight, "minimize": .minimize,
            "minimize window": .minimize, "minimize this": .minimize, "full screen": .fullScreen,
            "fullscreen": .fullScreen, "enter full screen": .fullScreen, "exit full screen": .fullScreen,
            "zoom in": .zoomIn, "zoom out": .zoomOut, "actual size": .actualSize, "hide app": .hideApp,
            "hide this app": .hideApp, "quit": .quitApp, "quit app": .quitApp, "quit this app": .quitApp,
            "quit this": .quitApp, "switch apps": .switchApp, "switch app": .switchApp, "last app": .switchApp
        ]
        if let sc = shortcuts[s] { return .shortcut(sc) }

        let system: [String: SystemAction] = [
            "tile left": .tileLeft, "tile window left": .tileLeft, "move window left": .tileLeft,
            "snap left": .tileLeft, "window left": .tileLeft, "left half": .tileLeft,
            "tile right": .tileRight, "tile window right": .tileRight, "move window right": .tileRight,
            "snap right": .tileRight, "window right": .tileRight, "right half": .tileRight,
            "fill window": .fillWindow, "fill screen": .fillWindow, "fill the screen": .fillWindow,
            "maximize": .fillWindow, "maximize window": .fillWindow, "maximize this": .fillWindow,
            "notification center": .notificationCenter, "notifications": .notificationCenter,
            "show notifications": .notificationCenter, "open notification center": .notificationCenter,
            "show apps": .apps, "apps": .apps, "launchpad": .apps, "show all apps": .apps, "open launchpad": .apps,
            "look up": .lookUp, "look it up": .lookUp, "look this up": .lookUp, "look that up": .lookUp,
            "define this": .lookUp, "define that": .lookUp, "smart zoom": .smartZoom
        ]
        if let action = system[s] { return .system(action) }

        // Clicking.
        if ["click", "click it", "click that", "click this", "click here", "tap", "left click", "select", "select it", "select that", "press it"].contains(s) { return .click }
        if ["double click", "double tap", "double click it", "double click that", "open it", "open that", "open this"].contains(s) { return .doubleClick }
        if ["right click", "right click it", "right click that", "control click", "secondary click", "context menu", "show menu"].contains(s) { return .rightClick }
        for verb in ["click on", "click", "tap on", "tap", "press the", "hit the", "select", "choose"] where starts(verb) {
            let target = rest(after: verb.split(separator: " ").count)
                .replacingOccurrences(of: "the ", with: "", options: .anchored)
                .replacingOccurrences(of: " button", with: "")
                .replacingOccurrences(of: " link", with: "")
            let asKey = target.replacingOccurrences(of: " key", with: "")
            if !target.isEmpty, parseKey(asKey.split(separator: " ").map(String.init)) == nil {
                return .clickNamed(target)
            }
        }

        // Scrolling.
        if starts("scroll") || starts("page") || starts("go to the") || starts("go to") || starts("jump to") {
            if t.contains("top") || t.contains("beginning") { return .scroll(.top, pages: 1) }
            if t.contains("bottom") || t.contains("end") { return .scroll(.bottom, pages: 1) }
            let pages = t.contains("lot") || t.contains("more") ? 3 : (t.contains("little") || t.contains("bit") ? 0 : 1)
            if t.contains("up") { return .scroll(.up, pages: pages) }
            if t.contains("down") { return .scroll(.down, pages: pages) }
            if t.contains("left") { return .scroll(.left, pages: pages) }
            if t.contains("right") { return .scroll(.right, pages: pages) }
        }

        // Apps.
        for verb in ["open", "launch", "start"] where starts(verb) {
            let name = rest(after: 1).replacingOccurrences(of: " app", with: "")
            if !name.isEmpty { return .openApp(name) }
        }
        for verb in ["switch to", "go to", "show me", "show", "bring up"] where starts(verb) {
            let name = rest(after: verb.split(separator: " ").count)
            if !name.isEmpty { return .switchApp(name) }
        }
        if starts("quit") || starts("close app") {
            let name = rest(after: starts("quit") ? 1 : 2)
            if !name.isEmpty { return .quitApp(name) }
        }

        // Keys: "press return", "press command shift t", or a bare key name.
        for verb in ["press", "hit", "push", "key"] where starts(verb) {
            if let k = parseKey(Array(t.dropFirst())) { return k }
        }
        // A bare key name ("return", "escape", "page down") — named keys only, never a lone letter,
        // so a stray "a" in the transcript can't type anything.
        if t.count <= 2, KeyCode.named[s] != nil, !["left", "right", "up", "down"].contains(s), let k = parseKey(t) { return k }

        // Text.
        if starts("type") || starts("write") || starts("enter text") {
            let n = starts("enter text") ? 2 : 1
            let text = rest(after: n)
            if !text.isEmpty { return .typeText(text) }
        }
        if starts("find") && t.count > 1 { return .findText(rest(after: starts("find the word") ? 3 : 1)) }
        for verb in ["search for", "spotlight search for", "spotlight search", "find app", "look up"] where starts(verb) {
            let q = rest(after: verb.split(separator: " ").count)
            if !q.isEmpty { return .search(q) }
        }
        return .unknown
    }

    /// "command shift t", "return", "escape", "option left arrow".
    static func parseKey(_ words: [String]) -> MacCommand? {
        var flags: CGEventFlags = []
        var rest = words
        while let w = rest.first, let f = KeyCode.modifiers[w] {
            flags.insert(f)
            rest.removeFirst()
        }
        if rest.first == "the" { rest.removeFirst() }
        if rest.last == "key" { rest.removeLast() }
        let name = rest.joined(separator: " ")
        guard !name.isEmpty, let code = KeyCode.code(for: name) else { return nil }
        let spoken = (words.first == "the" ? Array(words.dropFirst()) : words).joined(separator: " ")
        return .pressKey(code, flags, name: spoken)
    }
}

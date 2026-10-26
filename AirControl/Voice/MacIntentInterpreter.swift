import CoreGraphics
import Foundation
import FoundationModels

@Generable
enum MacAction {
    case click
    case doubleClick
    case rightClick
    case clickControl
    case scroll
    case openApp
    case switchToApp
    case quitApp
    case closeWindow
    case closeTab
    case newWindow
    case newTab
    case goBack
    case goForward
    case reload
    case copy
    case paste
    case cut
    case undo
    case redo
    case selectAll
    case save
    case find
    case typeText
    case pressKey
    case search
    case missionControl
    case showDesktop
    case nextSpace
    case previousSpace
    case minimize
    case fullScreen
    case zoomIn
    case zoomOut
    case startDictation
    case unclear
}

@Generable
struct MacIntent {
    @Guide(description: "The one action the person wants their Mac to do. Use unclear if it isn't an instruction for the computer.")
    var action: MacAction

    @Guide(description: "For clickControl: the exact label of the control to click, copied from the list of controls on screen. For openApp, switchToApp and quitApp: the app name. For typeText: the exact text to type. For search and find: what to search for. For pressKey: the key, such as return, escape, tab, space, delete, up, down, page down, or a single letter.")
    var target: String?

    @Guide(description: "For scroll: up, down, left, right, top or bottom.")
    var direction: String?

    @Guide(description: "For pressKey: modifier keys held with it, such as command, shift, option, control. Empty if none.")
    var modifiers: [String]?
}

/// Natural-language Mac control through Apple's on-device Foundation Models. Used for anything
/// the rule parser can't handle, e.g. "hit the blue send button" or "get me back to my email".
final class MacIntentInterpreter {
    static let instructions = """
    You turn a person's spoken request into one action on their Mac. \
    You're given the frontmost app, its window title, the labelled buttons and links on screen, and the running apps. \
    When they describe a control ("the send button", "the blue one that says continue"), choose clickControl and copy \
    the closest label from the on-screen list exactly. When they name an app, use its proper name (for example Safari, \
    Mail, Messages, Finder, System Settings, Visual Studio Code). "Get me back to" or "go to" a running app means \
    switchToApp. For typing, copy the words they want typed exactly, without the instruction itself.
    """

    static let openMicNote = """
    There was no wake word, so this may just be the person talking to someone else or thinking out loud. \
    Choose unclear unless it is plainly an instruction for the computer.
    """

    var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    func interpret(_ utterance: String, context: String, openMic: Bool) async -> MacCommand? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: openMic ? Self.instructions + " " + Self.openMicNote
                                                                 : Self.instructions)
        let prompt = "On screen:\n\(context)\n\nThe person said: \"\(utterance)\""
        do {
            let response = try await session.respond(to: prompt, generating: MacIntent.self)
            return Self.command(from: response.content)
        } catch {
            return nil
        }
    }

    static func command(from intent: MacIntent) -> MacCommand {
        let target = intent.target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch intent.action {
        case .click: return .click
        case .doubleClick: return .doubleClick
        case .rightClick: return .rightClick
        case .clickControl: return target.isEmpty ? .click : .clickNamed(target)
        case .scroll:
            let d = ScrollDirection(rawValue: (intent.direction ?? "down").lowercased()) ?? .down
            return .scroll(d, pages: 1)
        case .openApp: return target.isEmpty ? .unknown : .openApp(target)
        case .switchToApp: return target.isEmpty ? .shortcut(.switchApp) : .switchApp(target)
        case .quitApp: return target.isEmpty ? .shortcut(.quitApp) : .quitApp(target)
        case .closeWindow: return .shortcut(.closeWindow)
        case .closeTab: return .shortcut(.closeTab)
        case .newWindow: return .shortcut(.newWindow)
        case .newTab: return .shortcut(.newTab)
        case .goBack: return .shortcut(.goBack)
        case .goForward: return .shortcut(.goForward)
        case .reload: return .shortcut(.reload)
        case .copy: return .shortcut(.copy)
        case .paste: return .shortcut(.paste)
        case .cut: return .shortcut(.cut)
        case .undo: return .shortcut(.undo)
        case .redo: return .shortcut(.redo)
        case .selectAll: return .shortcut(.selectAll)
        case .save: return .shortcut(.save)
        case .find: return target.isEmpty ? .shortcut(.find) : .findText(target)
        case .typeText: return target.isEmpty ? .unknown : .typeText(target)
        case .pressKey:
            let words = (intent.modifiers ?? []).map { $0.lowercased() } + target.lowercased().split(separator: " ").map(String.init)
            return MacCommandParser.parseKey(words) ?? .unknown
        case .search: return target.isEmpty ? .shortcut(.spotlight) : .search(target)
        case .missionControl: return .shortcut(.missionControl)
        case .showDesktop: return .shortcut(.showDesktop)
        case .nextSpace: return .shortcut(.nextSpace)
        case .previousSpace: return .shortcut(.previousSpace)
        case .minimize: return .shortcut(.minimize)
        case .fullScreen: return .shortcut(.fullScreen)
        case .zoomIn: return .shortcut(.zoomIn)
        case .zoomOut: return .shortcut(.zoomOut)
        case .startDictation: return .startDictation
        case .unclear: return .unknown
        }
    }
}

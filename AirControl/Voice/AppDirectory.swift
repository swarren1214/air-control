import AppKit

/// Finds apps by spoken name: "safari", "vs code", "settings", "messages".
enum AppDirectory {
    /// What people say → the app's real name.
    static let aliases: [String: String] = [
        "settings": "System Settings", "system preferences": "System Settings", "preferences": "System Settings",
        "vs code": "Visual Studio Code", "vscode": "Visual Studio Code", "code": "Visual Studio Code",
        "chrome": "Google Chrome", "google chrome": "Google Chrome", "word": "Microsoft Word",
        "excel": "Microsoft Excel", "powerpoint": "Microsoft PowerPoint", "outlook": "Microsoft Outlook",
        "teams": "Microsoft Teams", "terminal": "Terminal", "the terminal": "Terminal", "mail": "Mail",
        "email": "Mail", "my email": "Mail", "texts": "Messages", "messages": "Messages", "imessage": "Messages",
        "music": "Music", "itunes": "Music", "app store": "App Store", "the app store": "App Store",
        "calculator": "Calculator", "calendar": "Calendar", "notes": "Notes", "photos": "Photos",
        "finder": "Finder", "files": "Finder", "x code": "Xcode", "xcode": "Xcode", "facetime": "FaceTime",
        "face time": "FaceTime", "activity monitor": "Activity Monitor", "preview": "Preview", "slack": "Slack",
        "figma": "Figma", "zoom": "zoom.us", "spotify": "Spotify", "notion": "Notion", "cursor": "Cursor",
        "claude": "Claude", "reminders": "Reminders", "maps": "Maps", "safari": "Safari", "firefox": "Firefox",
        "arc": "Arc", "pages": "Pages", "numbers": "Numbers", "keynote": "Keynote"
    ]

    private static let folders: [URL] = {
        let fm = FileManager.default
        var dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", "/System/Library/CoreServices"].map { URL(fileURLWithPath: $0) }
        dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return dirs
    }()

    /// Installed apps by lowercased name. Built once, lazily (a few hundred directory entries).
    private static var installed: [String: URL] = {
        var map: [String: URL] = [:]
        let fm = FileManager.default
        for dir in folders {
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "app" {
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                if map[name] == nil { map[name] = url }
            }
        }
        return map
    }()

    static func canonical(_ spoken: String) -> String {
        let s = spoken.lowercased().trimmingCharacters(in: .whitespaces)
        return aliases[s] ?? spoken
    }

    static func running(named spoken: String) -> NSRunningApplication? {
        let wanted = canonical(spoken).lowercased()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { ($0.localizedName ?? "").lowercased() == wanted }
            ?? apps.first { ($0.localizedName ?? "").lowercased().hasPrefix(wanted) }
            ?? apps.first { ($0.localizedName ?? "").lowercased().contains(wanted) }
    }

    static func installedURL(named spoken: String) -> URL? {
        let wanted = canonical(spoken).lowercased()
        if let exact = installed[wanted] { return exact }
        if let prefix = installed.keys.filter({ $0.hasPrefix(wanted) }).min(by: { $0.count < $1.count }) { return installed[prefix] }
        if let contains = installed.keys.filter({ $0.contains(wanted) }).min(by: { $0.count < $1.count }) { return installed[contains] }
        // "visual studio" → "visual studio code": every spoken word appears in the name.
        let words = wanted.split(separator: " ")
        if let all = installed.keys.filter({ name in words.allSatisfy { name.contains($0) } }).min(by: { $0.count < $1.count }) {
            return installed[all]
        }
        return nil
    }

    static var runningNames: [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
    }
}

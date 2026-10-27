import AppKit

/// Puts the user's own pictures back on the desktops that aren't in view. macOS keeps a picture for every desktop
/// (Space) on every display, and an app can only change the ones in view, so a painting left on another desktop as
/// Outbound quits would stay there. WallpaperAgent keeps all those pictures in a store of its own, which this edits:
/// each entry showing a painting gets a copy of an entry showing the picture that painting covered, or failing that
/// its own entry with that picture in the painting's place, and the agent starts again to read it. Nothing is touched
/// unless the store looks just as expected; those desktops then get their pictures back as each comes into view while
/// Outbound runs, as before.
@MainActor
enum OtherDesktops {
    private static let agentID = "com.apple.wallpaper.agent"
    private static let agentPath = "/System/Library/CoreServices/WallpaperAgent.app"

    private static var store: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// Replaces every painting `isStill` knows with the picture `original` says it covered, after keeping a copy of the
    /// store in `backups`. The paintings in `settling` have just left the desktops in view, which the agent saves
    /// first. Returns the file names of the paintings the store still shows afterwards, or nil when it couldn't be
    /// read or changed.
    static func putBack(isStill: (URL) -> Bool, original: (URL) -> URL?, backups: URL,
                        settling: Set<String> = []) -> Set<String>? {
        guard #available(macOS 14, *) else { return nil }
        if !settling.isEmpty { waitForSave(dropping: settling, isStill: isStill) }
        guard let data = try? Data(contentsOf: store),
              let plan = Plan(data, isStill: isStill, original: original) else { return nil }
        guard !plan.changes.isEmpty else { return plan.left }
        guard let agent = NSRunningApplication.runningApplications(withBundleIdentifier: agentID)
            .first(where: { $0.bundleURL?.path == agentPath }) else { return nil }
        let pid = agent.processIdentifier
        // Held still while the store changes, so it can't write over it, then stopped outright rather than asked to
        // quit, so it never saves its own copy on the way out. launchd starts it again, and it reads the store afresh.
        guard kill(pid, SIGSTOP) == 0 else { return nil }
        var held = true
        defer { if held { kill(pid, SIGCONT) } }
        // Read again, now that nothing else can change it.
        guard let fresh = try? Data(contentsOf: store),
              let again = Plan(fresh, isStill: isStill, original: original) else { return nil }
        guard !again.changes.isEmpty else { return again.left }
        guard let changed = again.applied() else { return nil }
        keep(fresh, in: backups)
        guard (try? changed.write(to: store, options: .atomic)) != nil,
              (try? Data(contentsOf: store)) == changed else {
            try? fresh.write(to: store, options: .atomic)
            return nil
        }
        kill(pid, SIGKILL)
        held = false
        Log.display.info("Put the user's own picture back on \(again.changes.count) desktop entries out of view")
        return again.left
    }

    /// The agent saves its store a moment after the desktops in view get their pictures back: waits until no entry
    /// shows the paintings they had, but never more than a second, as another desktop may show one too.
    private static func waitForSave(dropping names: Set<String>, isStill: (URL) -> Bool) {
        let deadline = Date.now.addingTimeInterval(1)
        while Date.now < deadline {
            guard let data = try? Data(contentsOf: store),
                  let plan = Plan(data, isStill: isStill, original: { _ in nil }) else { return }
            if plan.shown.isDisjoint(with: names) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// The last three copies of the store, from before each change.
    private static func keep(_ data: Data, in folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = Int(Date.now.timeIntervalSince1970 * 1000)
        try? data.write(to: folder.appending(path: "Index-\(stamp).plist"), options: .atomic)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix("Index-") }.sorted()
        for name in names.dropLast(3) { try? FileManager.default.removeItem(at: folder.appending(path: name)) }
    }

    /// The store as read, and what putting the pictures back would change in it.
    private struct Plan {
        let root: NSMutableDictionary
        let format: PropertyListSerialization.PropertyListFormat
        /// Entries showing a painting, each with the content to give it.
        var changes: [(entry: NSMutableDictionary, content: Any)] = []
        /// The paintings the store shows.
        var shown: Set<String> = []
        /// Paintings the store would still show, as nothing can be put in their place.
        var left: Set<String> = []

        init?(_ data: Data, isStill: (URL) -> Bool, original: (URL) -> URL?) {
            var format = PropertyListSerialization.PropertyListFormat.binary
            guard let root = (try? PropertyListSerialization.propertyList(
                      from: data, options: .mutableContainersAndLeaves, format: &format)) as? NSMutableDictionary,
                  let spaces = root["Spaces"] as? NSDictionary else { return nil }
            self.root = root
            self.format = format
            // Each desktop entry with the display it is for, or "Default" for a desktop's own.
            var desktops: [(display: String, entry: NSMutableDictionary)] = []
            func add(_ display: String, _ holder: Any?) {
                if let entry = (holder as? NSDictionary)?["Desktop"] as? NSMutableDictionary {
                    desktops.append((display, entry))
                }
            }
            for case let space as NSDictionary in spaces.allValues {
                add("Default", space["Default"])
                for case let (display as String, holder) in space["Displays"] as? NSDictionary ?? [:] {
                    add(display, holder)
                }
            }
            for case let (display as String, holder) in root["Displays"] as? NSDictionary ?? [:] {
                add(display, holder)
            }
            for (display, entry) in desktops {
                guard let painting = Self.picture(entry), isStill(painting) else { continue }
                shown.insert(painting.lastPathComponent)
                guard let wanted = original(painting),
                      let content = Self.copy(showing: wanted, for: display, from: desktops, isStill)
                          ?? Self.content(entry, showing: wanted) else {
                    left.insert(painting.lastPathComponent)
                    continue
                }
                changes.append((entry, content))
            }
        }

        func applied() -> Data? {
            for change in changes { change.entry["Content"] = change.content }
            return try? PropertyListSerialization.data(fromPropertyList: root, format: format, options: 0)
        }

        /// The image file a desktop entry shows, if it is one picture from a file, as the system and Outbound set them.
        static func picture(_ entry: NSDictionary) -> URL? {
            guard let configuration = Self.configuration(entry), let location = configuration["url"] as? NSDictionary,
                  let relative = location["relative"] as? String, let url = URL(string: relative), url.isFileURL
            else { return nil }
            return url
        }

        /// An entry's one choice, and what it shows, if it is a picture from a file.
        private static func configuration(_ entry: NSDictionary) -> NSMutableDictionary? {
            guard let content = entry["Content"] as? NSDictionary, let choices = content["Choices"] as? NSArray,
                  choices.count == 1, let choice = choices[0] as? NSDictionary,
                  let data = choice["Configuration"] as? Data, !data.isEmpty,
                  let configuration = (try? PropertyListSerialization.propertyList(
                      from: data, options: .mutableContainersAndLeaves, format: nil)) as? NSMutableDictionary,
                  configuration["type"] as? String == "imageFile", let location = configuration["url"] as? NSDictionary,
                  location.count == 1, location["relative"] is String else { return nil }
            return configuration
        }

        /// A copy of what an entry showing `picture` holds, preferring one for the same display.
        static func copy(showing picture: URL, for display: String,
                         from desktops: [(display: String, entry: NSMutableDictionary)],
                         _ isStill: (URL) -> Bool) -> Any? {
            func shows(_ entry: NSDictionary) -> Bool {
                guard let shown = Self.picture(entry), !isStill(shown) else { return false }
                return shown.standardizedFileURL.path == picture.standardizedFileURL.path
            }
            let source = desktops.first { $0.display == display && shows($0.entry) } ?? desktops.first { shows($0.entry) }
            return source.flatMap { Self.deepCopy($0.entry["Content"]) }
        }

        /// What a painting's own entry holds with `picture` in the painting's place: its fill colour, which the system
        /// kept from the picture it covered, and filling the screen, as the painting did.
        static func content(_ entry: NSDictionary, showing picture: URL) -> Any? {
            guard let configuration = Self.configuration(entry),
                  let content = Self.deepCopy(entry["Content"]) as? NSMutableDictionary,
                  let choice = (content["Choices"] as? NSArray)?.firstObject as? NSMutableDictionary else { return nil }
            configuration["url"] = NSMutableDictionary(dictionary: ["relative": picture.absoluteString])
            guard let data = try? PropertyListSerialization.data(fromPropertyList: configuration, format: .binary,
                                                                 options: 0) else { return nil }
            choice["Configuration"] = data
            return content
        }

        static func deepCopy(_ value: Any?) -> Any? {
            guard let value, let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary,
                                                                              options: 0) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves,
                                                               format: nil)
        }
    }
}

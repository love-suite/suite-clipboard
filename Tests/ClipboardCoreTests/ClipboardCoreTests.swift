import Foundation
import Testing
@testable import ClipboardCore
import ClipboardSettings

private func text(_ string: String, rich: Bool = false, extra: [String: Data] = [:]) -> PasteboardSnapshot {
    var item: [String: Data] = [PasteboardType.plainText: Data(string.utf8)]
    if rich { item[PasteboardType.rtf] = Data("{\\rtf1 \(string)}".utf8) }
    item.merge(extra) { $1 }
    return PasteboardSnapshot(items: [item])
}

private func clip(_ string: String, date: Date = Date()) -> ClipItem {
    ClipClassifier.item(from: text(string), date: date)!
}

@Suite struct ClassifierTests {
    @Test func plainRichAndLinks() {
        #expect(ClipClassifier.item(from: text("Hello"))?.kind == .text)
        #expect(ClipClassifier.item(from: text("Hello", rich: true))?.kind == .richText)
        #expect(ClipClassifier.item(from: text("https://www.apple.com/fr/"))?.kind == .link)
        #expect(ClipClassifier.item(from: text("  mailto:someone@example.com\n"))?.kind == .link)
        #expect(ClipClassifier.item(from: text("see https://apple.com"))?.kind == .text)
        #expect(ClipClassifier.item(from: text("file:///etc"))?.kind == .text)
        #expect(ClipClassifier.item(from: text("   \n ")) == nil)
        #expect(ClipClassifier.item(from: PasteboardSnapshot(items: [])) == nil)
    }

    @Test func filesComeFirstOneLinePerFile() throws {
        let snapshot = PasteboardSnapshot(items: [
            [PasteboardType.fileURL: Data("file:///Users/me/a%20b.txt".utf8),
             PasteboardType.plainText: Data("a b.txt".utf8)],
            [PasteboardType.fileURL: Data("file:///Users/me/Pictures/".utf8)],
        ])
        let item = try #require(ClipClassifier.item(from: snapshot))
        #expect(item.kind == .files)
        #expect(item.text == "/Users/me/a b.txt\n/Users/me/Pictures")
        #expect(item.title == "a b.txt, Pictures")
        #expect(item.fileURLs.count == 2)
    }

    @Test func picturesAreFingerprintedByTheirData() throws {
        let png = PasteboardSnapshot(items: [[PasteboardType.png: Data([1, 2, 3])]])
        let item = try #require(ClipClassifier.item(from: png))
        #expect(item.kind == .image)
        #expect(item.text.isEmpty)
        #expect(item.fingerprint == ClipClassifier.item(from: png)?.fingerprint)
        let other = PasteboardSnapshot(items: [[PasteboardType.tiff: Data([4])]])
        #expect(ClipClassifier.item(from: other)?.fingerprint != item.fingerprint)
    }

    @Test func titleIsTheFirstNonEmptyLine() {
        #expect(clip("\n\n  First line  \nsecond").title == "First line")
    }

    @Test func trimDropsPrivateTypesAndCutsBigItems() throws {
        let small = text("Hi", extra: ["dyn.ah62d4rv4gu8y": Data([0])])
        #expect(ClipClassifier.trimmed(small)?.types == [PasteboardType.plainText])

        let big = PasteboardSnapshot(items: [[
            PasteboardType.plainText: Data("Hi".utf8),
            "com.microsoft.Word.private": Data(count: 100),
            PasteboardType.tiff: Data(count: 50),
            PasteboardType.png: Data(count: 10),
        ]])
        let cut = try #require(ClipClassifier.trimmed(big, maxBytes: 70))
        #expect(cut.types == [PasteboardType.plainText, PasteboardType.png])
        #expect(ClipClassifier.trimmed(big, maxBytes: 5) == nil)
    }
}

@Suite struct HistoryTests {
    @Test func newestFirstAndDuplicatesMoveToTheTop() {
        var history = ClipboardHistory()
        let a = clip("a"), b = clip("b")
        history.add(a)
        history.add(b)
        #expect(history.items.map(\.text) == ["b", "a"])

        let again = clip("a")
        let dropped = history.add(again)
        #expect(history.items.map(\.text) == ["a", "b"])
        #expect(history.items.first?.id == again.id)
        #expect(dropped.map(\.id) == [a.id])
    }

    @Test func theOldestItemsGoBeyondTheLimit() {
        var history = ClipboardHistory(limit: 2)
        history.add(clip("1"))
        history.add(clip("2"))
        let dropped = history.add(clip("3"))
        #expect(history.items.map(\.text) == ["3", "2"])
        #expect(dropped.map(\.text) == ["1"])

        #expect(history.setLimit(1).map(\.text) == ["2"])
        #expect(history.items.map(\.text) == ["3"])
        #expect(history.setLimit(5).isEmpty)
    }

    @Test func clearRemovesEverything() {
        var history = ClipboardHistory()
        let a = clip("a"), b = clip("b")
        [a, b].forEach { history.add($0) }
        #expect(Set(history.clear().map(\.id)) == [a.id, b.id])
        #expect(history.items.isEmpty)
    }

    @Test func removeAndMoveToTop() {
        var history = ClipboardHistory()
        let a = clip("a"), b = clip("b")
        history.add(a)
        history.add(b)
        history.moveToTop(a.id)
        #expect(history.items.map(\.id) == [a.id, b.id])
        #expect(history.remove(b.id)?.id == b.id)
        #expect(history.remove(b.id) == nil)
        #expect(history.items.map(\.id) == [a.id])
    }

    @Test func searchIgnoresCaseAndAccentsAndNeedsEveryWord() {
        var history = ClipboardHistory()
        history.add(clip("Le café de la gare"))
        history.add(clip("Gare du Nord"))
        history.add(ClipClassifier.item(from: PasteboardSnapshot(items: [[PasteboardType.png: Data([1])]]))!)
        #expect(history.matching("CAFE").map(\.text) == ["Le café de la gare"])
        #expect(history.matching("gare").count == 2)
        #expect(history.matching("gare nord").map(\.text) == ["Gare du Nord"])
        #expect(history.matching("picture").map(\.kind) == [.image])
        #expect(history.matching("  ").count == 3)
    }

    @Test func itemsAreSortedOnLoad() {
        let old = clip("old", date: Date(timeIntervalSince1970: 0))
        let new = clip("new", date: Date(timeIntervalSince1970: 100))
        #expect(ClipboardHistory(items: [old, new]).items.map(\.text) == ["new", "old"])
    }
}

@Suite struct FilterTests {
    @Test func skipsWhatPasswordManagersMark() {
        let filter = ClipboardFilter(ignoredApps: [])
        #expect(filter.shouldRecord(text("hello"), frontmostApp: nil))
        for marker in [PasteboardType.concealed, PasteboardType.transient, PasteboardType.autoGenerated] {
            #expect(!filter.shouldRecord(text("secret", extra: [marker: Data()]), frontmostApp: nil))
        }
    }

    @Test func skipsIgnoredAppsByNamedSourceOrFrontmostApp() {
        let filter = ClipboardFilter(ignoredApps: ["com.example.vault"])
        #expect(!filter.shouldRecord(text("x"), frontmostApp: "com.example.vault"))
        #expect(filter.shouldRecord(text("x"), frontmostApp: "com.apple.TextEdit"))
        let named = text("x", extra: [PasteboardType.source: Data("com.example.vault".utf8)])
        #expect(!filter.shouldRecord(named, frontmostApp: "com.apple.TextEdit"))
        #expect(ClipboardFilter.source(of: named, frontmostApp: "other") == "com.example.vault")
    }

    @Test func applePasswordAppsAreIgnoredByDefault() {
        #expect(!ClipboardFilter().shouldRecord(text("x"), frontmostApp: "com.apple.Passwords"))
    }
}

@Suite struct StoreTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardStore-\(UUID().uuidString)")
    }

    @Test func historyAndContentsSurviveARestart() throws {
        let root = folder()
        let store = ClipboardStore(folder: root)
        var history = ClipboardHistory()
        let snapshot = text("Bonjour", rich: true)
        let item = try #require(ClipClassifier.item(from: snapshot))
        try store.write(snapshot, for: item.id)
        history.add(item)
        try store.save(history)

        let reloaded = ClipboardStore(folder: root)
        let loaded = reloaded.loadHistory(limit: 50)
        #expect(loaded.items == history.items)
        #expect(reloaded.snapshot(for: item.id) == snapshot)
    }

    @Test func readsAHistorySavedWithPins() throws {
        let root = folder()
        let store = ClipboardStore(folder: root)
        let item = clip("old")
        try store.write(text("old"), for: item.id)
        let json = """
            [{"id":"\(item.id.uuidString)","kind":"text","date":0,"isPinned":true,"text":"old",
              "fingerprint":"text:old","byteCount":3}]
            """
        try Data(json.utf8).write(to: root.appendingPathComponent("history.json"))
        #expect(store.loadHistory(limit: 50).items.map(\.text) == ["old"])
    }

    @Test func dropsEntriesWithoutContentsAndContentsWithoutEntries() throws {
        let root = folder()
        let store = ClipboardStore(folder: root)
        let kept = clip("kept"), lost = clip("lost"), orphan = UUID()
        try store.write(text("kept"), for: kept.id)
        try store.write(text("orphan"), for: orphan)
        var history = ClipboardHistory()
        history.add(kept)
        history.add(lost)
        try store.save(history)

        #expect(store.loadHistory(limit: 50).items.map(\.id) == [kept.id])
        #expect(store.snapshot(for: orphan) == nil)
    }

    @Test func aSmallerLimitRemovesTheirContents() throws {
        let store = ClipboardStore(folder: folder())
        var history = ClipboardHistory()
        let items = (1...3).map { clip("\($0)") }
        for item in items {
            try store.write(text(item.text), for: item.id)
            history.add(item)
        }
        try store.save(history)
        #expect(store.loadHistory(limit: 1).items.map(\.text) == ["3"])
        #expect(store.snapshot(for: items[0].id) == nil)
        #expect(store.snapshot(for: items[2].id) != nil)
    }
}

@Suite struct HoldGestureTests {
    @Test func aShortCommandVStillPastes() {
        var gesture = PasteHoldGesture()
        #expect(gesture.handle(.pasteDown(isRepeat: false)) == (false, .startTimer))
        #expect(gesture.handle(.pasteUp) == (false, .paste))
        #expect(gesture.state == .idle)
        // The timer firing afterwards does nothing.
        #expect(gesture.handle(.holdElapsed) == (true, nil))
    }

    @Test func commandLetGoFirstIsStillATap() {
        var gesture = PasteHoldGesture()
        _ = gesture.handle(.pasteDown(isRepeat: false))
        #expect(gesture.handle(.commandReleased) == (true, .paste))
        #expect(gesture.handle(.pasteUp) == (true, nil))
    }

    @Test func holdingOpensThenEachVStepsAndLettingGoPastes() {
        var gesture = PasteHoldGesture()
        _ = gesture.handle(.pasteDown(isRepeat: false))
        #expect(gesture.handle(.holdElapsed) == (false, .openPanel))
        // Key repeats while V stays down don't step.
        #expect(gesture.handle(.pasteDown(isRepeat: true)) == (false, nil))
        #expect(gesture.handle(.pasteUp) == (false, nil))
        #expect(gesture.handle(.pasteDown(isRepeat: false)) == (false, .selectNext))
        #expect(gesture.handle(.pasteUp) == (false, nil))
        #expect(gesture.handle(.pasteDown(isRepeat: false)) == (false, .selectNext))
        #expect(gesture.handle(.commandReleased) == (true, .commit))
        #expect(gesture.state == .idle)
    }

    @Test func aKeyRepeatBeforeTheTimerAlsoOpens() {
        var gesture = PasteHoldGesture()
        _ = gesture.handle(.pasteDown(isRepeat: false))
        #expect(gesture.handle(.pasteDown(isRepeat: true)) == (false, .openPanel))
    }

    @Test func lettingGoWithoutSteppingLeavesTheListOpen() {
        var gesture = PasteHoldGesture()
        _ = gesture.handle(.pasteDown(isRepeat: false))
        _ = gesture.handle(.holdElapsed)
        _ = gesture.handle(.pasteUp)
        #expect(gesture.handle(.commandReleased) == (true, nil))
        #expect(gesture.state == .idle)
        // ⌘V in the open list (into its search field) is an ordinary tap again.
        #expect(gesture.handle(.pasteDown(isRepeat: false)) == (false, .startTimer))
    }

    @Test func closingTheListEndsTheGesture() {
        var gesture = PasteHoldGesture()
        _ = gesture.handle(.pasteDown(isRepeat: false))
        _ = gesture.handle(.holdElapsed)
        _ = gesture.handle(.pasteDown(isRepeat: false))
        #expect(gesture.handle(.panelClosed) == (true, nil))
        #expect(gesture.handle(.commandReleased) == (true, nil))
    }

    @Test func otherEventsPassThroughWhenIdle() {
        var gesture = PasteHoldGesture()
        #expect(gesture.handle(.pasteUp) == (true, nil))
        #expect(gesture.handle(.commandReleased) == (true, nil))
        #expect(gesture.handle(.pasteDown(isRepeat: true)) == (true, nil))
    }
}

@Suite struct SettingsTests {
    @Test func settingsHaveDefaultsAndPersist() throws {
        let suite = "ClipboardSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardSettings(defaults: defaults)
        #expect(settings.historyLimit == 50)
        #expect(settings.holdsCommandV)
        #expect(settings.ignoredApps == ClipboardFilter.defaultIgnoredApps)
        #expect(settings.isEnabled)
        #expect(settings.loginStatus == .off)

        settings.historyLimit = 100
        settings.holdsCommandV = false
        settings.loginStatus = .needsApproval
        settings.ignoredApps = ["a", "b", "a"]
        let again = ClipboardSettings(defaults: defaults)
        #expect(again.historyLimit == 100)
        #expect(!again.holdsCommandV)
        #expect(again.loginStatus == .needsApproval)
        #expect(again.ignoredApps == ["a", "b"])
        #expect(!again.filter.shouldRecord(text("x"), frontmostApp: "b"))
    }
}

@Suite struct TimeTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }
    let locale = Locale(identifier: "en_GB")

    func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter.date(from: string)!
    }

    @Test func todayShowsTheTimeOnly() {
        let now = date("2026-11-20T18:00:00")
        #expect(ClipTime.label(for: date("2026-11-20T14:05:32"), withSeconds: false, now: now,
                               calendar: calendar, locale: locale) == "14:05")
        #expect(ClipTime.label(for: date("2026-11-20T14:05:32"), withSeconds: true, now: now,
                               calendar: calendar, locale: locale) == "14:05:32")
    }

    @Test func earlierDaysShowTheDay() {
        let now = date("2026-11-20T18:00:00")
        let label = ClipTime.label(for: date("2026-11-18T09:07:00"), withSeconds: false, now: now,
                                   calendar: calendar, locale: locale)
        #expect(label.contains("18 Nov") && label.contains("09:07") && !label.contains("2026"))
        let lastYear = ClipTime.label(for: date("2025-12-31T23:59:00"), withSeconds: false, now: now,
                                      calendar: calendar, locale: locale)
        #expect(lastYear.contains("2025"))
    }

    @Test func secondsOnlyWhereTwoShareAMinute() {
        let a = date("2026-11-20T14:05:01"), b = date("2026-11-20T14:05:59"), c = date("2026-11-20T14:06:00")
        let crowded = ClipTime.crowdedMinutes([a, b, c], calendar: calendar)
        #expect(crowded.contains(ClipTime.minute(of: a, calendar: calendar)))
        #expect(!crowded.contains(ClipTime.minute(of: c, calendar: calendar)))
    }
}

@Suite struct ExpiryAndPictureTextTests {
    @Test func expiryIsNeverByDefaultAndForgetsOldItems() throws {
        let suite = "ClipboardExpiryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ClipboardSettings(defaults: defaults)
        #expect(settings.expiryDays == 0)
        #expect(settings.expiryDate() == nil)
        #expect(settings.quickListSize == ClipboardSettings.defaultQuickListSize)
        #expect(settings.pinnedListOnTop)

        settings.expiryDays = 7
        let now = Date()
        let cutoff = try #require(settings.expiryDate(now: now))
        var history = ClipboardHistory()
        history.add(clip("old", date: now.addingTimeInterval(-8 * 86_400)))
        history.add(clip("recent", date: now.addingTimeInterval(-86_400)))
        let dropped = history.removeItems(copiedBefore: cutoff)
        #expect(dropped.map(\.text) == ["old"])
        #expect(history.items.map(\.text) == ["recent"])
    }

    @Test func searchFindsTheTextInPictures() throws {
        var history = ClipboardHistory()
        let picture = try #require(ClipClassifier.item(from: PasteboardSnapshot(items: [[PasteboardType.png: Data([1, 2, 3])]])))
        history.add(picture)
        history.add(clip("something else"))
        #expect(history.matching("facture").isEmpty)
        history.setRecognizedText("FACTURE n° 42", for: picture.id)
        #expect(history.matching("facture").map(\.id) == [picture.id])
        #expect(history.item(picture.id)?.recognizedText == "FACTURE n° 42")
    }
}

@Suite struct OtherDeviceTests {
    @Test func copiesFromAnotherDeviceAreTaggedWithoutTheAppInFront() throws {
        let remote = text("from the phone", extra: [PasteboardType.remoteClipboard: Data()])
        let item = try #require(ClipClassifier.item(from: remote, sourceApp: "com.apple.Safari", sourceName: "Safari"))
        #expect(item.isFromOtherDevice)
        #expect(item.sourceApp == nil && item.sourceName == nil)
        let local = try #require(ClipClassifier.item(from: text("here"), sourceApp: "com.apple.Safari", sourceName: "Safari"))
        #expect(!local.isFromOtherDevice)
        #expect(local.sourceName == "Safari")

        var history = ClipboardHistory()
        history.add(item)
        history.add(local)
        #expect(history.matching("iphone").map(\.id) == [item.id])
        #expect(history.matching("icloud").map(\.id) == [item.id])
    }

    @Test func historiesSavedBeforeTheTagStillLoad() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","kind":"text","date":0,"text":"x","fingerprint":"text:x","byteCount":1}]"#
        let items = try JSONDecoder().decode([ClipItem].self, from: Data(json.utf8))
        #expect(items.first?.isFromOtherDevice == false)
    }
}

@Suite struct BackupTests {
    @Test func backsUpAndRestoresIntoAnEmptyHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardBackupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardStore(folder: root.appendingPathComponent("store"))
        let backup = ClipboardBackup(store: store.folder, root: root.appendingPathComponent("iCloud"), machine: "Mac A")
        #expect(!backup.exists)

        var history = store.loadHistory(limit: 50)
        let first = clip("first"), second = clip("second")
        for item in [first, second] {
            try store.write(text(item.text), for: item.id)
            history.add(item)
        }
        try store.save(history)
        try backup.backUp()
        #expect(backup.exists)

        // An item leaves the history: its copy leaves the backup.
        history.remove(first.id)
        store.removeContents(of: [first.id])
        try store.save(history)
        try backup.backUp()
        let backedUp = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("iCloud/Mac A/Items").path)
        #expect(backedUp == ["\(second.id.uuidString).plist"])

        // Another Mac, with no backup of its own: an empty store gets Mac A's back; its own backup
        // goes to a folder of its own.
        let other = ClipboardStore(folder: root.appendingPathComponent("other"))
        let otherBackup = ClipboardBackup(store: other.folder, root: backup.root, machine: "Mac B")
        #expect(!otherBackup.exists)
        let source = try #require(otherBackup.restoreSource)
        #expect(source.lastPathComponent == "Mac A")
        try otherBackup.restore(from: source)
        let restored = other.loadHistory(limit: 50)
        #expect(restored.items.map(\.text) == ["second"])
        #expect(other.snapshot(for: second.id) == text("second"))
        try otherBackup.backUp()
        #expect(otherBackup.exists && backup.exists)
        #expect(otherBackup.restoreSource?.lastPathComponent == "Mac B")
    }
}

// История буфера обмена для macOS — аналог Win+V.
// Живёт в строке меню, запоминает текст, картинки, скриншоты и файлы,
// по сочетанию клавиш показывает список рядом с курсором.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CryptoKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Helpers

func dlog(_ fmt: String, _ args: CVarArg...) {
    let line = String(format: fmt, arguments: args) + "\n"
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClipHistory/debug.log")
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: url) }
}

func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
    return many
}

func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func thumbnailPNG(_ img: NSImage, maxW: CGFloat = 240, maxH: CGFloat = 120) -> Data? {
    let s = img.size
    guard s.width > 0, s.height > 0 else { return nil }
    let scale = min(maxW / s.width, maxH / s.height, 1)
    let w = max(1, Int(s.width * scale * 2)), h = max(1, Int(s.height * scale * 2))
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: CGFloat(w) / 2, height: CGFloat(h) / 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    img.draw(in: NSRect(origin: .zero, size: rep.size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Model & storage

struct ClipEntry: Codable {
    enum Kind: String, Codable { case text, image, files }
    var id: String
    var date: Date
    var kind: Kind
    var title: String
    var detail: String
    var hash: String
}

@MainActor
final class Store {
    let dir: URL
    private(set) var entries: [ClipEntry] = []
    private var thumbs: [String: NSImage] = [:]
    let maxEntries = 100
    private let io = DispatchQueue(label: "cliphistory.io")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("ClipHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: indexURL),
           let e = try? JSONDecoder().decode([ClipEntry].self, from: d) {
            entries = e
        }
    }

    private var indexURL: URL { dir.appendingPathComponent("index.json") }
    private func dataURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).plist") }
    private func thumbURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).thumb.png") }

    func thumb(for id: String) -> NSImage? {
        if let t = thumbs[id] { return t }
        if let t = NSImage(contentsOf: thumbURL(id)) { thumbs[id] = t; return t }
        return nil
    }

    func add(kind: ClipEntry.Kind, title: String, detail: String, hash: String,
             payload: [[String: Data]], thumb: Data?) {
        guard let blob = try? PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        else { return }
        let id: String
        if let i = entries.firstIndex(where: { $0.hash == hash }) {
            var e = entries.remove(at: i)
            e.date = Date(); e.title = title; e.detail = detail
            entries.insert(e, at: 0)
            id = e.id
        } else {
            id = UUID().uuidString
            entries.insert(ClipEntry(id: id, date: Date(), kind: kind, title: title, detail: detail, hash: hash), at: 0)
        }
        if let thumb, let img = NSImage(data: thumb) { thumbs[id] = img }
        let dURL = dataURL(id), tURL = thumbURL(id)
        io.async {
            try? blob.write(to: dURL, options: .atomic)
            if let thumb { try? thumb.write(to: tURL, options: .atomic) }
        }
        while entries.count > maxEntries { deleteFiles(entries.removeLast().id) }
        saveIndex()
    }

    func payload(_ id: String) -> [[String: Data]]? {
        io.sync {}  // дождаться записи на диск
        guard let d = try? Data(contentsOf: dataURL(id)) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil)) as? [[String: Data]]
    }

    func moveToTop(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries.remove(at: i)
        e.date = Date()
        entries.insert(e, at: 0)
        saveIndex()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        deleteFiles(id)
        saveIndex()
    }

    func clear() {
        let ids = entries.map(\.id)
        entries.removeAll()
        ids.forEach(deleteFiles)
        saveIndex()
    }

    private func deleteFiles(_ id: String) {
        thumbs[id] = nil
        let a = dataURL(id), b = thumbURL(id)
        io.async {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
    }

    private func saveIndex() {
        let e = entries, u = indexURL
        io.async {
            if let d = try? JSONEncoder().encode(e) { try? d.write(to: u, options: .atomic) }
        }
    }
}

// MARK: - Global hotkey (Carbon, не требует разрешений)

struct HotkeyPreset {
    let short: String
    let title: String
    let code: UInt32
    let mods: UInt32
}

let hotkeyPresets: [HotkeyPreset] = [
    HotkeyPreset(short: "⌘⇧V", title: "⌘⇧V   Command + Shift + V", code: UInt32(kVK_ANSI_V), mods: UInt32(cmdKey | shiftKey)),
    HotkeyPreset(short: "⌥V", title: "⌥V   Option + V", code: UInt32(kVK_ANSI_V), mods: UInt32(optionKey)),
    HotkeyPreset(short: "⌃V", title: "⌃V   Control + V", code: UInt32(kVK_ANSI_V), mods: UInt32(controlKey)),
    HotkeyPreset(short: "⌘⌥V", title: "⌘⌥V   Command + Option + V", code: UInt32(kVK_ANSI_V), mods: UInt32(cmdKey | optionKey)),
]

final class HotKeyCenter {
    nonisolated(unsafe) static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { HotKeyCenter.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ p: HotkeyPreset) -> Bool {
        if let ref { UnregisterEventHotKey(ref); self.ref = nil }
        let hid = EventHotKeyID(signature: 0x434C_4950, id: 1)  // 'CLIP'
        return RegisterEventHotKey(p.code, p.mods, hid, GetApplicationEventTarget(), 0, &ref) == noErr
    }
}

// MARK: - Отдача картинки в формате TIFF по запросу

final class ImageProvider: NSObject, NSPasteboardItemDataProvider {
    let source: Data
    init(source: Data) { self.source = source }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff else { return }
        if let tiff = NSBitmapImageRep(data: source)?.tiffRepresentation(using: .lzw, factor: 0) ?? NSImage(data: source)?.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
    }
}

// MARK: - Слежение за папкой скриншотов

@MainActor
final class ScreenshotWatcher {
    var onNew: ((URL) -> Void)?
    private(set) var folder: URL?
    private(set) var accessOK = true
    private var source: DispatchSourceFileSystemObject?
    private var seen = Set<String>()
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp"]

    /// Папка, куда macOS сохраняет скриншоты (по умолчанию — Рабочий стол).
    static func screenshotFolder() -> URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"), !loc.isEmpty {
            let p = (loc as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    private var generation = 0
    private var starting = false

    func start() {
        stop()
        let dir = Self.screenshotFolder()
        folder = dir
        generation += 1
        let gen = generation
        starting = true
        // Первое обращение к Рабочему столу показывает системный вопрос о доступе
        // и ждёт ответа — делаем это в фоне, чтобы не подвешивать приложение.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let fd = open(dir.path, O_EVTONLY)
            let err = errno
            let files = fd >= 0 ? Set(Self.listFiles(dir).map(\.path)) : []
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, gen == self.generation else { if fd >= 0 { close(fd) }; return }
                    self.finishStart(dir: dir, fd: fd, err: err, files: files)
                }
            }
        }
    }

    private func finishStart(dir: URL, fd: Int32, err: Int32, files: Set<String>) {
        starting = false
        guard fd >= 0 else { accessOK = false; dlog("cannot open %@ errno=%d", dir.path, err); return }
        accessOK = true
        seen = files  // старые файлы не трогаем
        dlog("watching %@ (%d files)", dir.path, seen.count)
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleScan() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        generation += 1
        starting = false
        source?.cancel()
        source = nil
    }

    /// Перезапустить, если пользователь поменял папку скриншотов.
    func refreshFolder() {
        if starting { return }
        if Self.screenshotFolder() != folder || source == nil { start() }
    }

    private func scheduleScan() {
        // macOS сначала пишет скрытый временный файл, потом переименовывает и ставит метку.
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scan() }
        }
    }

    nonisolated private static func listFiles(_ dir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
    }

    private func scan() {
        guard let dir = folder else { return }
        for url in Self.listFiles(dir) where !seen.contains(url.path) {
            guard Self.imageExts.contains(url.pathExtension.lowercased()) else { seen.insert(url.path); continue }
            if Self.isScreenshot(url) {
                seen.insert(url.path)
                onNew?(url)
            } else {
                // Не скриншот: запоминаем, когда файл уже «устоялся», чтобы не проверять снова.
                let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if Date().timeIntervalSince(created) > 5 { seen.insert(url.path) }
            }
        }
    }

    static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }
}

// MARK: - Picker UI

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class EmphasizedRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
}

final class ClipCell: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("ClipCell")
    let title = NSTextField(wrappingLabelWithString: "")
    let sub = NSTextField(labelWithString: "")
    let thumbView = NSImageView()
    let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseID

        title.font = .systemFont(ofSize: 13)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        title.cell?.truncatesLastVisibleLine = true
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sub.font = .systemFont(ofSize: 11)
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        badge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        badge.alignment = .right
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)

        thumbView.imageScaling = .scaleProportionallyDown
        thumbView.wantsLayer = true
        thumbView.layer?.cornerRadius = 5
        thumbView.layer?.masksToBounds = true
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            thumbView.widthAnchor.constraint(equalToConstant: 64),
            thumbView.heightAnchor.constraint(equalToConstant: 52),
        ])

        let texts = NSStackView(views: [title, sub])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        texts.setHuggingPriority(.defaultLow, for: .horizontal)

        for v in [thumbView, texts, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textsAfterThumb = texts.leadingAnchor.constraint(equalTo: thumbView.trailingAnchor, constant: 10)
        textsAtEdge = texts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbView.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.centerYAnchor.constraint(equalTo: centerYAnchor),
            texts.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -8),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 28),
            textsAtEdge,
        ])
        applyColors()
    }

    private var textsAfterThumb: NSLayoutConstraint!
    private var textsAtEdge: NSLayoutConstraint!

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ e: ClipEntry, thumb: NSImage?, index: Int, time: String, width: CGFloat) {
        let hasThumb = e.kind != .text
        thumbView.isHidden = !hasThumb
        thumbView.image = thumb
        if hasThumb {
            textsAtEdge.isActive = false
            textsAfterThumb.isActive = true
        } else {
            textsAfterThumb.isActive = false
            textsAtEdge.isActive = true
        }
        title.stringValue = e.title
        title.preferredMaxLayoutWidth = max(80, width - (hasThumb ? 74 : 0) - 60)
        sub.stringValue = e.detail.isEmpty ? time : "\(e.detail) · \(time)"
        badge.stringValue = index < 9 ? "⌘\(index + 1)" : ""
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        let sel = backgroundStyle == .emphasized
        title.textColor = sel ? .white : .labelColor
        sub.textColor = sel ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        badge.textColor = sel ? NSColor.white.withAlphaComponent(0.8) : .tertiaryLabelColor
    }
}

@MainActor
final class PickerController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    let store: Store
    var onPick: ((ClipEntry, Bool) -> Void)?
    var needsAccessibilityWarning: (() -> Bool)?
    var onFixAccessibility: (() -> Void)?
    private let axButton = NSButton(title: "", target: nil, action: nil)
    var hotkeyLabel = "⌘⇧V" { didSet { headerHint.stringValue = hotkeyLabel } }

    private let panel: KeyPanel
    private let search = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let headerHint = NSTextField(labelWithString: "⌘⇧V")
    private var items: [ClipEntry] = []
    private var keyMonitor: Any?
    private let timeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()
    private static let digitKeys: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    private let size = NSSize(width: 420, height: 480)

    init(store: Store) {
        self.store = store
        panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        buildUI()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.panel.isKeyWindow else { return false }
                return self.handleKey(ev)
            }
            return handled ? nil : ev
        }
    }

    private func buildUI() {
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.delegate = self

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        panel.contentView = fx

        let header = NSTextField(labelWithString: "Буфер обмена")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        headerHint.font = .systemFont(ofSize: 11)
        headerHint.textColor = .tertiaryLabelColor

        search.placeholderString = "Поиск"
        search.delegate = self
        search.focusRingType = .none
        search.sendsSearchStringImmediately = true

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 13)

        let footer = NSTextField(labelWithString: "↩ вставить   ⇧↩ без форматирования   ⌘⌫ удалить   esc закрыть")
        footer.font = .systemFont(ofSize: 10.5)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail

        axButton.title = "⚠︎ Включить автовставку"
        axButton.isBordered = false
        axButton.font = .systemFont(ofSize: 11, weight: .medium)
        axButton.contentTintColor = .systemOrange
        axButton.target = self
        axButton.action = #selector(axClicked)
        axButton.toolTip = "Сейчас выбранное только копируется — вставьте его сами через ⌘V. Разрешите «Универсальный доступ», чтобы вставлялось сразу."

        for v in [header, headerHint, axButton, search, scroll, emptyLabel, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            fx.addSubview(v)
        }
        NSLayoutConstraint.activate([
            axButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            axButton.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -14),
            header.topAnchor.constraint(equalTo: fx.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 16),
            headerHint.firstBaselineAnchor.constraint(equalTo: header.firstBaselineAnchor),
            headerHint.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -16),

            search.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            search.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 12),
            search.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -12),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -6),

            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 40),
            emptyLabel.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -40),

            footer.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: fx.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: fx.bottomAnchor, constant: -10),
        ])
    }

    var isVisible: Bool { panel.isVisible }

    func toggle() { isVisible ? hide() : show() }

    @objc private func axClicked() {
        hide()
        onFixAccessibility?()
    }

    func show() {
        let warn = needsAccessibilityWarning?() ?? false
        axButton.isHidden = !warn
        headerHint.isHidden = warn
        search.stringValue = ""
        reload()
        position()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    func hide() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    func refreshIfVisible() {
        if panel.isVisible { reload(keepSelection: true) }
    }

    /// Отрисовать окно в PNG (для проверки вёрстки).
    func snapshot(to url: URL) {
        let wasVisible = panel.isVisible
        if !wasVisible { reload(); position(); panel.orderFrontRegardless() }
        panel.contentView?.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        if let v = panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        if !wasVisible { hide() }
    }

    private func reload(keepSelection: Bool = false) {
        let prevID = keepSelection && table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow].id : nil
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        items = q.isEmpty ? store.entries
            : store.entries.filter { $0.title.lowercased().contains(q) || $0.detail.lowercased().contains(q) }
        table.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        emptyLabel.stringValue = store.entries.isEmpty
            ? "Здесь пока пусто.\nСкопируйте текст, картинку или сделайте скриншот — они появятся в этом списке."
            : "Ничего не найдено"
        guard !items.isEmpty else { return }
        let row = prevID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        select(row)
    }

    private func select(_ row: Int) {
        guard !items.isEmpty else { return }
        let r = min(max(row, 0), items.count - 1)
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    private func position() {
        var anchor = NSEvent.mouseLocation
        var avoidTop: CGFloat? = nil
        if let caret = caretRect() {
            anchor = NSPoint(x: caret.minX, y: caret.minY - 6)
            avoidTop = caret.maxY + 6
        }
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var x = anchor.x - 16
        var y = anchor.y - size.height
        if y < vf.minY { y = avoidTop ?? (anchor.y + 6) }
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: false)
    }

    /// Положение текстового курсора в активном приложении (если есть доступ).
    private func caretRect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.2)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let el = focused as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(bounds as! AXValue, .cgRect, &r), r.origin != .zero || r.size != .zero else { return nil }
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: r.origin.x, y: primaryH - r.origin.y - r.height, width: r.width, height: r.height)
        return NSScreen.screens.contains { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) } ? rect : nil
    }

    // MARK: keys

    private func handleKey(_ ev: NSEvent) -> Bool {
        let flags = ev.modifierFlags.intersection([.command, .shift, .option, .control])
        switch ev.keyCode {
        case 36, 76:  // Return, Enter
            pick(row: table.selectedRow, plain: flags.contains(.shift))
            return true
        case 53:  // Esc
            if search.stringValue.isEmpty { hide() } else { search.stringValue = ""; reload() }
            return true
        case 125:  // ↓
            select(table.selectedRow + 1); return true
        case 126:  // ↑
            select(table.selectedRow - 1); return true
        case 51 where flags.contains(.command), 117 where flags.contains(.command):  // ⌘⌫
            deleteSelected(); return true
        default:
            if flags == .command, let n = Self.digitKeys.firstIndex(of: ev.keyCode) {
                pick(row: n, plain: false); return true
            }
            return false
        }
    }

    private func pick(row: Int, plain: Bool) {
        guard row >= 0, row < items.count else { NSSound.beep(); return }
        let e = items[row]
        hide()
        onPick?(e, plain)
    }

    private func deleteSelected() {
        let r = table.selectedRow
        guard r >= 0, r < items.count else { return }
        store.remove(items[r].id)
        reload()
        select(r)
    }

    @objc private func rowClicked() {
        let r = table.clickedRow
        guard r >= 0 else { return }
        pick(row: r, plain: NSEvent.modifierFlags.contains(.shift))
    }

    // MARK: delegates

    func controlTextDidChange(_ obj: Notification) { reload() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): select(table.selectedRow - 1); return true
        case #selector(NSResponder.moveDown(_:)): select(table.selectedRow + 1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(row: table.selectedRow, plain: false); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        default: return false
        }
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        items[row].kind == .text ? 48 : 66
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { EmphasizedRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = (tableView.makeView(withIdentifier: ClipCell.reuseID, owner: nil) as? ClipCell) ?? ClipCell(frame: .zero)
        let e = items[row]
        let time = Date().timeIntervalSince(e.date) < 10 ? "только что" : timeFmt.localizedString(for: e.date, relativeTo: Date())
        cell.configure(e, thumb: store.thumb(for: e.id), index: row, time: time, width: size.width - 40)
        return cell
    }
}

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    lazy var picker = PickerController(store: store)
    let hotkeys = HotKeyCenter()
    let screenshots = ScreenshotWatcher()
    var imageProviders: [ImageProvider] = []
    var statusItem: NSStatusItem!
    var lastChange = NSPasteboard.general.changeCount
    var hotkeyOK = true
    let defaults = UserDefaults.standard

    static let ignoredTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType", "Pasteboard generator type",
        "com.typeit4me.clipping", "net.antelle.keeweb",
    ]

    var presetIndex: Int {
        get { min(max(defaults.integer(forKey: "hotkeyPreset"), 0), hotkeyPresets.count - 1) }
        set { defaults.set(newValue, forKey: "hotkeyPreset") }
    }
    var autoPaste: Bool {
        get { defaults.object(forKey: "autoPaste") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoPaste") }
    }
    var watchScreenshots: Bool {
        get { defaults.object(forKey: "watchScreenshots") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "watchScreenshots") }
    }
    var screenshotsToClipboard: Bool {
        get { defaults.bool(forKey: "screenshotsToClipboard") }
        set { defaults.set(newValue, forKey: "screenshotsToClipboard") }
    }
    var paused = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        screenshots.onNew = { [weak self] url in self?.addScreenshot(url) }
        if watchScreenshots { screenshots.start() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "История буфера")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "История буфера")
        statusItem.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        picker.onPick = { [weak self] e, plain in self?.paste(e, plain: plain) }
        picker.needsAccessibilityWarning = { [weak self] in
            guard let self else { return false }
            return self.autoPaste && !AXIsProcessTrusted()
        }
        picker.onFixAccessibility = { [weak self] in self?.askAccessibility() }
        HotKeyCenter.action = { [weak self] in
            MainActor.assumeIsolated { self?.hotkeyPressed() }
        }
        applyHotkey()

        // Запомнить то, что уже лежит в буфере.
        lastChange = -1
        checkPasteboard()

        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
        RunLoop.main.add(timer, forMode: .common)

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("local.cliphistory.show"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hotkeyPressed() }
        }
        dnc.addObserver(forName: .init("local.cliphistory.snapshot"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.picker.snapshot(to: self.store.dir.appendingPathComponent("snapshot.png"))
            }
        }

        if !defaults.bool(forKey: "didShowWelcome") {
            defaults.set(true, forKey: "didShowWelcome")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showWelcome() }
        }
    }

    func applyHotkey() {
        let p = hotkeyPresets[presetIndex]
        hotkeyOK = hotkeys.register(p)
        picker.hotkeyLabel = p.short
        dlog("hotkey %@ registered=%@", p.short, hotkeyOK ? "yes" : "no")
    }

    func hotkeyPressed() {
        picker.toggle()
    }

    // MARK: clipboard capture

    func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard !paused else { return }
        capture(pb)
        picker.refreshIfVisible()
    }

    func capture(_ pb: NSPasteboard) {
        guard let items = pb.pasteboardItems, !items.isEmpty else { return }
        let types = Set(items.flatMap { $0.types.map(\.rawValue) })
        guard types.isDisjoint(with: Self.ignoredTypes) else { return }

        var payload: [[String: Data]] = []
        var total = 0
        for item in items {
            var dict: [String: Data] = [:]
            for t in item.types {
                guard let d = item.data(forType: t), d.count <= 50_000_000 else { continue }
                dict[t.rawValue] = d
                total += d.count
            }
            if !dict.isEmpty { payload.append(dict) }
        }
        guard !payload.isEmpty, total <= 150_000_000 else { return }

        // Файлы из Finder
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty {
            let title = urls.map(\.lastPathComponent).joined(separator: ", ")
            let detail = urls.count == 1
                ? (urls[0].deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
                : "\(urls.count) \(plural(urls.count, "файл", "файла", "файлов"))"
            var img: NSImage?
            if let first = urls.first {
                if let ut = UTType(filenameExtension: first.pathExtension), ut.conforms(to: .image) {
                    img = NSImage(contentsOf: first)
                }
                if img == nil { img = NSWorkspace.shared.icon(forFile: first.path) }
            }
            store.add(kind: .files, title: title, detail: detail,
                      hash: "f:" + sha(Data(urls.map(\.path).joined(separator: "\n").utf8)),
                      payload: payload, thumb: img.flatMap { thumbnailPNG($0) })
            return
        }

        // Текст
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let head = String(s.prefix(1500))
            let title = head.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            let n = s.count
            store.add(kind: .text, title: title, detail: "\(n) \(plural(n, "символ", "символа", "символов"))",
                      hash: "t:" + sha(Data(s.utf8)), payload: payload, thumb: nil)
            return
        }

        // Картинка / скриншот
        if let img = NSImage(pasteboard: pb) {
            let rep = img.representations.first
            let w = rep?.pixelsWide ?? Int(img.size.width), h = rep?.pixelsHigh ?? Int(img.size.height)
            let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff) ?? img.tiffRepresentation ?? Data()
            store.add(kind: .image, title: "Изображение", detail: "\(w)×\(h)",
                      hash: "i:" + sha(raw), payload: payload, thumb: thumbnailPNG(img))
        }
    }

    // MARK: screenshots

    func addScreenshot(_ url: URL) {
        guard watchScreenshots, !paused else { return }
        guard let data = try? Data(contentsOf: url), data.count <= 50_000_000,
              let img = NSImage(data: data) else { return }
        let rep = img.representations.first
        let w = rep?.pixelsWide ?? Int(img.size.width), h = rep?.pixelsHigh ?? Int(img.size.height)
        let isPNG = url.pathExtension.lowercased() == "png"
        guard let png = isPNG ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        else { return }
        let payload = [[NSPasteboard.PasteboardType.png.rawValue: png]]
        store.add(kind: .image, title: "Скриншот", detail: "\(w)×\(h)",
                  hash: "i:" + sha(png), payload: payload, thumb: thumbnailPNG(img))
        if screenshotsToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            let it = NSPasteboardItem()
            it.setData(png, forType: .png)
            let provider = ImageProvider(source: png)
            imageProviders = [provider]
            it.setDataProvider(provider, forTypes: [.tiff])
            pb.writeObjects([it])
            lastChange = pb.changeCount
        }
        picker.refreshIfVisible()
    }

    // MARK: paste

    func paste(_ e: ClipEntry, plain: Bool) {
        guard let p = store.payload(e.id) else { NSSound.beep(); return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let plainText = plain
            ? p.compactMap { $0[NSPasteboard.PasteboardType.string.rawValue].flatMap { String(data: $0, encoding: .utf8) } }.first
            : nil
        if let plainText {
            pb.setString(plainText, forType: .string)
        } else {
            imageProviders.removeAll()
            let items = p.map { dict -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for (k, v) in dict { it.setData(v, forType: NSPasteboard.PasteboardType(k)) }
                // Многие программы (Telegram, iMe, старые приложения) читают картинку только как TIFF —
                // отдаём TIFF по запросу, не храня его на диске.
                let tiffKey = NSPasteboard.PasteboardType.tiff.rawValue
                if dict[tiffKey] == nil,
                   let img = dict[NSPasteboard.PasteboardType.png.rawValue] ?? dict["public.jpeg"] ?? dict["public.heic"] {
                    let provider = ImageProvider(source: img)
                    imageProviders.append(provider)
                    it.setDataProvider(provider, forTypes: [.tiff])
                }
                return it
            }
            pb.writeObjects(items)
        }
        lastChange = pb.changeCount
        store.moveToTop(e.id)

        guard autoPaste else { return }
        guard AXIsProcessTrusted() else {
            if !defaults.bool(forKey: "askedAX") {
                defaults.set(true, forKey: "askedAX")
                requestAccessibility()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Self.sendCmdV() }
    }

    static func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let p = hotkeyPresets[presetIndex]

        menu.addItem(item("Открыть историю   \(p.short)", #selector(openPicker)))
        if !hotkeyOK {
            let w = NSMenuItem(title: "⚠︎ \(p.short) занято другой программой — выберите другое", action: nil, keyEquivalent: "")
            w.isEnabled = false
            menu.addItem(w)
        }
        menu.addItem(.separator())

        if store.entries.isEmpty {
            let empty = NSMenuItem(title: "История пуста", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for (i, e) in store.entries.prefix(10).enumerated() {
                var t = e.kind == .image ? "🖼 \(e.title) \(e.detail)" : (e.kind == .files ? "📄 \(e.title)" : e.title)
                if t.count > 50 { t = String(t.prefix(50)) + "…" }
                let it = item(t, #selector(pasteFromMenu(_:)))
                it.tag = i
                if e.kind != .text, let th = store.thumb(for: e.id) {
                    let img = th.copy() as! NSImage
                    let r = min(32 / max(img.size.width, 1), 20 / max(img.size.height, 1))
                    img.size = NSSize(width: img.size.width * r, height: img.size.height * r)
                    it.image = img
                    it.title = e.kind == .image ? "\(e.title) \(e.detail)" : t.replacingOccurrences(of: "📄 ", with: "")
                }
                menu.addItem(it)
            }
        }
        menu.addItem(.separator())

        let keys = NSMenuItem(title: "Сочетание клавиш", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (i, pr) in hotkeyPresets.enumerated() {
            let it = item(pr.title, #selector(choosePreset(_:)))
            it.tag = i
            it.state = i == presetIndex ? .on : .off
            sub.addItem(it)
        }
        keys.submenu = sub
        menu.addItem(keys)

        let ap = item("Сразу вставлять выбранное", #selector(toggleAutoPaste))
        ap.state = autoPaste ? .on : .off
        menu.addItem(ap)
        if autoPaste && !AXIsProcessTrusted() {
            menu.addItem(item("⚠︎ Разрешить автовставку…", #selector(askAccessibility)))
        }

        if watchScreenshots { screenshots.refreshFolder() }
        let shots = item("Добавлять скриншоты в историю", #selector(toggleScreenshots))
        shots.state = watchScreenshots ? .on : .off
        menu.addItem(shots)
        if watchScreenshots {
            let toPB = item("Сразу класть скриншот в буфер (как в Windows)", #selector(toggleScreenshotsToClipboard))
            toPB.state = screenshotsToClipboard ? .on : .off
            menu.addItem(toPB)
            if !screenshots.accessOK {
                let w = NSMenuItem(title: "⚠︎ Нет доступа к папке скриншотов", action: nil, keyEquivalent: "")
                w.isEnabled = false
                menu.addItem(w)
            }
        }

        let login = item("Запускать при входе в систему", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let pause = item("Пауза (не запоминать)", #selector(togglePause))
        pause.state = paused ? .on : .off
        menu.addItem(pause)

        menu.addItem(.separator())
        menu.addItem(item("Очистить историю…", #selector(clearHistory)))
        menu.addItem(item("Выйти", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc func openPicker() {
        // Меню закрывается асинхронно — открываем панель чуть позже.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.picker.show() }
    }

    @objc func pasteFromMenu(_ sender: NSMenuItem) {
        guard sender.tag < store.entries.count else { return }
        let e = store.entries[sender.tag]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.paste(e, plain: false) }
    }

    @objc func choosePreset(_ sender: NSMenuItem) {
        presetIndex = sender.tag
        applyHotkey()
        if !hotkeyOK {
            alert("Сочетание \(hotkeyPresets[sender.tag].short) уже занято",
                  "Его использует другая программа. Выберите другое сочетание в меню.")
        }
    }

    @objc func toggleAutoPaste() {
        autoPaste.toggle()
        if autoPaste && !AXIsProcessTrusted() { requestAccessibility() }
    }

    @objc func askAccessibility() {
        requestAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func toggleScreenshots() {
        watchScreenshots.toggle()
        if watchScreenshots { screenshots.start() } else { screenshots.stop() }
    }

    @objc func toggleScreenshotsToClipboard() {
        screenshotsToClipboard.toggle()
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Не получилось изменить автозапуск",
                  "Добавьте приложение вручную: Системные настройки → Основные → Объекты входа.\n\n\(error.localizedDescription)")
        }
    }

    @objc func togglePause() {
        paused.toggle()
        statusItem.button?.appearsDisabled = paused
    }

    @objc func clearHistory() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Очистить всю историю буфера?"
        a.informativeText = "Все сохранённые тексты и картинки будут удалены. Это нельзя отменить."
        a.addButton(withTitle: "Очистить")
        a.addButton(withTitle: "Отмена")
        a.buttons.first?.hasDestructiveAction = true
        if a.runModal() == .alertFirstButtonReturn { store.clear() }
    }

    @objc func quit() { NSApp.terminate(nil) }

    func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    func showWelcome() {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "История буфера обмена работает"
        a.informativeText = """
        Нажмите \(hotkeyPresets[presetIndex].short) в любом приложении — откроется список всего, что вы копировали: текст, картинки, скриншоты и файлы.

        Значок приложения — в строке меню вверху экрана.

        Чтобы выбранный элемент сразу вставлялся (как Win+V в Windows), разрешите приложению «Универсальный доступ». Без этого элемент просто попадёт в буфер, и вставить его можно будет через ⌘V.
        """
        a.addButton(withTitle: "Разрешить автовставку")
        a.addButton(withTitle: "Позже")
        if a.runModal() == .alertFirstButtonReturn { requestAccessibility() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}

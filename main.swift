import AppKit
import Carbon.HIToolbox
import Combine
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import Metal
import Network
import ServiceManagement
import SwiftUI

// MARK: - Image collection

func collectImages(from paths: [String]) -> [URL] {
    let extensions: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"]
    var result: [URL] = []
    let fm = FileManager.default

    for path in paths {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            fputs("wp: not found: \(path)\n", stderr)
            continue
        }
        if isDir.boolValue {
            let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            let found = contents
                .filter { extensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            result.append(contentsOf: found)
        } else if extensions.contains(url.pathExtension.lowercased()) {
            result.append(url)
        }
    }
    return result
}

// Returns the displayed width/height ratio, reading only the file header so
// it stays cheap for large folders. EXIF orientations 5–8 are rotated 90°
// (common for phone portraits stored as landscape pixels), so width and
// height swap.
func imageAspect(_ url: URL) -> CGFloat? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          w > 0, h > 0
    else { return nil }
    let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    return (5...8).contains(orientation) ? CGFloat(h / w) : CGFloat(w / h)
}

// A missing entry means the header couldn't be read; callers treat it as wide.
func readAspects(_ urls: [URL]) -> [URL: CGFloat] {
    Dictionary(urls.compactMap { url in imageAspect(url).map { (url, $0) } },
               uniquingKeysWith: { first, _ in first })
}

// Groups portrait images into side-by-side slides for a screen of the given
// aspect; wide images stay alone. Portraits are chunked in order and each
// group sits where its first member was, so the overall order is kept.
//
// Each chunk takes 1–3 portraits, whichever combined aspect is closest to
// the screen's (log ratio, so too wide and too narrow weigh the same).
// A chunk of 2 or 3 that would strand a single last portrait is skipped,
// e.g. 4 left becomes 2+2 rather than 3+1.
func buildSlides(_ urls: [URL], aspects: [URL: CGFloat], screenAspect: CGFloat) -> [Slide] {
    let portraits = urls.filter { (aspects[$0] ?? 1) < 1 }
    var groupAt: [URL: Slide] = [:]
    var i = 0
    while i < portraits.count {
        let remaining = portraits.count - i
        let fit = { (n: Int) -> CGFloat in
            let sum = portraits[i..<i + n].reduce(0) { $0 + aspects[$1]! }
            return abs(log(sum / screenAspect))
        }
        let n = (1...min(3, remaining))
            .filter { $0 == 1 || remaining - $0 != 1 }
            .min { fit($0) < fit($1) }!
        groupAt[portraits[i]] = Array(portraits[i..<i + n])
        i += n
    }

    var slides: [Slide] = []
    for url in urls {
        if let group = groupAt[url] {
            slides.append(group)
        } else if (aspects[url] ?? 1) >= 1 {
            slides.append([url])
        }
    }
    return slides
}

// Truncates a filename to at most `maxLength` characters, eliding the middle
// of the base name so both the start and the extension stay visible.
func truncateFilename(_ name: String, maxLength: Int = 80) -> String {
    guard name.count > maxLength else { return name }
    let ext = (name as NSString).pathExtension
    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    let suffix = ext.isEmpty ? "" : ".\(ext)"
    let budget = maxLength - suffix.count - 1 // 1 for the ellipsis
    guard budget > 0 else { return String(name.prefix(maxLength)) }
    let headLen = (budget + 1) / 2
    let tailLen = budget / 2
    let head = base.prefix(headLen)
    let tail = base.suffix(tailLen)
    return "\(head)…\(tail)\(suffix)"
}

// MARK: - HTTP Server

final class HTTPServer {
    enum State: Equatable { case stopped, listening(UInt16), failed(String) }

    // Called on the main thread. Not called for stop(), which the caller
    // already knows about.
    var onStateChange: (State) -> Void = { _ in }

    private let port: UInt16
    private let onNext: (CycleTarget) -> Void
    private let onPrev: (CycleTarget) -> Void
    private let onBlur: () -> Void
    private let onAutoCycle: () -> Void
    private var listener: NWListener?

    init(port: UInt16, onNext: @escaping (CycleTarget) -> Void, onPrev: @escaping (CycleTarget) -> Void, onBlur: @escaping () -> Void, onAutoCycle: @escaping () -> Void) {
        self.port = port
        self.onNext = onNext
        self.onPrev = onPrev
        self.onBlur = onBlur
        self.onAutoCycle = onAutoCycle
    }

    func start() {
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            fputs("wp: http: \(error)\n", stderr)
            report(.failed(Self.describe(error)))
            return
        }

        listener?.stateUpdateHandler = { [weak self, port] state in
            if case .ready = state {
                fputs("wp: http listening on :\(port)\n", stderr)
                self?.report(.listening(port))
            }
            if case .failed(let err) = state {
                fputs("wp: http: \(err)\n", stderr)
                self?.report(.failed(Self.describe(err)))
            }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .background))
            self?.handle(conn)
        }

        listener?.start(queue: .global(qos: .background))
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { self.onStateChange(state) }
    }

    // NWError's description is "POSIXErrorCode(rawValue: 48): Address
    // already in use"; keep only the readable part.
    private static func describe(_ error: Error) -> String {
        if case .posix(let code) = error as? NWError { return String(cString: strerror(code.rawValue)) }
        return error.localizedDescription
    }

    // Cancelling is asynchronous and the port stays bound until it finishes,
    // so a restart on the same port has to wait for `done`.
    func stop(then done: @escaping () -> Void = {}) {
        guard let listener else { done(); return }
        listener.stateUpdateHandler = { state in
            if case .cancelled = state { DispatchQueue.main.async(execute: done) }
        }
        listener.cancel()
        self.listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { conn.cancel(); return }

            let req       = String(data: data, encoding: .utf8) ?? ""
            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            let parts     = firstLine.components(separatedBy: " ")
            let rawPath   = parts.count > 1 ? parts[1] : ""

            let pathParts = rawPath.components(separatedBy: "?")
            let path      = pathParts[0]
            let target: CycleTarget = (pathParts.count > 1 && pathParts[1].contains("current_display=true"))
                ? .currentDisplay : .all

            let (status, body): (String, String)
            switch path {
            case "/next": DispatchQueue.main.async { self.onNext(target) }; (status, body) = ("200 OK", "next\n")
            case "/prev": DispatchQueue.main.async { self.onPrev(target) }; (status, body) = ("200 OK", "prev\n")
            case "/blur": DispatchQueue.main.async { self.onBlur() };       (status, body) = ("200 OK", "blur\n")
            case "/auto-cycle": DispatchQueue.main.async { self.onAutoCycle() }; (status, body) = ("200 OK", "auto-cycle\n")
            default:                                                         (status, body) = ("404 Not Found", "endpoints: /next /prev /blur /auto-cycle\n")
            }

            let msg = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(msg.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

// Live server state for the settings window, kept apart from Settings since
// it's runtime state rather than a preference.
final class HTTPStatus: ObservableObject {
    @Published var state: HTTPServer.State = .stopped
}

// MARK: - Single instance

let activateNotification = Notification.Name("dev.abdus.apps.wp.activate")

// MARK: - Cycle target

enum CycleTarget { case all, currentDisplay }

// MARK: - Auto cycle intervals

let autoCycleIntervals: [(label: String, seconds: TimeInterval)] = [
    ("5s", 5), ("10s", 10), ("30s", 30),
    ("1m", 60), ("5m", 300), ("15m", 900),
    ("30m", 1800), ("1h", 3600), ("2h", 7200),
    ("6h", 21600), ("12h", 43200), ("24h", 86400)
]

// MARK: - Hotkeys

enum HotkeyAction: String, CaseIterable, Codable {
    case next, prev, nextCurrentDisplay, prevCurrentDisplay, toggleBlur, toggleShuffle

    var title: String {
        switch self {
        case .next:               return "Next image"
        case .prev:               return "Previous image"
        case .nextCurrentDisplay: return "Next image on display under cursor"
        case .prevCurrentDisplay: return "Previous image on display under cursor"
        case .toggleBlur:         return "Toggle blur"
        case .toggleShuffle:      return "Toggle shuffle"
        }
    }

    // Carbon hotkey ids must be non-zero.
    var carbonID: UInt32 { UInt32(Self.allCases.firstIndex(of: self)!) + 1 }
}

// A key combination. The key's name is captured when it's recorded, since
// turning a key code back into a character depends on the keyboard layout.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon flags: controlKey, optionKey, shiftKey, cmdKey
    var key: String

    var display: String {
        let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }
}

// In order, F1 to F20.
let functionKeyCodes = [
    kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
    kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
]

// Keys whose typed character is blank or unreadable get a fixed name.
let specialKeyNames: [Int: String] = {
    var names: [Int: String] = [
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]
    for (i, code) in functionKeyCodes.enumerated() { names[code] = "F\(i + 1)" }
    return names
}()

// Registers system-wide hotkeys through Carbon, which unlike an NSEvent
// global monitor needs no Accessibility permission and swallows the key
// press so the frontmost app doesn't also get it.
final class HotkeyCenter {
    var onPress: (HotkeyAction) -> Void = { _ in }
    private var refs: [EventHotKeyRef] = []
    private static let signature: OSType = 0x7770_484B // 'wpHK'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // A C callback can't capture, so the center is passed through
        // userData. The controller keeps it alive for the app's lifetime.
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let err = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard err == noErr else { return err }
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            if let action = HotkeyAction.allCases.first(where: { $0.carbonID == id.id }) {
                center.onPress(action)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    // Replaces all registrations. Returns the actions that couldn't be
    // registered: the combination is taken by another app, or by another
    // action here. Registering in list order means a duplicate is always
    // flagged on the later action.
    func register(_ hotkeys: [HotkeyAction: Hotkey]) -> Set<HotkeyAction> {
        unregisterAll()
        var failed: Set<HotkeyAction> = []
        for action in HotkeyAction.allCases {
            guard let hotkey = hotkeys[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.carbonID)
            let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { failed.insert(action) }
        }
        return failed
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }
}

// Runtime hotkey state for the settings window. While a shortcut is being
// recorded, all hotkeys are unregistered so pressing an existing combination
// reaches the recorder instead of firing.
final class HotkeyState: ObservableObject {
    @Published var failed: Set<HotkeyAction> = []
    @Published var recording: HotkeyAction?
}

// MARK: - Settings

// A folder images are read from. Disabled folders stay in the list so they
// can be switched back on without picking them again.
struct Source: Codable, Identifiable, Equatable {
    var path: String
    var enabled = true
    var id: String { path }
}

// User preferences, persisted in UserDefaults. The settings window edits
// these directly; the controller subscribes to the ones it acts on.
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var sources: [Source] {
        didSet { defaults.set(try? JSONEncoder().encode(sources), forKey: "sources") }
    }
    var enabledSourcePaths: [String] { sources.filter(\.enabled).map(\.path) }

    @Published var autoBlurOnLock: Bool {
        didSet { defaults.set(autoBlurOnLock, forKey: "autoBlurOnLock") }
    }
    @Published var blurAmount: Double {
        didSet { defaults.set(blurAmount, forKey: "blurAmount") }
    }
    @Published var autoCycle: Bool {
        didSet { defaults.set(autoCycle, forKey: "autoCycle") }
    }
    @Published var autoCycleInterval: TimeInterval {
        didSet { defaults.set(autoCycleInterval, forKey: "autoCycleInterval") }
    }
    @Published var httpEnabled: Bool {
        didSet { defaults.set(httpEnabled, forKey: "httpEnabled") }
    }
    @Published var httpPort: Int {
        didSet { defaults.set(httpPort, forKey: "httpPort") }
    }
    // Stored keyed by the action's raw value: JSONEncoder writes a
    // dictionary with enum keys as a flat array rather than an object.
    @Published var hotkeys: [HotkeyAction: Hotkey] {
        didSet {
            let byName = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
            defaults.set(try? JSONEncoder().encode(byName), forKey: "hotkeys")
        }
    }

    init() {
        defaults.register(defaults: [
            "autoBlurOnLock": true,
            "blurAmount": 50.0,
            "autoCycle": false,
            "autoCycleInterval": 300.0,
            "httpEnabled": false,
            "httpPort": 9876,
        ])
        sources = defaults.data(forKey: "sources")
            .flatMap { try? JSONDecoder().decode([Source].self, from: $0) } ?? []
        autoBlurOnLock = defaults.bool(forKey: "autoBlurOnLock")
        blurAmount = min(100, max(0, defaults.double(forKey: "blurAmount")))
        autoCycle = defaults.bool(forKey: "autoCycle")
        autoCycleInterval = defaults.double(forKey: "autoCycleInterval")
        httpEnabled = defaults.bool(forKey: "httpEnabled")
        httpPort = defaults.integer(forKey: "httpPort")
        let byName = defaults.data(forKey: "hotkeys")
            .flatMap { try? JSONDecoder().decode([String: Hotkey].self, from: $0) } ?? [:]
        hotkeys = Dictionary(uniqueKeysWithValues: byName.compactMap { name, hotkey in
            HotkeyAction(rawValue: name).map { ($0, hotkey) }
        })
    }
}

// Start-at-login state. The system owns it (the user can also change it in
// System Settings → Login Items), so it's read back from SMAppService
// rather than saved in UserDefaults. Registration needs a real app bundle;
// a bare binary run from the terminal can't be a login item.
final class LoginItem: ObservableObject {
    @Published private(set) var status = SMAppService.mainApp.status
    @Published private(set) var error: String?

    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    var isEnabled: Bool { status == .enabled }

    func refresh() { status = SMAppService.mainApp.status }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

// Toolbar tabs, the standard macOS settings window layout (as in Safari or
// Mail): icon + label tabs in the toolbar, the window title follows the
// selected tab, and the window resizes to each tab's height. SwiftUI's
// TabView only gives this inside a SwiftUI App's Settings scene, so the
// tabs are an AppKit NSTabViewController hosting one SwiftUI view each.
func makeSettingsTabs(settings: Settings, httpStatus: HTTPStatus, hotkeyState: HotkeyState,
                      sourcesOverridden: Bool, httpPortOverride: UInt16?) -> NSTabViewController {
    func tab(_ label: String, _ symbol: String, height: CGFloat, _ view: some View) -> NSTabViewItem {
        let hosting = NSHostingController(rootView: view.frame(width: 500, height: height))
        // Report the SwiftUI size as preferredContentSize, which the tab
        // controller uses to resize the window on tab switches.
        hosting.sizingOptions = .preferredContentSize
        hosting.title = label   // shown as the window title while selected
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }

    let tabs = NSTabViewController()
    tabs.tabStyle = .toolbar
    tabs.addTabViewItem(tab("General", "gearshape", height: 585,
        GeneralSettingsView(settings: settings, httpStatus: httpStatus, httpPortOverride: httpPortOverride)))
    tabs.addTabViewItem(tab("Sources", "folder", height: 400,
        SourcesSettingsView(settings: settings, overridden: sourcesOverridden)))
    tabs.addTabViewItem(tab("Hotkeys", "keyboard", height: 340,
        HotkeysSettingsView(settings: settings, state: hotkeyState)))
    return tabs
}

struct GeneralSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var httpStatus: HTTPStatus
    var httpPortOverride: UInt16? = nil
    @StateObject private var loginItem = LoginItem()

    var body: some View {
        Form {
            Section {
                Toggle("Start at login", isOn: Binding(get: { loginItem.isEnabled },
                                                       set: { loginItem.setEnabled($0) }))
                    .disabled(!loginItem.isAvailable)
            } footer: {
                if !loginItem.isAvailable {
                    Text("Only available when running wp.app, not the bare binary.")
                        .foregroundStyle(.secondary)
                } else if loginItem.status == .requiresApproval {
                    HStack {
                        Text("Needs approval in System Settings → Login Items.")
                            .foregroundStyle(.secondary)
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.link)
                    }
                } else if let error = loginItem.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section("Blur") {
                LabeledContent("Amount") {
                    HStack {
                        Slider(value: $settings.blurAmount, in: 0...100, step: 1)
                        Text("\(Int(settings.blurAmount))%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Blur when the screen locks or sleeps", isOn: $settings.autoBlurOnLock)
            }
            Section("Auto Cycle") {
                Toggle("Cycle images automatically", isOn: $settings.autoCycle)
                LabeledContent("Interval") {
                    HStack {
                        Slider(value: intervalIndex, in: 0...Double(autoCycleIntervals.count - 1), step: 1)
                        Text(autoCycleIntervals[Int(intervalIndex.wrappedValue)].label)
                            .monospacedDigit()
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                .disabled(!settings.autoCycle)
            }
            Section {
                Toggle("Enable HTTP API", isOn: $settings.httpEnabled)
                TextField("Port", value: $settings.httpPort, format: .number.grouping(.never))
                    .disabled(!settings.httpEnabled)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isListening ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(statusText)
                    }
                }
            } header: {
                Text("HTTP API")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let httpPortOverride {
                        Text("PORT=\(String(httpPortOverride)) is set in the environment, so the API runs on that port and these settings apply on the next launch without it.")
                    }
                    Text("GET /next, /prev, /blur, /auto-cycle. Add ?current_display=true to /next or /prev to change only the display under the cursor.")
                    Text("Listens on all network interfaces, so other devices on your network can reach it.")
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Pick up changes made in System Settings while the window was open.
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
    }

    private var isListening: Bool {
        if case .listening = httpStatus.state { return true }
        return false
    }

    private var statusText: String {
        switch httpStatus.state {
        case .stopped:              return "Stopped"
        case .listening(let port):  return "Listening on port \(port)"
        case .failed(let reason):   return "Failed: \(reason)"
        }
    }

    // The slider moves over positions in autoCycleIntervals; the setting
    // itself is stored in seconds. An unknown saved value shows as 5m.
    private var intervalIndex: Binding<Double> {
        Binding(
            get: {
                let i = autoCycleIntervals.firstIndex { $0.seconds == settings.autoCycleInterval } ?? 4
                return Double(i)
            },
            set: { settings.autoCycleInterval = autoCycleIntervals[Int($0.rounded())].seconds }
        )
    }
}

// The standard macOS editable list: a bordered list with a + / − button bar
// along its bottom edge. − (or Delete) removes the selected rows. Folders
// can also be dropped onto the list from Finder.
struct SourcesSettingsView: View {
    @ObservedObject var settings: Settings
    let overridden: Bool
    @State private var selection: Set<String> = []
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    // Rows look sources up by id rather than binding by
                    // index, since removing a row while SwiftUI still holds
                    // an index binding to it can crash.
                    ForEach(settings.sources) { source in
                        HStack(spacing: 8) {
                            Toggle("Enabled", isOn: enabledBinding(for: source.id))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(URL(fileURLWithPath: source.path).lastPathComponent)
                                Text((source.path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
                .onDeleteCommand(perform: removeSelected)
                .overlay {
                    if settings.sources.isEmpty {
                        Text("Drop folders here or click +").foregroundStyle(.secondary)
                    }
                }

                Divider()
                HStack(spacing: 0) {
                    Button(action: addFolders) {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add folders")
                    Divider().frame(height: 14)
                    Button(action: removeSelected) {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .help("Remove selected folders")
                    .disabled(selection.isEmpty)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isDropTarget ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: isDropTarget ? 2 : 1)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: addDropped)

            if overridden {
                Text("Paths passed on the command line are in use. Changes here apply on the next launch without arguments.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func removeSelected() {
        settings.sources.removeAll { selection.contains($0.id) }
        selection = []
    }

    private func enabledBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { settings.sources.first { $0.id == id }?.enabled ?? false },
            set: { value in
                if let i = settings.sources.firstIndex(where: { $0.id == id }) {
                    settings.sources[i].enabled = value
                }
            }
        )
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    // Drops can carry files too; only folders become sources. Each provider
    // loads its URL asynchronously, so results are added as they arrive.
    private func addDropped(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { return }
                DispatchQueue.main.async { add([url]) }
            }
        }
        return true
    }

    private func add(_ urls: [URL]) {
        let known = Set(settings.sources.map(\.path))
        settings.sources += urls.map(\.path).filter { !known.contains($0) }.map { Source(path: $0) }
    }
}

struct HotkeysSettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var state: HotkeyState

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.allCases, id: \.self) { action in
                    LabeledContent(action.title) {
                        HStack(spacing: 6) {
                            if state.failed.contains(action) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .help("Couldn't register. Another app or another action here already uses this shortcut.")
                            }
                            ShortcutRecorder(action: action, hotkey: binding(for: action), state: state)
                        }
                    }
                }
            } footer: {
                Text("Click a shortcut to record a new one. Esc cancels, Delete clears. Shortcuts need ⌘, ⌥ or ⌃ unless they use a function key.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding(for action: HotkeyAction) -> Binding<Hotkey?> {
        Binding(get: { settings.hotkeys[action] },
                set: { settings.hotkeys[action] = $0 })
    }
}

// A button that, when clicked, captures the next key combination typed into
// the settings window. Only one recorder is active at a time: starting
// another one (state.recording changes) stops this one.
struct ShortcutRecorder: View {
    let action: HotkeyAction
    @Binding var hotkey: Hotkey?
    @ObservedObject var state: HotkeyState
    @State private var monitor: Any?

    private var isRecording: Bool { state.recording == action }

    var body: some View {
        Button(action: { isRecording ? stop() : start() }) {
            Text(isRecording ? "Type shortcut…" : hotkey?.display ?? "Record Shortcut")
                .foregroundStyle(hotkey == nil || isRecording ? .secondary : .primary)
                .frame(minWidth: 110)
        }
        .onReceive(state.$recording) { recording in
            if recording != action { removeMonitor() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        state.recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        let code = Int(event.keyCode)
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])

        if code == kVK_Escape { stop(); return }
        if flags.isEmpty && (code == kVK_Delete || code == kVK_ForwardDelete) {
            hotkey = nil
            stop()
            return
        }
        // A bare letter or Shift+letter would hijack normal typing everywhere.
        guard functionKeyCodes.contains(code) || !flags.isDisjoint(with: [.control, .option, .command]) else {
            NSSound.beep()
            return
        }

        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option)  { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift)   { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        // Without modifiers applied, ⌥A reads as "A" rather than "å".
        let key = specialKeyNames[code] ?? (event.characters(byApplyingModifiers: []) ?? "?").uppercased()
        hotkey = Hotkey(keyCode: UInt32(code), modifiers: modifiers, key: key)
        stop()
    }

    private func stop() {
        removeMonitor()
        if state.recording == action { state.recording = nil }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - WallpaperRowView

// Two-line, clickable menu row: a small display-name label above a larger
// filename label. Custom NSMenuItem views don't get AppKit's automatic
// hover-highlight or click-to-select behavior, so both are done by hand
// here: a tracking area drives the highlight paint/text color, and mouseUp
// dismisses the menu and fires onClick.
final class WallpaperRowView: NSView {
    var onClick: () -> Void = {}

    private let top: NSTextField
    private let bottom: NSTextField
    private var trackingArea: NSTrackingArea?

    private var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            needsDisplay = true
            top.textColor = isHighlighted ? .white : .secondaryLabelColor
            bottom.textColor = isHighlighted ? .white : .labelColor
        }
    }

    init(displayName: String, filename: String, onClick: @escaping () -> Void) {
        self.onClick = onClick

        top = NSTextField(labelWithString: displayName)
        top.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        top.textColor = .secondaryLabelColor
        top.translatesAutoresizingMaskIntoConstraints = false

        bottom = NSTextField(labelWithString: truncateFilename(filename))
        bottom.font = .systemFont(ofSize: NSFont.systemFontSize)
        bottom.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(top)
        addSubview(bottom)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            heightAnchor.constraint(equalToConstant: 36),

            top.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            top.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            top.topAnchor.constraint(equalTo: topAnchor, constant: 3),

            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            bottom.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            bottom.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                   options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHighlighted = true }
    override func mouseExited(with event: NSEvent) { isHighlighted = false }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        enclosingMenuItem?.menu?.cancelTracking()
        onClick()
    }
}

// MARK: - DesktopWindow

private class DesktopWindow: NSWindow {
    // NSWindow.constrainFrameRect clips to visibleFrame, which excludes the menu bar.
    // Return the rect unchanged so our window covers the full screen.frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }
}

// MARK: - Controller

// Per-display state, keyed by the display's stable identity. The window is
// transient (recreated when a display reconnects), but imageIndex and the
// shuffled order persist so a display resumes exactly where it left off after
// a disconnect/reconnect (e.g. closing and reopening the lid).
//
// A slide is the set of images shown together on one display. imageIndex
// indexes into `slides`, which is rebuilt from the active image order.
typealias Slide = [URL]

final class Display {
    let key: String
    var window: NSWindow?
    var imageIndex = 0
    var renderGeneration = 0
    var shuffled: [URL]
    var slides: [Slide] = []
    var aspect: CGFloat?        // screen aspect the slides were grouped for

    init(key: String, shuffled: [URL]) {
        self.key = key
        self.shuffled = shuffled
    }
}

class WallpaperController: NSObject, NSMenuDelegate {
    private(set) var images: [URL]
    private(set) var aspects: [URL: CGFloat] // missing entry = unreadable header, treated as wide
    var displays: [String: Display] = [:]   // persists across disconnects
    var order: [String] = []                 // keys of connected displays, in screen order
    var blurEnabled = false
    private var blurAmount: Double
    var shuffleEnabled = true
    var blurCache: [Slide: NSImage] = [:]
    var statusItem: NSStatusItem!
    var blurMenuItem: NSMenuItem!
    var shuffleMenuItem: NSMenuItem!
    var globalMonitor: Any?
    var httpServer: HTTPServer?
    var httpGeneration = 0
    let httpStatus = HTTPStatus()
    let hotkeyCenter = HotkeyCenter()
    let hotkeyState = HotkeyState()
    var autoCycleTimer: Timer?
    var wallpaperMenuItems: [NSMenuItem] = []
    let settings: Settings
    let sourcesOverridden: Bool              // command-line paths win over saved sources
    var settingsWindow: NSWindow?
    var cancellables: Set<AnyCancellable> = []

    var connected: [Display] { order.compactMap { displays[$0] } }

    func activeImages(for display: Display) -> [URL] {
        shuffleEnabled ? display.shuffled : images
    }

    // Keeps the display on the image it was showing, since regrouping moves
    // slide boundaries and the old index would point somewhere else.
    func rebuildSlides(for display: Display) {
        let showing = currentSlide(for: display)?.first
        display.slides = buildSlides(activeImages(for: display), aspects: aspects,
                                     screenAspect: display.aspect ?? 16.0 / 9.0)
        display.imageIndex = showing.flatMap { url in
            display.slides.firstIndex { $0.contains(url) }
        } ?? 0
    }

    // Replaces the image list at runtime, e.g. after sources change. Each
    // display gets a fresh shuffle but stays on its current image if that
    // image is still in the list.
    func setImages(_ urls: [URL]) {
        images = urls
        aspects = readAspects(urls)
        blurCache.removeAll()
        for display in displays.values {
            display.shuffled = urls.shuffled()
            rebuildSlides(for: display)
        }
        updateImages()
        restartAutoCycle()
    }

    // Keep each display on a surviving member of its current slide, or the
    // next available slide in its existing order. Include disconnected displays
    // so reconnecting cannot bring a removed image back into rotation.
    private func removeImages(_ urls: Set<URL>) {
        let removed = urls.intersection(images)
        guard !removed.isEmpty else { return }
        for url in removed { fputs("wp: not found: \(url.path)\n", stderr) }
        images.removeAll { removed.contains($0) }
        for url in removed { aspects.removeValue(forKey: url) }
        blurCache = blurCache.filter { $0.key.allSatisfy { !removed.contains($0) } }
        for display in displays.values {
            let slides = display.slides
            var showing: URL?
            for offset in 0..<slides.count {
                let slide = slides[(display.imageIndex + offset) % slides.count]
                if let url = slide.first(where: { !removed.contains($0) }) {
                    showing = url
                    break
                }
            }
            display.shuffled.removeAll { removed.contains($0) }
            rebuildSlides(for: display)
            display.imageIndex = showing.flatMap { url in
                display.slides.firstIndex { $0.contains(url) }
            } ?? 0
        }
    }

    lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    init(images: [URL], settings: Settings, sourcesOverridden: Bool) {
        self.images = images
        self.aspects = readAspects(images)
        self.blurAmount = settings.blurAmount
        self.settings = settings
        self.sourcesOverridden = sourcesOverridden
        super.init()
        syncScreens()
        setupMenu()
        setupMouseMonitor()
        if let envPort { startHTTPServer(port: envPort) }
        setupLockScreenMonitor()
        observeSettings()
        // Posted by a second launch that found this instance already running.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(openSettings), name: activateNotification, object: nil,
            suspensionBehavior: .deliverImmediately)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        autoCycleTimer?.invalidate()
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    // MARK: Windows

    @objc private func screensChanged() {
        syncScreens()
    }

    // A display's identity must survive disconnect/reconnect (unplugging a
    // monitor, or closing and reopening the lid while an external display is
    // attached). CGDirectDisplayID is only valid for the current configuration
    // and can be renumbered, so it's unusable as a persistent key. The EDID
    // vendor/model/serial triple identifies the physical panel itself; fall
    // back to the localized name when EDID is unavailable (e.g. some virtual
    // or software displays).
    private func stableKey(for screen: NSScreen) -> String {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return screen.localizedName }
        let vendor = CGDisplayVendorNumber(id)
        let model  = CGDisplayModelNumber(id)
        let serial = CGDisplaySerialNumber(id)
        guard vendor != 0 || model != 0 || serial != 0 else { return screen.localizedName }
        return "\(vendor)-\(model)-\(serial)"
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let win = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        win.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        win.backgroundColor = .black
        win.isOpaque = true
        win.isReleasedWhenClosed = false

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspectFill
        view.layer?.masksToBounds = true
        view.autoresizingMask = [.width, .height]
        win.contentView = view
        win.setFrame(screen.frame, display: false)
        win.orderFrontRegardless()
        return win
    }

    // Reconciles windows against the currently-connected displays. State for
    // each display is looked up by its stable key, so a reconnected display
    // keeps its window position, image index, and shuffle order; a genuinely
    // new display gets fresh state. Disconnected displays keep their state in
    // `displays` (only their window is torn down) so they resume on reconnect.
    private func syncScreens() {
        let screens = NSScreen.screens
        var newOrder: [String] = []

        for screen in screens {
            let key = stableKey(for: screen)
            newOrder.append(key)

            let display = displays[key] ?? {
                let d = Display(key: key, shuffled: images.shuffled())
                displays[key] = d
                return d
            }()

            // Portrait grouping depends on the screen's shape, so a new
            // display or a resolution change regroups.
            let aspect = screen.frame.width / screen.frame.height
            if display.aspect != aspect {
                display.aspect = aspect
                rebuildSlides(for: display)
            }

            if let win = display.window {
                win.setFrame(screen.frame, display: false)
                win.contentView?.setFrameSize(screen.frame.size)
            } else {
                display.window = makeWindow(for: screen)
            }
        }

        let connectedKeys = Set(newOrder)
        for display in displays.values where !connectedKeys.contains(display.key) {
            display.window?.orderOut(nil)
            display.window = nil
        }

        order = newOrder
        updateImages()
    }

    // MARK: Rendering

    private func fadeTransition() -> CATransition {
        let t = CATransition()
        t.duration = 0.6
        t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return t
    }

    func currentSlide(for display: Display) -> Slide? {
        let slides = display.slides
        guard !slides.isEmpty else { return nil }
        return slides[display.imageIndex % slides.count]
    }

    private func updateImages(_ target: Display? = nil) {
        var targets = target.map { [$0] } ?? connected
        // Check before using even a cached blur. Repeat because removing a
        // slide can expose another missing image; the loop is bounded by the
        // number of images in the rotation.
        while true {
            let missing = Set(targets.flatMap { currentSlide(for: $0) ?? [] }
                .filter { !FileManager.default.fileExists(atPath: $0.path) })
            guard !missing.isEmpty else { break }
            removeImages(missing)
            targets = connected
        }
        for display in targets {
            display.renderGeneration += 1
            let generation = display.renderGeneration
            guard let win = display.window else { continue }
            guard let slide = currentSlide(for: display), let url = slide.first else {
                win.contentView?.layer?.contents = nil
                continue
            }

            if !blurEnabled && slide.count == 1 && !isPortrait(url) {
                let image = NSImage(contentsOf: url)
                if image == nil && !FileManager.default.fileExists(atPath: url.path) {
                    removeImages([url])
                    updateImages()
                    return
                }
                let layer = win.contentView?.layer
                layer?.add(fadeTransition(), forKey: "transition")
                layer?.contents = image
                continue
            }

            if blurEnabled, let cached = blurCache[slide] {
                let layer = win.contentView?.layer
                layer?.add(fadeTransition(), forKey: "transition")
                layer?.contents = cached
                continue
            }

            // Compositing and blurring are too slow for the main thread.
            // Cycling or changing blur can finish renders out of order, so
            // only the display's latest render may replace its wallpaper.
            let blur = blurEnabled
            // 50% preserves the original blur strength (sigma 200).
            let sigma = blurAmount * 4
            let size = win.frame.size
            let scale = win.backingScaleFactor
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak win, weak display] in
                guard let self else { return }
                let img = self.renderSlide(slide, size: size, scale: scale)
                let out = img.flatMap { blur ? self.blurImage($0, sigma: sigma) : $0 }
                DispatchQueue.main.async {
                    // A file may disappear after the initial check, while the
                    // background render is reading it.
                    let missing = Set(slide.filter { !FileManager.default.fileExists(atPath: $0.path) })
                    if !missing.isEmpty {
                        self.removeImages(missing)
                        self.updateImages()
                        return
                    }
                    guard slide.allSatisfy({ self.images.contains($0) }), let out else { return }
                    guard let display, display.renderGeneration == generation,
                          self.blurEnabled == blur, !blur || self.blurAmount * 4 == sigma,
                          self.currentSlide(for: display) == slide else { return }
                    if blur { self.blurCache[slide] = out }
                    let layer = win?.contentView?.layer
                    layer?.add(self.fadeTransition(), forKey: "transition")
                    layer?.contents = out
                }
            }
        }
    }

    private func isPortrait(_ url: URL) -> Bool { (aspects[url] ?? 1) < 1 }

    private func renderSlide(_ slide: Slide, size: CGSize, scale: CGFloat) -> NSImage? {
        if slide.count == 1 && !isPortrait(slide[0]) { return NSImage(contentsOf: slide[0]) }
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let cg = composite(slide, pixelSize: pixelSize) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    // The thumbnail API applies EXIF orientation and decodes at the requested
    // size instead of full resolution.
    private func loadThumbnail(_ url: URL, maxPixelSize: CGFloat) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize.rounded(.up)),
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    // Centers an image of the given aspect in `box`. Fill covers the box and
    // overflows one side; fit stays inside it and leaves bars on one side.
    private func placed(aspect: CGFloat, in box: CGRect, fill: Bool) -> CGRect {
        let widthLimited = (aspect > box.width / box.height) != fill
        let size = widthLimited
            ? CGSize(width: box.width, height: box.width / aspect)
            : CGSize(width: box.height * aspect, height: box.height)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    // Draws a slide's images side by side into one screen-sized image. Each
    // image gets a slot whose width is proportional to its aspect ratio, then
    // is aspect-filled into that slot, so a well-matched group crops little.
    // A portrait alone is fitted whole over a blurred, stretched copy of itself.
    private func composite(_ slide: Slide, pixelSize: CGSize) -> CGImage? {
        guard let ctx = CGContext(data: nil,
                                  width: Int(pixelSize.width), height: Int(pixelSize.height),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(.black)
        ctx.fill(CGRect(origin: .zero, size: pixelSize))
        ctx.interpolationQuality = .high

        let canvas = CGRect(origin: .zero, size: pixelSize)
        let aspects = slide.map { self.aspects[$0] ?? 1 }

        if slide.count == 1 {
            let url = slide[0], aspect = aspects[0]
            // The backdrop is blurred anyway, so a small decode is enough.
            if let small = loadThumbnail(url, maxPixelSize: 256) {
                let ci = CIImage(cgImage: small)
                let blurred = ci.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: ci.extent)
                if let bg = ciContext.createCGImage(blurred, from: ci.extent) {
                    ctx.draw(bg, in: placed(aspect: aspect, in: canvas, fill: true))
                }
            }
            let rect = placed(aspect: aspect, in: canvas, fill: false)
            if let img = loadThumbnail(url, maxPixelSize: max(rect.width, rect.height)) {
                ctx.draw(img, in: rect)
            }
            return ctx.makeImage()
        }

        let total = aspects.reduce(0, +)
        var cumulative: CGFloat = 0

        for (url, aspect) in zip(slide, aspects) {
            // Slot edges come from the running sum so rounding never leaves
            // a gap at the right edge.
            let left = (pixelSize.width * cumulative / total).rounded()
            cumulative += aspect
            let right = (pixelSize.width * cumulative / total).rounded()
            let slot = CGRect(x: left, y: 0, width: right - left, height: pixelSize.height)

            let rect = placed(aspect: aspect, in: slot, fill: true)
            guard let img = loadThumbnail(url, maxPixelSize: max(rect.width, rect.height)) else { continue }

            ctx.saveGState()
            ctx.clip(to: slot)
            ctx.draw(img, in: rect)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    private func blurImage(_ image: NSImage, sigma: Double) -> NSImage? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let ci = CIImage(cgImage: cg)
        // clampedToExtent repeats edge pixels into infinity so the blur has
        // no dark halo at image borders; crop back to original bounds after.
        let blurred = ci.clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: ci.extent)
        guard let out = ciContext.createCGImage(blurred, from: ci.extent) else { return nil }
        return NSImage(cgImage: out, size: image.size)
    }

    // MARK: Menu

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "photo.fill.on.rectangle.fill",
                                accessibilityDescription: "Wallpaper")
        }

        let menu = NSMenu()

        // macOS 26 adds icons on its own to standard items like Settings… and
        // Quit, which indents their titles past items without one. Giving
        // every item an icon keeps the titles aligned on all versions.
        func item(_ title: String, _ symbol: String, _ action: Selector?, _ key: String,
                  target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target ?? self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
            return item
        }

        // Actions that have configurable global hotkeys get no key
        // equivalent here; a fixed one would contradict the Hotkeys tab.
        _ = item("Previous Image", "chevron.backward", #selector(prevImage), "")
        _ = item("Next Image", "chevron.forward", #selector(nextImage), "")

        menu.addItem(.separator())

        let wallpaperItem = item("Current Wallpapers", "photo.on.rectangle", nil, "")
        let wallpaperSubmenu = NSMenu()
        wallpaperSubmenu.delegate = self
        wallpaperItem.submenu = wallpaperSubmenu

        menu.addItem(.separator())

        blurMenuItem = item("Blur", "drop", #selector(toggleBlur), "")
        shuffleMenuItem = item("Shuffle", "shuffle", #selector(toggleShuffle), "")
        shuffleMenuItem.state = .on

        menu.addItem(.separator())

        _ = item("Settings…", "gearshape", #selector(openSettings), ",")

        menu.addItem(.separator())
        _ = item("Quit", "xmark.square", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        statusItem.menu = menu
    }

    // Rebuilds the per-display wallpaper filename rows each time the menu
    // opens, since the current image and connected displays can change
    // between menu openings.
    func menuWillOpen(_ menu: NSMenu) {
        for item in wallpaperMenuItems { menu.removeItem(item) }
        wallpaperMenuItems.removeAll()

        for display in connected {
            guard let slide = currentSlide(for: display) else { continue }
            let displayName = display.window?.screen?.localizedName ?? "Display"

            for url in slide {
                let row = WallpaperRowView(displayName: displayName, filename: url.lastPathComponent) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                let item = NSMenuItem()
                item.view = row
                menu.addItem(item)
                wallpaperMenuItems.append(item)
            }
        }
    }

    // MARK: Actions

    @objc func nextImage() { cycleImage(delta:  1, display: nil) }
    @objc func prevImage() { cycleImage(delta: -1, display: nil) }

    func cycleImage(delta: Int, display target: Display?, resetTimer: Bool = true) {
        let targets = target.map { [$0] } ?? connected
        for display in targets {
            let count = display.slides.count
            guard count > 0 else { continue }
            display.imageIndex = (display.imageIndex + delta + count) % count
        }
        updateImages(target)
        if resetTimer { restartAutoCycle() }
    }

    private func displayUnderCursor() -> Display? {
        let loc = NSEvent.mouseLocation
        return connected.first { $0.window?.frame.contains(loc) ?? false }
    }

    @objc func toggleBlur() {
        blurEnabled.toggle()
        blurMenuItem.state = blurEnabled ? .on : .off
        updateImages()
    }

    @objc func toggleShuffle() {
        shuffleEnabled.toggle()
        shuffleMenuItem.state = shuffleEnabled ? .on : .off
        for display in displays.values {
            if shuffleEnabled { display.shuffled = images.shuffled() }
            rebuildSlides(for: display)
            display.imageIndex = 0
        }
        updateImages()
        restartAutoCycle()
    }

    private func restartAutoCycle() {
        guard settings.autoCycle else { return }
        startAutoCycle(every: settings.autoCycleInterval)
    }

    private func startAutoCycle(every secs: TimeInterval) {
        autoCycleTimer?.invalidate()
        let timer = Timer(timeInterval: secs, repeats: true) { [weak self] _ in
            self?.cycleImage(delta: 1, display: nil, resetTimer: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCycleTimer = timer
    }

    private func stopAutoCycle() {
        autoCycleTimer?.invalidate()
        autoCycleTimer = nil
    }

    // MARK: Settings

    // @Published emits on willSet, so sinks use the values they're handed
    // rather than reading `settings` back. Each sink also fires once on
    // subscribe, which applies the saved settings at launch.
    private func observeSettings() {
        settings.$blurAmount
            .removeDuplicates()
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] amount in
                guard let self, self.blurAmount != amount else { return }
                self.blurAmount = amount
                self.blurCache.removeAll()
                if self.blurEnabled { self.updateImages() }
            }
            .store(in: &cancellables)

        settings.$autoCycle
            .combineLatest(settings.$autoCycleInterval)
            .sink { [weak self] enabled, secs in
                enabled ? self?.startAutoCycle(every: secs) : self?.stopAutoCycle()
            }
            .store(in: &cancellables)

        // Images were loaded from the saved sources at launch, so only later
        // changes rescan. Runs on the main thread, so a very large folder
        // stalls the UI briefly while headers are read.
        if !sourcesOverridden {
            settings.$sources
                .map { $0.filter(\.enabled).map(\.path) }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] paths in self?.setImages(collectImages(from: paths)) }
                .store(in: &cancellables)
        }

        // Ports outside UInt16 (or 0) are ignored rather than crashing the
        // listener; the field shows what was typed until it's fixed.
        if envPort == nil {
            settings.$httpEnabled
                .combineLatest(settings.$httpPort)
                .removeDuplicates { $0 == $1 }
                .sink { [weak self] enabled, port in
                    if enabled, let port = UInt16(exactly: port), port > 0 {
                        self?.startHTTPServer(port: port)
                    } else {
                        self?.stopHTTPServer()
                    }
                }
                .store(in: &cancellables)
        }

        hotkeyCenter.onPress = { [weak self] action in self?.perform(action) }
        settings.$hotkeys
            .combineLatest(hotkeyState.$recording)
            .sink { [weak self] hotkeys, recording in
                guard let self else { return }
                if recording != nil {
                    self.hotkeyCenter.unregisterAll()
                } else {
                    self.hotkeyState.failed = self.hotkeyCenter.register(hotkeys)
                }
            }
            .store(in: &cancellables)
    }

    private func perform(_ action: HotkeyAction) {
        switch action {
        case .next:               cycleImage(delta:  1, display: nil)
        case .prev:               cycleImage(delta: -1, display: nil)
        case .nextCurrentDisplay: cycleImage(delta:  1, display: displayUnderCursor())
        case .prevCurrentDisplay: cycleImage(delta: -1, display: displayUnderCursor())
        case .toggleBlur:         toggleBlur()
        case .toggleShuffle:      toggleShuffle()
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let tabs = makeSettingsTabs(settings: settings, httpStatus: httpStatus, hotkeyState: hotkeyState,
                                        sourcesOverridden: sourcesOverridden, httpPortOverride: envPort)
            let win = NSWindow(contentViewController: tabs)
            win.styleMask = [.titled, .closable]
            win.toolbarStyle = .preference
            win.isReleasedWhenClosed = false
            // The hosting controller only sizes the window on its first
            // layout pass, so centering right away places a tiny window that
            // then grows past the top of the screen and jumps back. Size it
            // to the first tab's SwiftUI content first.
            if let first = tabs.tabViewItems.first?.viewController {
                win.setContentSize(first.view.fittingSize)
            }
            win.center()
            // The window is hidden, not destroyed, so the recorder's
            // onDisappear may not run. A recording left active would keep
            // every hotkey unregistered.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win,
                                                   queue: .main) { [weak self] _ in
                self?.hotkeyState.recording = nil
            }
            settingsWindow = win
        }
        // A menu-bar-only app isn't active, so bring it forward first or the
        // window opens behind whatever app is in front.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // SwiftUI focuses the first control (the Blur switch) once the window
        // is key, which draws a focus ring before anything was pressed.
        // Clearing it after that pass leaves focus to Tab, like other apps.
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: Lock screen monitor
    // com.apple.screenIsLocked covers the login-window lock; screensDidSleep
    // also catches lid-close/display-sleep, which doesn't always post a lock
    // notification (e.g. no password required). Blur only ever turns on here
    // and stays on until the user toggles it off manually.
    private func setupLockScreenMonitor() {
        // The 4-arg addObserver on DistributedNotificationCenter defaults to a
        // suspension behavior that can coalesce/drop notifications for a
        // background (non-frontmost) app like this one; deliverImmediately
        // is required so a menu-bar accessory app reliably gets these.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(engageAutoBlur),
            name: Notification.Name("com.apple.screenIsLocked"), object: nil,
            suspensionBehavior: .deliverImmediately)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(engageAutoBlur),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
    }

    @objc private func engageAutoBlur() {
        guard settings.autoBlurOnLock, !blurEnabled else { return }
        toggleBlur()
    }

    // MARK: HTTP server

    // PORT in the environment wins over the saved setting, like paths on the
    // command line do over saved sources.
    let envPort = ProcessInfo.processInfo.environment["PORT"].flatMap { UInt16($0) }

    // The new listener only starts once the old one has released its port.
    // Rapid setting changes can queue several starts; the generation check
    // lets only the latest one through.
    private func startHTTPServer(port: UInt16) {
        httpGeneration += 1
        let generation = httpGeneration
        let old = httpServer
        httpServer = nil
        let start = { [weak self] in
            guard let self, self.httpGeneration == generation else { return }
            self.makeHTTPServer(port: port)
        }
        if let old { old.stop(then: start) } else { start() }
    }

    private func stopHTTPServer() {
        httpGeneration += 1
        httpServer?.stop()
        httpServer = nil
        httpStatus.state = .stopped
    }

    private func makeHTTPServer(port: UInt16) {
        let server = HTTPServer(port: port,
                                onNext: { [weak self] target in
                                    guard let self else { return }
                                    let display = target == .currentDisplay ? self.displayUnderCursor() : nil
                                    self.cycleImage(delta:  1, display: display)
                                },
                                onPrev: { [weak self] target in
                                    guard let self else { return }
                                    let display = target == .currentDisplay ? self.displayUnderCursor() : nil
                                    self.cycleImage(delta: -1, display: display)
                                },
                                onBlur: { [weak self] in self?.toggleBlur() },
                                onAutoCycle: { [weak self] in self?.settings.autoCycle.toggle() })
        // Only the current server may update the status, not one that's
        // being replaced.
        server.onStateChange = { [weak self, weak server] state in
            guard let self, let server, self.httpServer === server else { return }
            self.httpStatus.state = state
        }
        httpServer = server
        server.start()
    }

    // MARK: Double-click monitor
    // Windows at kCGDesktopWindowLevel sit below Finder's desktop layer, so they
    // can't receive mouse events normally. A global monitor sees all clicks without
    // requiring Accessibility permissions for mouse events.
    private func setupMouseMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.clickCount == 2 else { return }
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
            let loc = NSEvent.mouseLocation
            guard self.connected.contains(where: { $0.window?.frame.contains(loc) ?? false }) else { return }
            guard self.isDesktopClick(at: loc) else { return }
            DispatchQueue.main.async { self.toggleBlur() }
        }
    }

    // Frontmost-app-is-Finder alone doesn't distinguish the desktop from an
    // actual (possibly maximized) Finder window, since both run as the same
    // process. Cross-check against the on-screen window list (no Accessibility
    // permission required) and bail if any normal window actually covers the
    // click point.
    private func isDesktopClick(at loc: NSPoint) -> Bool {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return true }
        let cgPoint = CGPoint(x: loc.x, y: primaryHeight - loc.y)

        guard let infoList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return true
        }

        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                               width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.contains(cgPoint) { return false }
        }
        return true
    }
}

// MARK: - Entry point

var version = "dev"

// Older macOS versions pass a -psn_ process serial number when launching
// from Finder; it isn't a path.
let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-psn_") }

let usage = """
Usage: wp [image|dir ...]

With no arguments, images come from the folders set in Settings → Sources.

  --version, -v   Print version and exit
  --help, -h      Show this help and exit

Environment:
  PORT            If set, starts an HTTP server on this port for remote control,
                  overriding Settings → General → HTTP API for this run:
                     /next   Show the next image (add ?current_display=true to target only the display under the cursor)
                     /prev   Show the previous image (same query param supported)
                     /blur   Toggle blur
                     /auto-cycle   Toggle automatic image cycling at the configured interval
"""

if args == ["--version"] || args == ["-v"] {
    print("wp \(version)")
    exit(0)
}

if args == ["--help"] || args == ["-h"] {
    print(usage)
    exit(0)
}

// One instance at a time, whether started as wp.app or the bare binary. An
// flock is released by the OS when the process dies, so a crash never leaves
// a stale lock. A second launch activates the running one (shows its
// Settings window) and exits; paths passed to it are not applied.
let lockPath = FileManager.default.temporaryDirectory.appendingPathComponent("dev.abdus.apps.wp.lock").path
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD >= 0 && flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    DistributedNotificationCenter.default().postNotificationName(
        activateNotification, object: nil, userInfo: nil, deliverImmediately: true)
    guard args.isEmpty else {
        fputs("wp: already running; quit it first to start with other paths\n", stderr)
        exit(1)
    }
    exit(0)
}

let settings = Settings()
let images = collectImages(from: args.isEmpty ? settings.enabledSourcePaths : args)

// Explicit paths that match nothing are a mistake worth failing on; with no
// arguments the app starts anyway so sources can be set up in Settings.
if !args.isEmpty && images.isEmpty {
    fputs("wp: no images found\n", stderr)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = WallpaperController(images: images, settings: settings, sourcesOverridden: !args.isEmpty)
if images.isEmpty { controller.openSettings() }

app.run()

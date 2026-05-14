import AppKit
import Foundation
import CoreImage
import Metal
import Network

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

// MARK: - HTTP Server

final class HTTPServer {
    private let port: UInt16
    private let onNext: (CycleTarget) -> Void
    private let onPrev: (CycleTarget) -> Void
    private let onBlur: () -> Void
    private var listener: NWListener?

    init(port: UInt16, onNext: @escaping (CycleTarget) -> Void, onPrev: @escaping (CycleTarget) -> Void, onBlur: @escaping () -> Void) {
        self.port = port
        self.onNext = onNext
        self.onPrev = onPrev
        self.onBlur = onBlur
    }

    func start() {
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            fputs("wp: http: \(error)\n", stderr)
            return
        }

        listener?.stateUpdateHandler = { [port] state in
            if case .ready = state { fputs("wp: http listening on :\(port)\n", stderr) }
            if case .failed(let err) = state { fputs("wp: http: \(err)\n", stderr) }
        }

        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .background))
            self?.handle(conn)
        }

        listener?.start(queue: .global(qos: .background))
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
            default:                                                         (status, body) = ("404 Not Found", "endpoints: /next /prev /blur\n")
            }

            let msg = "HTTP/1.1 \(status)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(msg.utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

// MARK: - Cycle target

enum CycleTarget { case all, currentDisplay }

// MARK: - Auto cycle intervals

let autoCycleIntervals: [(label: String, seconds: TimeInterval)] = [
    ("5s", 5), ("10s", 10), ("30s", 30),
    ("1m", 60), ("5m", 300), ("15m", 900),
    ("30m", 1800), ("1h", 3600), ("2h", 7200),
    ("6h", 21600), ("12h", 43200), ("24h", 86400)
]

// MARK: - IntervalSliderView

final class IntervalSliderView: NSView {
    var onChange: (Int) -> Void = { _ in }

    private let slider: NSSlider
    private let label: NSTextField

    init(initialIndex: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange

        slider = NSSlider()
        slider.minValue = 0
        slider.maxValue = Double(autoCycleIntervals.count - 1)
        slider.numberOfTickMarks = autoCycleIntervals.count
        slider.allowsTickMarkValuesOnly = true
        slider.integerValue = initialIndex
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false

        label = NSTextField(labelWithString: autoCycleIntervals[initialIndex].label)
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(slider)
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            heightAnchor.constraint(equalToConstant: 34),

            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 32),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            slider.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        slider.target = self
        slider.action = #selector(sliderChanged(_:))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let idx = sender.integerValue
        label.stringValue = autoCycleIntervals[idx].label
        onChange(idx)
    }

    func setEnabled(_ enabled: Bool) {
        slider.isEnabled = enabled
        label.alphaValue = enabled ? 1 : 0.4
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

class WallpaperController: NSObject {
    let images: [URL]
    var imageIndices: [Int] = []
    var blurEnabled = false
    var shuffleEnabled = true
    var shuffledImages: [[URL]] = []
    var blurCache: [URL: NSImage] = [:]
    var windows: [NSWindow] = []
    var statusItem: NSStatusItem!
    var blurMenuItem: NSMenuItem!
    var shuffleMenuItem: NSMenuItem!
    var globalMonitor: Any?
    var httpServer: HTTPServer?
    var autoCycleEnabled = false
    var autoCycleIntervalIndex = 4
    var autoCycleTimer: Timer?
    var autoCycleMenuItem: NSMenuItem!
    var autoCycleSliderView: IntervalSliderView!

    func activeImages(for windowIndex: Int) -> [URL] {
        shuffleEnabled && windowIndex < shuffledImages.count ? shuffledImages[windowIndex] : images
    }

    lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    init(images: [URL]) {
        self.images = images
        super.init()
        setupWindows()
        setupMenu()
        setupMouseMonitor()
        setupHTTPServer()
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
    }

    // MARK: Windows

    @objc private func screensChanged() {
        for win in windows { win.orderOut(nil) }
        windows = []
        blurCache = [:]
        setupWindows()
    }

    private func setupWindows() {
        for screen in NSScreen.screens {
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
            windows.append(win)
        }
        imageIndices   = Array(repeating: 0, count: windows.count)
        shuffledImages = (0..<windows.count).map { _ in images.shuffled() }
        updateImages()
    }

    // MARK: Rendering

    private func fadeTransition() -> CATransition {
        let t = CATransition()
        t.duration = 0.6
        t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return t
    }

    private func updateImages(windowIndex: Int? = nil) {
        let targets = windowIndex.map { [$0] } ?? Array(windows.indices)
        for i in targets {
            guard i < windows.count, i < imageIndices.count else { continue }
            let win = windows[i]
            let pool = activeImages(for: i)
            let url  = pool[imageIndices[i] % pool.count]

            if !blurEnabled {
                let layer = win.contentView?.layer
                layer?.add(fadeTransition(), forKey: "transition")
                layer?.contents = NSImage(contentsOf: url)
                continue
            }

            if let cached = blurCache[url] {
                let layer = win.contentView?.layer
                layer?.add(fadeTransition(), forKey: "transition")
                layer?.contents = cached
                continue
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak win] in
                guard let self,
                      let img = NSImage(contentsOf: url),
                      let blurred = self.blurImage(img, sigma: 200) else { return }
                DispatchQueue.main.async {
                    self.blurCache[url] = blurred
                    let layer = win?.contentView?.layer
                    layer?.add(self.fadeTransition(), forKey: "transition")
                    layer?.contents = blurred
                }
            }
        }
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

        let prev = NSMenuItem(title: "Previous Image", action: #selector(prevImage), keyEquivalent: "[")
        prev.target = self
        menu.addItem(prev)

        let next = NSMenuItem(title: "Next Image", action: #selector(nextImage), keyEquivalent: "]")
        next.target = self
        menu.addItem(next)

        menu.addItem(.separator())

        blurMenuItem = NSMenuItem(title: "Blur", action: #selector(toggleBlur), keyEquivalent: "b")
        blurMenuItem.target = self
        menu.addItem(blurMenuItem)

        shuffleMenuItem = NSMenuItem(title: "Shuffle", action: #selector(toggleShuffle), keyEquivalent: "s")
        shuffleMenuItem.target = self
        shuffleMenuItem.state = .on
        menu.addItem(shuffleMenuItem)

        menu.addItem(.separator())

        autoCycleMenuItem = NSMenuItem(title: "Auto Cycle", action: #selector(toggleAutoCycle), keyEquivalent: "a")
        autoCycleMenuItem.target = self
        menu.addItem(autoCycleMenuItem)

        autoCycleSliderView = IntervalSliderView(initialIndex: autoCycleIntervalIndex) { [weak self] idx in
            self?.setAutoCycleInterval(idx)
        }
        autoCycleSliderView.setEnabled(false)
        let sliderItem = NSMenuItem()
        sliderItem.view = autoCycleSliderView
        menu.addItem(sliderItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    // MARK: Actions

    @objc func nextImage() { cycleImage(delta:  1, windowIndex: nil) }
    @objc func prevImage() { cycleImage(delta: -1, windowIndex: nil) }

    func cycleImage(delta: Int, windowIndex: Int?) {
        let targets = windowIndex.map { [$0] } ?? Array(imageIndices.indices)
        for i in targets where i < imageIndices.count {
            let count = activeImages(for: i).count
            imageIndices[i] = (imageIndices[i] + delta + count) % count
        }
        updateImages(windowIndex: windowIndex)
    }

    private func currentDisplayWindowIndex() -> Int? {
        let loc = NSEvent.mouseLocation
        return windows.firstIndex(where: { $0.frame.contains(loc) })
    }

    @objc func toggleBlur() {
        blurEnabled.toggle()
        blurMenuItem.state = blurEnabled ? .on : .off
        updateImages()
    }

    @objc func toggleShuffle() {
        shuffleEnabled.toggle()
        if shuffleEnabled { shuffledImages = (0..<windows.count).map { _ in images.shuffled() } }
        shuffleMenuItem.state = shuffleEnabled ? .on : .off
        imageIndices = Array(repeating: 0, count: windows.count)
        updateImages()
    }

    @objc func toggleAutoCycle() {
        autoCycleEnabled.toggle()
        autoCycleMenuItem.state = autoCycleEnabled ? .on : .off
        autoCycleSliderView.setEnabled(autoCycleEnabled)
        autoCycleEnabled ? startAutoCycle() : stopAutoCycle()
    }

    func setAutoCycleInterval(_ index: Int) {
        autoCycleIntervalIndex = index
        if autoCycleEnabled { startAutoCycle() }
    }

    private func startAutoCycle() {
        autoCycleTimer?.invalidate()
        let secs = autoCycleIntervals[autoCycleIntervalIndex].seconds
        let timer = Timer(timeInterval: secs, repeats: true) { [weak self] _ in
            self?.nextImage()
        }
        RunLoop.main.add(timer, forMode: .common)
        autoCycleTimer = timer
    }

    private func stopAutoCycle() {
        autoCycleTimer?.invalidate()
        autoCycleTimer = nil
    }

    // MARK: HTTP server

    private func setupHTTPServer() {
        guard let portStr = ProcessInfo.processInfo.environment["PORT"],
              let port = UInt16(portStr) else { return }
        httpServer = HTTPServer(port: port,
                                onNext: { [weak self] target in
                                    guard let self else { return }
                                    let idx = target == .currentDisplay ? self.currentDisplayWindowIndex() : nil
                                    self.cycleImage(delta:  1, windowIndex: idx)
                                },
                                onPrev: { [weak self] target in
                                    guard let self else { return }
                                    let idx = target == .currentDisplay ? self.currentDisplayWindowIndex() : nil
                                    self.cycleImage(delta: -1, windowIndex: idx)
                                },
                                onBlur: { [weak self] in self?.toggleBlur() })
        httpServer?.start()
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
            guard self.windows.contains(where: { $0.frame.contains(loc) }) else { return }
            DispatchQueue.main.async { self.toggleBlur() }
        }
    }
}

// MARK: - Entry point

var version = "dev"

let args = Array(CommandLine.arguments.dropFirst())

if args == ["--version"] || args == ["-v"] {
    print("wp \(version)")
    exit(0)
}

guard !args.isEmpty else {
    fputs("Usage: wp <image|dir> [...]\n", stderr)
    exit(1)
}

let images = collectImages(from: args)
guard !images.isEmpty else {
    fputs("wp: no images found\n", stderr)
    exit(1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = WallpaperController(images: images)

app.run()

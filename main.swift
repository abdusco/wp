import AppKit
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
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
    var shuffled: [URL]
    var slides: [Slide] = []
    var aspect: CGFloat?        // screen aspect the slides were grouped for

    init(key: String, shuffled: [URL]) {
        self.key = key
        self.shuffled = shuffled
    }
}

class WallpaperController: NSObject, NSMenuDelegate {
    let images: [URL]
    let aspects: [URL: CGFloat]              // missing entry = unreadable header, treated as wide
    var displays: [String: Display] = [:]   // persists across disconnects
    var order: [String] = []                 // keys of connected displays, in screen order
    var blurEnabled = false
    var shuffleEnabled = true
    var blurCache: [Slide: NSImage] = [:]
    var statusItem: NSStatusItem!
    var blurMenuItem: NSMenuItem!
    var shuffleMenuItem: NSMenuItem!
    var globalMonitor: Any?
    var httpServer: HTTPServer?
    var autoBlurOnLockEnabled = true
    var autoBlurOnLockMenuItem: NSMenuItem!
    var autoCycleEnabled = false
    var autoCycleIntervalIndex = 4
    var autoCycleTimer: Timer?
    var autoCycleMenuItem: NSMenuItem!
    var autoCycleSliderView: IntervalSliderView!
    var wallpaperMenuItems: [NSMenuItem] = []

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

    lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    init(images: [URL]) {
        self.images = images
        self.aspects = Dictionary(
            images.compactMap { url in imageAspect(url).map { (url, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        super.init()
        syncScreens()
        setupMenu()
        setupMouseMonitor()
        setupHTTPServer()
        setupLockScreenMonitor()
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
        let targets = target.map { [$0] } ?? connected
        for display in targets {
            guard let win = display.window else { continue }
            guard let slide = currentSlide(for: display), let url = slide.first else { continue }

            if !blurEnabled && slide.count == 1 {
                let layer = win.contentView?.layer
                layer?.add(fadeTransition(), forKey: "transition")
                layer?.contents = NSImage(contentsOf: url)
                continue
            }

            if blurEnabled, let cached = blurCache[slide] {
                let layer = win.contentView?.layer
                layer?.add(fadeTransition(), forKey: "transition")
                layer?.contents = cached
                continue
            }

            // Compositing and blurring are too slow for the main thread.
            // Rapid next/prev can finish renders out of order, so a result is
            // dropped if the display has moved on to another slide meanwhile.
            let blur = blurEnabled
            let size = win.frame.size
            let scale = win.backingScaleFactor
            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak win, weak display] in
                guard let self,
                      let img = self.renderSlide(slide, size: size, scale: scale),
                      let out = blur ? self.blurImage(img, sigma: 200) : img else { return }
                DispatchQueue.main.async {
                    if blur { self.blurCache[slide] = out }
                    guard let display, self.currentSlide(for: display) == slide else { return }
                    let layer = win?.contentView?.layer
                    layer?.add(self.fadeTransition(), forKey: "transition")
                    layer?.contents = out
                }
            }
        }
    }

    private func renderSlide(_ slide: Slide, size: CGSize, scale: CGFloat) -> NSImage? {
        if slide.count == 1 { return NSImage(contentsOf: slide[0]) }
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let cg = composite(slide, pixelSize: pixelSize) else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    // Draws a slide's images side by side into one screen-sized image. Each
    // image gets a slot whose width is proportional to its aspect ratio, then
    // is aspect-filled into that slot, so a well-matched group crops little.
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

        let aspects = slide.map { self.aspects[$0] ?? 1 }
        let total = aspects.reduce(0, +)
        var cumulative: CGFloat = 0

        for (url, aspect) in zip(slide, aspects) {
            // Slot edges come from the running sum so rounding never leaves
            // a gap at the right edge.
            let left = (pixelSize.width * cumulative / total).rounded()
            cumulative += aspect
            let right = (pixelSize.width * cumulative / total).rounded()
            let slot = CGRect(x: left, y: 0, width: right - left, height: pixelSize.height)

            // Aspect-fill: match whichever side leaves no gap, overflow the other.
            let drawn = aspect > slot.width / slot.height
                ? CGSize(width: slot.height * aspect, height: slot.height)
                : CGSize(width: slot.width, height: slot.width / aspect)
            let rect = CGRect(x: slot.midX - drawn.width / 2, y: slot.midY - drawn.height / 2,
                              width: drawn.width, height: drawn.height)

            // The thumbnail API applies EXIF orientation and decodes at the
            // drawn size instead of full resolution.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(max(drawn.width, drawn.height).rounded(.up)),
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
            else { continue }

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

        let prev = NSMenuItem(title: "Previous Image", action: #selector(prevImage), keyEquivalent: "[")
        prev.target = self
        menu.addItem(prev)

        let next = NSMenuItem(title: "Next Image", action: #selector(nextImage), keyEquivalent: "]")
        next.target = self
        menu.addItem(next)

        menu.addItem(.separator())

        let wallpaperItem = NSMenuItem(title: "Current Wallpapers", action: nil, keyEquivalent: "")
        let wallpaperSubmenu = NSMenu()
        wallpaperSubmenu.delegate = self
        wallpaperItem.submenu = wallpaperSubmenu
        menu.addItem(wallpaperItem)

        menu.addItem(.separator())

        blurMenuItem = NSMenuItem(title: "Blur", action: #selector(toggleBlur), keyEquivalent: "b")
        blurMenuItem.target = self
        menu.addItem(blurMenuItem)

        shuffleMenuItem = NSMenuItem(title: "Shuffle", action: #selector(toggleShuffle), keyEquivalent: "s")
        shuffleMenuItem.target = self
        shuffleMenuItem.state = .on
        menu.addItem(shuffleMenuItem)

        menu.addItem(.separator())

        autoBlurOnLockMenuItem = NSMenuItem(title: "Auto Blur on Lock", action: #selector(toggleAutoBlurOnLock), keyEquivalent: "")
        autoBlurOnLockMenuItem.target = self
        autoBlurOnLockMenuItem.state = autoBlurOnLockEnabled ? .on : .off
        menu.addItem(autoBlurOnLockMenuItem)

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

    func cycleImage(delta: Int, display target: Display?) {
        let targets = target.map { [$0] } ?? connected
        for display in targets {
            let count = display.slides.count
            guard count > 0 else { continue }
            display.imageIndex = (display.imageIndex + delta + count) % count
        }
        updateImages(target)
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

    @objc func toggleAutoBlurOnLock() {
        autoBlurOnLockEnabled.toggle()
        autoBlurOnLockMenuItem.state = autoBlurOnLockEnabled ? .on : .off
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
        guard autoBlurOnLockEnabled, !blurEnabled else { return }
        toggleBlur()
    }

    // MARK: HTTP server

    private func setupHTTPServer() {
        guard let portStr = ProcessInfo.processInfo.environment["PORT"],
              let port = UInt16(portStr) else { return }
        httpServer = HTTPServer(port: port,
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

let args = Array(CommandLine.arguments.dropFirst())

let usage = """
Usage: wp <image|dir> [...]

  --version, -v   Print version and exit
  --help, -h      Show this help and exit

Environment:
  PORT            If set, starts an HTTP server on this port for remote control:
                     /next   Show the next image (add ?current_display=true to target only the display under the cursor)
                     /prev   Show the previous image (same query param supported)
                     /blur   Toggle blur
"""

if args == ["--version"] || args == ["-v"] {
    print("wp \(version)")
    exit(0)
}

if args == ["--help"] || args == ["-h"] {
    print(usage)
    exit(0)
}

guard !args.isEmpty else {
    fputs(usage + "\n", stderr)
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

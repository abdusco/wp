import AppKit
import Foundation
import CoreImage

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

// MARK: - Controller

class WallpaperController: NSObject {
    let images: [URL]
    var baseIndex = 0
    var blurEnabled = false
    var blurCache: [URL: NSImage] = [:]
    var windows: [NSWindow] = []
    var statusItem: NSStatusItem!
    var blurMenuItem: NSMenuItem!
    var globalMonitor: Any?

    // One shared GPU-backed context for all blur operations
    lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    init(images: [URL]) {
        self.images = images
        super.init()
        setupWindows()
        setupMenu()
        setupMouseMonitor()
    }

    deinit {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
    }

    // MARK: Windows

    private func setupWindows() {
        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            win.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
        updateImages()
    }

    // MARK: Rendering

    private func updateImages() {
        for (i, win) in windows.enumerated() {
            let url = images[(baseIndex + i) % images.count]

            if !blurEnabled {
                win.contentView?.layer?.contents = NSImage(contentsOf: url)
                return
            }

            if let cached = blurCache[url] {
                win.contentView?.layer?.contents = cached
                return
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self, weak win] in
                guard let self,
                      let img = NSImage(contentsOf: url),
                      let blurred = self.blurImage(img, sigma: 200) else { return }
                DispatchQueue.main.async {
                    self.blurCache[url] = blurred
                    win?.contentView?.layer?.contents = blurred
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

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    // MARK: Actions

    @objc func nextImage() {
        baseIndex = (baseIndex + 1) % images.count
        updateImages()
    }

    @objc func prevImage() {
        baseIndex = (baseIndex - 1 + images.count) % images.count
        updateImages()
    }

    @objc func toggleBlur() {
        blurEnabled.toggle()
        blurMenuItem.state = blurEnabled ? .on : .off
        updateImages()
    }

    // MARK: Double-click monitor
    // Windows at kCGDesktopWindowLevel sit below Finder's desktop layer, so they
    // can't receive mouse events normally. A global monitor sees all clicks without
    // requiring Accessibility permissions for mouse events.
    private func setupMouseMonitor() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.clickCount == 2 else { return }
            let loc = NSEvent.mouseLocation
            guard self.windows.contains(where: { $0.frame.contains(loc) }) else { return }
            DispatchQueue.main.async { self.toggleBlur() }
        }
    }
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
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

import AppKit
import Foundation

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
    var windows: [NSWindow] = []
    var statusItem: NSStatusItem!

    init(images: [URL]) {
        self.images = images
        super.init()
        setupWindows()
        setupMenu()
    }

    private func setupWindows() {
        for (i, screen) in NSScreen.screens.enumerated() {
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

            _ = i // suppress unused warning; index used via enumerated
        }
        updateImages()
    }

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
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private func updateImages() {
        for (i, win) in windows.enumerated() {
            let url = images[(baseIndex + i) % images.count]
            if let img = NSImage(contentsOf: url) {
                win.contentView?.layer?.contents = img
            }
        }
    }

    @objc private func nextImage() {
        baseIndex = (baseIndex + 1) % images.count
        updateImages()
    }

    @objc private func prevImage() {
        baseIndex = (baseIndex - 1 + images.count) % images.count
        updateImages()
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

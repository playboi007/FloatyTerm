import AppKit

/// A tab that displays a single image file (PNG / JPEG / GIF / …), opened from
/// a terminal selection via the right-click "Open in Image Viewer" action.
///
/// Inline image rendering in the scrollback is already handled by SwiftTerm
/// (iTerm2 OSC 1337 + Kitty graphics). This controller is the dedicated,
/// full-size view: the user selects an image path in the terminal and opens it
/// in a child tab placed next to the parent terminal.
///
/// Follows the ephemeral-viewer pattern of `DiffViewerController` /
/// `MirrorController`: it carries no live session, so `restorableRecord` is nil
/// (image tabs are not restored across launches in v1).
final class ImageViewerController: NSObject, TabContent {

    private let imagePath: String
    private let fileName: String
    private let scrollView = NSScrollView()
    private let imageView = NSImageView()

    /// File extensions we treat as openable images.
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif",
        "heic", "heif", "webp", "ico", "icns"
    ]

    /// True when `path` is an existing regular file with a recognized image
    /// extension. Callers use this to decide whether a selected path is worth
    /// offering to open here.
    static func isImageFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        guard imageExtensions.contains(ext) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            && !isDir.boolValue
    }

    /// Fails when the path isn't a decodable image, so the caller can fall back
    /// gracefully instead of opening an empty tab.
    init?(path: String) {
        guard Self.isImageFile(path),
              let image = NSImage(contentsOfFile: path) else { return nil }
        self.imagePath = path
        self.fileName = (path as NSString).lastPathComponent
        super.init()

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = true          // animate GIFs
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.autoresizingMask = [.width, .height]

        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.allowsMagnification = true     // scroll / pinch to zoom
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8.0
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false        // show the panel blur through
        scrollView.autoresizingMask = [.width, .height]
    }

    // MARK: - TabContent

    var view: NSView { scrollView }

    var title: String { fileName }
    var customName: String?
    var displayName: String { customName ?? fileName }

    var hasUnseenOutput: Bool { false }
    var isCurrentlyViewed: Bool = false

    var onTitleChanged: (() -> Void)?
    var onTerminated: (() -> Void)?

    // Ephemeral — mirrors DiffViewerController / MirrorController.
    var restorableRecord: TabRecord? { nil }

    func focus(in panel: NSWindow) {
        panel.makeFirstResponder(scrollView)
        fitToViewport()
    }

    func cleanup() {
        imageView.image = nil
    }

    /// Sizes the image view to the current viewport so the proportional scaling
    /// fits the whole image on screen, and resets any prior zoom.
    private func fitToViewport() {
        let viewport = scrollView.contentView.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return }
        imageView.frame = NSRect(origin: .zero, size: viewport)
        scrollView.magnification = 1.0
    }
}

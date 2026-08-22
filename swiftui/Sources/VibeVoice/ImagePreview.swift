import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Full-screen viewer for a frame that appears in the transcript.
///
/// The thumbnail in the transcript is 92 points tall and cropped to fill, which is enough
/// to say "a screenshot went out here" and nowhere near enough to read a line of code in
/// it. The image behind that thumbnail is the *whole* capture at `screenshotSize` (1280 px
/// on its long edge by default) — the same pixels that were sent to the model — so there
/// is nothing to re-capture or re-fetch: clicking simply shows what is already in memory
/// at a size worth looking at.
///
/// It is a panel over the whole screen rather than a sheet on the app window for the
/// obvious reason: the thing being previewed is a picture of a screen, and a preview of a
/// screen inside a 372-point sidebar is not a preview.
@MainActor
enum ScreenshotPreview {

    private static var panel: PreviewPanel?

    /// Opens (or re-targets) the viewer. Calling it twice swaps the image rather than
    /// stacking a second panel over the first.
    static func show(_ image: NSImage, title: String, captured: Date? = nil) {
        let model = PreviewModel(image: image, title: title, captured: captured)
        if let existing = panel {
            existing.retarget(model)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let p = PreviewPanel(model: model)
        panel = p
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close() {
        panel?.orderOut(nil)
        panel = nil
    }

    /// Called by the panel when it dismisses itself, so the cached reference cannot
    /// outlive the window and swallow the next `show`.
    fileprivate static func forget(_ p: PreviewPanel) {
        if panel === p { panel = nil }
    }
}

// MARK: - Model

@MainActor
final class PreviewModel: ObservableObject {
    @Published var image: NSImage
    @Published var title: String
    @Published var captured: Date?
    /// Fit-to-screen, or the capture's own pixels one-to-one.
    @Published var actualSize = false
    /// Transient confirmation for Copy — a button that silently succeeds looks broken.
    @Published var flash: String?
    /// The window this is being shown in, so a Save panel can hang off it as a sheet.
    weak var host: NSWindow?

    init(image: NSImage, title: String, captured: Date?) {
        self.image = image
        self.title = title
        self.captured = captured
    }

    var pixelSize: CGSize {
        guard let rep = image.representations.first else { return image.size }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    var dimensionLabel: String {
        let s = pixelSize
        return "\(Int(s.width)) × \(Int(s.height))"
    }

    func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        say("Copied")
    }

    /// Writes a PNG to a temp file and hands it to whatever opens PNGs — Preview, for
    /// almost everyone. Cheaper than a Save panel when all you want is to zoom in.
    func openInPreview() {
        guard let url = writePNG(to: FileManager.default.temporaryDirectory
            .appendingPathComponent(safeFilename())) else {
            say("Couldn't open it")
            return
        }
        NSWorkspace.shared.open(url)
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = safeFilename()
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.say(self.writePNG(to: url) != nil ? "Saved" : "Couldn't save it")
        }
        // As a sheet, so the viewer underneath stays put. `runModal` would resign the
        // panel's key status and dismiss the very thing being saved.
        if let host { panel.beginSheetModal(for: host, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    private func safeFilename() -> String {
        let base = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? "Screenshot" : base) + ".png"
    }

    @discardableResult
    private func writePNG(to url: URL) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("[preview] could not write %@: %@", url.lastPathComponent, error.localizedDescription)
            return nil
        }
    }

    private func say(_ message: String) {
        flash = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if self?.flash == message { self?.flash = nil }
        }
    }
}

// MARK: - Panel

/// Borderless, screen-filling, and dismissed by Escape like every other macOS overlay.
final class PreviewPanel: NSPanel {

    private let model: PreviewModel

    @MainActor
    init(model: PreviewModel) {
        self.model = model
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        super.init(contentRect: frame,
                   styleMask: [.borderless, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)

        // Above the app AND above the floating widget, which lives at `.screenSaver`.
        // A preview that opens behind the thing that opened it is not a preview.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // The overlay is a dark scrim in both system appearances; without pinning this,
        // Theme's tokens resolve light and the caption paints near-white on near-white.
        appearance = NSAppearance(named: .darkAqua)
        isReleasedWhenClosed = false
        animationBehavior = .none

        let host = NSHostingView(rootView: PreviewOverlay(model: model, onClose: { [weak self] in
            self?.dismiss()
        }))
        host.autoresizingMask = [.width, .height]
        contentView = host
        setFrame(frame, display: true)
        model.host = self
    }

    @MainActor
    func retarget(_ next: PreviewModel) {
        model.image = next.image
        model.title = next.title
        model.captured = next.captured
        model.actualSize = false
        model.flash = nil
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Guards the dismiss-on-resign below. Without it the panel can tear itself down
    /// during the ordering dance, before it has ever actually been in front.
    private var hasBeenKey = false
    override func becomeKey() { super.becomeKey(); hasBeenKey = true }

    /// Escape. `cancelOperation` is what AppKit routes it to once the panel is key, and
    /// wiring it here rather than in SwiftUI means it works no matter what has focus.
    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func keyDown(with event: NSEvent) {
        // ⌘W as well, because the panel looks like a window and people close windows.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            dismiss()
            return
        }
        super.keyDown(with: event)
    }

    /// Clicking through to another app should not leave a full-screen scrim behind.
    /// A Save sheet is the exception — it takes key from its own parent by design, and
    /// closing the window out from under it would cancel the save.
    override func resignKey() {
        super.resignKey()
        guard hasBeenKey, attachedSheet == nil else { return }
        dismiss()
    }

    @MainActor
    private func dismiss() {
        orderOut(nil)
        ScreenshotPreview.forget(self)
    }
}

// MARK: - Overlay

private struct PreviewOverlay: View {
    @ObservedObject var model: PreviewModel
    var onClose: () -> Void

    var body: some View {
        ZStack {
            // The scrim is the dismiss target: clicking off the image closes, which is
            // what a Quick Look-shaped thing is expected to do.
            Color.black.opacity(0.86)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            VStack(spacing: 14) {
                image
                caption
            }
            .padding(34)

            VStack {
                HStack {
                    Spacer()
                    toolbar
                }
                Spacer()
            }
            .padding(20)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var image: some View {
        // Fit is the default. Actual size gets a scroll view, because a 1280-wide capture
        // on a 1280-wide laptop screen is not going to fit and clipping it silently would
        // be worse than a scrollbar.
        if model.actualSize {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: model.image)
                    .resizable()
                    .frame(width: model.pixelSize.width, height: model.pixelSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .onTapGesture { model.actualSize = false }
        } else {
            Image(nsImage: model.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 32, y: 12)
                .contentShape(Rectangle())
                .onTapGesture { model.actualSize = true }
                .help("Click to view at actual size")
        }
    }

    private var caption: some View {
        HStack(spacing: 10) {
            Text(model.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Text(model.dimensionLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
            if let at = model.captured {
                Text(at, style: .time)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            if let flash = model.flash {
                Text(flash)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.flash)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(Color.white.opacity(0.09)))
        .accessibilityElement(children: .combine)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            chip(model.actualSize ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                 model.actualSize ? "Fit to screen" : "Actual size") {
                model.actualSize.toggle()
            }
            chip("doc.on.doc", "Copy") { model.copyToPasteboard() }
            chip("arrow.up.forward.app", "Open in Preview") { model.openInPreview() }
            chip("square.and.arrow.down", "Save as PNG…") { model.save() }
            chip("xmark", "Close (esc)") { onClose() }
        }
    }

    private func chip(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .background(Circle().fill(Color.white.opacity(0.12)))
        .help(label)
        .accessibilityLabel(label)
    }
}

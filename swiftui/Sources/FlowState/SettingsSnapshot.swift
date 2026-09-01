import SwiftUI
import AppKit
import FlowStateCore

/// Renders Settings to PNG files without anyone looking at the screen.
///
/// Two jobs, both of which came out of trying to check this pane's layout on a Mac whose
/// display was asleep and whose terminal had no Screen Recording grant — a screenshot was
/// simply not obtainable, and "it compiles" is not a claim about how something looks.
///
/// 1. Every tab, at its natural height, so a layout change can be inspected as a picture.
/// 2. Every moving backdrop as a still, which is the closest thing to a contact sheet for
///    nine animations, and the fastest way to see that one of them has come out as a flat
///    gradient because its shader failed to bind.
///
/// Off unless asked for:
///
///     FLOWSTATE_SNAPSHOT=/tmp/flowstate-ui open -a swiftui/FlowState.app
///
/// or `swiftui/Scripts/snapshot-ui.sh`, which sets it and opens the folder afterwards.
/// The app quits as soon as the files are written — this is a rendering mode, not a
/// debug overlay on a running session.
@MainActor
enum SettingsSnapshot {

    /// The folder to write into, if this launch was asked for snapshots at all.
    static var requested: URL? {
        guard let path = ProcessInfo.processInfo.environment["FLOWSTATE_SNAPSHOT"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Renders everything and terminates. Called once, from the app's first `task`.
    ///
    /// The delay is not superstition: `ImageRenderer` walks a real view tree, and the
    /// motion previews need one turn of the run loop to get past their first frame — with
    /// no wait at all every backdrop renders as the flat gradient it starts from.
    static func runIfRequested(state: AppState) async {
        guard let dir = requested else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("[snapshot] \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        try? await Task.sleep(for: .milliseconds(700))

        for scheme in [ColorScheme.dark, .light] {
            for tab in SettingsTab.allCases {
                // SettingsView reads its tab from UserDefaults, so this is how the
                // renderer asks for one — the same path the user's clicks take.
                UserDefaults.standard.set(tab.rawValue, forKey: "settings.tab")
                write(pane(state: state, scheme: scheme),
                      to: dir.appendingPathComponent("settings-\(tab.rawValue)-\(name(scheme)).png"))
            }
            write(motionSheet(state: state, scheme: scheme),
                  to: dir.appendingPathComponent("motion-styles-\(name(scheme)).png"))
            write(transcriptSheet(state: state, scheme: scheme),
                  to: dir.appendingPathComponent("transcript-states-\(name(scheme)).png"))
            for style in MotionStyle.allCases {
                write(gallery(style: style, scheme: scheme),
                      to: dir.appendingPathComponent("motion-picker-\(style.rawValue)-\(name(scheme)).png"))
            }
        }

        FileHandle.standardOutput.write(Data("[snapshot] wrote to \(dir.path)\n".utf8))
        exit(0)
    }

    private static func name(_ scheme: ColorScheme) -> String { scheme == .dark ? "dark" : "light" }

    // MARK: - What gets rendered

    /// Settings inside a stand-in for the floating pane: same corner radius, same
    /// hairline, same title bar height. Not the real `FloatingPanel`, which needs a
    /// window and a drag gesture to be itself, but the same silhouette.
    private static func pane(state: AppState, scheme: ColorScheme) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "xmark").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.fill))
            }
            .padding(.horizontal, 16).padding(.vertical, 11)

            Divider().overlay(Theme.hairline)

            SettingsView(state: state, flattened: true)
        }
        .frame(width: 440)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .padding(24)
        .background(Theme.bg)
        .environment(\.colorScheme, scheme)
    }

    /// The moving-backdrop picker as Settings shows it, for a style the user may not
    /// currently have selected.
    ///
    /// Rendered from `MotionStyleGallery` with constant bindings rather than by switching
    /// the live backdrop: this is a snapshot run, and a snapshot run that rewrites the
    /// settings file it happens to be inspecting is a trap, not a tool.
    private static func gallery(style: MotionStyle, scheme: ColorScheme) -> some View {
        MotionStyleGallery(look: .constant(LookSelection(backdrop: .motion, motionStyle: style)),
                           intensity: .constant(0.6),
                           assetsEnabled: .constant(true),
                           installError: .constant(nil))
            .frame(width: 396)
            .padding(22)
            .background(Theme.panel)
            .environment(\.colorScheme, scheme)
    }

    /// All nine moving backdrops at once, at a size where the difference between them is
    /// actually visible.
    private static func motionSheet(state: AppState, scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Moving backgrounds")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(240), spacing: 14), count: 2),
                      spacing: 14) {
                ForEach(MotionStyle.allCases) { style in
                    VStack(alignment: .leading, spacing: 5) {
                        MotionBackdropView(style: style,
                                           intensity: state.settings.motionIntensity,
                                           assetsEnabled: state.settings.motionAssets)
                            .frame(width: 240, height: 135)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        Text(style.label)
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
                        Text(style.blurb)
                            .font(.system(size: 10)).foregroundStyle(Theme.textFaint)
                            .frame(width: 240, alignment: .leading)
                    }
                }
            }
        }
        .padding(22)
        .background(Theme.bg)
        .environment(\.colorScheme, scheme)
    }

    /// The transcript column in the states that are otherwise only reachable by talking
    /// to the app for a while: live, pinned, hidden.
    ///
    /// Worth a picture rather than a test because each one is a claim made in pixels —
    /// that a pinned transcript LOOKS locked, and that a hidden one does not look like a
    /// transcript that has been thrown away.
    private static func transcriptSheet(state: AppState, scheme: ColorScheme) -> some View {
        let now = Date()
        let said: [TranscriptItem] = [
            TranscriptItem(speaker: .user,
                           text: "keep this transcript around — I want to come back to it tomorrow",
                           at: now.addingTimeInterval(-240)),
            TranscriptItem(speaker: .assistant,
                           text: "Pinned. It stays saved, retention skips it, and it is what opens next time.",
                           at: now.addingTimeInterval(-232)),
            TranscriptItem(speaker: .system,
                           text: "✎ summary: pinned the conversation about transcript retention.",
                           at: now.addingTimeInterval(-200)),
            TranscriptItem(speaker: .user,
                           text: "and fix the line where it heard \"jak\"",
                           at: now.addingTimeInterval(-40)),
        ]

        return HStack(alignment: .top, spacing: 16) {
            column("Live", TranscriptView(items: said, flattened: true))
            column("Pinned", TranscriptView(items: said, pinned: true, flattened: true))
            column("Hidden", hiddenColumn(lines: said.count))
        }
        .padding(22)
        .background(Theme.bg)
        .environment(\.colorScheme, scheme)
    }

    private static func column<V: View>(_ title: String, _ content: V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10.5, weight: .bold)).tracking(1.0)
                .foregroundStyle(Theme.textFaint)
            content
                .frame(width: 300, height: 260, alignment: .top)
                .background(Theme.sidebar)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1))
        }
    }

    /// The hidden state, drawn from the same words `TranscriptColumn` uses. Not the view
    /// itself, which needs a live `AppState` whose settings this run must not rewrite.
    private static func hiddenColumn(lines: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "eye.slash")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.textFaint.opacity(0.55))
            Text("Transcript hidden")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textFaint)
            Text("\(lines) lines still here, still being saved.\nNothing was deleted.")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textFaint.opacity(0.75))
            Text("Show transcript")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accentInk)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.fill))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rendering

    private static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        // Retina, because half the point is checking hairlines and 10-point captions.
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("[snapshot] could not render \(url.lastPathComponent)\n".utf8))
            return
        }
        try? png.write(to: url)
    }
}

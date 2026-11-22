import AppKit
import UniformTypeIdentifiers

/// The render stage is the drop destination; ordinary mouse input still goes
/// to the Metal view above it, which also moves into the fullscreen preview.
final class PhotoDropStage: NSView {
    var onPhoto: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    private func photo(in sender: NSDraggingInfo) -> URL? {
        guard onPhoto != nil,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                  options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1,
              PhotoWindowImport.accepts(urls[0]) else { return nil }
        return urls[0]
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        photo(in: sender) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let photo = photo(in: sender), let onPhoto else { return false }
        // Open any required panels after AppKit has finished the drag session.
        DispatchQueue.main.async { onPhoto(photo) }
        return true
    }
}

final class PhotoWindowImport {
    enum Mode { case sharp(tools: URL), depth(model: URL) }

    /// A packaged copy carries neither helper. Let a user with a trusted
    /// checkout explicitly choose it, without changing where their app reads
    /// or saves its bundled shaders.
    static func helperRoot(checkout: URL?) -> URL? {
        if let checkout, hasHelpers(checkout) { return checkout }
        let panel = NSOpenPanel()
        panel.message = "Choose a trusted Lerping@Home checkout with the photo import tools."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let root = panel.url else { return nil }
        guard hasHelpers(root) else {
            let alert = NSAlert()
            alert.messageText = "Photo import tools not found"
            alert.informativeText = "Choose the root of a current Lerping@Home source checkout."
            alert.runModal()
            return nil
        }
        return root
    }

    private static func hasHelpers(_ root: URL) -> Bool {
        let wm = FileManager.default
        return wm.fileExists(atPath: root.appendingPathComponent("scripts/photo-window.sh").path)
            && wm.fileExists(atPath: root.appendingPathComponent("scripts/depth-window.swift").path)
            && wm.fileExists(atPath: root.appendingPathComponent("Makefile").path)
    }

    static func accepts(_ url: URL) -> Bool {
        url.isFileURL && ["jpg", "jpeg", "png", "heic"].contains(url.pathExtension.lowercased())
    }

    static func choosePhoto() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Runs off the main thread. Finding a ready install must not start a
    /// 2.8 GB SHARP weights download, or move any existing model.
    static func readyMode(root: URL) -> Mode? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let models = home.appendingPathComponent("models", isDirectory: true)
        var locations = [models, root.appendingPathComponent("tools", isDirectory: true)]
        if let common = try? run("/usr/bin/git", ["rev-parse", "--path-format=absolute", "--git-common-dir"], root: root),
           common.hasPrefix("/") {
            locations.append(URL(fileURLWithPath: common).deletingLastPathComponent()
                .appendingPathComponent("tools", isDirectory: true))
        }
        if let custom = ProcessInfo.processInfo.environment["LERP_TOOLS"], custom.hasPrefix("/") {
            locations.insert(URL(fileURLWithPath: custom, isDirectory: true), at: 0)
        }
        let fm = FileManager.default
        for dir in locations {
            let sharp = dir.appendingPathComponent("ml-sharp")
            if fm.isExecutableFile(atPath: sharp.appendingPathComponent(".venv/bin/sharp").path),
               fm.fileExists(atPath: sharp.appendingPathComponent("weights/sharp_2572gikvuh.pt").path) {
                return .sharp(tools: dir)
            }
        }
        return nil
    }

    static func offerDepthFallback() -> Mode? {
        let alert = NSAlert()
        alert.messageText = "Use a lighter depth window?"
        alert.informativeText = "Apple SHARP isn't set up in this checkout. The depth window processes your photo on this Mac using a smaller model (about 50 MB on first use)."
        alert.addButton(withTitle: "Make Depth Window")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let model = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("models/depth-anything-v2-small", isDirectory: true)
        return .depth(model: model)
    }

    static func generate(photo: URL, root: URL, mode: Mode) throws -> String {
        let suffix = String(UUID().uuidString.lowercased().prefix(12))
        let stem = photo.deletingPathExtension().lastPathComponent.lowercased()
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let slug = stem.components(separatedBy: letters.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let name = (slug.isEmpty ? "photo" : String(slug.prefix(40))) + "-" + suffix
        // The depth target interpolates its IMAGE variable in a shell recipe.
        // Pass only this generated, shell-safe path, never the user's filename.
        let temp = URL(fileURLWithPath: "/tmp/lerp-import-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let input: URL
        if photo.pathExtension.lowercased() == "heic" {
            input = temp.appendingPathComponent("photo.jpg")
            _ = try run("/usr/bin/sips", ["-s", "format", "jpeg", photo.path, "--out", input.path], root: root)
        } else {
            input = temp.appendingPathComponent("photo." + photo.pathExtension.lowercased())
            try fm.copyItem(at: photo, to: input)
        }
        switch mode {
        case .sharp(let tools):
            _ = try run("/bin/bash", [root.appendingPathComponent("scripts/photo-window.sh").path, input.path, name],
                        root: root, extraEnvironment: ["LERP_TOOLS": tools.path])
            return "splat-photo-\(name)"
        case .depth(let model):
            // Make's model targets don't escape spaces in target names. The
            // standard ~/models path is fine unless the user's home has one.
            let safePath = CharacterSet(charactersIn: "/._-abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            guard model.path.unicodeScalars.allSatisfy(safePath.contains) else {
                throw Failure(output: "The model folder path contains characters the depth helper cannot use.")
            }
            _ = try run("/usr/bin/make", ["depth-window", "IMAGE=\(input.path)", "NAME=\(name)",
                                        "DEPTH_MODEL_DIR=\(model.path)"], root: root)
            return "depth-window-\(name)"
        }
    }

    struct Failure: LocalizedError {
        let output: String
        var errorDescription: String? { output }
    }

    /// Drain while the child runs (model downloads and inference can write
    /// more than the capacity of a pipe), keeping only the tail for errors.
    private static func run(_ executable: String, _ args: [String], root: URL,
                            extraEnvironment: [String: String] = [:]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = root
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        for (key, value) in extraEnvironment { environment[key] = value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        var output = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            output.append(chunk)
            if output.count > 8_192 { output.removeFirst(output.count - 8_192) }
        }
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw Failure(output: text.isEmpty ? "Photo helper exited with status \(process.terminationStatus)." : text)
        }
        return text
    }
}

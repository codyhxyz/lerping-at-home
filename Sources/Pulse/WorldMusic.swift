import AppKit
import ImageIO

struct WorldMusic: Codable, Equatable {
    var playing = false
    var title = "", artist = "", album = "", source = "", trackUri = ""
    var palette: [[Double]] = []
}

private struct SpotAPIUpdate: Decodable {
    var playing: Bool?
    let title, artist, album, trackUri, image_url: String
    var updatedAt: Double?
}

struct WorldTrack: Equatable {
    var music: WorldMusic
    var imageURL: URL?
    var imageData: Data?

    var key: [String] { [music.source, music.trackUri, music.title, music.artist, music.album] }

    static func local(_ info: [AnyHashable: Any], source: String, previous: Self?) -> Self? {
        func string(_ keys: String...) -> String {
            for key in keys {
                if let value = info[key] as? String, !value.isEmpty { return String(value.prefix(1024)) }
            }
            return ""
        }
        let state = string("Player State", "Playback State").lowercased()
        let playing: Bool
        switch state {
        case "playing": playing = true
        case "paused": playing = false
        case "stopped": return Self(music: WorldMusic(source: source))
        default: return nil
        }
        let title = string("Name", "Track Name"), artist = string("Artist"), album = string("Album")
        let uri = source == "spotify" ? string("Track ID", "Track URI") : ""
        let sameTrack = previous.map {
            (uri.isEmpty || $0.music.trackUri.isEmpty || $0.music.trackUri == uri)
                && (title.isEmpty || $0.music.title == title)
                && (artist.isEmpty || $0.music.artist == artist)
                && (album.isEmpty || $0.music.album == album)
        } ?? false
        let prior = sameTrack ? previous : nil
        let metadata = WorldMusic(playing: playing, title: title.isEmpty ? prior?.music.title ?? "" : title,
            artist: artist.isEmpty ? prior?.music.artist ?? "" : artist, album: album.isEmpty ? prior?.music.album ?? "" : album,
            source: source, trackUri: uri.isEmpty ? prior?.music.trackUri ?? "" : uri)
        // Never read a file or load an arbitrary remote URL supplied by IPC.
        let art = string("Artwork URL", "ArtworkURL", "Album Artwork URL", "Album Artwork", "Artwork")
        let data = (info["Artwork Data"] ?? info["Artwork"] ?? info["Album Artwork"]) as? Data
        return Self(music: metadata, imageURL: WorldArtwork.url(art) ?? prior?.imageURL,
                    imageData: data.flatMap { $0.count <= WorldArtwork.byteLimit ? $0 : nil } ?? prior?.imageData)
    }

    fileprivate init(_ update: SpotAPIUpdate) {
        let hasTrack = !update.trackUri.isEmpty || !update.title.isEmpty
        music = WorldMusic(playing: update.playing == true && hasTrack, title: update.title, artist: update.artist,
                           album: update.album, source: hasTrack ? "spotify-connect" : "", trackUri: update.trackUri)
        imageURL = WorldArtwork.url(update.image_url)
    }

    init(music: WorldMusic, imageURL: URL? = nil, imageData: Data? = nil) {
        self.music = music
        self.imageURL = imageURL
        self.imageData = imageData
    }
}

/// Local players announce changes without Apple Events, Accessibility or
/// system-audio capture. Connect is an opt-in input, not a player controller.
final class WorldMusicMonitor {
    private struct Local {
        let track: WorldTrack
        let seen: Date
    }
    private var local: [String: Local] = [:]
    private var remote: WorldTrack?
    private var current: WorldTrack?
    private var palette: [[Double]] = []
    private var artworkTask: Task<Void, Never>?
    private var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var terminationObserver: NSObjectProtocol?
    private var timer: Timer?
    private let bridge: WorldSpotAPIBridge?
    private let watchConnect: Bool
    private let connectURL: URL
    private var watchRetry = Date.distantPast
    private var enrichmentRetry = Date.distantPast
    private var watchProcess: Process?
    private var enrichmentProcess: Process?

    init(folder: URL, settings: WorldSettings) {
        connectURL = folder.appendingPathComponent("world-spotify-connect.json")
        bridge = WorldSpotAPIBridge(folder: folder, settings: settings)
        watchConnect = settings.spotAPIWatchConnect == true
    }

    deinit {
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        terminationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        timer?.invalidate()
        if let watchProcess, watchProcess.isRunning { watchProcess.terminate() }
        if let enrichmentProcess, enrichmentProcess.isRunning { enrichmentProcess.terminate() }
        artworkTask?.cancel()
    }

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let names = ["spotify": "com.spotify.client.PlaybackStateChanged", "apple-music": "com.apple.Music.playerInfo"]
        for (source, name) in names {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name),
                                                                               object: nil, queue: .main) { [weak self] note in
                guard let self, let values = note.userInfo,
                      let track = WorldTrack.local(values, source: source, previous: self.local[source]?.track)
                else { return }
                self.local[source] = Local(track: track, seen: Date())
                self.selectTrack()
            })
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                                                object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let source = names.first(where: { $0.value.hasPrefix((app.bundleIdentifier ?? "-") + ".") })?.key
            else { return }
            self.local[source] = nil
            self.selectTrack()
        }
        if watchConnect, bridge != nil {
            let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.tick(now: Date()) }
            timer.tolerance = 1
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func tick(now: Date) {
        guard watchConnect, let bridge else { return }
        if watchProcess == nil, now >= watchRetry {
            watchRetry = now.addingTimeInterval(15 * 60)
            watchProcess = bridge.watch(to: connectURL) { [weak self] in
                self?.watchProcess = nil
                self?.watchRetry = Date().addingTimeInterval(15 * 60)
            }
        }
        remote = Self.connectTrack(from: connectURL, now: now)
        selectTrack()
    }

    func snapshot() -> WorldMusic {
        var result = current?.music ?? WorldMusic()
        result.palette = palette
        return result
    }

    static func probe(folder: URL, settings: WorldSettings, now: Date) -> WorldMusic {
        struct Published: Decodable {
            let version: Int
            let updatedAt: Double
            let music: WorldMusic
        }
        // Notifications do not replay playback already in progress to a new
        // process. Use the daemon's current observation if it is running.
        if let data = try? Data(contentsOf: folder.appendingPathComponent("world.json")), data.count <= 65_536,
           let published = try? JSONDecoder().decode(Published.self, from: data), published.version == 1,
           (-5...90).contains(now.timeIntervalSince1970 - published.updatedAt),
           published.music.source != "spotify-connect" || settings.spotAPIWatchConnect == true {
            return published.music
        }
        if settings.spotAPIWatchConnect == true,
           let remote = connectTrack(from: folder.appendingPathComponent("world-spotify-connect.json"), now: now) {
            return remote.music
        }
        return WorldMusic()
    }

    private static func connectTrack(from url: URL, now: Date) -> WorldTrack? {
        guard let data = try? Data(contentsOf: url), data.count <= 16384,
              let update = try? JSONDecoder().decode(SpotAPIUpdate.self, from: data),
              let stamp = update.updatedAt, (-5...25).contains(now.timeIntervalSince1970 - stamp)
        else { return nil }
        return WorldTrack(update)
    }

    private func selectTrack() {
        let recent = local.values.sorted { $0.seen > $1.seen }.map(\.track)
        // Active local playback takes priority over remote or paused playback.
        let next = recent.first(where: { $0.music.playing }) ?? (remote?.music.playing == true ? remote : nil)
            ?? recent.first(where: { !$0.music.title.isEmpty || !$0.music.trackUri.isEmpty }) ?? remote
        guard current != next else { return }
        let changed = current?.key != next?.key || current?.imageURL != next?.imageURL || current?.imageData != next?.imageData
        current = next
        if changed {
            palette = []
            artworkTask?.cancel()
            artworkTask = nil
            if let next { loadPalette(for: next) }
        }
        onChange?()
    }

    private func loadPalette(for track: WorldTrack) {
        if let bytes = track.imageData, let colors = WorldArtwork.palette(bytes) {
            palette = colors
        } else if let url = track.imageURL {
            downloadPalette(url, key: track.key)
        } else if track.music.source.hasPrefix("spotify"), let bridge, Date() >= enrichmentRetry, enrichmentProcess == nil {
            let uri = track.music.trackUri
            guard uri.isEmpty || uri.hasPrefix("spotify:track:") else { return }
            let query = uri.isEmpty ? [track.music.artist, track.music.title].joined(separator: " ") : uri
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            enrichmentProcess = bridge.enrich(query) { [weak self] update in
                guard let self else { return }
                self.enrichmentProcess = nil
                if update == nil { self.enrichmentRetry = Date().addingTimeInterval(30 * 60) }
                guard let update, let current = self.current, current.imageURL == nil, current.imageData == nil else { return }
                if current.key != track.key { self.loadPalette(for: current) }
                else if let url = WorldArtwork.url(update.image_url) { self.downloadPalette(url, key: track.key) }
            }
            if enrichmentProcess == nil { enrichmentRetry = Date().addingTimeInterval(30 * 60) }
        }
    }

    private func downloadPalette(_ url: URL, key: [String]) {
        artworkTask = Task { @MainActor [weak self] in
            guard let data = await WorldDownload.get(url, byteLimit: WorldArtwork.byteLimit),
                  !Task.isCancelled, let colors = WorldArtwork.palette(data), let self,
                  self.current?.key == key, self.current?.imageURL == url || self.current?.imageURL == nil else { return }
            self.palette = colors
            self.onChange?()
        }
    }
}

struct WorldArtwork {
    static let byteLimit = 4 * 1024 * 1024

    static func url(_ text: String) -> URL? {
        if text.hasPrefix("spotify:image:") {
            let id = text.dropFirst("spotify:image:".count)
            if id.count == 40, id.allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) {
                return URL(string: "https://i.scdn.co/image/\(id)")
            }
        }
        guard let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), components.port == nil, components.user == nil,
              components.password == nil, host == "i.scdn.co" || host.hasSuffix(".spotifycdn.com")
                || host.hasSuffix(".scdn.co") || host.hasSuffix(".mzstatic.com") else { return nil }
        return components.url
    }

    static func palette(_ data: Data) -> [[Double]]? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 48]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let n = 48
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                          bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return drawn ? palette(rgba: pixels) : nil
    }

    static func palette(rgba pixels: [UInt8]) -> [[Double]]? {
        var bins: [Int: (count: Int, sum: SIMD3<Double>)] = [:]
        for i in stride(from: 0, to: pixels.count - 3, by: 4) {
            let alpha = Double(pixels[i + 3])
            guard alpha >= 128 else { continue }
            let rgb = SIMD3(Double(pixels[i]) / alpha, Double(pixels[i + 1]) / alpha, Double(pixels[i + 2]) / alpha)
            let r = Int(worldUnit(rgb.x) * 15), g = Int(worldUnit(rgb.y) * 15), b = Int(worldUnit(rgb.z) * 15)
            let key = (r << 8) | (g << 4) | b
            let bin = bins[key] ?? (0, .zero)
            bins[key] = (bin.count + 1, bin.sum + rgb)
        }
        let ranked = bins.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        var chosen: [SIMD3<Double>] = []
        for (_, bin) in ranked {
            let rgb = bin.sum / Double(bin.count)
            if chosen.contains(where: { c in
                let d = c - rgb
                return d.x * d.x + d.y * d.y + d.z * d.z < 0.0225
            }) { continue }
            chosen.append(rgb)
            if chosen.count == 3 { break }
        }
        guard let last = chosen.last else { return nil }
        while chosen.count < 3 { chosen.append(last) }
        func luminance(_ c: SIMD3<Double>) -> Double { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }
        return chosen.sorted { luminance($0) > luminance($1) }.map { [worldUnit($0.x), worldUnit($0.y), worldUnit($0.z), 1] }
    }
}

private struct WorldSpotAPIBridge {
    let script: URL
    let python: URL
    let profile: String?

    init?(folder: URL, settings: WorldSettings) {
        let fm = FileManager.default
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let candidates = [folder.appendingPathComponent("Pulse/spotapi-bridge.py"),
                          executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/spotapi-bridge.py")]
        let scripts = settings.spotAPIBridge.map { [URL(fileURLWithPath: $0)] } ?? candidates
        let interpreters = settings.spotAPIPython.map { [$0] } ?? ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let script = scripts.first(where: { fm.isReadableFile(atPath: $0.path) }),
              let python = interpreters.first(where: { fm.isExecutableFile(atPath: $0) }) else { return nil }
        self.script = script
        self.python = URL(fileURLWithPath: python)
        profile = settings.spotAPIProfile
    }

    func watch(to url: URL, finished: @escaping () -> Void) -> Process? {
        var args = ["--watch-connect", "--output", url.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        if let profile { args += ["--profile", profile] }
        let process = makeProcess(args, allowCookie: true)
        process.terminationHandler = { _ in DispatchQueue.main.async(execute: finished) }
        return launch(process)
    }

    func enrich(_ query: String, finished: @escaping (SpotAPIUpdate?) -> Void) -> Process? {
        let process = makeProcess(["--enrich-track=\(query)"], allowCookie: false)
        let pipe = Pipe()
        process.standardOutput = pipe
        // Read concurrently so the helper can always exit even if its payload
        // would fill a pipe. Its JSON is intentionally capped on both sides.
        guard let launched = launch(process) else { return nil }
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            launched.waitUntilExit()
            let update = launched.terminationStatus == 0 && data.count <= 16_384
                ? try? JSONDecoder().decode(SpotAPIUpdate.self, from: data) : nil
            DispatchQueue.main.async { finished(update) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak launched] in
            if let launched, launched.isRunning { launched.terminate() }
        }
        return launched
    }

    private func makeProcess(_ args: [String], allowCookie: Bool) -> Process {
        let process = Process()
        process.executableURL = python
        process.arguments = [script.path] + args
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if !allowCookie { environment["SPOTIFY_COOKIE"] = nil }
        process.environment = environment
        return process
    }

    private func launch(_ process: Process) -> Process? {
        do { try process.run(); return process } catch { return nil }
    }
}

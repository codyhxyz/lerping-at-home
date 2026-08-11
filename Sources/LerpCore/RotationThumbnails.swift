import AppKit
import Metal

/// Preview stills for the rotation gallery: one per (shader, preset), rendered
/// offscreen through the same `LerpSnapshot` path the screensaver's wallpaper
/// handoff uses, cached on disk, and delivered to the UI as they arrive.
///
/// ## Why this is not just a loop
///
/// A 240×360 still costs ~65 ms, and there are 123 of them. Rendering them
/// serially on the main thread would take ~7 s with the window frozen, which is
/// not a thing a window is allowed to do. So:
///
/// - **Nothing blocks.** `start` returns immediately; tiles fill in as their
///   images land, in whatever order they land.
/// - **Cheapest source first.** Memory, then the read-only stills baked into the
///   host bundle, then the writable cache, then — only for what none of those
///   had — the GPU.
/// - **Then parallel.** The misses are grouped by shader and dealt round-robin
///   to a small pool of workers, each with a `ShaderLibrary` and `LerpRenderer`
///   of its own (neither is thread-safe; a `MTLDevice` is). Grouping by shader
///   matters: pipeline compilation dominates the cost, and one worker taking a
///   whole shader compiles it once for all of its presets.
///
/// ## Why the cache key is what it is
///
/// A frame is a pure function of (shader source, parameters, time, seed, size),
/// so the key is exactly that: the entry, a stable hash of the shader's *source
/// text*, and the recipe. Editing one `.metal` file changes that file's hash and
/// therefore misses only that shader's tiles — every other shader keeps its
/// cached stills. The hash is FNV-1a rather than `String.hashValue`, which is
/// seeded per process and would invalidate the whole cache on every launch.
///
/// That one property is also what makes the bundled tier safe. `make saver`
/// renders the stills into `Contents/Resources/Thumbnails` under exactly these
/// filenames, so a baked still and a freshly rendered one are the same file for
/// the same shader source — and a `.metal` that has been changed without its
/// still being redrawn simply misses, and is drawn at runtime. A stale bundled
/// still cannot be shown, because a stale one has a different name.
///
/// The stills are rendered at a fixed `time` and `seed` so they are the same
/// pictures every time the gallery opens, and so two hosts agree about what a
/// look looks like.
public final class RotationThumbnails {

    /// Everything that goes into a still besides the shader itself. `version`
    /// exists so a change to how stills are made can invalidate the cache
    /// without anyone having to find and delete it.
    public struct Recipe {
        public var width = 240
        public var height = 360
        /// Far enough in that nothing is still easing out of its t=0 pose.
        public var time: Float = 6
        /// Fixed, so a tile is the same picture on every launch.
        public var seed: Float = 0.37
        public var version = 1

        public init() {}

        public var token: String { "\(width)x\(height)-t\(time)-s\(seed)-v\(version)" }
    }

    /// One thing to draw: the rotation entry and the shader it belongs to.
    public struct Job {
        public let entry: LerpRotationEntry
        public let shader: LerpShader

        public init(entry: LerpRotationEntry, shader: LerpShader) {
            self.entry = entry
            self.shader = shader
        }
    }

    /// Every look these shaders offer, paired with the shader it came from —
    /// the whole work list, in rotation order.
    public static func jobs(for shaders: [LerpShader]) -> [Job] {
        let byName = Dictionary(uniqueKeysWithValues: shaders.map { ($0.name, $0) })
        return shaders.rotationEntries().compactMap { entry in
            byName[entry.shader].map { Job(entry: entry, shader: $0) }
        }
    }

    public let recipe: Recipe
    private let searchURLs: [URL]
    private let directory: URL
    /// Directories searched for a ready-made still but never written to: the
    /// stills baked into the host bundle. See `bundledDirectory(in:)`.
    private let readOnlyDirectories: [URL]

    /// Decoded stills, keyed the same way the files are. Held so a filter
    /// change or a window resize redraws instantly.
    private var memory: [String: NSImage] = [:]

    /// Bumped by every `start` and every `cancel`; a delivery from an older
    /// generation is dropped rather than painted over the new one.
    private var generation = 0

    /// Reported in the host log: how many stills came off disk versus how many
    /// the GPU had to draw. A warm gallery is all hits.
    private(set) public var diskHits = 0
    /// The part of `diskHits` that came out of the host bundle rather than out
    /// of the writable cache — inside the screensaver's sandbox that is the
    /// number that matters, because it is the work the GPU did not have to do.
    private(set) public var bundledHits = 0
    private(set) public var memoryHits = 0
    private(set) public var rendered = 0
    private(set) public var failed: [String] = []
    private let queue = DispatchQueue(label: "lerping.rotation.thumbnails", qos: .userInitiated)
    private let lock = NSLock()

    public init(searchURLs: [URL], recipe: Recipe = Recipe(), directory: URL? = nil,
                readOnlyDirectories: [URL] = []) {
        self.searchURLs = searchURLs
        self.recipe = recipe
        self.directory = directory ?? Self.defaultDirectory
        self.readOnlyDirectories = readOnlyDirectories
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Where the cache lives

    /// `~/Library/Caches/<bundle id>/RotationThumbnails`: regenerable data,
    /// outside the repo and scoped to its host app.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let id = Bundle.main.bundleIdentifier ?? "com.hergenroeder.lerping.playground"
        return base.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("RotationThumbnails", isDirectory: true)
    }

    /// A cache directory a *sandboxed* host can actually write.
    ///
    /// The screensaver's Options… sheet is built inside `legacyScreenSaver`,
    /// which is App Sandboxed. `NSHomeDirectory()` there is the sandbox
    /// container, and the container is the only place it may write — the real
    /// `~/Library` is denied, exactly as it is for the wallpaper handoff (see
    /// `LerpSaverView.writableWallpaperDirectory`). The real home is kept as a
    /// second candidate so an unsandboxed host such as the preview app lands
    /// somewhere sensible instead of nowhere.
    ///
    /// Each candidate is probed by writing a file, because "the sandbox will let
    /// me write here" is not something to assume.
    public static func writableCacheDirectory(named name: String) -> URL? {
        LerpFileLocations.writableHomeDirectory(appending: "Library/Caches/" + name)
    }

    /// Where a host bundle keeps the stills that were rendered into it at build
    /// time. `Bundle(for:)` is the `.saver` bundle when this code is linked into
    /// it; `Bundle.main` covers the plain executables, where the two differ —
    /// the same pair `ShaderLibrary.builtInDirectory` walks, for the same
    /// reason.
    public static func bundledDirectories() -> [URL] {
        var out: [URL] = []
        for bundle in [Bundle(for: RotationThumbnails.self), Bundle.main] {
            guard let url = bundle.resourceURL?.appendingPathComponent(bundledFolder),
                  FileManager.default.fileExists(atPath: url.path),
                  !out.contains(url) else { continue }
            out.append(url)
        }
        return out
    }

    /// The folder name `make saver` renders into and `bundledDirectories()`
    /// looks for. One constant, so the Makefile and the lookup cannot drift.
    public static let bundledFolder = "Thumbnails"

    public var cacheDirectory: URL { directory }

    /// Deterministic 64-bit FNV-1a. `String.hashValue` is seeded per process, so
    /// using it here would mean a cold cache on every single launch.
    public static func hash(_ text: String) -> String {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return String(format: "%016llx", value)
    }

    /// Ordered shader identity used to decide whether a gallery needs reloading.
    public static func fingerprint(for shaders: [LerpShader]) -> String {
        shaders.map { $0.name + ":" + hash($0.source) }.joined(separator: ",")
    }

    /// The cache key for a look: what it is, what its shader's source says, and
    /// how the still is made. Any of the three changing is a different picture.
    public func key(entry: LerpRotationEntry, source: String) -> String {
        Self.hash(entry.key + "\u{1}" + source + "\u{1}" + recipe.token)
    }

    /// `voronoi-Molten-4f0c….png` — the hash is what makes it unique; the
    /// readable part is so the cache directory can be looked at by a human.
    public func fileName(entry: LerpRotationEntry, source: String) -> String {
        Self.slug(entry.shader) + "-" + Self.slug(entry.preset ?? "defaults")
            + "-" + key(entry: entry, source: source) + ".png"
    }

    /// Where this still is written. Always the writable directory: the bundled
    /// tier is read at `existingURL`, never written.
    public func url(entry: LerpRotationEntry, source: String) -> URL {
        directory.appendingPathComponent(fileName(entry: entry, source: source))
    }

    /// The first tier that already holds this still, or nil. The writable cache
    /// comes first only because a still rendered this session is the one most
    /// likely to be warm in the page cache; the two are the same picture by
    /// construction, since the filename carries the source hash.
    public func existingURL(entry: LerpRotationEntry, source: String) -> URL? {
        let name = fileName(entry: entry, source: source)
        for dir in [directory] + readOnlyDirectories {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func slug(_ text: String) -> String {
        let out = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(out).prefix(28))
    }

    // MARK: - Lookup

    /// The still for a look if it is already decoded, without touching the disk.
    public func image(entry: LerpRotationEntry, source: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        return memory[key(entry: entry, source: source)]
    }

    // MARK: - Running

    /// Fills in every job's still, cheapest source first, without blocking.
    ///
    /// `onImage` and `onFinished` are called on the main queue. Calling `start`
    /// again supersedes the run in flight.
    public func start(_ jobs: [Job],
                      onImage: @escaping (LerpRotationEntry, NSImage) -> Void,
                      onProgress: @escaping (_ done: Int, _ total: Int) -> Void,
                      onFinished: @escaping () -> Void) {
        lock.lock()
        generation += 1
        let run = generation
        diskHits = 0; bundledHits = 0; memoryHits = 0; rendered = 0; failed = []
        // Deliver what is already decoded before anything touches the disk, so
        // a filter change or a reopen paints instantly.
        var pending: [Job] = []
        var warm: [(LerpRotationEntry, NSImage)] = []
        for job in jobs {
            if let image = memory[key(entry: job.entry, source: job.shader.source)] {
                warm.append((job.entry, image))
            } else {
                pending.append(job)
            }
        }
        memoryHits = warm.count
        lock.unlock()

        let total = jobs.count
        var done = warm.count
        DispatchQueue.main.async {
            guard self.isCurrent(run) else { return }
            warm.forEach { onImage($0.0, $0.1) }
            onProgress(done, total)
            if pending.isEmpty { self.finish(run: run, onFinished: onFinished) }
        }
        guard !pending.isEmpty else { return }

        /// One delivery. Counts, then hands the image to the UI.
        func deliver(_ entry: LerpRotationEntry, _ image: NSImage) {
            DispatchQueue.main.async {
                guard self.isCurrent(run) else { return }
                done += 1
                onImage(entry, image)
                onProgress(done, total)
            }
        }

        queue.async {
            // Phase 1 — the disk, bundle included. A whole warm gallery lands
            // here, and inside the screensaver's sandbox so does a cold one.
            var misses: [Job] = []
            for job in pending {
                guard self.isCurrent(run) else { return }
                let key = self.key(entry: job.entry, source: job.shader.source)
                guard let url = self.existingURL(entry: job.entry, source: job.shader.source),
                      let image = NSImage(contentsOf: url), image.isValid else {
                    // A half-written file from an interrupted run reads as a
                    // miss and is drawn again, rather than as a broken tile.
                    try? FileManager.default.removeItem(
                        at: self.url(entry: job.entry, source: job.shader.source))
                    misses.append(job)
                    continue
                }
                self.store(image, forKey: key)
                self.countDiskHit(bundled: !url.path.hasPrefix(self.directory.path))
                deliver(job.entry, image)
            }

            // Phase 2 — the GPU, in parallel, a shader at a time.
            self.render(misses, run: run, deliver: deliver)

            self.prune(expected: Set(jobs.map {
                self.fileName(entry: $0.entry, source: $0.shader.source)
            }))
            DispatchQueue.main.async {
                self.finish(run: run, onFinished: onFinished)
            }
        }
    }

    /// Renders whatever is missing and returns when it is done — what
    /// `LerpPreview --thumbnails` uses to bake the stills into the `.saver`
    /// bundle at build time. Same key, same files, same pictures as the runtime
    /// path, because it is the runtime path.
    @discardableResult
    public func renderMissing(_ jobs: [Job]) -> (rendered: Int, cached: Int, failed: [String]) {
        lock.lock()
        generation += 1
        let run = generation
        rendered = 0; diskHits = 0; bundledHits = 0; memoryHits = 0; failed = []
        lock.unlock()

        var misses: [Job] = []
        for job in jobs {
            if existingURL(entry: job.entry, source: job.shader.source) != nil {
                countDiskHit(bundled: false)
            } else {
                misses.append(job)
            }
        }
        render(misses, run: run, deliver: { _, _ in })
        prune(expected: Set(jobs.map { fileName(entry: $0.entry, source: $0.shader.source) }))
        return (rendered, diskHits, failed)
    }

    /// Drops any run in flight. Deliveries already queued are discarded.
    public func cancel() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    /// Forgets every still it owns, on disk and in memory, so the next `start`
    /// redraws all of them. What the gallery's Regenerate button does. The
    /// bundled tier is not ours to delete and is left alone — a bundled still is
    /// exactly as correct as a rendered one, so there is nothing to gain.
    public func evictAll() {
        cancel()
        lock.lock()
        memory.removeAll()
        lock.unlock()
        let directory = self.directory
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension == "png" {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Internals

    private func isCurrent(_ run: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == run
    }

    private func store(_ image: NSImage, forKey key: String) {
        lock.lock(); memory[key] = image; lock.unlock()
    }

    private func countDiskHit(bundled: Bool) {
        lock.lock()
        diskHits += 1
        if bundled { bundledHits += 1 }
        lock.unlock()
    }

    private func countRender() { lock.lock(); rendered += 1; lock.unlock() }

    private func finish(run: Int, onFinished: () -> Void) {
        guard isCurrent(run) else { return }
        onFinished()
    }

    /// Renders the misses across a small pool. Each worker owns its own library
    /// and renderer — `ShaderLibrary` caches pipelines in a plain dictionary and
    /// `LerpRenderer` owns a command queue, so neither may be shared — while the
    /// `MTLDevice` underneath them is shared and thread-safe.
    private func render(_ jobs: [Job], run: Int,
                        deliver: (LerpRotationEntry, NSImage) -> Void) {
        guard !jobs.isEmpty else { return }
        // Grouped by shader, in first-seen order, so a worker that takes a
        // shader compiles its pipeline once and reuses it for every preset.
        var order: [String] = []
        var groups: [String: [Job]] = [:]
        for job in jobs {
            if groups[job.shader.name] == nil { order.append(job.shader.name) }
            groups[job.shader.name, default: []].append(job)
        }
        let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        DispatchQueue.concurrentPerform(iterations: min(workers, order.count)) { slot in
            guard let renderer = LerpRenderer() else { return }
            let library = ShaderLibrary(device: renderer.device, extraSearchURLs: searchURLs)
            var index = slot
            while index < order.count {
                guard isCurrent(run) else { return }
                for job in groups[order[index]] ?? [] {
                    guard isCurrent(run) else { return }
                    let values = job.shader.parameterValues(for: job.entry)
                    let url = url(entry: job.entry, source: job.shader.source)
                    let result = LerpSnapshot.render(shader: job.shader, library: library,
                                                     renderer: renderer,
                                                     width: recipe.width, height: recipe.height,
                                                     time: recipe.time, seed: recipe.seed,
                                                     params: values, to: url)
                    guard result.error == nil, let image = NSImage(contentsOf: url), image.isValid else {
                        lock.lock()
                        failed.append(job.entry.key + ": " + (result.error ?? "unreadable PNG"))
                        lock.unlock()
                        continue
                    }
                    store(image, forKey: key(entry: job.entry, source: job.shader.source))
                    countRender()
                    deliver(job.entry, image)
                }
                index += workers
            }
        }
    }

    /// Drops cache files no current look claims — which is how a shader that was
    /// edited stops paying rent for the still of the version before the edit.
    /// Only ever in the writable directory; the bundle is not ours.
    private func prune(expected: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "png" && !expected.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

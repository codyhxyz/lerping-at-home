import Foundation
import simd

/// A capture author's own camera path: the keyframed fly-through a SuperSplat
/// scene plays when it opens (its `settings.json` `animTracks`), as
/// `scripts/splat-convert.py` writes it beside the capture — `<capture>.path.json`,
/// already taken into the capture's Lerping frame.
///
/// Played the way SuperSplat's viewer plays it, so the move is the one the
/// author drew: a cubic Hermite spline through position, target and field of
/// view together (`CubicSpline` in supersplat-viewer, tangents scaled by the
/// track's smoothness), and the same cursor — `repeat` wraps the path's end
/// round to its start; `pingpong` and `none` run it there and back, since a
/// screensaver that stopped on the last key would be a still.
struct LerpSplatPath: Decodable {
    var duration: Float
    var frameRate: Float
    var loopMode: String
    var smoothness: Float
    var up: SIMD3<Float>
    var times: [Float]
    var position: [SIMD3<Float>]
    var target: [SIMD3<Float>]
    /// Degrees, across the wider side of the frame (PlayCanvas's
    /// `horizontalFov` on a landscape screen, which is how SuperSplat sets it).
    var fov: [Float]

    struct Pose { var eye: SIMD3<Float>; var target: SIMD3<Float>; var fov: Float }

    /// The pose `seconds` into the path.
    func pose(at seconds: Float) -> Pose {
        let d = max(1e-3, duration)
        let cursor: Float
        if loopMode == "repeat" {
            cursor = seconds - d * floor(seconds / d)
        } else {
            let c = seconds - 2 * d * floor(seconds / (2 * d))
            cursor = c > d ? 2 * d - c : c
        }
        return evaluate(cursor * frameRate)
    }

    /// Knots as `CubicSpline.fromPoints` / `fromPointsLooping` lay them out:
    /// a repeating track gets the last two keys copied before its start and
    /// the first two after its end, so the wrap is as smooth as the rest.
    private var knots: (times: [Float], points: [[Float]]) {
        let n = min(times.count, position.count, target.count, fov.count)
        var t = Array(times.prefix(n))
        var p = (0..<n).map { i in
            [position[i].x, position[i].y, position[i].z, target[i].x, target[i].y, target[i].z, fov[i]]
        }
        if loopMode == "repeat", n >= 2 {
            // supersplat-viewer: one more frame of length when the duration
            // ends exactly on the last key, so that key is not the first again.
            let length = Self.repeatLength(duration: duration, frameRate: frameRate, last: t[n - 1])
            t = [t[n - 2] - length, t[n - 1] - length] + t + [length + t[0], length + t[1]]
            p = [p[n - 2], p[n - 1]] + p + [p[0], p[1]]
        }
        return (t, p)
    }

    private func evaluate(_ time: Float) -> Pose {
        let (t, p) = knots
        let n = t.count
        func pose(_ v: [Float]) -> Pose {
            Pose(eye: SIMD3(v[0], v[1], v[2]), target: SIMD3(v[3], v[4], v[5]), fov: v[6])
        }
        guard n >= 2 else { return pose(p.first ?? [0, 0, 3, 0, 0, 0, 60]) }
        if time <= t[0] { return pose(p[0]) }
        if time >= t[n - 1] { return pose(p[n - 1]) }
        var seg = 0
        while time >= t[seg + 1] { seg += 1 }

        // The tangent at key i, per unit of the segment parameter on the side
        // given (`calcKnots`).
        func tangent(_ i: Int, _ j: Int, outgoing: Bool) -> Float {
            let slope: Float
            if i == 0 { slope = (p[1][j] - p[0][j]) / (t[1] - t[0]) }
            else if i == n - 1 { slope = (p[i][j] - p[i - 1][j]) / (t[i] - t[i - 1]) }
            else { slope = (p[i + 1][j] - p[i - 1][j]) / (t[i + 1] - t[i - 1]) }
            let scale: Float
            if outgoing { scale = i < n - 1 ? t[i + 1] - t[i] : t[i] - t[i - 1] }
            else { scale = i > 0 ? t[i] - t[i - 1] : t[1] - t[0] }
            return slope * scale * smoothness
        }
        let u = (time - t[seg]) / (t[seg + 1] - t[seg])
        let u2 = u * u, omu = 1 - u, omu2 = omu * omu
        let v = (0..<7).map { j -> Float in
            let p0 = p[seg][j], p1 = p[seg + 1][j]
            let m0 = tangent(seg, j, outgoing: true), m1 = tangent(seg + 1, j, outgoing: false)
            return p0 * ((1 + 2 * u) * omu2) + m0 * (u * omu2) + p1 * (u2 * (3 - 2 * u)) + m1 * (u2 * (u - 1))
        }
        return pose(v)
    }

    private enum CodingKeys: String, CodingKey {
        case duration, frameRate, loopMode, smoothness, up, times, position, target, fov
    }

    private static let limitsKey = CodingUserInfoKey(rawValue: "lerp.splat-path-limits")!

    static func decode(_ bytes: Data, limits: AssetSafetyLimits = .portableIngress) throws -> Self {
        guard bytes.count <= limits.maxPathBytes else { throw PortableArtifactError.invalid("Camera path exceeds byte limit") }
        let decoder = JSONDecoder()
        decoder.userInfo[limitsKey] = limits
        return try decoder.decode(Self.self, from: bytes)
    }

    init(from decoder: Decoder) throws {
        let limits = (decoder.userInfo[Self.limitsKey] as? AssetSafetyLimits) ?? .portableIngress
        let data = try decoder.container(keyedBy: CodingKeys.self)
        duration = try data.decode(Float.self, forKey: .duration)
        frameRate = try data.decode(Float.self, forKey: .frameRate)
        loopMode = try data.decode(String.self, forKey: .loopMode)
        smoothness = try data.decode(Float.self, forKey: .smoothness)
        up = try data.decode(SIMD3<Float>.self, forKey: .up)
        let invalid = PortableArtifactError.invalid("Invalid camera path timing, keyframes or field of view")
        guard duration.isFinite, duration > 0, (2 * duration).isFinite,
              frameRate.isFinite, frameRate > 0, (duration * frameRate).isFinite,
              smoothness.isFinite, Self.isFinite(up), up != .zero else { throw invalid }

        // Reject the count before allocating the arrays we will interpolate.
        // Some decoders do not supply a count; still cap each incremental read.
        func bounded<T: Decodable>(_ type: T.Type, _ key: CodingKeys, max count: Int) throws -> [T] {
            var input = try data.nestedUnkeyedContainer(forKey: key)
            if let size = input.count, size > count { throw invalid }
            var values: [T] = []
            values.reserveCapacity(input.count ?? 0)
            while !input.isAtEnd {
                guard values.count < count else { throw invalid }
                values.append(try input.decode(type))
            }
            return values
        }
        times = try bounded(Float.self, .times, max: limits.maxPathKeyframes)
        guard !times.isEmpty, times.allSatisfy(\.isFinite),
              zip(times, times.dropFirst()).allSatisfy({ $0 < $1 && ($1 - $0).isFinite }) else { throw invalid }
        let count = times.count
        if loopMode == "repeat", count >= 2 {
            let length = Self.repeatLength(duration: duration, frameRate: frameRate, last: times[count - 1])
            // The four synthetic knots must also be finite and strictly ordered.
            let before = [times[count - 2] - length, times[count - 1] - length, times[0]]
            let after = [times[count - 1], length + times[0], length + times[1]]
            for keys in [before, after] {
                guard keys.allSatisfy(\.isFinite), zip(keys, keys.dropFirst()).allSatisfy({ $0 < $1 }) else { throw invalid }
            }
        }
        position = try bounded(SIMD3<Float>.self, .position, max: count)
        target = try bounded(SIMD3<Float>.self, .target, max: count)
        fov = try bounded(Float.self, .fov, max: count)
        guard position.count == count, target.count == count, fov.count == count,
              position.allSatisfy(Self.isFinite), target.allSatisfy(Self.isFinite),
              fov.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 180 }) else { throw invalid }
    }

    private static func repeatLength(duration: Float, frameRate: Float, last: Float) -> Float {
        let extra: Float = abs(duration - last / frameRate) < 1e-4 ? 1 : 0
        return (duration + extra) * frameRate
    }

    private static func isFinite(_ value: SIMD3<Float>) -> Bool {
        value.x.isFinite && value.y.isFinite && value.z.isFinite
    }

    static func load(_ location: LerpSplatAssets.Location) -> LerpSplatPath? {
        do {
            let (data, limits) = try AssetSafety.readSplatFile(location, isPath: true)
            return try decode(data, limits: limits)
        } catch {
            NSLog("Lerping: camera path %@ is unreadable: %@", location.url.lastPathComponent, "\(error)")
            return nil
        }
    }
}

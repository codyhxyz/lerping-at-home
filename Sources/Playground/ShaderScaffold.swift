import Foundation

// MARK: - Where shaders live

enum ShaderPaths {

    /// The repo's `Sources/Shaders` directory, if we can find it. Tries the
    /// working directory first (that's how `make playground` runs us), then
    /// walks up from the executable so the binary also works when launched
    /// from Finder or a different cwd.
    static func repoShaderDirectory() -> URL? {
        var candidates: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/Shaders"),
        ]
        var dir = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<5 {
            candidates.append(dir.appendingPathComponent("Sources/Shaders"))
            dir = dir.deletingLastPathComponent()
        }
        var isDirectory: ObjCBool = false
        for candidate in candidates
        where FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            && isDirectory.boolValue {
            return candidate.standardizedFileURL
        }
        return nil
    }

    /// `~/Library/Application Support/Lerping/Shaders` — the drop folder the
    /// preview app and screensaver already scan. Used when the repo isn't
    /// around (e.g. the binary was copied elsewhere).
    static var customDirectory: URL {
        ShaderLocations.customShaderDirectories()[0]
    }

    /// Destination for newly scaffolded shaders.
    static func newShaderDirectory() -> URL {
        if let repo = repoShaderDirectory() { return repo }
        try? FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        return customDirectory
    }
}

// MARK: - New shader scaffolding

enum ShaderScaffold {

    /// `My Cool Shader` → `my-cool-shader`. Returns nil if nothing usable is left.
    static func sanitize(name raw: String) -> String? {
        var out = ""
        var lastWasDash = false
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !out.isEmpty && !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    static func displayName(for stem: String) -> String {
        stem.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// PORTING.md asks for a shader-specific prefix on file-local symbols so
    /// nothing collides with the prelude. `smoke-ring` → `SR`.
    static func symbolPrefix(for stem: String) -> String {
        let initials = stem.split(separator: "-").compactMap { $0.first }.map(String.init).joined().uppercased()
        let trimmed = String(initials.prefix(3))
        return trimmed.isEmpty ? "SH" : trimmed
    }

    /// A starter shader that compiles, animates, uses the seed, and dithers —
    /// i.e. it already passes the PORTING.md checklist before you touch it.
    static func template(for stem: String) -> String {
        let prefix = symbolPrefix(for: stem)
        return """
        // \(displayName(for: stem)) — Lerping@Home shader.
        //
        // Contract (PORTING.md): exactly one entry point,
        //   fragment half4 lerpMain(float4 pos [[position]],
        //                          constant LerpUniforms& u [[buffer(0)]])
        // Sources/LerpCore/Prelude.swift is prepended before compilation, so do
        // not redefine anything it declares — prefix file-local helpers instead.
        //
        // Uniforms:  u.resolution (px)  u.time (s)  u.seed ([0,1), per launch)
        // Prelude:   lerpUV, lerpScreenUV, rotate, hash11/21/22, valueNoise,
        //            snoise, glmod/2/3, lerpDither, PI, TWO_PI

        constant float3 \(prefix)_BACKGROUND = float3(0.024, 0.028, 0.055); // near-black indigo
        constant float3 \(prefix)_MID        = float3(0.157, 0.412, 0.545); // dusk teal
        constant float3 \(prefix)_HIGHLIGHT  = float3(0.925, 0.788, 0.545); // warm sand

        // Two octaves of simplex — cheap, and enough to look alive.
        static float \(prefix)Field(float2 p, float t) {
            float n = snoise(p + float2(0.0, 0.15 * t));
            n += 0.5 * snoise(p * 2.1 - float2(0.11 * t, 0.0));
            return n / 1.5;
        }

        fragment half4 lerpMain(float4 pos [[position]], constant LerpUniforms& u [[buffer(0)]]) {
            float2 uv = lerpUV(pos, u.resolution);          // [-1,1] short axis, y up
            float t = 0.35 * u.time + 60.0 * u.seed;        // calm, and seeded per launch

            float n = \(prefix)Field(uv * 1.2, t);
            float band = 0.5 + 0.5 * sin(2.2 * n + 0.6 * t);

            float3 color = mix(\(prefix)_BACKGROUND, \(prefix)_MID, smoothstep(0.05, 0.75, band));
            color = mix(color, \(prefix)_HIGHLIGHT, smoothstep(0.82, 1.0, band) * 0.7);

            // Soft falloff so the corners stay quiet.
            color *= 1.0 - 0.25 * smoothstep(0.6, 1.8, length(uv));

            color = lerpDither(color, pos);
            return half4(half3(color), 1.0h);
        }

        """
    }
}

// MARK: - Compiler diagnostics

struct ShaderDiagnostic {
    let line: Int
    let column: Int
    let severity: String   // "error", "warning", "note"
    let message: String

    var isError: Bool { severity == "error" }

    var display: String {
        String(format: "%4d:%-3d %@: %@", line, column, severity, message)
    }
}

enum ShaderDiagnostics {

    // Metal's runtime compiler reports against the synthetic translation unit
    // "program_source". The prelude ends with `#line 1`, so the numbers it
    // prints already refer to the shader file itself — no offset correction.
    private static let pattern = try! NSRegularExpression(
        pattern: "program_source:(\\d+):(\\d+): (error|warning|note): ([^\\n]*)")

    /// Extracts structured diagnostics plus the raw text to show when nothing
    /// parses (linker errors, missing `lerpMain`, …).
    static func parse(_ error: Error) -> (items: [ShaderDiagnostic], raw: String) {
        let nsError = error as NSError
        var raw = nsError.localizedDescription
        if !raw.contains("program_source") {
            let described = String(describing: error)
            if described.contains("program_source") { raw = described }
        }
        // Metal sometimes stashes the full log here.
        if let log = nsError.userInfo["MTLCompilerLog"] as? String, log.contains("program_source") {
            raw = log
        }

        let full = NSRange(raw.startIndex..., in: raw)
        var items: [ShaderDiagnostic] = []
        pattern.enumerateMatches(in: raw, range: full) { match, _, _ in
            guard let match,
                  let lineRange = Range(match.range(at: 1), in: raw),
                  let columnRange = Range(match.range(at: 2), in: raw),
                  let severityRange = Range(match.range(at: 3), in: raw),
                  let messageRange = Range(match.range(at: 4), in: raw),
                  let line = Int(raw[lineRange]), let column = Int(raw[columnRange]) else { return }
            items.append(ShaderDiagnostic(line: line, column: column,
                                          severity: String(raw[severityRange]),
                                          message: String(raw[messageRange])
                                              .trimmingCharacters(in: .whitespaces)))
        }
        return (items, cleanUp(raw))
    }

    private static func cleanUp(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "program_source:", with: "")
            .replacingOccurrences(of: "Error Domain=MTLLibraryErrorDomain ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summary(items: [ShaderDiagnostic], raw: String) -> String {
        guard !items.isEmpty else { return raw }
        return items.map(\.display).joined(separator: "\n")
    }
}

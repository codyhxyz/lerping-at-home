import Foundation

// MARK: - Where shaders live

enum ShaderPaths {

    /// `~/Library/Application Support/Lerping/Shaders` — the drop folder the
    /// preview app and screensaver already scan.
    static var customDirectory: URL { ShaderLocations.customShaderDirectories()[0] }

    /// Destination for newly scaffolded shaders: the checkout this copy resolved
    /// — the one it walked up to, or the one recorded when it was installed —
    /// otherwise the drop folder.
    static var newShaderDirectory: URL {
        if let repo = RepoLocation.searchURLs.first { return repo }
        try? FileManager.default.createDirectory(at: customDirectory, withIntermediateDirectories: true)
        return customDirectory
    }

    /// Development copies save back into their checkout. The signed standalone
    /// app cannot modify its own bundle, so its first save of a built-in shader
    /// creates the same user-owned override the screensaver already reads.
    static func saveURL(for shader: LerpShader) -> URL {
        if RepoLocation.isStandalone && shader.isBuiltIn {
            return customDirectory.appendingPathComponent(shader.name + ".metal")
        }
        return shader.url ?? newShaderDirectory.appendingPathComponent(shader.name + ".metal")
    }
}

// MARK: - New shader scaffolding

enum ShaderScaffold {

    /// `My Cool Shader` → `my-cool-shader`. Returns nil if nothing usable is left.
    static func sanitize(name raw: String) -> String? {
        var out = ""
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.isEmpty && !out.hasSuffix("-") {
                out.append("-")
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    /// PORTING.md asks for a shader-specific prefix on file-local symbols so
    /// nothing collides with the prelude. `smoke-ring` → `SR`.
    static func symbolPrefix(for stem: String) -> String {
        let initials = stem.split(separator: "-").compactMap(\.first).map(String.init).joined().uppercased()
        return initials.isEmpty ? "SH" : String(initials.prefix(3))
    }

    /// A starter shader that compiles, animates, uses the seed, and dithers —
    /// i.e. it already passes the PORTING.md checklist before you touch it.
    static func template(for stem: String) -> String {
        let prefix = symbolPrefix(for: stem)
        let title = LerpShader(name: stem, source: "", isBuiltIn: false, url: nil).displayName
        return """
        // \(title) — Lerping@Home shader. Contract in PORTING.md:
        // exactly one entry point, `lerpMain`, and no redefinition of anything
        // Sources/LerpCore/Prelude.swift declares (prefix file-local helpers).
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

// MARK: - Preset authoring

/// Where a new `// lerp-preset:` block goes in a file that already exists.
///
/// Deliberately separate from `LerpPresetWriter`, which decides what the block
/// *says*: that is a question about values and belongs beside the parser that
/// reads them back, while this is a question about somebody's source file and
/// belongs next to the only other code in the project that writes one.
enum PresetScaffold {

    /// `source` with `lines` spliced in as a new preset declaration.
    ///
    /// Immediately after the last `// lerp-preset:` line the file already has,
    /// so a new preset is **appended** to the declaration order rather than
    /// inserted into it.
    ///
    /// That placement is load-bearing, not tidiness. The saved rotation stores a
    /// roster of each shader's presets in declaration order, and
    /// `LerpRotation.renamePairs` decides whether a name it has not seen before
    /// is a new look (joins the rotation) or an old one under a new name (keeps
    /// whatever the user decided about it) by lining those two orders up index
    /// by index. Adding a preset is safe wherever it lands — pairing needs a
    /// name that *vanished*, and adding one vanishes nothing — but the roster
    /// written today is what a rename tomorrow gets aligned against, and
    /// appending is the one edit that leaves every existing index where it was.
    ///
    /// With no presets yet it goes after the last `// lerp-param:` line with a
    /// `//` spacer between, which is the shape every shader in the tree has:
    /// the parameters, a blank comment, then the presets. With neither — a file
    /// declaring nothing, which cannot have produced any values worth saving —
    /// it goes at the end rather than nowhere, keeping whatever trailing
    /// newline the file had.
    ///
    /// Lines are found through `LerpParamParser.directiveBody`, so "this is a
    /// declaration" means here exactly what it will mean when the file is parsed
    /// back a moment later.
    static func inserting(_ lines: [String], into source: String) -> String {
        var text = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func lastLine(carrying directive: String) -> Int? {
            text.lastIndex { LerpParamParser.directiveBody($0, directive) != nil }
        }

        if let index = lastLine(carrying: LerpParamParser.presetDirective) {
            text.insert(contentsOf: lines, at: index + 1)
        } else if let index = lastLine(carrying: LerpParamParser.paramDirective) {
            text.insert(contentsOf: ["//"] + lines, at: index + 1)
        } else {
            let end = text.last?.isEmpty == true ? text.count - 1 : text.count
            text.insert(contentsOf: [""] + lines, at: end)
        }
        return text.joined(separator: "\n")
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
        // Metal stashes the compiler log in different places depending on how
        // the failure happened; take the first one that actually has line info.
        let raw = [nsError.userInfo["MTLCompilerLog"] as? String,
                   nsError.localizedDescription,
                   String(describing: error)]
            .compactMap { $0 }
            .first { $0.contains("program_source") } ?? nsError.localizedDescription

        var items: [ShaderDiagnostic] = []
        pattern.enumerateMatches(in: raw, range: NSRange(raw.startIndex..., in: raw)) { match, _, _ in
            guard let match else { return }
            let field = { (index: Int) in
                Range(match.range(at: index), in: raw).map { String(raw[$0]) } ?? "" }
            guard let line = Int(field(1)), let column = Int(field(2)) else { return }
            items.append(ShaderDiagnostic(line: line, column: column,
                                          severity: field(3),
                                          message: field(4).trimmingCharacters(in: .whitespaces)))
        }
        let cleaned = raw
            .replacingOccurrences(of: "program_source:", with: "")
            .replacingOccurrences(of: "Error Domain=MTLLibraryErrorDomain ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (items, cleaned)
    }

    static func summary(items: [ShaderDiagnostic], raw: String) -> String {
        items.isEmpty ? raw : items.map(\.display).joined(separator: "\n")
    }
}

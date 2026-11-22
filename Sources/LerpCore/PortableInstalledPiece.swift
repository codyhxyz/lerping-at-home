import Foundation

/// The native installed catalog uses a source-only Piece identity, just like the
/// stock postcards. Runtime providers belong to the installed shader; imported
/// asset blobs are never substituted for them.
struct PortableInstalledPiece {
    let shader: LerpShader
    let sourceDigest: String
    let piece: PortablePiece
    let reference: PortableReference
    let metadata: ShaderMetadata

    init(_ shader: LerpShader) throws {
        self.shader = shader
        sourceDigest = PortableReference.digest(Data(shader.source.utf8))
        piece = try PortablePiece(source: "blob:sha256:\(sourceDigest)", assets: [:])
        reference = try piece.reference()
        metadata = ShaderMetadata.parse(source: shader.source)
    }

    func look(for entry: LerpRotationEntry) throws -> PortableLook {
        guard entry.shader == shader.name,
              entry.preset.map({ name in shader.presets.contains { $0.name.utf8.elementsEqual(name.utf8) } }) ?? true else {
            throw PortableArtifactError.invalid("The saved look is no longer available")
        }
        let title = shader.captionLines.first { $0.role == .title }?.text ?? shader.displayName
        return try PortableLook(title: title + (entry.preset.map { " · \($0)" } ?? ""),
                                piece: reference, preset: entry.preset, tuning: [:],
                                authors: metadata.authors, remixedFrom: metadata.remixedFrom,
                                license: metadata.license)
    }

    /// Quarantine may select a saved look but may not silently discard tuning
    /// or apply it to the local installation.
    func entry(matching look: PortableLook) throws -> LerpRotationEntry? {
        let values = try look.parameterValues(for: reference, schema: LerpParamParser.parse(source: shader.source))
        let entry = LerpRotationEntry(shader: shader.name, preset: look.preset)
        return values.rendersSameLook(as: shader.parameterValues(for: entry)) ? entry : nil
    }
}

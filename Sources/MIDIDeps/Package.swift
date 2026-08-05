// swift-tools-version: 6.0
//
// MIDIDeps — the playground's only third-party dependency, kept behind a shim.
//
// The repo builds with plain `swiftc` and has no Xcode project, so it cannot
// consume a SwiftPM dependency directly. This package exists to turn
// `orchetect/swift-midi`'s I/O module into two things swiftc understands: a
// directory of `.swiftmodule` files (`-I .build/release/Modules`) and a static
// archive (`-L .build/release -lMIDIDeps`). Only the LerpPlayground target
// links it; the screensaver, the preview app and the snapshot renderer stay
// dependency-free.
//
//   make midi-deps      builds it (also a prerequisite of playground-build)
//
// `swift build` ships with the Xcode command line tools the README already
// requires, so this adds no new toolchain. CoreMIDI.framework is picked up
// through Swift autolink metadata — no `-framework CoreMIDI` needed.

import PackageDescription

let package = Package(
    name: "MIDIDeps",
    // Matches the `-target arm64-apple-macos14.0` the Makefile passes swiftc,
    // so the module files it emits are loadable by the playground build.
    platforms: [.macOS(.v14)],
    products: [
        // Static on purpose: a dynamic product would need an rpath and a copy
        // step, and the playground is a bare executable run straight out of
        // build/.
        .library(name: "MIDIDeps", type: .static, targets: ["MIDIDeps"])
    ],
    dependencies: [
        // Formerly MIDIKit; renamed and split into six repos in April 2026.
        // `exact:` because this is a build input to a Makefile, not an app with
        // a resolved lockfile — reproducibility beats picking up patches.
        .package(url: "https://github.com/orchetect/swift-midi-io", exact: "1.1.0")
    ],
    targets: [
        .target(
            name: "MIDIDeps",
            dependencies: [.product(name: "SwiftMIDIIO", package: "swift-midi-io")]
        )
    ]
)

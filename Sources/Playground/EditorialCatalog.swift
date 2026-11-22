import Foundation

/// A small, hand-ordered exhibition. IDs are real rotation entries, not display names.
enum EditorialCatalog {
    enum Mood: String, CaseIterable { case Restful, Tactile, Curious }
    enum Motion: String, CaseIterable { case Still, Drifting, Lively }
    enum Brightness: String, CaseIterable { case Low, Soft, Bright }

    struct Piece {
        var entry: LerpRotationEntry
        var title: String
        var placard: String
        var mood: Mood
        var motion: Motion
        var brightness: Brightness

        init(_ shader: String, _ preset: String? = nil, _ title: String, _ placard: String,
             _ mood: Mood, _ motion: Motion, _ brightness: Brightness) {
            entry = LerpRotationEntry(shader: shader, preset: preset)
            self.title = title
            self.placard = placard
            self.mood = mood
            self.motion = motion
            self.brightness = brightness
        }
    }

    struct Shelf {
        var title: String
        var placard: String
        var pieces: [Piece]
    }

    static let shelves: [Shelf] = [
        Shelf(title: "Artist Spotlight · Mårten Rånge",
              placard: "One piece, one horizon. Originally published as Sea and Moon on Shadertoy (CC0).",
              pieces: [Piece("sea-and-moon", nil, "Sea and Moon", "A low moon over an analytic swell.",
                             .Restful, .Drifting, .Low)]),
        Shelf(title: "Rainy Desk", placard: "Two quiet windows for a grey afternoon.", pieces: [
            Piece("lamplight", nil, "Lamplight", "A lantern carried along a winding path.",
                  .Restful, .Drifting, .Low),
            Piece("window-room", "Blueprint", "Window Room · Blueprint", "A room drawn in the language of plans.",
                  .Curious, .Still, .Soft),
        ]),
        Shelf(title: "Paper & Ink", placard: "The texture of a sheet; the movement of a wash.", pieces: [
            Piece("paper-texture", nil, "Paper Texture", "Light catches the grain and stray fibres.",
                  .Tactile, .Still, .Bright),
            Piece("ink-fluid", "Sumi", "Ink Fluid · Sumi", "Grey ink blooms in a shallow dark field.",
                  .Tactile, .Drifting, .Low),
        ]),
        Shelf(title: "Captured Places", placard: "Photographic volumes, from a town square to a patch of soil.", pieces: [
            Piece("splat-trogir", nil, "Trogir", "An arc across a Dalmatian square.",
                  .Curious, .Drifting, .Bright),
            Piece("splat-forest-floor", nil, "Forest Floor", "A small study of bark and seedlings.",
                  .Tactile, .Drifting, .Soft),
        ]),
        Shelf(title: "Midnight Focus", placard: "Slow movement with plenty of room for shadow.", pieces: [
            Piece("dusk-terrain", "Blue Hour", "Dusk Terrain · Blue Hour", "Mountain ridges above a sea of cloud.",
                  .Restful, .Drifting, .Low),
            Piece("star-nest", nil, "Star Nest", "Fine points of light in a deep field.",
                  .Restful, .Drifting, .Low),
        ]),
        Shelf(title: "Kinetic Studies", placard: "Fields and feedback, observed in motion.", pieces: [
            Piece("ferrofluid", "Copper", "Ferrofluid · Copper", "Copper ridges answer an unseen field.",
                  .Tactile, .Lively, .Soft),
            Piece("torque", "Upstream", "Torque · Upstream", "A study in torsion, after Xor’s original.",
                  .Curious, .Lively, .Bright),
        ]),
    ]
}

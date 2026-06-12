import SwiftUI

/// Which companion lives in the corner. Dog breeds share the shiba geometry
/// with different coats; cat and parrot have their own sprites.
enum CompanionSpecies: String, CaseIterable, Identifiable {
    case shiba, husky, golden, cat, parrot, seal, penguin

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shiba: "Shiba (Biscuit)"
        case .husky: "Husky"
        case .golden: "Golden Retriever"
        case .cat: "Cat"
        case .parrot: "Parrot"
        case .seal: "Seal"
        case .penguin: "Penguin"
        }
    }
}

/// Sprite lookup for the companion window: 16×16 character maps drawn by
/// PixelArtView. '.' = transparent; every other character is resolved
/// through the species palette.
enum PixelPet {

    static func palette(for species: CompanionSpecies) -> [Character: Color] {
        switch species {
        case .shiba:
            return [
                "B": Color(red: 0.79, green: 0.54, blue: 0.29),
                "D": Color(red: 0.29, green: 0.18, blue: 0.10),
                "W": Color(red: 0.95, green: 0.89, blue: 0.82),
                "K": Color(red: 0.11, green: 0.11, blue: 0.12),
                "P": Color(red: 0.90, green: 0.42, blue: 0.54),
            ]
        case .husky:
            return [
                "B": Color(red: 0.55, green: 0.58, blue: 0.64),
                "D": Color(red: 0.15, green: 0.17, blue: 0.21),
                "W": Color(red: 0.93, green: 0.94, blue: 0.96),
                "K": Color(red: 0.10, green: 0.10, blue: 0.12),
                "P": Color(red: 0.90, green: 0.42, blue: 0.54),
            ]
        case .golden:
            return [
                "B": Color(red: 0.87, green: 0.67, blue: 0.34),
                "D": Color(red: 0.42, green: 0.26, blue: 0.10),
                "W": Color(red: 0.97, green: 0.92, blue: 0.78),
                "K": Color(red: 0.12, green: 0.10, blue: 0.09),
                "P": Color(red: 0.90, green: 0.42, blue: 0.54),
            ]
        case .cat:
            return [
                "B": Color(red: 0.88, green: 0.56, blue: 0.25),
                "D": Color(red: 0.32, green: 0.17, blue: 0.08),
                "W": Color(red: 0.97, green: 0.92, blue: 0.84),
                "K": Color(red: 0.13, green: 0.12, blue: 0.12),
                "P": Color(red: 0.92, green: 0.48, blue: 0.58),
            ]
        case .parrot:
            return [
                "G": Color(red: 0.22, green: 0.64, blue: 0.30),
                "D": Color(red: 0.07, green: 0.23, blue: 0.12),
                "Y": Color(red: 0.95, green: 0.78, blue: 0.22),
                "O": Color(red: 0.94, green: 0.54, blue: 0.14),
                "R": Color(red: 0.85, green: 0.24, blue: 0.20),
                "K": Color(red: 0.10, green: 0.10, blue: 0.11),
            ]
        case .seal:
            return [
                "B": Color(red: 0.66, green: 0.71, blue: 0.78),
                "D": Color(red: 0.22, green: 0.26, blue: 0.33),
                "W": Color(red: 0.93, green: 0.95, blue: 0.97),
                "K": Color(red: 0.12, green: 0.12, blue: 0.14),
                "P": Color(red: 0.90, green: 0.42, blue: 0.54),
            ]
        case .penguin:
            return [
                "B": Color(red: 0.14, green: 0.16, blue: 0.22),
                "D": Color(red: 0.05, green: 0.06, blue: 0.09),
                "W": Color(red: 0.95, green: 0.96, blue: 0.98),
                "K": Color(red: 0.10, green: 0.10, blue: 0.12),
                "O": Color(red: 0.94, green: 0.60, blue: 0.16),
            ]
        }
    }

    static func frames(species: CompanionSpecies, state: AssistantState) -> [[String]] {
        switch species {
        case .shiba, .husky, .golden:
            return PixelDog.frames(for: state)
        case .cat:
            return PixelCat.frames(for: state)
        case .parrot:
            return PixelParrot.frames(for: state)
        case .seal:
            return PixelSeal.frames(for: state)
        case .penguin:
            return PixelPenguin.frames(for: state)
        }
    }
}

/// 16×16 pixel dog. '.' = transparent, B = body, D = dark outline,
/// W = cream, K = black (eyes/nose), P = pink (tongue).
enum PixelDog {

    static func frames(for state: AssistantState) -> [[String]] {
        switch state {
        case .listening: [earsUpTailDown, earsUpTailUp]
        case .responding: [speakingClosed, speakingTongue]
        case .error: [earsDown, earsDown]
        default: [baseTailDown, baseTailUp]
        }
    }

    static let baseTailDown: [String] = [
        "................",
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD.D.",
        "..DBWWBBBWWBDD..",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let baseTailUp: [String] = [
        "................",
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD..D.",
        "..DBBBBBBBBBD.D.",
        "..DBWWBBBWWBDD..",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let earsUpTailDown: [String] = [
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "..DBBD...DBBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD.D.",
        "..DBWWBBBWWBDD..",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let earsUpTailUp: [String] = [
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "..DBBD...DBBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD..D.",
        "..DBBBBBBBBBD.D.",
        "..DBWWBBBWWBDD..",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let speakingClosed = baseTailUp

    static let speakingTongue: [String] = [
        "................",
        "..D.........D...",
        "..DD.......DD...",
        "..DBD.....DBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWPWBBD....",
        "....DBBPBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD.D.",
        "..DBWWBBBWWBDD..",
        "..DDDDDDDDDDD...",
        "................",
    ]

    static let earsDown: [String] = [
        "................",
        "................",
        "..DD.......DD...",
        "..DBDD...DDBD...",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD...",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
    ]
}

/// 16×16 pixel cat: triangle ears with pink inners, pink nose, long tail.
enum PixelCat {

    static func frames(for state: AssistantState) -> [[String]] {
        switch state {
        case .listening: [alertTailDown, alertTailUp]
        case .responding: [baseTailUp, speakingTongue]
        case .error: [earsFlat, earsFlat]
        default: [baseTailDown, baseTailUp]
        }
    }

    static let baseTailDown: [String] = [
        "................",
        "....D.....D.....",
        "...DPD...DPD....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWPWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD.D.",
        "..DBWWBBBWWBDD..",
        "..DDDDDDDDDDD...",
        "................",
        "................",
    ]

    static let baseTailUp: [String] = [
        "................",
        "....D.....D.....",
        "...DPD...DPD....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWPWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD..D.",
        "..DBBBBBBBBBD.D.",
        "..DBWWBBBWWBDD..",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
        "................",
    ]

    static let alertTailDown: [String] = [
        "....D.....D.....",
        "...DPD...DPD....",
        "...DPD...DPD....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWPWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD.D.",
        "..DBWWBBBWWBDD..",
        "..DDDDDDDDDDD...",
        "................",
        "................",
    ]

    static let alertTailUp: [String] = [
        "....D.....D.....",
        "...DPD...DPD....",
        "...DPD...DPD....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWPWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD..D.",
        "..DBBBBBBBBBD.D.",
        "..DBWWBBBWWBDD..",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
        "................",
    ]

    static let speakingTongue: [String] = [
        "................",
        "....D.....D.....",
        "...DPD...DPD....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWPWWBD....",
        "...DBBWPWBBD....",
        "....DBBPBBD.....",
        "...DBBBBBBBD..D.",
        "..DBBBBBBBBBD.D.",
        "..DBWWBBBWWBDD..",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
        "................",
    ]

    static let earsFlat: [String] = [
        "................",
        "................",
        "...DD.....DD....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWPWWBD....",
        "...DBBWWWBBD....",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWBBBWWBD...",
        "..DBWWBBBWWBD...",
        "..DDDDDDDDDDD...",
        "................",
        "................",
    ]
}

/// 16×16 pixel parrot: red crest, orange beak, yellow chest, wing flap.
enum PixelParrot {

    static func frames(for state: AssistantState) -> [[String]] {
        switch state {
        case .listening: [crestUpWingsIn, crestUpWingsOut]
        case .responding: [beakOpen, wingsIn]
        case .error: [crestDown, crestDown]
        default: [wingsIn, wingsOut]
        }
    }

    static let wingsIn: [String] = [
        "................",
        ".....DRRD.......",
        "....DRRRRD......",
        "....DGGGGGD.....",
        "...DGGGGGGGD....",
        "...DGKGGGKGD....",
        "...DGGOOOGGD....",
        "...DGGGOGGGD....",
        "...DGYYYYYGD....",
        "...DGYYYYYGD....",
        "..DGGYYYYYGGD...",
        "...DGGYYYGGD....",
        "....DGGGGGD.....",
        ".....DODOD......",
        "................",
        "................",
    ]

    static let wingsOut: [String] = [
        "................",
        ".....DRRD.......",
        "....DRRRRD......",
        "....DGGGGGD.....",
        "...DGGGGGGGD....",
        "...DGKGGGKGD....",
        "...DGGOOOGGD....",
        "...DGGGOGGGD....",
        "...DGYYYYYGD....",
        "...DGYYYYYGD....",
        ".DGGGYYYYYGGGD..",
        "...DGGYYYGGD....",
        "....DGGGGGD.....",
        ".....DODOD......",
        "................",
        "................",
    ]

    static let crestUpWingsIn: [String] = [
        ".....DRRD.......",
        "....DRRRRD......",
        "....DRRRRD......",
        "....DGGGGGD.....",
        "...DGGGGGGGD....",
        "...DGKGGGKGD....",
        "...DGGOOOGGD....",
        "...DGGGOGGGD....",
        "...DGYYYYYGD....",
        "...DGYYYYYGD....",
        "..DGGYYYYYGGD...",
        "...DGGYYYGGD....",
        "....DGGGGGD.....",
        ".....DODOD......",
        "................",
        "................",
    ]

    static let crestUpWingsOut: [String] = [
        ".....DRRD.......",
        "....DRRRRD......",
        "....DRRRRD......",
        "....DGGGGGD.....",
        "...DGGGGGGGD....",
        "...DGKGGGKGD....",
        "...DGGOOOGGD....",
        "...DGGGOGGGD....",
        "...DGYYYYYGD....",
        "...DGYYYYYGD....",
        ".DGGGYYYYYGGGD..",
        "...DGGYYYGGD....",
        "....DGGGGGD.....",
        ".....DODOD......",
        "................",
        "................",
    ]

    static let beakOpen: [String] = [
        "................",
        ".....DRRD.......",
        "....DRRRRD......",
        "....DGGGGGD.....",
        "...DGGGGGGGD....",
        "...DGKGGGKGD....",
        "...DGGOOOGGD....",
        "...DGGKKKGGD....",
        "...DGGOOOGGD....",
        "...DGYYYYYGD....",
        "..DGGYYYYYGGD...",
        "...DGGYYYGGD....",
        "....DGGGGGD.....",
        ".....DODOD......",
        "................",
        "................",
    ]

    static let crestDown: [String] = [
        "................",
        "................",
        "....DDRRD.......",
        "....DGGGGGD.....",
        "...DGGGGGGGD....",
        "...DGKGGGKGD....",
        "...DGGOOOGGD....",
        "...DGGGOGGGD....",
        "...DGYYYYYGD....",
        "...DGYYYYYGD....",
        "..DGGYYYYYGGD...",
        "...DGGYYYGGD....",
        "....DGGGGGD.....",
        ".....DODOD......",
        "................",
        "................",
    ]
}

/// 16×16 pixel seal: silver coat, cream belly, side flippers.
enum PixelSeal {

    static func frames(for state: AssistantState) -> [[String]] {
        switch state {
        case .listening: [alertA, alertB]
        case .responding: [baseA, speakingTongue]
        case .error: [droopy, droopy]
        default: [baseA, baseB]
        }
    }

    static let baseA: [String] = [
        "................",
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "....DBWWWBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWWWWWWBD...",
        "..DBWWWWWWWBD...",
        "...DBBBBBBBD....",
        "..DBBD....DBBD..",
        "..DDDD....DDDD..",
        "................",
    ]

    static let baseB: [String] = [
        "................",
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "....DBWWWBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWWWWWWBD...",
        "..DBWWWWWWWBD...",
        "..DDBBBBBBBDD...",
        ".DBBD......DBBD.",
        ".DDDD......DDDD.",
        "................",
    ]

    static let alertA: [String] = [
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "....DBWWWBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWWWWWWBD...",
        "..DBWWWWWWWBD...",
        "..DBWWWWWWWBD...",
        "...DBBBBBBBD....",
        "..DBBD....DBBD..",
        "..DDDD....DDDD..",
        "................",
    ]

    static let alertB: [String] = [
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "....DBWWWBD.....",
        "...DBBBBBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWWWWWWBD...",
        "..DBWWWWWWWBD...",
        "..DDBWWWWWBDD...",
        ".DBBDBBBBBDBBD..",
        ".DDDD......DDDD.",
        "................",
        "................",
    ]

    static let speakingTongue: [String] = [
        "................",
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "....DBWPWBD.....",
        "...DBBBPBBBD....",
        "..DBBBBBBBBBD...",
        "..DBWWWWWWWBD...",
        "..DBWWWWWWWBD...",
        "...DBBBBBBBD....",
        "..DBBD....DBBD..",
        "..DDDD....DDDD..",
        "................",
    ]

    static let droopy: [String] = [
        "................",
        "................",
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBKBBBKBD....",
        "...DBBBBBBBD....",
        "...DBWWKWWBD....",
        "....DBWWWBD.....",
        "..DBBBBBBBBBD...",
        "..DBWWWWWWWBD...",
        "..DBWWWWWWWBD...",
        "...DBBBBBBBD....",
        "..DBBD....DBBD..",
        "..DDDD....DDDD..",
        "................",
    ]
}

/// 16×16 pixel penguin: black coat, white belly and face, orange beak/feet.
enum PixelPenguin {

    static func frames(for state: AssistantState) -> [[String]] {
        switch state {
        case .listening: [alertA, alertB]
        case .responding: [baseA, beakOpen]
        case .error: [droopy, droopy]
        default: [baseA, baseB]
        }
    }

    static let baseA: [String] = [
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBWWWWWBD....",
        "...DBWKWKWBD....",
        "...DBWWOWWBD....",
        "...DBWOOOWBD....",
        "...DBWWWWWBD....",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "...DBWWWWWBD....",
        "....DBBBBBD.....",
        "....DOODOOD.....",
        "................",
        "................",
    ]

    static let baseB: [String] = [
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBWWWWWBD....",
        "...DBWKWKWBD....",
        "...DBWWOWWBD....",
        "...DBWOOOWBD....",
        "...DBWWWWWBD....",
        ".DBBBWWWWWBBBD..",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "...DBWWWWWBD....",
        "....DBBBBBD.....",
        "....DOODOOD.....",
        "................",
        "................",
    ]

    static let alertA: [String] = [
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBWWWWWBD....",
        "...DBWKWKWBD....",
        "...DBWWOWWBD....",
        "...DBWOOOWBD....",
        "...DBWWWWWBD....",
        "..DBBWWWWWBBD...",
        ".DBBBWWWWWBBBD..",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "...DBWWWWWBD....",
        "....DBBBBBD.....",
        "....DOODOOD.....",
        "................",
        "................",
    ]

    static let alertB: [String] = [
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBWWWWWBD....",
        "...DBWKWKWBD....",
        "...DBWWOWWBD....",
        "...DBWOOOWBD....",
        "...DBWWWWWBD....",
        ".DBBBWWWWWBBBD..",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "...DBWWWWWBD....",
        "....DBBBBBD.....",
        "....DOODOOD.....",
        "................",
        "................",
    ]

    static let beakOpen: [String] = [
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBWWWWWBD....",
        "...DBWKWKWBD....",
        "...DBWOOOWBD....",
        "...DBWOKOWBD....",
        "...DBWOOOWBD....",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "...DBWWWWWBD....",
        "....DBBBBBD.....",
        "....DOODOOD.....",
        "................",
        "................",
    ]

    static let droopy: [String] = [
        "................",
        "................",
        "....DBBBBBD.....",
        "...DBBBBBBBD....",
        "...DBWWWWWBD....",
        "...DBWKWKWBD....",
        "...DBWWOWWBD....",
        "...DBWOOOWBD....",
        "...DBWWWWWBD....",
        "..DBBWWWWWBBD...",
        "..DBBWWWWWBBD...",
        "...DBWWWWWBD....",
        "....DBBBBBD.....",
        "....DOODOOD.....",
        "................",
        "................",
    ]
}


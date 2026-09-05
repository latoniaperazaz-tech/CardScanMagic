import Foundation
import SwiftUI

struct CardFace: Equatable, Hashable {
    let code: String
    let rank: String
    let suit: Suit?

    enum Suit: Character, CaseIterable {
        case clubs = "c"
        case diamonds = "d"
        case hearts = "h"
        case spades = "s"

        var glyph: String {
            switch self {
            case .clubs: return "♣"
            case .diamonds: return "♦"
            case .hearts: return "♥"
            case .spades: return "♠"
            }
        }

        var chineseName: String {
            switch self {
            case .clubs: return "梅花"
            case .diamonds: return "方块"
            case .hearts: return "红桃"
            case .spades: return "黑桃"
            }
        }

        var color: Color {
            switch self {
            case .diamonds, .hearts: return .red
            case .clubs, .spades: return .primary
            }
        }
    }

    static func parse(_ rawLabel: String) -> CardFace? {
        let normalized = rawLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized == "joker" {
            return CardFace(code: "joker", rank: "Joker", suit: nil)
        }

        guard normalized.count >= 2,
              let suitCharacter = normalized.last,
              let suit = Suit(rawValue: suitCharacter) else {
            return nil
        }

        let rank = String(normalized.dropLast()).uppercased()
        let validRanks: Set<String> = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"]
        guard validRanks.contains(rank) else {
            return nil
        }

        return CardFace(code: "\(rank.lowercased())\(suit.rawValue)", rank: rank, suit: suit)
    }

    var displayText: String {
        guard let suit else { return rank }
        return "\(rank)\(suit.glyph)"
    }

    var chineseName: String {
        guard let suit else { return rank }
        return "\(suit.chineseName)\(rank)"
    }

    var displayColor: Color {
        suit?.color ?? .primary
    }
}

struct CardRecord: Identifiable, Equatable {
    let id = UUID()
    let card: CardFace
    let confidence: Float
    let recordedAt: Date
}

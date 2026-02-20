// SharedViewComponents.swift
// Cortex — Personal Knowledge Agent
//
// Shared UI components and extensions used across multiple views.

import SwiftUI

// MARK: - StatusDot

struct StatusDot: View {
    let status: ItemStatus

    var body: some View {
        Circle()
            .fill(status.color)
            .frame(width: 6, height: 6)
    }
}

// MARK: - Extensions

extension SourcePlatform {
    var systemImage: String {
        switch self {
        case .twitter: return "bubble.left.and.bubble.right"
        case .reddit:  return "person.2.circle"
        case .youtube: return "play.rectangle"
        case .web:     return "globe"
        case .manual:  return "pencil"
        }
    }
}

extension ItemStatus {
    var color: Color {
        switch self {
        case .pending, .extracting: return .orange
        case .indexed, .enriched, .connected: return .green
        case .partial: return .yellow
        case .blocked, .failed: return .red
        }
    }
}

extension Color {
    /// Initialize from a hex string like "#7B2FBE"
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

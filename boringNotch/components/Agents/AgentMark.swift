//
//  AgentMark.swift
//  boringNotch
//
//  A vendor's logo and its quota ring, drawn as agent-hud draws them.
//

import AgentHUDCore
import AppKit
import SwiftUI

/// Level colours from agent-hud's palette, on the notch's black: a reading in good standing stays white, so colour
/// only appears when it says something.
enum AgentPalette {
    static let ok = Color.white.opacity(0.92)
    static let warning = Color(red: 1, green: 0xd2 / 255, blue: 0x3f / 255)
    static let critical = Color(red: 1, green: 0x45 / 255, blue: 0x3a / 255)
    static let track = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.5)

    static func color(_ level: StatusLevel?) -> Color {
        switch level {
        case .critical: critical
        case .warning: warning
        case .ok, nil: ok
        }
    }
}

/// A vendor's bundled logo (`Logos/agent-*.png`), or a neutral glyph for one without.
struct AgentLogo: View {
    let vendor: String

    private static let files = ["Claude": "claude", "ChatGPT": "chatgpt", "Antigravity": "antigravity", "Muse": "muse",
                                "Notion": "notion", "Kie": "kie", "DeepSeek": "deepseek", "OpenRouter": "openrouter",
                                "Anthropic API": "anthropic"]
    /// Single-colour marks, drawn in the text colour.
    private static let monochrome: Set<String> = ["Notion", "OpenRouter", "Anthropic API"]
    private static let openAIGreen = Color(red: 16 / 255, green: 163 / 255, blue: 127 / 255)

    var body: some View {
        let mark = VendorMark.key(vendor)
        if let name = Self.files[mark], let image = NSImage(named: "agent-\(name)") {
            if mark == "ChatGPT" {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit().foregroundStyle(Self.openAIGreen)
            } else if Self.monochrome.contains(mark) {
                Image(nsImage: image).resizable().renderingMode(.template).scaledToFit().foregroundStyle(.white)
            } else {
                Image(nsImage: image).resizable().scaledToFit()
            }
        } else {
            Image(systemName: "sparkles").resizable().scaledToFit().foregroundStyle(.white.opacity(0.8))
        }
    }
}

/// The share used as a ring round the logo: clockwise from twelve o'clock, round-capped, in the level's colour.
struct AgentRingMark: View {
    let vendor: String
    let usedPct: Double?
    let level: StatusLevel?
    var size: CGFloat = 36
    var lineWidth: CGFloat = 3

    private var fraction: Double { max(0, min(1, (usedPct ?? 0) / 100)) }

    var body: some View {
        ZStack {
            Circle().stroke(AgentPalette.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(AgentPalette.color(level), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .opacity(usedPct == nil ? 0 : 1)
            AgentLogo(vendor: vendor)
                .frame(width: size * 0.5, height: size * 0.5)
        }
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.45), value: fraction)
        .animation(.smooth(duration: 0.3), value: level)
    }
}

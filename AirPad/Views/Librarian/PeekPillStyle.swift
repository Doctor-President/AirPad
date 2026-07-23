// PeekPillStyle.swift
// #2 — the Librarian peek pill's typed, per-mode appearance. LIGHT and DARK are
// BAKED from T's on-device dial (2026-07-23); the DEBUG tuner has been removed.
//
// ONE shadow primitive per mode — a SHADOW/separation, NOT a "glow":
//   • LIGHT: a warm brown drop shadow with a slight offset.
//   • DARK:  a BLACK shadow at ZERO offset — a dark separation halo off the panel.
//
// The pill is TRANSLUCENT: the only fill is the material (it samples the real
// backdrop); the shadow is applied to the material-backed shape (no opaque fill
// behind it). The shadow + stroke are scoped to the PEEK state via `visibility`
// (fed from the morph progress in LibrarianSurface).

import SwiftUI

// MARK: - Colour storage (RGB 0…1)

struct PeekPillRGB: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
}

// MARK: - Material choice

enum PeekPillMaterial {
    case thin, ultraThin, regular, glass

    /// The translucent pill FACE, rendered into `shape`.
    @ViewBuilder
    func faceView<S: Shape>(_ shape: S) -> some View {
        switch self {
        case .thin:      shape.fill(.thinMaterial)
        case .ultraThin: shape.fill(.ultraThinMaterial)
        case .regular:   shape.fill(.regularMaterial)
        case .glass:
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
    }
}

// MARK: - The typed per-mode style (baked literals — T-dialled)

struct PeekPillStyle: Equatable {
    var material: PeekPillMaterial
    var tint: PeekPillRGB
    /// Light = 0 (unused), but the field STAYS — DARK uses it (0.204).
    var tintOpacity: Double
    /// A SHADOW/separation (not a glow). Dark is black @ zero offset.
    var shadow: PeekPillRGB
    var shadowRadius: Double
    var shadowOpacity: Double
    var shadowOffsetX: Double
    var shadowOffsetY: Double
    var strokeEnabled: Bool
    var stroke: PeekPillRGB
    var strokeWidth: Double

    var tintColor: Color { tint.color }
    var strokeColorResolved: Color { stroke.color }

    /// LIGHT — warm brown drop shadow with a slight offset + a light warm stroke.
    /// Tint opacity 0 (kept: DARK uses the field).
    static let light = PeekPillStyle(
        material: .ultraThin,
        tint: PeekPillRGB(r: 0.98, g: 0.94, b: 0.86), tintOpacity: 0.0,
        shadow: PeekPillRGB(r: 0.263, g: 0.216, b: 0.165),
        shadowRadius: 22.2, shadowOpacity: 0.149, shadowOffsetX: 3.05, shadowOffsetY: 1.44,
        strokeEnabled: true,
        stroke: PeekPillRGB(r: 0.807, g: 0.734, b: 0.637), strokeWidth: 1.21
    )

    /// DARK — a BLACK shadow at ZERO offset (a dark separation halo, not a glow),
    /// a subtle black tint wash, and a faint warm-grey stroke.
    static let dark = PeekPillStyle(
        material: .ultraThin,
        tint: PeekPillRGB(r: 0.0, g: 0.0, b: 0.0), tintOpacity: 0.204,
        shadow: PeekPillRGB(r: 0.0, g: 0.0, b: 0.0),
        shadowRadius: 35.8, shadowOpacity: 0.468, shadowOffsetX: 0.0, shadowOffsetY: 0.0,
        strokeEnabled: true,
        stroke: PeekPillRGB(r: 0.351, g: 0.301, b: 0.337), strokeWidth: 0.56
    )
}

// MARK: - The pill background (translucent material + peek-scoped shadow)

struct PeekPillBackground<S: InsettableShape>: ViewModifier {
    let shape: S
    /// The shadow/separation + stroke belong to the PEEK state only. `visibility`
    /// fades them out as the pill expands (1 at peek → 0 by half/full); the
    /// material + tint always render. Default 1 for non-morphing call sites.
    var visibility: Double = 1
    @Environment(\.colorScheme) private var colorScheme

    private var style: PeekPillStyle { colorScheme == .dark ? .dark : .light }

    func body(content: Content) -> some View {
        let s = style
        return content
            .background {
                // Translucent: the ONLY fill is the material (samples the real
                // backdrop). The shadow/separation is applied to the material-
                // backed shape — no opaque fill behind it.
                ZStack {
                    s.material.faceView(shape)                      // translucent
                    shape.fill(s.tintColor.opacity(s.tintOpacity))  // tint wash (dark only)
                }
                .shadow(color: s.shadow.color.opacity(s.shadowOpacity * visibility),
                        radius: s.shadowRadius, x: s.shadowOffsetX, y: s.shadowOffsetY)
            }
            .overlay {
                if s.strokeEnabled && visibility > 0.01 {
                    shape.strokeBorder(s.strokeColorResolved.opacity(visibility),
                                       lineWidth: s.strokeWidth)
                }
            }
    }
}

extension View {
    /// Apply the typed, per-mode peek-pill background (translucent material + tint
    /// + a peek-scoped shadow/separation + optional stroke).
    func peekPillBackground<S: InsettableShape>(_ shape: S, visibility: Double = 1) -> some View {
        modifier(PeekPillBackground(shape: shape, visibility: visibility))
    }
}

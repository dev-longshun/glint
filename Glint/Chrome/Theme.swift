import SwiftUI
import AppKit

enum Theme {
    // backgrounds
    static let bgWindow   = Color(red: 0.039, green: 0.043, blue: 0.063)   // #0A0B10
    static let bgPane     = Color(red: 0.043, green: 0.039, blue: 0.078)   // #0B0A14 (slight indigo)

    // vibrancy tint overlays — black-first with the faintest indigo cast
    static let sidebarTintTop    = Color(red: 0.075, green: 0.065, blue: 0.110).opacity(0.86)
    static let sidebarTintBottom = Color(red: 0.045, green: 0.038, blue: 0.085).opacity(0.90)
    static let toolbarTint       = Color(red: 0.060, green: 0.052, blue: 0.095).opacity(0.86)

    // text
    static let text1 = Color(red: 0.925, green: 0.929, blue: 0.949)        // #ECEDF2
    static let text2 = Color(red: 0.717, green: 0.725, blue: 0.784)        // #B7B9C8
    static let text3 = Color(red: 0.494, green: 0.510, blue: 0.565)        // #7E8290
    static let text4 = Color(red: 0.337, green: 0.353, blue: 0.424)        // #565A6C

    // accents
    static let accent       = Color(red: 0.369, green: 0.361, blue: 0.902) // #5E5CE6 systemIndigo
    static let accentBright = Color(red: 0.549, green: 0.549, blue: 1.000) // #8C8CFF
    static let green        = Color(red: 0.188, green: 0.820, blue: 0.345) // #30D158
    static let orange       = Color(red: 1.000, green: 0.624, blue: 0.039) // #FF9F0A
    static let pink         = Color(red: 1.000, green: 0.392, blue: 0.510) // #FF6482
    static let cyan         = Color(red: 0.392, green: 0.824, blue: 1.000) // #64D2FF

    // separators
    static let divider = Color.white.opacity(0.045)
    static let border  = Color.white.opacity(0.07)
}

extension Font {
    static let glintUI       = Font.system(size: 13, weight: .medium)
    static let glintUISmall  = Font.system(size: 12, weight: .medium)
    static let glintCaption  = Font.system(size: 10.5, weight: .semibold).leading(.tight)
    static let glintSection  = Font.system(size: 10.5, weight: .semibold)
    static let glintMono     = Font.system(size: 12.5, weight: .regular, design: .monospaced)
    static let glintMonoBig  = Font.system(size: 13, weight: .regular, design: .monospaced)
    static let glintStatus   = Font.system(size: 11, weight: .medium, design: .monospaced)
}

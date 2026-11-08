import AppKit
import SwiftUI

/// Farge som ARGB-verdi, så den kan brukes både i SwiftUI, AppKit og CSS (chatten, «Om»-siden).
struct HexColor: Equatable {
    let argb: UInt32

    init(_ argb: UInt32) { self.argb = argb }

    var a: Double { Double((argb >> 24) & 0xFF) / 255 }
    var r: Double { Double((argb >> 16) & 0xFF) / 255 }
    var g: Double { Double((argb >> 8) & 0xFF) / 255 }
    var b: Double { Double(argb & 0xFF) / 255 }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var css: String { String(format: "#%06X", argb & 0xFFFFFF) }

    /// Blanding: [f] = 0 gir denne fargen, 1 gir [other].
    func mix(_ other: HexColor, _ f: Double) -> HexColor {
        func ch(_ shift: UInt32) -> UInt32 {
            let x = Double((argb >> shift) & 0xFF)
            let y = Double((other.argb >> shift) & 0xFF)
            return UInt32((x + (y - x) * f).rounded()) & 0xFF
        }
        return HexColor((ch(24) << 24) | (ch(16) << 16) | (ch(8) << 8) | ch(0))
    }
}

/// Fargene i ett tema. Alle temaene har samme stil: skarpe hjørner og tynn kantlinje i stedet for skygger.
struct PtColors: Equatable {
    var bg, text, link, fg, fgText, topBar, topBarText, border: HexColor
    var red, blue, green, orange, pressedBg, pressedBorder: HexColor
    /// Slør over bakgrunnsbildet, så teksten alltid er lesbar.
    var overlay: HexColor
    var light = false
    /// Aktivt menypunkt i bunnmenyen.
    var navActive: HexColor? = nil
    /// Bakgrunn for innlegg som svarer eller nevner meg: grønn, men blå i det grønne temaet.
    var mentionBg = HexColor(0xFF173D28)
}

/// Temaene brukeren kan velge mellom på profilsiden. [rawValue] lagres, så den må ikke endres.
enum AppTheme: String, CaseIterable, Identifiable {
    /// Pleroma-temaet «gaute.space»: mørke blågrønne flater og tan kantlinje (#AB9977).
    case green = "standard"
    case blue
    case purple
    case dark
    case light

    var id: String { rawValue }

    static func from(_ id: String?) -> AppTheme { AppTheme(rawValue: id ?? "") ?? .green }

    var label: String {
        switch self {
        case .green: return L("theme_green")
        case .blue: return L("theme_blue")
        case .purple: return L("theme_purple")
        case .dark: return L("theme_dark")
        case .light: return L("theme_light")
        }
    }

    var colors: PtColors {
        switch self {
        case .green:
            return PtColors(
                bg: HexColor(0xFF203237), text: HexColor(0xFFC2D9D4), link: HexColor(0xFFAB9977),
                fg: HexColor(0xFF132B29), fgText: HexColor(0xFFB5D4CE),
                topBar: HexColor(0xFF132B29), topBarText: HexColor(0xFF65C89C), border: HexColor(0xFFAB9977),
                red: HexColor(0xFF9E555B), blue: HexColor(0xFF81A6C4), green: HexColor(0xFF319195), orange: HexColor(0xFFD6924C),
                pressedBg: HexColor(0xFF443D30), pressedBorder: HexColor(0xFF7D7057), overlay: HexColor(0x33102022),
                mentionBg: HexColor(0xFF1A3552)
            )
        case .blue:
            return PtColors(
                bg: HexColor(0xFF1E2B3D), text: HexColor(0xFFC9D6E8), link: HexColor(0xFF8FB8DE),
                fg: HexColor(0xFF121C2B), fgText: HexColor(0xFFBCCDE3),
                topBar: HexColor(0xFF121C2B), topBarText: HexColor(0xFF7FC4F0), border: HexColor(0xFF8FB8DE),
                red: HexColor(0xFFB05C66), blue: HexColor(0xFF81A6C4), green: HexColor(0xFF4FA3A8), orange: HexColor(0xFFD6924C),
                pressedBg: HexColor(0xFF2A3A52), pressedBorder: HexColor(0xFF5C7A9E), overlay: HexColor(0x55101A2C),
                navActive: HexColor(0xFFD6EEFF)
            )
        case .purple:
            return PtColors(
                bg: HexColor(0xFF2A2238), text: HexColor(0xFFDCD0EA), link: HexColor(0xFFB9A0E0),
                fg: HexColor(0xFF1C1626), fgText: HexColor(0xFFCFC2E0),
                topBar: HexColor(0xFF1C1626), topBarText: HexColor(0xFFD3A6F2), border: HexColor(0xFFB9A0E0),
                red: HexColor(0xFFB05C70), blue: HexColor(0xFF8FA6D6), green: HexColor(0xFF5FA39A), orange: HexColor(0xFFD6924C),
                pressedBg: HexColor(0xFF3A2E50), pressedBorder: HexColor(0xFF7E68A3), overlay: HexColor(0x5520122C),
                navActive: HexColor(0xFFF2E2FF)
            )
        case .dark:
            return PtColors(
                bg: HexColor(0xFF1A1A1A), text: HexColor(0xFFD6D6D6), link: HexColor(0xFFAB9977),
                fg: HexColor(0xFF101010), fgText: HexColor(0xFFC8C8C8),
                topBar: HexColor(0xFF101010), topBarText: HexColor(0xFFD9C9A8), border: HexColor(0xFFAB9977),
                red: HexColor(0xFF9E555B), blue: HexColor(0xFF81A6C4), green: HexColor(0xFF319195), orange: HexColor(0xFFD6924C),
                pressedBg: HexColor(0xFF3A352B), pressedBorder: HexColor(0xFF7D7057), overlay: HexColor(0x88000000),
                navActive: HexColor(0xFFFFF6E3)
            )
        case .light:
            return PtColors(
                bg: HexColor(0xFFE8EEEC), text: HexColor(0xFF1F2E2C), link: HexColor(0xFF7D6232),
                fg: HexColor(0xFFF8FAF9), fgText: HexColor(0xFF2A3B38),
                topBar: HexColor(0xFFF8FAF9), topBarText: HexColor(0xFF1F7A5A), border: HexColor(0xFFA08A62),
                red: HexColor(0xFFB0444C), blue: HexColor(0xFF3F6E96), green: HexColor(0xFF23787C), orange: HexColor(0xFFB86E25),
                pressedBg: HexColor(0xFFE6DCC6), pressedBorder: HexColor(0xFF7D6232), overlay: HexColor(0xAAE8EEEC),
                light: true, mentionBg: HexColor(0xFFE3F5E5)
            )
        }
    }
}

/// Det valgte temaet. Observeres, så alt som leser fargene tegnes på nytt når brukeren bytter tema.
@Observable
final class ThemeManager {
    static let shared = ThemeManager()
    var theme: AppTheme = .green

    static let fontScaleRange = 0.8...1.4

    /// Skriftstørrelsen i feedene, justert med glideren i tema-dialogen (1 = standard). Felles for alle brukere.
    var fontScale: Double = {
        let v = UserDefaults.standard.object(forKey: "font_scale") as? Double ?? 1
        return min(max(v, fontScaleRange.lowerBound), fontScaleRange.upperBound)
    }() {
        didSet { UserDefaults.standard.set(fontScale, forKey: "font_scale") }
    }
}

/// Fargene i det valgte temaet (tilsvarer PT i Android-appen).
enum PT {
    static var c: PtColors { ThemeManager.shared.theme.colors }

    static var bg: Color { c.bg.color }
    static var text: Color { c.text.color }
    static var link: Color { c.link.color }
    static var fg: Color { c.fg.color }
    static var fgText: Color { c.fgText.color }
    static var topBar: Color { c.topBar.color }
    static var topBarText: Color { c.topBarText.color }
    static var border: Color { c.border.color }
    static var red: Color { c.red.color }
    static var blue: Color { c.blue.color }
    static var green: Color { c.green.color }
    static var orange: Color { c.orange.color }
    static var pressedBg: Color { c.pressedBg.color }
    static var pressedBorder: Color { c.pressedBorder.color }
    static var overlay: Color { c.overlay.color }
    static var navActive: Color { (c.navActive ?? c.topBarText).color }
    static var mentionBg: Color { c.mentionBg.color }
    static var muted: Color { fgText.opacity(0.65) }

    static let panelAlpha = 0.8
}

/// Skriftstørrelser (tilsvarer Material-typografien i Android-appen).
enum PF {
    static let body: CGFloat = 14
    static let small: CGFloat = 12
    static let title: CGFloat = 16
    /// Tekst i feedene (innlegg, tråder, profiler og varsler), skalert med brukerens valg.
    static var feedBody: CGFloat { 16 * ThemeManager.shared.fontScale }
    static var feedSmall: CGFloat { 13.5 * ThemeManager.shared.fontScale }
    /// Ikoner og tall i knapperaden under innleggene.
    static var feedIcon: CGFloat { 16 * ThemeManager.shared.fontScale }
    static var feedCount: CGFloat { 14 * ThemeManager.shared.fontScale }
}

// MARK: - Byggeklosser

extension View {
    /// Pleroma-«panel»: halvtransparent flate med tynn kantlinje.
    func panel(border: Color? = nil, background: Color? = nil) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background((background ?? PT.fg).opacity(PT.panelAlpha))
            .overlay(Rectangle().strokeBorder(border ?? PT.border, lineWidth: 1))
    }

    /// Tynn kantlinje rundt et element (skarpe hjørner).
    func pBorder(_ color: Color, _ width: CGFloat = 1) -> some View {
        overlay(Rectangle().strokeBorder(color, lineWidth: width))
    }

    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, _ transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// Knapp i temaets stil: flat, kantlinje, mørkere «innrykket» ved trykk.
struct PButton: View {
    let text: String
    var icon: String? = nil
    var filled = false
    var enabled = true
    /// Verktøytips og beskrivelse for skjermlesere når knappen bare har ikon.
    var help: String? = nil
    var expand = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .medium))
                }
                if !text.isEmpty {
                    Text(text).font(.system(size: PF.body, weight: .medium)).lineLimit(1)
                }
            }
            .padding(.horizontal, text.isEmpty ? 10 : 14)
            .padding(.vertical, 8)
            .frame(minHeight: 34)
            .frame(maxWidth: expand ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(PButtonStyle(filled: filled))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help ?? "")
        .accessibilityLabel(help ?? text)
    }
}

struct PButtonStyle: ButtonStyle {
    var filled = false

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .foregroundStyle(filled && !pressed ? PT.fg : PT.link)
            .background(pressed ? PT.pressedBg : filled ? PT.link : PT.fg)
            .pBorder(pressed ? PT.pressedBorder : PT.border.opacity(0.8))
    }
}

/// Tekstknapp i dialoger («Lukk», «Avbryt» …).
struct PTextButton: View {
    let text: String
    var color: Color? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: PF.body, weight: .medium))
                .foregroundStyle(color ?? PT.link)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// Enlinjet tekstfelt i temaets stil.
struct PField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var monospaced = false
    var onSubmit: () -> Void = {}
    var focused: FocusState<Bool>.Binding? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).foregroundStyle(PT.link)
            }
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(PT.muted).lineLimit(1).allowsHitTesting(false)
                }
                field
            }
        }
        .font(monospaced ? .system(size: PF.body, design: .monospaced) : .system(size: PF.body))
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(PT.fg.opacity(0.85))
        .pBorder(PT.border.opacity(0.8))
    }

    @ViewBuilder
    private var field: some View {
        let f = TextField("", text: $text)
            .textFieldStyle(.plain)
            .foregroundStyle(PT.text)
            .focusEffectDisabled()
            .onSubmit(onSubmit)
        if let focused {
            f.focused(focused)
        } else {
            f
        }
    }
}

/// Tynn skillelinje i kantfargen.
struct PDivider: View {
    var color: Color? = nil
    var body: some View {
        Rectangle().fill(color ?? PT.border).frame(height: 1)
    }
}

/// Liten roterende ring (lasting).
struct Spinner: View {
    var size: CGFloat = 24
    @ViewState private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.85)
            .stroke(PT.link, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

struct LoadingRow: View {
    var body: some View {
        HStack { Spacer(); Spinner(size: 26); Spacer() }.padding(16)
    }
}

struct ErrorPanel: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message).foregroundStyle(PT.text).font(.system(size: PF.body))
            PButton(text: L("retry"), action: onRetry)
        }
        .padding(14)
        .panel(border: PT.red)
    }
}

/// Panel med en enkel tekst (tom liste o.l.).
struct MessagePanel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: PF.body))
            .foregroundStyle(PT.text)
            .padding(14)
            .panel()
    }
}

/// Åpner en adresse i standardnettleseren.
func openExternal(_ url: String) {
    guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return }
    NSWorkspace.shared.open(u)
}

/// macOS 27-SDK-et har gjort @State om til en makro som Command Line Tools ikke har plugin for.
/// Egenskapsomslaget (State-strukturen) finnes fortsatt, så vi bruker det via et alias.
typealias ViewState<Value> = SwiftUI.State<Value>

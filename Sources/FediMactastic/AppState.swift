import AppKit
import SwiftUI

/// En dialog som vises midt i vinduet, over alt annet.
struct DialogItem: Identifiable {
    let id = UUID()
    let content: AnyView
}

/// Hovedkolonnen eller varselkolonnen til høyre (i brede vinduer).
enum SignalScope { case main, side }

private struct SignalScopeKey: EnvironmentKey {
    static let defaultValue = SignalScope.main
}

extension EnvironmentValues {
    var signalScope: SignalScope {
        get { self[SignalScopeKey.self] }
        set { self[SignalScopeKey.self] = newValue }
    }
}

/// Kommandoer fra menylinjen.
enum AppCommand: Equatable {
    case compose
    case tab(MainTab)
    case refresh
    case back
}

/// Det som deles mellom skjermene (tilsvarer «Graph» i Android-appen).
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    @ObservationIgnored let store = SessionStore()
    @ObservationIgnored lazy var api = ApiClient(store: store)

    var toastMessage: String?
    var dialogs: [DialogItem] = []
    var viewer: (images: [MediaAttachment], index: Int)?

    /// Siste kommando fra menyen; [commandTick] øker for hver, så samme kommando kan gjentas.
    var command: AppCommand?
    var commandTick = 0

    /// Dobbeltklikk på toppfeltet: listen som vises ruller til toppen.
    var scrollTopTick = 0
    /// Dobbeltklikk på en fane / ⌘R: feeden som vises lastes på nytt.
    var refreshTick = 0
    /// Hvilken kolonne rulle-/oppdateringssignalet gjelder (nil = begge).
    var signalScope: SignalScope?

    /// Ber listen som vises om å rulle til toppen og/eller laste på nytt.
    func signal(scroll: Bool = false, refresh: Bool = false, scope: SignalScope? = nil) {
        signalScope = scope
        if scroll { scrollTopTick += 1 }
        if refresh { refreshTick += 1 }
    }

    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var emojiCache: (instance: String?, list: [Emoji])?

    static let postedNotification = Notification.Name("FediMactasticPosted")

    func toast(_ message: String) {
        toastMessage = message
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { toastMessage = nil }
        }
    }

    func present<V: View>(_ view: V) {
        dialogs.append(DialogItem(content: AnyView(view)))
    }

    func dismissDialog() {
        if !dialogs.isEmpty { dialogs.removeLast() }
    }

    func openViewer(_ images: [MediaAttachment], _ index: Int) {
        viewer = (images, index)
    }

    func send(_ c: AppCommand) {
        command = c
        commandTick += 1
    }

    /// Brukeren har publisert noe: tidslinjene oppdateres.
    func notifyPosted() {
        NotificationCenter.default.post(name: Self.postedNotification, object: nil)
    }

    /// Instansens egendefinerte emojier, hentet én gang per instans.
    func cachedEmojis() -> [Emoji]? {
        guard let c = emojiCache, c.instance == store.instance else { return nil }
        return c.list
    }

    func loadEmojis() async throws -> [Emoji] {
        let list = try await api.customEmojis()
            .filter(\.visibleInPicker)
            .sorted { ($0.category ?? "", $0.shortcode) < ($1.category ?? "", $1.shortcode) }
        emojiCache = (store.instance, list)
        return list
    }
}

/// Kjører en handling og viser feilen som en melding hvis den feiler.
@MainActor
func act(_ block: @escaping @MainActor () async throws -> Void) {
    Task { @MainActor in
        do {
            try await block()
        } catch is CancellationError {
        } catch {
            AppState.shared.toast(userMessage(error))
        }
    }
}

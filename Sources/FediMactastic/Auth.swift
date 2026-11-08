import AppKit
import AuthenticationServices
import SwiftUI

struct AuthState {
    var loggedIn: Bool
    /// Den aktive brukeren; skjermene lages på nytt når den byttes.
    var activeKey: String?
    var accounts: [SavedAccount] = []
    /// Innloggingsskjermen vises for å legge til en bruker, selv om man er innlogget.
    var addingAccount = false
    var me: Account?
    var busy = false
    var error: String?
    var maxChars = SessionStore.defaultMaxChars
    var postFormats: [String] = []
    var altLimit = SessionStore.defaultAltLimit
    var canEdit = false
    /// Instansen er Pleroma (har «Om»-side med panel og tjenestevilkår).
    var isPleroma = false
}

/// Kan innlegg redigeres? Pleroma sier fra med «editing» i funksjonslisten sin. Mastodon og
/// GoToSocial har ingen slik liste, men støtter redigering, så der regnes det som støttet.
private func editAllowed(_ features: [String], _ isPleroma: Bool?) -> Bool {
    features.contains("editing") || isPleroma == false
}

private final class AuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor() }
    }
}

@MainActor
@Observable
final class AuthModel {
    var state: AuthState

    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var webAuth: ASWebAuthenticationSession?
    @ObservationIgnored private let presenter = AuthPresenter()
    @ObservationIgnored private var handledCodes = Set<String>()

    private var store: SessionStore { AppState.shared.store }
    private var api: ApiClient { AppState.shared.api }

    init() {
        state = AuthState(loggedIn: false)
        state = stateFromStore()
        if store.token != nil { startSession() }
    }

    /// Tilstand for den aktive brukeren slik den er lagret (før noe er hentet fra instansen).
    private func stateFromStore() -> AuthState {
        let active = store.active
        var s = AuthState(loggedIn: active != nil)
        s.activeKey = active?.key
        s.accounts = store.accounts
        s.maxChars = active?.maxChars ?? SessionStore.defaultMaxChars
        s.postFormats = active?.postFormats ?? []
        s.altLimit = active?.altLimit ?? SessionStore.defaultAltLimit
        s.canEdit = editAllowed(active?.features ?? [], active?.isPleroma)
        s.isPleroma = active?.isPleroma == true
        return s
    }

    /// Henter brukeren og instansinfo for den aktive brukeren i bakgrunnen.
    private func startSession() {
        guard let key = store.activeKey else { return }
        sessionTask?.cancel()
        sessionTask = Task {
            do {
                try await loadSession(key)
            } catch let e as ApiError where e.code == 401 {
                if store.activeKey == key { logout() }
            } catch {
                // Offline ved oppstart: bruk det som er lagret.
            }
        }
    }

    /// Registrerer appen hos instansen og åpner innloggingssiden.
    func login(_ input: String) {
        state.busy = true
        state.error = nil
        guard let base = api.normalizeInstance(input) else {
            state.busy = false
            state.error = L("login_invalid_instance")
            return
        }
        Task {
            do {
                let reg = try await api.registerApp(base: base)
                guard let url = api.authorizeUrl(base: base, clientId: reg.clientId) else {
                    throw ApiError(code: 0, message: "Ugyldig adresse")
                }
                startWebAuth(url, base: base, clientId: reg.clientId, secret: reg.clientSecret)
            } catch {
                state.busy = false
                state.error = userMessage(error)
            }
        }
    }

    private func startWebAuth(_ url: URL, base: String, clientId: String, secret: String) {
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "feditastic") { [weak self] callback, error in
            Task { @MainActor in
                self?.webAuthFinished(callback, error, base: base, clientId: clientId, secret: secret)
            }
        }
        session.presentationContextProvider = presenter
        session.prefersEphemeralWebBrowserSession = false
        webAuth = session
        if !session.start() {
            state.busy = false
            state.error = L("login_denied")
        }
    }

    private func webAuthFinished(_ callback: URL?, _ error: Error?, base: String, clientId: String, secret: String) {
        webAuth = nil
        if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
            state.busy = false
            return
        }
        guard let callback,
              let code = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            state.busy = false
            state.error = L("login_denied")
            return
        }
        handleCode(code, base: base, clientId: clientId, secret: secret)
    }

    /// Bytter koden fra innloggingssiden mot et token og legger til brukeren.
    private func handleCode(_ code: String, base: String, clientId: String, secret: String) {
        guard handledCodes.insert(code).inserted else { return }
        let previous = store.activeKey
        state.busy = true
        state.error = nil
        Task {
            var added: SavedAccount?
            do {
                let token = try await api.exchangeToken(base: base, clientId: clientId, clientSecret: secret, code: code)
                sessionTask?.cancel()
                added = store.addAccount(instance: base, clientId: clientId, clientSecret: secret, token: token)
                try await loadSession(added!.key)
                // Samme bruker som før på samme instans: behold bare den nye innloggingen
                store.removeDuplicates(of: added!.key)
                state.loggedIn = true
                state.activeKey = added!.key
                state.accounts = store.accounts
                state.addingAccount = false
                state.busy = false
            } catch {
                if let a = added { store.removeAccount(a.key) }
                store.activeKey = previous
                state.busy = false
                state.accounts = store.accounts
                state.error = userMessage(error)
                if previous != nil { startSession() }
            }
        }
    }

    /// Viser innloggingsskjermen for å legge til en bruker til.
    func startAddingAccount() {
        state.addingAccount = true
        state.error = nil
    }

    func cancelAddingAccount() {
        webAuth?.cancel()
        webAuth = nil
        state.addingAccount = false
        state.busy = false
        state.error = nil
    }

    func switchTo(_ key: String) {
        guard key != store.activeKey, store.accounts.contains(where: { $0.key == key }) else { return }
        store.activeKey = key
        state = stateFromStore()
        startSession()
    }

    /// Logger ut den aktive brukeren. Finnes det flere, byttes det til en av dem.
    func logout() {
        sessionTask?.cancel()
        if let k = store.activeKey { store.removeAccount(k) }
        state = stateFromStore()
        if store.token != nil { startSession() }
    }

    private func loadSession(_ key: String) async throws {
        let me = try await api.verifyCredentials()
        let info = try? await api.instanceInfo()
        // Tegngrense: konfigurasjon (Mastodon/Pleroma) → max_toot_chars (Pleroma) → 5000.
        let reported = info?.maxCharacters ?? info?.maxTootChars
        let max = (reported ?? 0) > 0 ? reported! : SessionStore.defaultMaxChars
        // Tekstformater: Pleroma oppgir dem i sine metadata, GoToSocial og glitch-soc i konfigurasjonen
        let formats = info?.postFormats ?? info?.supportedMimeTypes ?? []
        let features = info?.features ?? []
        let altLimit = (info?.descriptionLimit ?? 0) > 0 ? info!.descriptionLimit! : SessionStore.defaultAltLimit
        store.updateAccount(key) {
            $0.userId = me.id
            $0.acct = me.acct
            $0.displayName = me.name
            $0.avatar = me.avatar
            $0.maxChars = max
            $0.postFormats = formats
            $0.altLimit = altLimit
            $0.features = features
            // Uten svar fra instansen beholdes det som ble funnet sist
            $0.isPleroma = info?.isPleroma ?? $0.isPleroma
        }
        let savedPleroma = store.accounts.first { $0.key == key }?.isPleroma
        // Brukeren kan ha byttet til en annen konto mens dette ble hentet
        guard store.activeKey == key else { return }
        state.me = me
        state.accounts = store.accounts
        state.maxChars = max
        state.postFormats = formats
        state.altLimit = altLimit
        state.canEdit = editAllowed(features, savedPleroma)
        state.isPleroma = savedPleroma == true
    }
}

// MARK: - Innloggingsskjermen

struct LoginView: View {
    let auth: AuthModel
    var onCancel: (() -> Void)? = nil
    @ViewState private var host = ""

    var body: some View {
        let state = auth.state
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("app_name"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(PT.topBarText)
                Spacer().frame(height: 10)
                if onCancel != nil {
                    Text(L("add_account")).bold().foregroundStyle(PT.text)
                    Spacer().frame(height: 6)
                    Text(L("add_account_intro")).foregroundStyle(PT.text)
                    Spacer().frame(height: 10)
                }
                Text(L("login_intro")).foregroundStyle(PT.text).fixedSize(horizontal: false, vertical: true)
                Spacer().frame(height: 18)
                Text(L("instance_label")).font(.system(size: PF.small)).foregroundStyle(PT.muted)
                Spacer().frame(height: 4)
                PField(placeholder: "social.gaute.space", text: $host, onSubmit: submit)
                if let e = state.error {
                    Spacer().frame(height: 10)
                    Text(e).foregroundStyle(PT.orange)
                }
                Spacer().frame(height: 18)
                HStack(spacing: 10) {
                    PButton(text: L("login_button"), filled: true, enabled: canSubmit, action: submit)
                        .keyboardShortcut(.defaultAction)
                    if let onCancel {
                        PButton(text: L("cancel"), action: onCancel)
                            .keyboardShortcut(.cancelAction)
                    }
                    if state.busy { Spinner(size: 22).padding(.leading, 4) }
                }
            }
            .font(.system(size: PF.body))
            .padding(20)
            .panel()
            .frame(maxWidth: 460)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 500)
        }
        .scrollContentBackground(.hidden)
    }

    private var canSubmit: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !auth.state.busy
    }

    private func submit() {
        if canSubmit { auth.login(host) }
    }
}

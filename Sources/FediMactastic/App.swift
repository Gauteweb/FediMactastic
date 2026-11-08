import AppKit
import SwiftUI

@MainActor let sharedAuth = AuthModel()

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FediMactasticApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window(L("app_name"), id: "main") {
            RootView()
                .frame(minWidth: 380, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 560, height: 940)
        .commands { AppCommands() }
    }
}

/// Menylinjen: «Nytt innlegg» og hurtigtaster for fanene (tilsvarer snarveiene og sveipingen på Android).
struct AppCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("menu_new_post")) { AppState.shared.send(.compose) }
                .keyboardShortcut("n")
        }
        CommandMenu(L("menu_go")) {
            ForEach(MainTab.allCases, id: \.self) { t in
                Button(t.label) { AppState.shared.send(.tab(t)) }
                    .keyboardShortcut(KeyEquivalent(Character("\(t.rawValue + 1)")))
            }
            Divider()
            Button(L("back")) { AppState.shared.send(.back) }
                .keyboardShortcut("[")
            Button(L("menu_refresh")) { AppState.shared.send(.refresh) }
                .keyboardShortcut("r")
        }
    }
}

struct RootView: View {
    private var auth: AuthModel { sharedAuth }
    private var app: AppState { AppState.shared }

    var body: some View {
        let state = auth.state
        ZStack {
            AppBackground()
            if !state.loggedIn {
                LoginView(auth: auth)
            } else {
                // Ny bruker: alle skjermer (og ViewModels) lages på nytt
                MainView(auth: auth).id(state.activeKey)
                if state.addingAccount {
                    ZStack {
                        PT.bg.ignoresSafeArea()
                        LoginView(auth: auth, onCancel: auth.cancelAddingAccount)
                    }
                }
            }
            // Bildevisningen ligger øverst, over alt annet (også bunnlinjen)
            if let v = app.viewer {
                ImageViewer(images: v.images, startIndex: v.index) { app.viewer = nil }
                    .id(v.images.map(\.id).joined() + "\(v.index)")
            }
            dialogs
            toast
        }
        .preferredColorScheme(PT.c.light ? .light : .dark)
        .tint(PT.link)
        // Hver bruker har sitt eget tema: bytt når en annen bruker blir aktiv (eller alle er logget ut)
        .onChange(of: state.activeKey, initial: true) {
            ThemeManager.shared.theme = AppTheme.from(app.store.activeTheme)
        }
        .background(WindowConfigurator())
    }

    @ViewBuilder
    private var dialogs: some View {
        ForEach(app.dialogs) { d in
            ZStack {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .onTapGesture { app.dismissDialog() }
                d.content
                    .padding(24)
                    .shadow(color: .black.opacity(0.35), radius: 16)
            }
            .transition(.opacity)
        }
        if !app.dialogs.isEmpty {
            Button("") { app.dismissDialog() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let message = app.toastMessage {
            VStack {
                Spacer()
                Text(message)
                    .font(.system(size: PF.body))
                    .foregroundStyle(PT.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(PT.fg)
                    .pBorder(PT.border)
                    .shadow(color: .black.opacity(0.3), radius: 8)
                    .padding(.bottom, 76)
                    .padding(.horizontal, 24)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: app.toastMessage)
        }
    }
}

/// Lar vinduet flyttes ved å dra i bakgrunnen, og gir det fargen til temaet før innholdet er tegnet.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.isMovableByWindowBackground = false
            w.titlebarAppearsTransparent = true
            w.backgroundColor = PT.c.bg.ns
            w.tabbingMode = .disallowed
        }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        v.window?.backgroundColor = PT.c.bg.ns
    }
}

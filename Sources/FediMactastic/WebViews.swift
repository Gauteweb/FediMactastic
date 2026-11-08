import AppKit
import SwiftUI
import WebKit

private func jsString(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    let arr = String(decoding: data, as: UTF8.self)
    return String(arr.dropFirst().dropLast())
}

// MARK: - Matrix-chat (Cinny på chat.gaute.space)

let chatUrl = URL(string: "https://chat.gaute.space/")!

/// Gir Cinny fargene i appens tema ved å overstyre Cinny sine fargevariabler. Variabelnavnene lages
/// når Cinny bygges, og kan endre seg ved oppdatering av Cinny – da faller chatten stille tilbake
/// til sine egne farger. Rekkefølgen følger Cinny sine fargegrupper: Background, Surface,
/// SurfaceVariant, Primary og Secondary.
private func chatThemeCss(_ c: PtColors) -> String {
    func hex(_ x: HexColor) -> String { x.css }
    func mix(_ a: HexColor, _ b: HexColor, _ f: Double) -> String { a.mix(b, f).css }
    let vars = [
        // Background
        hex(c.bg), mix(c.bg, c.text, 0.06), mix(c.bg, c.text, 0.12), mix(c.bg, c.text, 0.2), hex(c.text),
        // Surface
        hex(c.fg), mix(c.fg, c.text, 0.06), mix(c.fg, c.text, 0.12), hex(c.border), hex(c.text),
        // SurfaceVariant
        mix(c.fg, c.text, 0.06), mix(c.fg, c.text, 0.12), mix(c.fg, c.text, 0.18), hex(c.pressedBorder), hex(c.text),
        // Primary
        hex(c.link), mix(c.link, c.text, 0.15), mix(c.link, c.text, 0.25), hex(c.pressedBorder), hex(c.fg),
        hex(c.pressedBg), mix(c.pressedBg, c.link, 0.1), mix(c.pressedBg, c.link, 0.2), hex(c.pressedBorder), hex(c.text),
        // Secondary
        hex(c.text), hex(c.fgText), mix(c.text, c.bg, 0.15), mix(c.text, c.bg, 0.25), hex(c.fg),
        mix(c.bg, c.text, 0.12), mix(c.bg, c.text, 0.16), mix(c.bg, c.text, 0.2), mix(c.bg, c.text, 0.3), hex(c.text),
    ]
    let names = "0123456789abcdefghijklmnopqrstuvwxy".map { "--oq6d07\($0)" }
    let declarations = zip(names, vars).map { "\($0): \($1);" }.joined(separator: " ")
    return """
    html ._15q3ngn0, html ._15q3ngn1, html ._15q3ngn2, html .oq6d071w { \(declarations) }
    html body { --tc-link: \(hex(c.link)) !important; }
    """
}

/// Legger stilarket inn i siden, eller bytter det ut når temaet endres. Skjuler også Cinny sin
/// grønne «Connecting...»-linje, som blir stående lenge selv når forbindelsen allerede er tilbake.
private func chatPageJs(_ css: String) -> String {
    """
    (function () {
      var s = document.getElementById('pleromastisk-theme');
      if (!s) {
        s = document.createElement('style');
        s.id = 'pleromastisk-theme';
        (document.head || document.documentElement).appendChild(s);
      }
      s.textContent = \(jsString(css));

      if (window.pleromastiskObserver) return;
      function hideConnecting(root) {
        if (root.nodeType !== 1 || (root.textContent || '').indexOf('Connecting...') < 0) return;
        var all = [root].concat(Array.prototype.slice.call(root.querySelectorAll('*')));
        all.forEach(function (el) {
          if (el.childElementCount !== 0 || el.textContent !== 'Connecting...') return;
          var box = el.parentElement, banner = box && box.parentElement;
          if (banner && box.style.padding && banner.childElementCount === 2) banner.style.display = 'none';
        });
      }
      window.pleromastiskObserver = new MutationObserver(function (records) {
        records.forEach(function (r) { r.addedNodes.forEach(hideConnecting); });
      });
      window.pleromastiskObserver.observe(document.documentElement, { childList: true, subtree: true });
      if (document.body) hideConnecting(document.body);
    })();
    """
}

/// Holder chatten i live mens man bytter faner (og brukere), så Matrix-forbindelsen ikke kobles ned
/// og siden ikke må lastes på nytt. Nettvisningen lages første gang chatten åpnes.
@MainActor
final class ChatSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = ChatSession()

    private var appliedTheme: PtColors?

    lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        return wv
    }()

    private var started = false

    func ensureStarted(_ colors: PtColors) {
        // Temaet legges inn før siden lastes, så Cinny sine egne farger aldri vises
        applyTheme(colors)
        if !started {
            started = true
            webView.load(URLRequest(url: chatUrl))
        }
    }

    /// Gir chatten fargene i [c], både på siden som vises nå og ved neste innlasting.
    func applyTheme(_ c: PtColors) {
        guard c != appliedTheme else { return }
        appliedTheme = c
        let js = chatPageJs(chatThemeCss(c))
        webView.underPageBackgroundColor = c.bg.ns
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // Lenker til andre nettsteder åpnes i nettleseren
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.allow) }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if !mainFrame || url.host == chatUrl.host || ["about", "blob", "data"].contains(url.scheme ?? "") {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    /// Filvelgeren for bilder og andre vedlegg i chatten.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
    }
}

private struct ChatWebView: NSViewRepresentable {
    let colors: PtColors

    func makeNSView(context: Context) -> WKWebView {
        // Samme nettvisning som sist, flyttet hit fra der den ble vist forrige gang
        let wv = ChatSession.shared.webView
        wv.removeFromSuperview()
        ChatSession.shared.ensureStarted(colors)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        // Temaet kan ha blitt byttet mens chatten lå i bakgrunnen
        ChatSession.shared.applyTheme(colors)
    }
}

/// Chatten på chat.gaute.space, vist i appen.
struct ChatView: View {
    var body: some View {
        ChatWebView(colors: PT.c)
    }
}

// MARK: - «Om»-siden til instansen

/// «Om»-siden til instansen brukeren er logget inn på, vist i appen (med vanlige menyer rundt).
/// Pleroma: panel-teksten og tjenestevilkårene, som Pleroma-FE sin /about.
/// Ellers (Mastodon m.fl.): det samme som Mastodons /about, hentet fra API-et.
struct InstanceAboutView: View {
    let pleroma: Bool
    @ViewState private var attempt = 0
    @ViewState private var result: Result<[String], Error>?

    var body: some View {
        Group {
            switch result {
            case nil: VStack { LoadingRow(); Spacer() }
            case .failure(let e): VStack { ErrorPanel(message: userMessage(e)) { attempt += 1 }; Spacer() }
            case .success(let sections) where sections.isEmpty: VStack { MessagePanel(text: L("instance_about_empty")); Spacer() }
            case .success(let sections):
                AboutWebView(page: aboutPage(sections), base: AppState.shared.store.instance ?? "")
                    .pBorder(PT.border)
            }
        }
        .padding(8)
        .frame(maxWidth: contentMaxWidth)
        .frame(maxWidth: .infinity)
        .task(id: attempt) {
            result = nil
            do {
                result = .success(pleroma ? try await AppState.shared.api.instanceAboutHtml() : try await mastodonAbout())
            } catch {
                result = .failure(error)
            }
        }
    }

    /// Ren tekst trygt inn i HTML, med linjeskift bevart.
    private func enc(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    /// Seksjonene på Mastodons /about: navn og kort beskrivelse, den lange beskrivelsen, serverreglene
    /// og hvem som administrerer instansen.
    private func mastodonAbout() async throws -> [String] {
        let api = AppState.shared.api
        async let infoTask = api.instanceInfo()
        async let extendedTask = api.extendedDescription()
        async let rulesTask = api.instanceRules()
        let i = try await infoTask
        let long = try await extendedTask.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = try await rulesTask.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        var out: [String] = []
        let short = i.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let intro = short.isEmpty || short == long ? "" : short.contains("<") ? short : "<p>\(enc(short))</p>"
        let title = i.title.isEmpty ? "" : "<h1>\(enc(i.title))</h1>"
        if !title.isEmpty || !intro.isEmpty { out.append(title + intro) }
        if !long.isEmpty { out.append(long) }
        if !rules.isEmpty {
            out.append("<h2>\(enc(L("instance_about_rules")))</h2><ol>" + rules.map { r in
                "<li>" + enc(r.text) + (r.hint.isEmpty ? "" : "<br><small>\(enc(r.hint))</small>") + "</li>"
            }.joined() + "</ol>")
        }
        let admin = i.contactAccount.flatMap { $0.acct.isEmpty ? nil : "<a href=\"\(enc($0.url))\">@\(enc($0.acct))</a>" }
        let mail = i.email.isEmpty ? nil : "<a href=\"mailto:\(enc(i.email))\">\(enc(i.email))</a>"
        if admin != nil || mail != nil {
            out.append("<h2>\(enc(L("instance_about_contact")))</h2><p>" + [admin, mail].compactMap { $0 }.joined(separator: "<br>") + "</p>")
        }
        return out
    }

    /// Setter seksjonene sammen til én side med appens farger.
    private func aboutPage(_ sections: [String]) -> String {
        let c = PT.c
        return """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html { background: \(c.fg.css); }
          body { margin: 0; padding: 14px; background: \(c.fg.css); color: \(c.text.css);
                 font-family: -apple-system, sans-serif; font-size: 14px; line-height: 1.45; word-wrap: break-word; }
          a { color: \(c.link.css); }
          h1, h2, h3 { color: \(c.topBarText.css); line-height: 1.2; }
          h1 { font-size: 1.35em; } h2 { font-size: 1.2em; } h3 { font-size: 1.05em; }
          img, video { max-width: 100%; height: auto; }
          table { border-collapse: collapse; max-width: 100%; }
          td, th { border: 1px solid \(c.border.css); padding: 4px; }
          hr, .section { border: 0; border-top: 1px solid \(c.border.css); margin: 18px 0; }
        </style>
        </head><body>
        \(sections.joined(separator: "\n<hr class=\"section\">\n"))
        </body></html>
        """
    }
}

private final class AboutDelegate: NSObject, WKNavigationDelegate {
    var lastPage: String?

    // Lenker åpnes i nettleseren, ikke inne i «Om»-visningen
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}

private struct AboutWebView: NSViewRepresentable {
    let page: String
    let base: String
    @Environment(\.screenActive) private var active

    func makeCoordinator() -> AboutDelegate { AboutDelegate() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.loadHTMLString(page, baseURL: URL(string: base + "/"))
        context.coordinator.lastPage = page
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        wv.underPageBackgroundColor = PT.c.fg.ns
        if context.coordinator.lastPage != page {
            context.coordinator.lastPage = page
            wv.loadHTMLString(page, baseURL: URL(string: base + "/"))
        }
    }
}

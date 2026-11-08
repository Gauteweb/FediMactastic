import AppKit
import SwiftUI

@MainActor
struct DialogButton {
    let text: String
    var color: Color? = nil
    var enabled = true
    let action: () -> Void

    static func close(_ text: String = L("about_close")) -> DialogButton {
        DialogButton(text: text) { AppState.shared.dismissDialog() }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Rullbart område som er akkurat så høyt som innholdet, men ikke høyere enn [maxHeight].
struct AutoHeightScroll<Content: View>: View {
    var maxHeight: CGFloat = 520
    @ViewBuilder let content: Content
    @ViewState private var height: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
        }
        .scrollContentBackground(.hidden)
        .frame(height: min(max(height, 1), maxHeight))
        .onPreferenceChange(HeightKey.self) { height = $0 }
    }
}

/// Dialog i temaets stil: flate med tynn kantlinje, tittel i overskriftsfargen og tekstknapper nederst.
struct PDialog<Title: View, Content: View>: View {
    let title: Title
    let content: Content
    var buttons: [DialogButton]
    var width: CGFloat = 420

    init(buttons: [DialogButton], width: CGFloat = 420, @ViewBuilder title: () -> Title, @ViewBuilder content: () -> Content) {
        self.buttons = buttons
        self.width = width
        self.title = title()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            title
            AutoHeightScroll { content }
            HStack(spacing: 4) {
                Spacer()
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in
                    PTextButton(text: b.text, color: b.color, enabled: b.enabled, action: b.action)
                }
            }
        }
        .font(.system(size: PF.body))
        .padding(22)
        .frame(width: width)
        .background(PT.fg)
        .pBorder(PT.border)
    }
}

extension PDialog where Title == DialogTitle {
    init(_ title: String, buttons: [DialogButton], width: CGFloat = 420, @ViewBuilder content: () -> Content) {
        self.init(buttons: buttons, width: width, title: { DialogTitle(text: title) }, content: content)
    }
}

struct DialogTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 20, weight: .bold)).foregroundStyle(PT.topBarText)
    }
}

/// Kort forklaring av en side, fra info-ikonet øverst til høyre (Bilder, Matrix).
struct InfoDialog: View {
    let title: String
    let text: String
    var body: some View {
        PDialog(title, buttons: [.close()]) {
            Text(text).foregroundStyle(PT.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ConfirmDialog: View {
    let title: String
    let text: String
    let confirm: String
    let onConfirm: () -> Void

    var body: some View {
        PDialog(title, buttons: [
            DialogButton(text: L("cancel")) { AppState.shared.dismissDialog() },
            DialogButton(text: confirm, color: PT.orange) {
                AppState.shared.dismissDialog()
                onConfirm()
            },
        ]) {
            Text(text).foregroundStyle(PT.fgText)
        }
    }
}

private let repoUrl = "https://github.com/Gauteweb/Feditastic"

/// «Om appen», fra info-ikonet på profilsiden.
struct AboutDialog: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        PDialog(L("about_title"), buttons: [.close()]) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("about_p1")).foregroundStyle(PT.text).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("about_p3")).foregroundStyle(PT.text)
                    Text(repoUrl)
                        .foregroundStyle(PT.link)
                        .underline()
                        .onTapGesture { openExternal(repoUrl) }
                        .handCursor()
                }
                Text(L("about_version", version)).foregroundStyle(PT.text)
            }
        }
    }
}

/// Velg fargetema. Temaet tas i bruk med en gang og huskes for brukeren man er logget inn som.
struct ThemePickerDialog: View {
    var body: some View {
        PDialog(L("theme_title"), buttons: [.close()]) {
            VStack(spacing: 8) {
                ForEach(AppTheme.allCases) { theme in
                    let active = theme == ThemeManager.shared.theme
                    HStack(spacing: 12) {
                        swatch(theme.colors)
                        Text(theme.label)
                            .fontWeight(active ? .bold : .regular)
                            .foregroundStyle(PT.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if active {
                            Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(PT.topBarText)
                        }
                    }
                    .padding(8)
                    .pBorder(active ? PT.border : PT.border.opacity(0.35))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        ThemeManager.shared.theme = theme
                        AppState.shared.store.saveTheme(theme.rawValue)
                    }
                }
            }
            FontSizeSlider().padding(.top, 8)
        }
    }

    /// Liten forhåndsvisning av et tema: bakgrunn med en flate, en knapp og overskriftsfargen.
    private func swatch(_ c: PtColors) -> some View {
        HStack(spacing: 4) {
            ForEach([c.fg, c.link, c.topBarText], id: \.argb) { fill in
                Rectangle().fill(fill.color).frame(width: 14, height: 14).pBorder(c.border.color)
            }
        }
        .padding(6)
        .background(c.bg.color)
        .pBorder(c.border.color)
    }
}

/// Glider for skriftstørrelsen i feedene. Endringen vises med en gang i feeden bak dialogen.
private struct FontSizeSlider: View {
    var body: some View {
        let tm = ThemeManager.shared
        let scale = Binding(get: { tm.fontScale }, set: { tm.fontScale = ($0 * 20).rounded() / 20 })
        VStack(alignment: .leading, spacing: 8) {
            PDivider(color: PT.border.opacity(0.5))
            HStack {
                Text(L("font_size")).bold().foregroundStyle(PT.text)
                Spacer()
                Text("\(Int((tm.fontScale * 100).rounded())) %").foregroundStyle(PT.muted).monospacedDigit()
            }
            HStack(spacing: 10) {
                Text("A").font(.system(size: 12, weight: .semibold)).foregroundStyle(PT.link)
                Slider(value: scale, in: ThemeManager.fontScaleRange, step: 0.05)
                    .tint(PT.link)
                Text("A").font(.system(size: 20, weight: .semibold)).foregroundStyle(PT.link)
            }
            HStack {
                Text("Aa").font(.system(size: PF.feedBody)).foregroundStyle(PT.text)
                Spacer()
                PTextButton(text: L("font_reset"), enabled: tm.fontScale != 1) { tm.fontScale = 1 }
            }
        }
    }
}

/// «Bytt bruker»: velg en av de innloggede brukerne, eller legg til en ny.
struct AccountSwitchDialog: View {
    let auth: AuthModel
    let onSelect: (String) -> Void
    let onAdd: () -> Void

    var body: some View {
        PDialog(L("switch_account"), buttons: [DialogButton(text: L("cancel")) { AppState.shared.dismissDialog() }]) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(auth.state.accounts) { a in
                    let active = a.key == auth.state.activeKey
                    HStack(spacing: 10) {
                        Avatar(url: a.avatar, size: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.displayName.isEmpty ? (a.acct.isEmpty ? a.handle : a.acct) : a.displayName)
                                .bold().foregroundStyle(PT.text).lineLimit(1)
                            Text("@" + a.handle).font(.system(size: PF.small)).foregroundStyle(PT.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if active {
                            Image(systemName: "checkmark")
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(PT.topBarText)
                                .help(L("switch_account_active"))
                        }
                    }
                    .padding(8)
                    .pBorder(active ? PT.border : PT.border.opacity(0.35))
                    .contentShape(Rectangle())
                    .onTapGesture { if active { AppState.shared.dismissDialog() } else { onSelect(a.key) } }
                }
                PButton(text: L("add_account"), icon: "person.badge.plus", action: onAdd).padding(.top, 4)
            }
        }
    }
}

/// Legg kontoen til i (eller fjern den fra) mine lister, eller lag en ny liste med den i.
struct ListMembershipDialog: View {
    let model: AccountModel
    @ViewState private var newTitle = ""

    var body: some View {
        PDialog(L("lists_add_title"), buttons: [.close()]) {
            VStack(alignment: .leading, spacing: 0) {
                if let s = model.lists {
                    if s.lists.isEmpty {
                        Text(L("lists_none")).foregroundStyle(PT.muted)
                    }
                    ForEach(s.lists) { list in
                        let member = s.memberOf.contains(list.id)
                        HStack(spacing: 10) {
                            Image(systemName: member ? "checkmark.square.fill" : "square")
                                .font(.system(size: 17))
                                .foregroundStyle(PT.link)
                            Text(list.title).foregroundStyle(PT.text)
                            Spacer()
                        }
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                        .onTapGesture { model.setInList(list.id, add: !member) }
                    }
                } else {
                    LoadingRow()
                }
                PDivider().padding(.vertical, 12)
                Text(L("lists_new")).bold().foregroundStyle(PT.topBarText)
                HStack(spacing: 8) {
                    PField(placeholder: L("lists_new_hint"), text: $newTitle, onSubmit: create)
                    PButton(text: L("lists_create"), filled: true, enabled: canCreate, action: create)
                }
                .padding(.top, 6)
            }
        }
        .onAppear { model.loadLists() }
    }

    private var canCreate: Bool {
        !newTitle.trimmingCharacters(in: .whitespaces).isEmpty && model.lists != nil
    }

    private func create() {
        guard canCreate else { return }
        model.createListAndAdd(newTitle)
        newTitle = ""
    }
}

/// Profilbildet i stort format, i samme stil som «Bytt bruker».
struct AvatarDialog: View {
    let account: Account
    var body: some View {
        PDialog(buttons: [.close()], width: 460) {
            EmojiText(text: account.name, emojis: account.emojis, size: 20, tone: .topBarText, bold: true, maxLines: 2)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                RemoteImage(url: account.avatar, fill: false, maxPixel: 1200)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(PT.bg)
                    .pBorder(PT.border)
                    .help(L("avatar_description", account.name))
                Text("@" + account.acct).font(.system(size: PF.small)).foregroundStyle(PT.muted).textSelection(.enabled)
            }
        }
    }
}

/// Helsestatusen til Pleroma-tjeneren, fra /api/pleroma/healthcheck: sunn eller ikke,
/// databasetilkoblinger, minnebruk og jobbkøene siden tjeneren startet.
struct HealthDialog: View {
    @ViewState private var attempt = 0
    /// nil = laster; .success(nil) = sjekken er slått av på tjeneren
    @ViewState private var result: Result<Healthcheck?, Error>?

    var body: some View {
        PDialog(L("health_title"), buttons: [
            DialogButton(text: L("health_refresh"), enabled: result != nil) { attempt += 1 },
            .close(),
        ]) {
            Group {
                switch result {
                case nil: LoadingRow()
                case .failure(let e): Text(userMessage(e)).foregroundStyle(PT.text)
                case .success(nil): Text(L("health_disabled")).foregroundStyle(PT.text)
                case .success(let h?): content(h)
                }
            }
        }
        .task(id: attempt) {
            result = nil
            do { result = .success(try await AppState.shared.api.healthcheck()) } catch { result = .failure(error) }
        }
    }

    private func content(_ h: Healthcheck) -> some View {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.locale = Lang.locale
        let fmt = { (n: Int) in nf.string(from: NSNumber(value: n)) ?? "\(n)" }
        let healthy = h.healthy == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: healthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(healthy ? PT.green : PT.red)
                Text(L(healthy ? "health_ok" : "health_bad")).bold().foregroundStyle(PT.text)
            }
            PDivider()
            VStack(alignment: .leading, spacing: 2) {
                Text(L("health_db")).foregroundStyle(PT.text)
                Text(L("health_db_value", h.active, h.idle) + (h.poolSize.map { " / " + L("health_db_pool", $0) } ?? ""))
                    .bold().foregroundStyle(PT.text)
            }
            if let mem = h.memoryUsed {
                statRow(L("health_memory"), String(format: "%.0f MB", mem))
            }
            if let total = h.processedJobs {
                PDivider()
                Text(L("health_jobs")).bold().foregroundStyle(PT.topBarText)
                Text(L("health_jobs_hint")).foregroundStyle(PT.muted).fixedSize(horizontal: false, vertical: true)
                statRow(L("health_jobs_total"), fmt(total))
                ForEach(h.queues.sorted { $0.stats.processedJobs > $1.stats.processedJobs }, id: \.name) { q in
                    HStack {
                        Text(queueLabel(q.name)).foregroundStyle(PT.text)
                        Spacer()
                        Text("✓ " + fmt(q.stats.success)).foregroundStyle(PT.green)
                        Text("✗ " + fmt(q.stats.failure)).foregroundStyle(q.stats.failure > 0 ? PT.red : PT.muted)
                    }
                }
            }
        }
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(PT.text)
            Spacer()
            Text(value).bold().foregroundStyle(PT.text)
        }
    }

    /// Lesbart navn på Pleromas jobbkøer; ukjente køer vises med navnet sitt.
    private func queueLabel(_ name: String) -> String {
        switch name {
        case "federator_incoming": return L("health_queue_incoming")
        case "federator_outgoing": return L("health_queue_outgoing")
        case "background": return L("health_queue_background")
        case "search_indexing": return L("health_queue_search")
        case "web_push": return L("health_queue_push")
        case "slow": return L("health_queue_slow")
        default:
            let s = name.replacingOccurrences(of: "_", with: " ")
            return s.prefix(1).uppercased() + s.dropFirst()
        }
    }
}

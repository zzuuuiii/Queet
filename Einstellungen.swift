import SwiftUI
import AppKit
import ApplicationServices

// MARK: Einstellungen von „Queet“ im Stil von BarDrop
//
// Öffnet sich, wenn man die App von Hand startet (Doppelklick, Spotlight). Der Hintergrund
// läuft getrennt (Anmeldeobjekt) und liest die Werte bei jeder Prüfung neu,
// Änderungen gelten also sofort. Schließt man das Fenster, beendet sich nur dieses Fenster.

/// Werte in der Domäne com.zzuuuiii.queet
final class Einstellungen: ObservableObject {
    private let d = UserDefaults.standard

    @Published var aktiv: Bool { didSet { d.set(!aktiv, forKey: "pause") } }
    @Published var frist: Double { didSet { d.set(frist, forKey: "gnadenfrist") } }
    @Published var ausnahmen: [String] { didSet { d.set(ausnahmen, forKey: "ausnahmen") } }
    @Published var freigabe = AXIsProcessTrusted()
    @Published var verlauf: [(id: String, zeit: Date)] = []

    init() {
        aktiv = !d.bool(forKey: "pause")
        let f = d.double(forKey: "gnadenfrist")
        frist = f > 0 ? f : 0.5
        ausnahmen = (d.array(forKey: "ausnahmen") as? [String]) ?? []
        // Freigabe nachprüfen, solange das Fenster offen ist (wird in den Systemeinstellungen erteilt)
        verlaufLesen()
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            let jetzt = AXIsProcessTrusted()
            if self?.freigabe != jetzt { self?.freigabe = jetzt }
            self?.verlaufLesen()
        }
    }

    private func verlaufLesen() {
        let neu = ((d.array(forKey: "verlauf") as? [[String: Any]]) ?? []).compactMap { e -> (id: String, zeit: Date)? in
            guard let id = e["id"] as? String, let zeit = e["zeit"] as? Date else { return nil }
            return (id, zeit)
        }
        if neu.map(\.id) != verlauf.map(\.id) || neu.map(\.zeit) != verlauf.map(\.zeit) { verlauf = neu }
    }

    func nieBeendet(_ id: String) -> Bool { ausnahmen.contains(id) }

    func nieBeenden(_ id: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            if !ausnahmen.contains(id) { ausnahmen.append(id) }
        }
    }

    var liste: [String] {
        get { ausnahmen }
        set { ausnahmen = newValue }
    }
}

// MARK: App und Fenster

enum EinstellungenApp {
    static let einstellungen = Einstellungen()
    static var fenster: NSWindow?
    private static let delegat = Delegat()

    /// Eigener Prozess nur für das Fenster; er endet mit dem Fenster
    static func starten() {
        NSApplication.shared.delegate = delegat
        zeigen()
    }

    static func zeigen() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = menue()
        let w = fenster ?? fensterBauen()
        fenster = w
        w.makeKeyAndOrderFront(nil)
        app.activate()
    }

    private final class Delegat: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
        func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
            EinstellungenApp.zeigen()
            return true
        }
    }

    /// Kleinstes Menü, damit ⌘W, ⌘Q und Bearbeiten wie gewohnt gehen
    private static func menue() -> NSMenu {
        let haupt = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(ClosureMenuItem("Nach Updates suchen …") { MainActor.assumeIsolated { Updater.suchen() } })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Queet ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Einstellungen schließen", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        haupt.addItem(appItem)
        let fensterItem = NSMenuItem()
        let fensterMenu = NSMenu(title: "Fenster")
        fensterMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fensterMenu.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        fensterItem.submenu = fensterMenu
        haupt.addItem(fensterItem)
        return haupt
    }

    static let groesse = NSSize(width: 440, height: 580)

    /// Fenster wie die Einstellungen von BarDrop: durchscheinend, hohe Titelleiste ohne Titel
    private static func fensterBauen() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: groesse),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.toolbar = NSToolbar(identifier: "QueetEinstellungen")
        if #available(macOS 26.0, *) { w.toolbarStyle = .unifiedCompact } else { w.toolbarStyle = .unified }
        w.titlebarSeparatorStyle = .none
        w.title = "Queet"
        w.isMovableByWindowBackground = false
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView = NSHostingView(rootView: EinstellungenRoot(einstellungen: einstellungen))
        w.setContentSize(groesse)
        w.center()
        w.setFrameAutosaveName("QueetEinstellungen")
        return w
    }
}

// MARK: Inhalt

struct EinstellungenRoot: View {
    @ObservedObject var einstellungen: Einstellungen

    var body: some View {
        detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsTheme.contentBackdrop)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsBackdrop().ignoresSafeArea())
            .ignoresSafeArea()
    }

    /// Wie in BarDrop: ab macOS 26 liegt die Überschrift als Leiste über dem Inhalt
    /// Ohne Seitenleiste: Die Ampel hat die Titelleiste für sich, Symbol und Name stehen darunter
    /// an derselben linken Kante wie die Karten (vorher neben der Ampel, wirkte zu weit in der Mitte)
    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 46)
            titel
                .padding(.leading, 20)
                .padding(.bottom, 14)
            seite
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Nur der Name, ohne Symbol
    private var titel: some View {
        Text("Queet")
            .font(.system(size: 17, weight: .semibold))
    }

    private var seite: some View {
        SettingsPage {
            if !einstellungen.freigabe {
                SettingsSection(note: "Ohne diese Freigabe kann Queet nicht sehen, wann ein Fenster zugeht.") {
                    SettingsRow("Zugriff auf Bedienungshilfen fehlt") {
                        Button("Öffnen") { freigabeOeffnen() }
                            .buttonStyle(KlackButtonStyle())
                    }
                }
            }

            SettingsSection {
                ToggleRow("Apps beim Schließen beenden", isOn: $einstellungen.aktiv)
                // Regler in Sekunden, Wert rechts
                VStack(spacing: 0) {
                    SettingsRow("Wartezeit",
                                info: "So lange wartet Queet nach dem letzten Fenster, bevor die App beendet wird. Direkt nach dem Start einer App und nach einem Öffnen-Fenster wartet es länger, damit nichts beim Laden beendet wird.") {
                        Text(einstellungen.frist.formatted(.number.precision(.fractionLength(1...2))) + " s")
                            .font(.system(size: 12.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().strokeBorder(Color.primary.opacity(0.15)))
                    }
                    // Grobe Stufen von 0,25 s mit Vibration bei jeder Stufe
                    Slider(value: Binding(get: { einstellungen.frist },
                                          set: { neu in
                                              let stufe = (neu * 4).rounded() / 4
                                              guard stufe != einstellungen.frist else { return }
                                              einstellungen.frist = stufe
                                              NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                                          }), in: 0.25...2, step: 0.25)
                        .padding(.horizontal, SettingsTheme.rowPadding)
                        .padding(.bottom, 12)
                }
                .disabled(!einstellungen.aktiv)
            }

            SettingsSection("Zuletzt beendet") {
                if einstellungen.verlauf.isEmpty {
                    Text("Noch keine App beendet")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, SettingsTheme.rowPadding)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                ForEach(Array(einstellungen.verlauf.prefix(3)), id: \.id) { e in
                    let nie = einstellungen.nieBeendet(e.id)
                    AppReihe(bundleID: e.id, knopf: nie ? nil : "Nie beenden", hinweis: nie ? "Wird nie beendet" : nil) {
                        einstellungen.nieBeenden(e.id)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSection("Ausnahmen") {
                    if einstellungen.liste.isEmpty {
                        Text("Keine Apps ausgenommen")
                            .font(.system(size: 13.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, SettingsTheme.rowPadding)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    ForEach(einstellungen.liste, id: \.self) { id in
                        AppReihe(bundleID: id, knopf: "Entfernen") {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
                                einstellungen.liste.removeAll { $0 == id }
                            }
                        }
                    }
                }
                AppHinzufuegen(einstellungen: einstellungen)
                    .padding(.top, 4)
            }
            .disabled(!einstellungen.aktiv)
        }
    }

    private func freigabeOeffnen() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Name und Symbol einer App, einmal gelesen und gemerkt (sonst flackern die Symbole beim
/// Darüberfahren, weil jede Neuzeichnung sie neu lädt)
@MainActor private enum AppInfo {
    static var cache: [String: (name: String, icon: NSImage?)] = [:]
    static func lesen(_ id: String) -> (name: String, icon: NSImage?) {
        if let c = cache[id] { return c }
        var e: (name: String, icon: NSImage?) = (id, nil)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            e = ((FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension,
                 NSWorkspace.shared.icon(forFile: url.path))
        }
        cache[id] = e; return e
    }
}

/// Eine App in einer Liste: Symbol, Name; beim Darüberfahren grau hinterlegt mit einem Knopf rechts.
/// Gleich für „Zuletzt beendet“ und „Ausnahmen“.
private struct AppReihe: View {
    let bundleID: String
    let knopf: String?
    var hinweis: String? = nil
    let aktion: () -> Void
    @State private var hovering = false

    var body: some View {
        let info = AppInfo.lesen(bundleID)
        HStack(spacing: 10) {
            Group {
                if let icon = info.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 18)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)
            Text(info.name).font(.system(size: 13.5)).lineLimit(1)
            Spacer(minLength: 8)
            if hovering, let knopf {
                Button(knopf, action: aktion).buttonStyle(KlackButtonStyle())
            } else if let hinweis {
                Text(hinweis).font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, SettingsTheme.rowPadding)
        .frame(height: 44)
        .background(Color.primary.opacity(hovering && knopf != nil ? 0.04 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// „+ ⌄“ unter der Liste: zuletzt geöffnete Apps oder eine andere wählen (wie in BarDrop).
private struct AppHinzufuegen: View {
    @ObservedObject var einstellungen: Einstellungen
    @State private var frame: CGRect = .zero

    var body: some View {
        AddListRow(title: "App hinzufügen", frame: $frame, action: menueZeigen)
    }

    private func menueZeigen() {
        let eigene = Bundle.main.bundleIdentifier
        let laufend = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
            .compactMap { app -> (id: String, name: String, icon: NSImage?)? in
                guard let id = app.bundleIdentifier, id != eigene, id != "com.apple.finder",
                      !einstellungen.liste.contains(id) else { return nil }
                return (id, app.localizedName ?? id, app.icon)
            }
            .prefix(8)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let menu = NSMenu()
        if !laufend.isEmpty {
            menu.addItem(.sectionHeader(title: "Geöffnete Apps"))
            for app in laufend {
                let item = ClosureMenuItem(app.name) { hinzufuegen(app.id) }
                if let icon = app.icon { item.image = MenuIcon.file(icon) }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        let andere = ClosureMenuItem("Andere App wählen") { waehlen() }
        andere.image = MenuIcon.file(NSWorkspace.shared.icon(forFile: "/Applications"))
        menu.addItem(andere)
        MenuPresenter.show(menu, below: frame)
    }

    private func hinzufuegen(_ id: String) {
        guard !einstellungen.liste.contains(id) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            einstellungen.liste.append(id)
        }
    }

    private func waehlen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Hinzufügen"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { hinzufuegen(id) }
        }
    }
}

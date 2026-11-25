// Queet: Beendet eine Dock-App, wenn ihr letztes Fenster geschlossen wird.
// Ohne Oberfläche, ereignisgesteuert, nur offizielle Schnittstellen.
// Einstellungen: App öffnen (Einstellungsfenster) oder per Terminal (Domäne com.zzuuuiii.queet):
//   defaults write com.zzuuuiii.queet ausnahmen -array com.beispiel.app …   Apps, die nie beendet werden
//   defaults write com.zzuuuiii.queet pause -bool true                        Pause
//   defaults write com.zzuuuiii.queet gnadenfrist -float 0.5                  Wartezeit (lang: gnadenfrist-lang)
// Prüfen: Queet.app/Contents/MacOS/queet --pruefen
import AppKit
import ApplicationServices
import ServiceManagement

let einst = UserDefaults.standard // Domäne com.zzuuuiii.queet (Bundle-ID)
// Gnadenfrist (gemessen 2026-11-25: Fenster sind nach < 0,15 s aus der Liste verschwunden).
// Kurz im Normalfall, lang, wenn die App gerade erst gestartet ist oder kurz vorher Fenster
// auf- und zugingen (Ladefenster, Öffnen-Dialog, Begrüßungsfenster → Dokumentfenster).
func kurzeFrist() -> Double { let v = einst.double(forKey: "gnadenfrist"); return v > 0 ? v : 0.5 }
func langeFrist() -> Double { let v = einst.double(forKey: "gnadenfrist-lang"); return v > 0 ? v : 2.5 }
var letzteFensterAktivitaet: [pid_t: Date] = [:]
var hatteHauptfenster: Set<pid_t> = []
var unterrollen: [pid_t: [(AXUIElement, String)]] = [:] // Fenster → Unterrolle bzw. "panel"
let immerAusnehmen: Set<String> = ["com.apple.finder", "com.zzuuuiii.queet"]

/// Protokoll in ~/Library/Logs/queet.log (der Autostart über SMAppService leitet nichts um)
let logPfad = NSHomeDirectory() + "/Library/Logs/queet.log"
func log(_ s: String) {
    let z = ISO8601DateFormatter().string(from: Date()) + " " + s + "\n"
    if !FileManager.default.fileExists(atPath: logPfad) { FileManager.default.createFile(atPath: logPfad, contents: nil) }
    guard let h = FileHandle(forWritingAtPath: logPfad) else { return }
    h.seekToEndOfFile(); h.write(Data(z.utf8)); try? h.close()
}

/// Zuletzt beendete Apps für das Einstellungsfenster (neueste zuerst, höchstens 20)
func verlaufMerken(_ id: String?) {
    guard let id else { return }
    var liste = (einst.array(forKey: "verlauf") as? [[String: Any]]) ?? []
    liste.removeAll { ($0["id"] as? String) == id }
    liste.insert(["id": id, "zeit": Date()], at: 0)
    einst.set(Array(liste.prefix(20)), forKey: "verlauf")
}

func ausgenommen(_ app: NSRunningApplication) -> Bool {
    guard let id = app.bundleIdentifier else { return true }
    if immerAusnehmen.contains(id) { return true }
    let liste = (einst.array(forKey: "ausnahmen") as? [String]) ?? []
    return liste.contains { $0.caseInsensitiveCompare(id) == .orderedSame }
}

func attr<T>(_ el: AXUIElement, _ n: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success else { return nil }
    return v as? T
}

/// Hat die App noch ein echtes Fenster? Im Zweifel ja (dann wird nichts beendet).
func hatFenster(_ app: NSRunningApplication) -> Bool {
    let pid = app.processIdentifier
    let a = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(a, 0.5)
    var v: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(a, kAXWindowsAttribute as CFString, &v)
    guard err == .success, let ws = v as? [AXUIElement] else { return true } // App antwortet nicht: nicht anfassen
    // Bedienungshilfen: jedes Fenster zählt, auch minimierte und ausgeblendete
    if ws.contains(where: { (attr($0, kAXSubroleAttribute) as String?) != nil || (attr($0, kAXMinimizedAttribute) as Bool?) == true }) { return true }
    // Fenster auf anderen Schreibtischen oder im Vollbild zeigen die Bedienungshilfen nicht an.
    // Deshalb eigene Liste: jedes normale Fenster, das aufging und noch nicht zuging, gilt als offen.
    // Beim Prüfen frisch nachsehen: Öffnen-/Sichern-Fenster sind oft nur ausgeblendet und zählen nicht,
    // nicht mehr gültige Fenster fliegen raus.
    var bleiben: [(AXUIElement, String)] = []
    var offen = false
    for (w, rolle) in unterrollen[pid] ?? [] {
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &v) == .invalidUIElement { continue }
        let jetzt = (attr(w, kAXSubroleAttribute) as String?) ?? rolle
        let id = attr(w, kAXIdentifierAttribute) as String?
        let panel = id == "open-panel" || id == "save-panel"
        bleiben.append((w, panel ? "panel" : jetzt))
        if !panel && jetzt == kAXStandardWindowSubrole as String { offen = true }
    }
    unterrollen[pid] = bleiben
    if offen { return true }
    return false
}

func frist(_ app: NSRunningApplication, panel: Bool) -> Double {
    let pid = app.processIdentifier
    if panel { return langeFrist() } // Öffnen-/Sichern-Fenster zu: meist folgt gleich das Dokument
    if let start = app.launchDate, Date().timeIntervalSince(start) < 15 { return langeFrist() }
    if let t = letzteFensterAktivitaet[pid], Date().timeIntervalSince(t) < 3 { return langeFrist() }
    return kurzeFrist()
}

var geplant: Set<pid_t> = []
var beendetVonMir: Set<pid_t> = []

/// Hat die App ein minimiertes Fenster? (Das soll sie offen halten, auch wenn sie sich versteckt hat)
func hatMinimiertes(_ app: NSRunningApplication) -> Bool {
    let a = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(a, 0.5)
    guard let ws: [AXUIElement] = attr(a, kAXWindowsAttribute) else { return true }
    return ws.contains { (attr($0, kAXMinimizedAttribute) as Bool?) == true }
}

/// versteckt: Die App hat sich beim Schließen ganz versteckt (z. B. Gemini). Dann zählt nur, ob sie
/// noch versteckt ist und kein minimiertes Fenster hat; ihre versteckten Fenster zählen nicht.
func pruefen(_ pid: pid_t, panel: Bool = false, versteckt: Bool = false, grund: String) {
    guard !geplant.contains(pid) else { return }
    guard let app0 = NSRunningApplication(processIdentifier: pid) else { return }
    geplant.insert(pid)
    let f = frist(app0, panel: panel)
    // Normales Schließen des letzten Fensters: die App dahinter sofort nach vorn holen, nicht erst
    // nach dem Beenden (sonst bleibt der Fokus kurz bei der fensterlosen App)
    // (kurz warten, bis das Fenster aus der Liste verschwunden ist)
    if !panel {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard app0.isActive, kandidat(app0), !(versteckt ? (!app0.isHidden || hatMinimiertes(app0)) : hatFenster(app0)),
                  let naechste = appDahinter(pid) else { return }
            nachVorn(naechste)
        }
    }
    // Zweimal nachsehen: nach der Gnadenfrist und kurz danach noch einmal
    func offen(_ app: NSRunningApplication) -> Bool {
        versteckt ? (!app.isHidden || hatMinimiertes(app)) : hatFenster(app)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + f) {
        guard let app = NSRunningApplication(processIdentifier: pid), kandidat(app), !offen(app) else { geplant.remove(pid); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            geplant.remove(pid)
            guard kandidat(app), !offen(app) else { return }
            hatteHauptfenster.remove(pid)
            log("beende \(app.bundleIdentifier ?? "?") (\(grund), Frist \(f) s)")
            // In „Zuletzt beendet“ erst, wenn sie wirklich zu ist (Abbrechen bei ungesicherten Änderungen)
            beendetVonMir.insert(pid)
            app.terminate() // wie Befehl-Q: die App darf nachfragen (z. B. ungesicherte Änderungen)
        }
    }
}

/// Die App mit dem obersten sichtbaren Fenster hinter der App pid (wie macOS nach dem Beenden)
func appDahinter(_ pid: pid_t) -> NSRunningApplication? {
    let liste = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in liste where (w[kCGWindowLayer as String] as? Int) == 0 {
        guard let p = w[kCGWindowOwnerPID as String] as? pid_t, p != pid, p != getpid(),
              let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular, !app.isHidden else { continue }
        return app
    }
    return NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
}

/// Holt eine App nach vorn. Über die Bedienungshilfen, weil macOS Wechsel von Hintergrund-Apps
/// sonst ignorieren kann.
func nachVorn(_ app: NSRunningApplication) {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 0.5)
    if AXUIElementSetAttributeValue(el, kAXFrontmostAttribute as CFString, kCFBooleanTrue) != .success { app.activate() }
}

/// Nur normale Dock-Apps. Menüleisten- und Hintergrund-Apps (rcmd, BarDrop, Helfer) nie.
func kandidat(_ app: NSRunningApplication) -> Bool {
    !app.isTerminated && app.isFinishedLaunching && app.activationPolicy == .regular
        && !einst.bool(forKey: "pause") && !ausgenommen(app)
}

// MARK: Beobachter je App (ereignisgesteuert, kein ständiges Abfragen)

var beobachter: [pid_t: AXObserver] = [:]

func merkeFenster(_ pid: pid_t, _ w: AXUIElement) {
    if (unterrollen[pid] ?? []).contains(where: { CFEqual($0.0, w) }) { return }
    var rolle = (attr(w, kAXSubroleAttribute) as String?) ?? "?"
    if let id = attr(w, kAXIdentifierAttribute) as String?, id == "open-panel" || id == "save-panel" { rolle = "panel" }
    unterrollen[pid, default: []].append((w, rolle))
    if rolle == kAXStandardWindowSubrole as String { hatteHauptfenster.insert(pid) }
}

/// War das geschlossene Fenster ein normales Fenster? Dialoge, Ladefenster und Paletten lösen nichts aus.
func geschlossenesFenster(_ pid: pid_t, _ el: AXUIElement) -> String {
    guard var liste = unterrollen[pid], let i = liste.firstIndex(where: { CFEqual($0.0, el) }) else { return "?" } // unbekannt: wie normal behandeln
    let rolle = liste.remove(at: i).1
    unterrollen[pid] = liste
    return rolle
}

let rueckruf: AXObserverCallback = { _, element, name, refcon in
    let pid = pid_t(Int(bitPattern: refcon))
    // Zeitstempel erst nach der Prüfung setzen, sonst zählt das Schließen selbst als „gerade aktiv“
    defer { letzteFensterAktivitaet[pid] = Date() }
    if name as String == kAXWindowCreatedNotification {
        if let o = beobachter[pid] {
            AXObserverAddNotification(o, element, kAXUIElementDestroyedNotification as CFString, refcon)
            merkeFenster(pid, element)
        }
    } else {
        // Nur Fenster, die der Helfer als normales Fenster kennt. Unbekannte (unsichtbare
        // Hilfsfenster, z. B. bei Mail, WhatsApp, Kalender beim Start) lösen nichts aus: Sonst
        // wurden Apps beendet, deren Fenster man gar nicht geschlossen hatte (Test 2026-11-25)
        let rolle = geschlossenesFenster(pid, element)
        if rolle == "panel" { pruefen(pid, panel: true, grund: "Öffnen-Fenster zu") }
        else if rolle == kAXStandardWindowSubrole as String { pruefen(pid, grund: "Fenster zu") }
    }
}

func beobachten(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    // Schon während des Starts beobachten, damit wiederhergestellte Fenster (auch auf anderen
    // Schreibtischen) als „aufgegangen“ ankommen. Menüleisten-Apps fallen in kandidat() raus.
    guard app.activationPolicy == .regular || !app.isFinishedLaunching, app.activationPolicy != .prohibited,
          !app.isTerminated, beobachter[pid] == nil else { return }
    var o: AXObserver?
    guard AXObserverCreate(pid, rueckruf, &o) == .success, let obs = o else { return }
    let ref = UnsafeMutableRawPointer(bitPattern: Int(pid))
    let a = AXUIElementCreateApplication(pid)
    // Gerade gestartete Apps sind manchmal noch nicht erreichbar: dann später erneut versuchen
    guard AXObserverAddNotification(obs, a, kAXWindowCreatedNotification as CFString, ref) == .success else { return }
    if let ws: [AXUIElement] = attr(a, kAXWindowsAttribute) {
        for w in ws { AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, ref); merkeFenster(pid, w) }
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
    beobachter[pid] = obs
}

func vergessen(_ pid: pid_t) {
    unterrollen[pid] = nil; letzteFensterAktivitaet[pid] = nil; hatteHauptfenster.remove(pid)
    if let o = beobachter.removeValue(forKey: pid) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
    }
}

func alleBeobachten() { NSWorkspace.shared.runningApplications.forEach(beobachten) }

/// Fenster nachtragen, die erst jetzt sichtbar sind (z. B. nach dem Wechsel auf einen anderen Schreibtisch).
func nachtragen() {
    for (pid, obs) in beobachter {
        let a = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(a, 0.3)
        guard let ws: [AXUIElement] = attr(a, kAXWindowsAttribute) else { continue }
        let ref = UnsafeMutableRawPointer(bitPattern: Int(pid))
        for w in ws where !(unterrollen[pid] ?? []).contains(where: { CFEqual($0.0, w) }) {
            AXObserverAddNotification(obs, w, kAXUIElementDestroyedNotification as CFString, ref)
            merkeFenster(pid, w)
        }
    }
}

// MARK: Fenster, die beim Schließen nur versteckt werden

/// Manche Apps verstecken ihr Fenster beim Schließen, statt es zu schließen (Kalender, viele
/// Electron-Apps). Dann kommt kein „Fenster zu“. Deshalb Klicks auf den roten Knopf und ⌘W
/// selbst erkennen und danach nachsehen, ob das Fenster weg ist (Vorbild: Swift Quit, PR #64).
let systemweit = AXUIElementCreateSystemWide()
let pruefSchlange = DispatchQueue(label: "queet.klick", qos: .userInitiated)

func schliessenErkannt(_ pid: pid_t, _ fenster: AXUIElement, warVersteckt: Bool) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        // Die App hat sich beim Schließen ganz versteckt statt das Fenster zu schließen (Gemini).
        // ⌘H allein löst das nicht aus, weil vorher der rote Knopf oder ⌘W kommen muss.
        if let app = NSRunningApplication(processIdentifier: pid), app.isHidden, !warVersteckt {
            log("App versteckt sich beim Schließen: \(app.bundleIdentifier ?? "?")")
            pruefen(pid, versteckt: true, grund: "App versteckt")
            return
        }
        let a = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(a, 0.5)
        guard let ws: [AXUIElement] = attr(a, kAXWindowsAttribute) else { return }
        // Noch sichtbar (nur ein Tab zu, Abbrechen gewählt): nichts tun
        if ws.contains(where: { CFEqual($0, fenster) }) { return }
        var v: CFTypeRef?
        // Wirklich zerstört: Man hat es selbst geschlossen, also prüfen (auch wenn der Helfer
        // das Fenster nicht kannte)
        if AXUIElementCopyAttributeValue(fenster, kAXRoleAttribute as CFString, &v) == .invalidUIElement {
            pruefen(pid, grund: "selbst geschlossen")
            return
        }
        // Versteckt: aus der eigenen Liste nehmen, sonst gälte es weiter als offen
        if let i = unterrollen[pid]?.firstIndex(where: { CFEqual($0.0, fenster) }) {
            let rolle = unterrollen[pid]!.remove(at: i).1
            guard rolle == kAXStandardWindowSubrole as String || rolle == "?" else { return }
        }
        log("Fenster versteckt statt geschlossen: \(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?")")
        pruefen(pid, grund: "versteckt")
    }
}

func klickBeobachten() {
    NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
        let p = NSEvent.mouseLocation
        guard let hoehe = NSScreen.screens.first?.frame.height else { return }
        // Bedienungshilfen zählen von oben links, AppKit von unten links
        let x = Float(p.x), y = Float(hoehe - p.y)
        pruefSchlange.async {
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemweit, x, y, &el) == .success, let el,
                  (attr(el, kAXSubroleAttribute) as String?) == kAXCloseButtonSubrole as String,
                  let fenster: AXUIElement = attr(el, kAXWindowAttribute) else { return }
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            DispatchQueue.main.async { schliessenErkannt(pid, fenster, warVersteckt: NSRunningApplication(processIdentifier: pid)?.isHidden ?? false) }
        }
    }
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
        // ⌘W ohne weitere Sondertasten
        guard e.keyCode == 13, e.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
              let app = NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        pruefSchlange.async {
            let a = AXUIElementCreateApplication(pid)
            guard let fenster: AXUIElement = attr(a, kAXFocusedWindowAttribute) else { return }
            DispatchQueue.main.async { schliessenErkannt(pid, fenster, warVersteckt: NSRunningApplication(processIdentifier: pid)?.isHidden ?? false) }
        }
    }
}

var bekannteApps: Set<pid_t> = []
var appListe: NSKeyValueObservation?

func starteHintergrund() {
    let nc = NSWorkspace.shared.notificationCenter
    // Neue Prozesse sofort sehen (früher als „App gestartet“), mit kurzen Wiederholungen
    bekannteApps = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
    appListe = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { ws, _ in
        DispatchQueue.main.async {
            for app in ws.runningApplications where !bekannteApps.contains(app.processIdentifier) {
                bekannteApps.insert(app.processIdentifier)
                for t in [0.0, 0.05, 0.15, 0.3, 0.6, 1.0, 2.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { beobachten(app) } }
            }
        }
    }
    nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { n in
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        // Manche Apps sind erst nach kurzer Zeit für die Bedienungshilfen erreichbar
        for t in [0.5, 2.0, 5.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { beobachten(app) } }
    }
    nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { n in
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if beendetVonMir.remove(app.processIdentifier) != nil { verlaufMerken(app.bundleIdentifier) }
        vergessen(app.processIdentifier); bekannteApps.remove(app.processIdentifier)
    }
    nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
        // Die Fenster erscheinen erst nach der Wechsel-Animation in der Liste: mehrmals nachsehen
        for t in [0.5, 1.5, 3.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) { nachtragen() } }
    }
    // Apps, die beim Start noch nicht erreichbar waren, beim Aktivieren nachholen
    nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
        if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            beobachten(app)
            if app.processIdentifier != getpid() { letzteFremdeApp = app }
        }
    }

    nc.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { n in
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              hatteHauptfenster.contains(app.processIdentifier) else { return }
        pruefen(app.processIdentifier, grund: "App gewechselt")
    }

    // Kein Systemdialog: Die Freigabe erteilt man einmal selbst unter Bedienungshilfen
    if !AXIsProcessTrusted() {
        log("Warte auf Freigabe unter Bedienungshilfen")
        // Nur beim allerersten Mal nach der Freigabe fragen, damit Queet in der Liste steht
        if !einst.bool(forKey: "freigabe-gefragt") {
            einst.set(true, forKey: "freigabe-gefragt")
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    }
    starten()
}

// Auf die Freigabe warten, ohne die App zu belasten
func starten() {
    if AXIsProcessTrusted() {
        AXUIElementSetMessagingTimeout(systemweit, 1.0)
        alleBeobachten(); klickBeobachten(); log("läuft"); return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { starten() }
}

// MARK: Rechtsklick im Finder: „App beenden“

/// Erst normal beenden, dann hart, zuletzt übrige Hilfsprozesse aus dem Programmpaket.
/// Fragt die App nach (z. B. Sichern-Dialog), wartet Queet, bis man sich entschieden hat.
final class Dienste: NSObject {
    @objc func appBeenden(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        // macOS holt Queet für den Dienst nach vorn: Fokus gleich zurück an den Finder
        let vorher = letzteFremdeApp
        if let vorher { nachVorn(vorher) }
        for u in urls { radikalBeenden(u.resolvingSymlinksInPath().path) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), let vorher, !vorher.isTerminated { nachVorn(vorher) }
        }
    }
}
let dienste = Dienste()
/// Zuletzt aktive App außer Queet (für den Dienst)
var letzteFremdeApp: NSRunningApplication?

/// Alle eigenen Prozesse, deren Programmdatei im Paket liegt
func prozesseIn(_ paket: String) -> [pid_t] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let anzahl = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var puffer = [CChar](repeating: 0, count: 4096)
    return pids.prefix(max(anzahl, 0)).filter { pid in
        pid > 0 && pid != getpid() && proc_pidpath(pid, &puffer, UInt32(puffer.count)) > 0
            && String(cString: puffer).hasPrefix(paket + "/")
    }
}

/// Zeigt die App gerade einen Dialog oder ein Blatt (Sichern, Beenden bestätigen)?
func fragtNach(_ app: NSRunningApplication) -> Bool {
    let el = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetMessagingTimeout(el, 0.5)
    guard let fenster: [AXUIElement] = attr(el, kAXWindowsAttribute) else { return false }
    return fenster.contains { f in
        (attr(f, kAXSubroleAttribute) as String?) == kAXDialogSubrole
            || ((attr(f, kAXChildrenAttribute) as [AXUIElement]?) ?? []).contains { (attr($0, kAXRoleAttribute) as String?) == kAXSheetRole }
    }
}

func radikalBeenden(_ paket: String) {
    guard paket != Bundle.main.bundlePath else { return }
    let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path == paket }
    guard !apps.isEmpty || !prozesseIn(paket).isEmpty else { return }
    log("App beenden (Finder): \((paket as NSString).lastPathComponent)")
    apps.forEach { $0.terminate() }
    nachsehen(paket, apps, schritt: 1)
}

private func nachsehen(_ paket: String, _ apps: [NSRunningApplication], schritt: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let offen = apps.filter { !$0.isTerminated }
        if !offen.isEmpty {
            // Ohne Freigabe sieht Queet keine Dialoge, dann nie hart beenden (ungesicherte Dokumente)
            guard AXIsProcessTrusted() else { log("Hart beenden übersprungen: keine Freigabe"); return }
            if offen.contains(where: fragtNach) {
                if schritt < 600 { nachsehen(paket, apps, schritt: schritt + 1) } // bis zu 5 min
                return
            }
            if schritt < 6 { nachsehen(paket, apps, schritt: schritt + 1); return } // 3 s Zeit
            for a in offen { log("Hart beendet: \(a.bundleIdentifier ?? "?")"); a.forceTerminate() }
        }
        // Hilfsprozesse kurz nachlaufen lassen, dann erst sanft, dann hart
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let rest = prozesseIn(paket); guard !rest.isEmpty else { return }
            log("Beende \(rest.count) übrige Prozesse"); rest.forEach { kill($0, SIGTERM) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { prozesseIn(paket).forEach { kill($0, SIGKILL) } }
        }
    }
}

// MARK: Start

/// Beim Anmelden trägt Queet sich selbst ein (Systemeinstellungen > Allgemein > Anmeldeobjekte).
/// Nur einmal, damit ein Ausschalten dort bestehen bleibt.
func autostartEinrichten() {
    guard !einst.bool(forKey: "autostart-eingerichtet"), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
    do { try SMAppService.mainApp.register(); einst.set(true, forKey: "autostart-eingerichtet"); log("Autostart eingetragen") }
    catch { log("Autostart: \(error)") }
}

/// Startzeit eines Prozesses (sysctl)
func startzeit(_ pid: pid_t) -> Date? {
    var info = kinfo_proc(); var groesse = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &groesse, nil, 0) == 0, groesse > 0 else { return nil }
    let t = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
}

/// Von der Anmeldung gestartet? Dann ohne Fenster. Erkennt das Anmelde-Ereignis oder einen Start
/// kurz nach dem Dock (das Dock startet mit jeder Anmeldung).
func beimAnmeldenGestartet() -> Bool {
    if let e = NSAppleEventManager.shared().currentAppleEvent,
       e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem { return true }
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
          let d = startzeit(dock.processIdentifier),
          let ich = startzeit(ProcessInfo.processInfo.processIdentifier) else { return false }
    return ich.timeIntervalSince(d) < 90
}

/// Aus dem DMG oder dem Downloads-Ordner gestartet: anbieten, Queet in „Programme“ zu legen
func inProgrammeLegen() -> Bool {
    let pfad = Bundle.main.bundlePath
    guard !pfad.hasPrefix("/Applications/") else { return false }
    NSApp.activate()
    let a = NSAlert()
    a.messageText = "Queet in „Programme“ legen?"
    a.informativeText = "Dann startet Queet bei jeder Anmeldung von selbst."
    a.addButton(withTitle: "In „Programme“ legen"); a.addButton(withTitle: "Nicht jetzt")
    guard a.runModal() == .alertFirstButtonReturn else { return false }
    let ziel = URL(fileURLWithPath: "/Applications/Queet.app")
    let fm = FileManager.default
    do {
        if fm.fileExists(atPath: ziel.path) { try fm.trashItem(at: ziel, resultingItemURL: nil) }
        try fm.copyItem(at: Bundle.main.bundleURL, to: ziel)
    } catch {
        let f = NSAlert(); f.messageText = "Das hat nicht geklappt."
        f.informativeText = "Zieh Queet bitte selbst in den Ordner „Programme“."; f.runModal(); return false
    }
    // Die Kopie hat man schon geöffnet, macOS soll nicht noch einmal nachfragen
    let x = Process(); x.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    x.arguments = ["-dr", "com.apple.quarantine", ziel.path]; try? x.run(); x.waitUntilExit()
    let k = NSWorkspace.OpenConfiguration(); k.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: ziel, configuration: k) { _, _ in DispatchQueue.main.async { exit(0) } }
    return true
}

/// Startet das Einstellungsfenster als eigenen Prozess; der Helfer bleibt ohne Oberfläche
func einstellungenOeffnen() {
    let p = Process(); p.executableURL = Bundle.main.executableURL
    p.arguments = ["--einstellungen"]
    p.standardError = FileHandle.nullDevice // Meldungen des Fensters nicht ins Protokoll
    try? p.run()
}

final class Hintergrund: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let stillGestartet = CommandLine.arguments.contains("--still") || beimAnmeldenGestartet()
        if !stillGestartet, inProgrammeLegen() { return }
        autostartEinrichten()
        starteHintergrund()
        if !stillGestartet { einstellungenOeffnen() }
    }
    /// Öffnet man Queet (Spotlight, Doppelklick), schickt macOS das an den laufenden Helfer
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        einstellungenOeffnen(); return false
    }
}
let hintergrund = Hintergrund()
NSApplication.shared.servicesProvider = dienste

if CommandLine.arguments.contains("--pruefen") {
    print(AXIsProcessTrusted() ? "Freigabe: ja" : "Freigabe: nein")
    print("Autostart:", SMAppService.mainApp.status.rawValue == 1 ? "an" : "aus")
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
        print(app.bundleIdentifier ?? "?", kandidat(app) ? "würde beendet ohne Fenster" : "ausgenommen", hatFenster(app) ? "– hat Fenster" : "– kein Fenster")
    }
    exit(0)
}
let ich = ProcessInfo.processInfo.processIdentifier
let andere = NSRunningApplication.runningApplications(withBundleIdentifier: "com.zzuuuiii.queet").filter { $0.processIdentifier != ich }
if CommandLine.arguments.contains("--einstellungen") || !andere.isEmpty {
    // Nur das Einstellungsfenster, eigener Prozess, der mit dem Fenster endet.
    // Ist schon eins offen, dieses nach vorn holen.
    if let offen = andere.first(where: { $0.activationPolicy == .regular }) { offen.activate(); exit(0) }
    EinstellungenApp.starten()
} else {
    // Hintergrund-Helfer ohne Oberfläche (kein Dock-Symbol: LSUIElement)
    NSApplication.shared.delegate = hintergrund
}
NSApplication.shared.run()

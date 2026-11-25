import AppKit
import Security

// MARK: Nach Updates suchen (Menü „Queet“ im Einstellungsfenster)
//
// Fragt die neueste Version auf GitHub ab, lädt die DMG und ersetzt die App. Installiert wird nur,
// wenn die neue App mit demselben Zertifikat signiert ist wie die laufende: So bleibt die Freigabe
// unter Bedienungshilfen erhalten, und eine fremde Datei kann sich nicht als Update ausgeben.

enum Updater {
    static let quelle = URL(string: "https://api.github.com/repos/zzuuuiii/Queet/releases/latest")!

    @MainActor static func suchen() {
        Task { @MainActor in
            do {
                var anfrage = URLRequest(url: quelle)
                anfrage.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (daten, _) = try await URLSession.shared.data(for: anfrage)
                guard let json = try JSONSerialization.jsonObject(with: daten) as? [String: Any],
                      let tag = json["tag_name"] as? String,
                      let dateien = json["assets"] as? [[String: Any]],
                      let dmg = dateien.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                      let adresse = (dmg["browser_download_url"] as? String).flatMap(URL.init(string:))
                else { throw Fehler("Die Antwort von GitHub war unvollständig.") }
                let neu = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let jetzt = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                guard neuer(neu, als: jetzt) else {
                    meldung("Queet ist aktuell.", "Du hast die neueste Version (\(jetzt))."); return
                }
                let a = NSAlert()
                a.messageText = "Queet \(neu) ist da."
                a.informativeText = "Du hast \(jetzt). Queet lädt die neue Version, ersetzt sich und startet neu."
                a.addButton(withTitle: "Laden und installieren"); a.addButton(withTitle: "Später")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                try await installieren(adresse)
            } catch {
                meldung("Update hat nicht geklappt.", (error as? Fehler)?.text ?? "Keine Verbindung zu GitHub. Später noch einmal versuchen.")
            }
        }
    }

    struct Fehler: Error { let text: String; init(_ t: String) { text = t } }

    static func neuer(_ a: String, als b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    @MainActor static func meldung(_ titel: String, _ text: String) {
        let a = NSAlert(); a.messageText = titel; a.informativeText = text; a.runModal()
    }

    /// Erstes Zertifikat der Signatur (nil bei ungültiger oder Ad-hoc-Signatur)
    static func zertifikat(_ app: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), nil) == errSecSuccess
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let d = info as? [String: Any],
              let zert = (d[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        else { return nil }
        return SecCertificateCopyData(zert) as Data
    }

    @discardableResult
    static func ausfuehren(_ pfad: String, _ argumente: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: pfad); p.arguments = argumente
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }

    @MainActor static func installieren(_ adresse: URL) async throws {
        let fm = FileManager.default
        let ordner = fm.temporaryDirectory.appendingPathComponent("Queet-Update-\(UUID().uuidString)")
        try fm.createDirectory(at: ordner, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ordner) }

        let (geladen, _) = try await URLSession.shared.download(from: adresse)
        let dmg = ordner.appendingPathComponent("Queet.dmg")
        try fm.moveItem(at: geladen, to: dmg)
        let mount = ordner.appendingPathComponent("dmg")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        guard ausfuehren("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path]) == 0
        else { throw Fehler("Die geladene Datei ließ sich nicht öffnen.") }
        let neu = ordner.appendingPathComponent("Queet.app")
        let kopiert = ausfuehren("/usr/bin/ditto", [mount.appendingPathComponent("Queet.app").path, neu.path])
        ausfuehren("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        guard kopiert == 0 else { throw Fehler("In der geladenen Datei fehlt Queet.") }

        // Nur dieselbe App vom selben Absender installieren
        guard Bundle(url: neu)?.bundleIdentifier == Bundle.main.bundleIdentifier,
              let alt = zertifikat(Bundle.main.bundleURL), zertifikat(neu) == alt
        else { throw Fehler("Die geladene Version ist nicht richtig signiert und wurde nicht installiert.") }

        let ziel = URL(fileURLWithPath: "/Applications/Queet.app")
        if fm.fileExists(atPath: ziel.path) { try fm.trashItem(at: ziel, resultingItemURL: nil) }
        try fm.copyItem(at: neu, to: ziel)
        ausfuehren("/usr/bin/xattr", ["-dr", "com.apple.quarantine", ziel.path])

        // Hintergrund-Helfer der alten Version beenden, neue Version starten
        let ich = ProcessInfo.processInfo.processIdentifier
        let andere = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ich }
        andere.forEach { $0.terminate() }
        try? await Task.sleep(for: .seconds(1))
        andere.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
        let k = NSWorkspace.OpenConfiguration(); k.createsNewApplicationInstance = true
        _ = try? await NSWorkspace.shared.openApplication(at: ziel, configuration: k)
        exit(0)
    }
}

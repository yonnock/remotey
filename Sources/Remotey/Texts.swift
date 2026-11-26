import Foundation

/// Every word the Mac's menu, assistant and settings show, in one place: a second language is a second table
/// here, not a search through the views. The checklist's sentences live with their rows in Setup.swift, which
/// decides them.
enum Texts {
    /// Dates and times are written for this locale, like the words.
    static let locale = Locale(identifier: "de_DE")

    enum Menu {
        static let name = "Remotey"
        static let remoteControl = "Fernsteuerung"
        static let paused = "Pausiert: kein iPhone steuert den Mac."
        static let noPhone = "Kein iPhone verbunden"
        static let sharedKey = "Web-Zugang"
        static let connected = "Verbunden"
        static let connectedLive = "Verbunden · Live-Bild an"
        static let connectedPaused = "Verbunden · pausiert"
        static let end = "Trennen"
        static func endHelp(_ name: String) -> String { "\(name) trennen. Es verbindet sich wieder, solange es gekoppelt ist." }
        static let status = "Status"
        static let accessibility = "Bedienungshilfen"
        static let screenRecording = "Bildschirmaufnahme"
        static let tailscale = "Tailscale"
        static let notAllowed = "Nicht erlaubt"
        static let onlyLiveView = "Nicht erlaubt · nur fürs Live-Bild"
        static let checking = "Wird geprüft …"
        static let tailscaleOff = "Nicht verbunden"
        static let httpsOff = "HTTPS im Tailnet aus"
        static let notShared = "Nicht im Tailnet freigegeben"
        static let funnel = "Funnel ist an"
        static let unreachable = "Nicht erreichbar"
        static let tokenNotSaved = "Schlüssel nicht gespeichert"
        static let addPhone = "iPhone hinzufügen …"
        static let faceID = "Mit Face ID entsperren …"
        static let faceIDOn = "Eingerichtet"
        static let faceIDOff = "Aus"
        static let settings = "Einstellungen …"
        static let quit = "Remotey beenden"
        /// What VoiceOver says for the states of a row.
        static let ok = "In Ordnung"
        static let needsAction = "Braucht dich"
        static let failed = "Fehler"

        static let symbolIdle = "Remotey"
        static let symbolConnected = "Remotey, iPhone verbunden"
        static let symbolPaused = "Remotey, pausiert"
        static let symbolProblem = "Remotey, Einrichtung prüfen"
    }

    enum Assistant {
        static let windowTitle = "Remotey einrichten"
        static let prepareTitle = "Remotey einrichten"
        static let prepareText = "Remotey prüft jeden Punkt selbst. Wo etwas fehlt, hilft die Taste daneben."
        static let pairTitle = "iPhone hinzufügen"
        static let pairText = "Scanne den Code mit der Kamera deines iPhones. Remotey prüft die Verbindung selbst."
        static let moveTitle = "Bewege den Finger"
        static let moveText = "Streiche mit einem Finger über das iPhone. Der Zeiger am Mac folgt."
        static let movedTitle = "Es funktioniert"
        static let movedText = "Das iPhone hat den Zeiger bewegt."
        static let homeTitle = "Zum Home-Bildschirm"
        static let homeText = "Als App vom Home-Bildschirm hat Remotey den ganzen Bildschirm und startet ohne Safari."
        /// `{symbol}` stands where the step shows the key's symbol.
        static let homeSteps = [(text: "In Safari auf {symbol} „Teilen“ tippen.", symbol: "square.and.arrow.up"),
                                (text: "„Zum Home-Bildschirm“ {symbol} wählen.", symbol: "plus.square"),
                                (text: "Remotey vom Home-Bildschirm öffnen.", symbol: "")]
        static func homeDigits(_ digits: String) -> String { "Fragt die App nach einem Code, gib \(digits) ein." }
        static let homeDone = "Remotey läuft vom Home-Bildschirm."

        static let startAtLogin = "Beim Anmelden starten"
        static let startAtLoginNote = "Damit dein iPhone den Mac auch nach einem Neustart erreicht."
        static let back = "Zurück"
        static let next = "Weiter"
        static let done = "Fertig"
        static let notReady = "Erst die markierten Punkte erledigen."

        static let accessibilityDone = "Bedienungshilfen erlaubt"
        static let accessibilityMissing = "Bedienungshilfen fehlen"
        static let screenDone = "Bildschirmaufnahme erlaubt"
        static let screenMissing = "Bildschirmaufnahme fehlt"
        static let screenMissingNote = "Nur fürs Live-Bild nötig"
        static let sharedDone = "Im Tailnet freigegeben"
        static let sharedMissing = "Noch nicht freigegeben"
        static let selfTestPassed = "Selbsttest über Port \(Tailscale.port) bestanden"
        static let waitingForPhone = "Warte auf iPhone …"
        static func paired(_ name: String) -> String { "\(name) gekoppelt" }
        static let moveStep = "Bewege den Finger"
        static let moveStepDone = "Der Zeiger hat sich bewegt"
        static let homeStep = "Zum Home-Bildschirm"

        static func codeValid(_ remaining: TimeInterval) -> String {
            let seconds = max(0, Int(remaining.rounded(.up)))
            if seconds < 60 { return "Der Code gilt noch \(seconds) Sekunden" }
            return String(format: "Der Code gilt noch %d:%02d Minuten", seconds / 60, seconds % 60)
        }
        static let digitsLabel = "Ohne Kamera diesen Code eingeben"
        static let newCode = "Neuer Code"
        static let expired = "Der Code ist abgelaufen."
        static let tries = "Zu viele falsche Versuche. Der Code gilt nicht mehr."
        static let waitingForTailscale = "Der Code erscheint, sobald Remotey im Tailnet freigegeben ist."
        static let qrLabel = "QR-Code zum Koppeln"
    }

    enum Settings {
        static let general = "Allgemein"
        static let phones = "iPhones"
        static let security = "Sicherheit"
        static let permissions = "Berechtigungen"

        static let startAtLogin = "Beim Anmelden starten"
        static let startAtLoginNote = "Damit dein iPhone den Mac auch nach einem Neustart erreicht."
        static let loginItemApproval = "In den Systemeinstellungen unter Anmeldeobjekte erlauben."
        static let loginItemUnavailable = "Geht nur mit der installierten App."
        static let openLoginItems = "Anmeldeobjekte öffnen …"
        static let remoteControl = "Fernsteuerung"
        static let remoteControlNote = "Aus: die iPhones bleiben gekoppelt, steuern aber nichts und sehen kein Bild."
        static let address = "Adresse im Tailnet"
        static let addressMissing = "Noch nicht freigegeben"
        static let agent = "Remotey"
        static func listening(_ port: UInt16) -> String { "Bereit auf Port \(port) und \(port + 1)" }
        static let starting = "Startet …"
        static func failed(_ reason: String) -> String { "Nicht erreichbar: \(reason). Neuer Versuch folgt." }
        static let openAssistant = "Einrichtung öffnen …"
        static let setup = "Einrichtung"

        static let pairedPhones = "Gekoppelte iPhones"
        static let noPhones = "Noch kein iPhone gekoppelt."
        static let addPhone = "iPhone hinzufügen …"
        static func connectedSince(_ time: String) -> String { "Verbunden seit \(time)" }
        static let liveView = "Live-Bild an"
        static func lastSeen(_ when: String) -> String { "Zuletzt \(when)" }
        static func pairedOn(_ when: String) -> String { "Gekoppelt \(when)" }
        static let today = "heute"
        static let yesterday = "gestern"
        static let details = "Details"
        static let name = "Name"
        static let pairedAt = "Gekoppelt"
        static let seenAt = "Zuletzt verbunden"
        static let pairedFrom = "Gekoppelt von"
        static let never = "Noch nie"
        static let revoke = "Widerrufen …"
        static func revokeTitle(_ name: String) -> String { "„\(name)“ widerrufen?" }
        static let revokeText = "Das iPhone wird sofort getrennt und kommt nicht wieder herein, bis du es neu koppelst. "
            + "Die anderen iPhones bleiben gekoppelt."
        static let revokeConfirm = "Widerrufen"
        static let ownKeys = "Jedes iPhone hat einen eigenen Schlüssel."
        static let sharedKey = "Web-Zugang ohne Gerätebindung"
        static let sharedKeyNote = "Der gemeinsame Schlüssel aus den Links von früher: wer ihn hat, steuert den Mac, "
            + "ohne gekoppelt zu sein. Ausschalten, sobald jedes iPhone gekoppelt ist."
        static let sharedKeyOffTitle = "Web-Zugang ohne Gerätebindung ausschalten?"
        static func sharedKeyOffText(_ connected: Int) -> String {
            let who = connected == 1 ? "Ein verbundenes Gerät nutzt ihn und wird" : "\(connected) verbundene Geräte nutzen ihn und werden"
            return "\(who) sofort getrennt. Gekoppelte iPhones sind nicht betroffen."
        }
        static let sharedKeyOff = "Ausschalten"
        static let disconnectAll = "Alle iPhones trennen …"
        static let disconnectAllTitle = "Alle iPhones trennen?"
        static let disconnectAllText = "Jedes gekoppelte iPhone verliert den Zugang und wird sofort getrennt. "
            + "Der gemeinsame Schlüssel wird erneuert. Danach musst du jedes iPhone neu koppeln."
        static let disconnectAllConfirm = "Alle trennen"
        static let cancel = "Abbrechen"
        static let done = "Fertig"

        static let faceID = "Mit Face ID entsperren"
        static let faceIDOn = "Eingerichtet"
        static let faceIDOff = "Nicht eingerichtet"
        static let faceIDNote = "Ein gekoppeltes iPhone entsperrt den gesperrten Mac mit Face ID. Wer das iPhone entsperren kann, "
            + "kann dann auch den Mac entsperren."
        static let faceIDSetUp = "Einrichten …"
        static let faceIDRemove = "Entfernen …"
        static let faceIDRemoveTitle = "Entsperren mit Face ID entfernen?"
        static let faceIDRemoveText = "Das abgelegte Passwort dieses Macs wird gelöscht. Danach entsperrt das iPhone nur noch "
            + "mit dem Passwort. Den Passkey löschst du am iPhone in der App Passwörter."
        static let faceIDRemoveConfirm = "Entfernen"
        static let tailnet = "Tailnet"
        static let allowed = "Zugelassen"
        static func onlyOwner(_ login: String) -> String { "Nur Geräte von \(login)" }
        static let ownerUnknown = "Wird geprüft …"
        static let removeServe = "Freigabe entfernen …"
        static let removeServeTitle = "Freigabe im Tailnet entfernen?"
        static let removeServeText = "Kein iPhone erreicht Remotey mehr, bis du wieder freigibst. "
            + "Andere Freigaben dieses Macs bleiben, wie sie sind."
        static let removeServeConfirm = "Entfernen"

        static let permissionsNote = "Remotey fragt nie von selbst. Die Schalter liegen in den Systemeinstellungen unter "
            + "Datenschutz & Sicherheit."
    }

    enum MainMenu {
        static let edit = "Bearbeiten"
        static let undo = "Widerrufen"
        static let redo = "Wiederholen"
        static let cut = "Ausschneiden"
        static let copy = "Kopieren"
        static let paste = "Einsetzen"
        static let selectAll = "Alles auswählen"
        static let window = "Fenster"
        static let close = "Schließen"
        static let minimize = "Im Dock ablegen"
    }

    enum FaceUnlock {
        static let title = "Mit Face ID entsperren"
        static let intro = "Das iPhone bekommt einen Passkey, und das Passwort dieses Macs wird damit verschlüsselt abgelegt: "
            + "ohne Face ID am iPhone ist es nicht zu lesen. Den Mac entsperrt dann, wer das iPhone entsperren kann."
        static let waitingTitle = "Warte auf das iPhone"
        static let waiting = "Öffne Remotey am iPhone und tippe dort auf „Einrichten“. Das Angebot gilt zwei Minuten."
        static let doneTitle = "Eingerichtet"
        static let done = "Ist der Mac gesperrt, entsperrt ihn „Entsperren…“ am iPhone mit Face ID."
        static let password = "Passwort dieses Macs"
        static let passwordAgain = "Passwort noch einmal"
        static let cancel = "Abbrechen"
        static let proceed = "Weiter"
        static let timeUp = "Die Zeit ist um, nichts wurde eingerichtet."
        static let unchecked = "Das Passwort ließ sich nicht prüfen. Bitte noch einmal eingeben: "
            + "nur wenn beide gleich sind, wird es abgelegt."
        static let different = "Die beiden Eingaben waren verschieden."
        static let wrong = "Das ist nicht das Passwort dieses Macs."
    }

    enum Problem {
        static let notSaved = "Nicht gespeichert"
        static let couldNotStart = "Remotey konnte nicht starten"
        static func ports(_ port: UInt16, _ error: String) -> String { "Port \(port)/\(port + 1): \(error)" }
        static let tokenNotRenewed = "Der bisherige Schlüssel gilt weiter."
        static func tokenNotSaved(_ reason: String) -> String { "Gilt nur bis zum Beenden: \(reason)" }
    }
}

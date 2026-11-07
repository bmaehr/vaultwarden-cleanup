# Vaultwarden & Bitwarden Maintenance Toolkit

Ein robustes Bash- und `jq`-Werkzeug mit zwei vollwertigen Betriebsmodi:
1. **Interaktiver Assistent (`-i` / `--interactive`):** Menügeführter Workflow mit Planungsvorschau, Detailanalyse und expliziter Bestätigung vor jedem Schreib-/Löschvorgang.
2. **Direkte Kommandozeilenaufrufe:** Für Skripte, CI/CD-Pipelines oder schnelle Terminalabfragen.

---

## 1. Interaktiver Modus (Assistent & Schritt-für-Schritt-Planung)

Starte den interaktiven Modus entweder direkt gegen eine exportierte JSON-Datei oder dein Vaultwarden-Setup:

```bash
# Offline gegen Test-Fixture oder unverschlüsselten JSON-Export
./vault_manager.sh -i --file tests/fixture_duplicates.json

# Gegen Live-Bitwarden CLI (Lokal)
export BW_SESSION="deine_session"
./vault_manager.sh -i

# Gegen Docker-Container
./vault_manager.sh -i --docker vaultwarden-cli
```

### Der Ablauf im interaktiven Modus:
1. **Hauptmenü:** Auswahl der Operation (KeePass-Fix, Namen generieren, Duplikat-Tiers 1-3, Merge & Bereinigung).
2. **Analyse & Fortschrittsanzeige:** Der Tresor wird mit visualisiertem Fortschrittsbalken gescannt.
3. **Planungsvorschau (Tabelle):** Es wird tabellarisch aufgeschlüsselt:
   * Welche Einträge betroffen sind.
   * Welche IDs kanonisch beibehalten werden.
   * Welche Felder (Notizen, URIs, Custom Fields) verschmolzen werden.
   * **Welche IDs zur Löschung vorgesehen sind.**
   * Status von Passkeys (`LOCKED 🔒` oder `YES ⚠️`).
4. **Explizite Bestätigungsabfrage:**
   ```text
   Aktion erforderlich:
     Soll die geplante Operation Löschung von 2 redundanten Duplikaten jetzt tatsächlich ausgeführt werden?
     [j/N] (Standard: Nein, Abbrechen):
   ```
5. Erst nach Bestätigung mit `j` oder `y` wird die Löschung oder Aktualisierung tatsächlich ausgeführt.

---

## 2. Direkte CLI-Aufrufe (Automatisierungsmodus)

```bash
# 1. Duplikate auflisten (Tier 2: Content-Match)
./vault_manager.sh --file export.json find-duplicates --tier content

# 2. Merge-Planung anzeigen (Standard: Dry-Run Preview)
./vault_manager.sh --file export.json merge-duplicates

# 3. KeePass-URIs migrieren und in neue Datei schreiben
./vault_manager.sh --file export.json fix-uris --output clean_vault.json
```

---

## 3. Duplikat-Stufen & Passkey-Sicherheitsgarantie

* **Tier 1 (`exact`):** Vergleicht ausnahmslos alle Attribute via `jq`. Nur die `id` wird ignoriert. Abweichungen im `creationDate` oder `revisionDate` gelten strikt als Unterschied.
* **Tier 2 (`content`):** Vergleicht die reinen Nutzdaten (Login, Passwort, URIs, Notizen, Felder) und ignoriert Server-Zeitstempel und IDs.
* **Tier 3 (`partial`):** Erkennt Konten mit gleicher Domain und demselben User, die asymmetrische Zusatzfelder haben (Merge-Kandidaten).
* **Passkey-Schutz (`fido2Credentials`):**
  * Einträge mit Passkeys werden **immer als kanonisch fixiert**.
  * Sie werden **niemals zur Löschung vorgeschlagen oder gelöscht**.
  * Haben mehrere Einträge eigene Passkeys, wird der Löschvorgang mit `CONFLICT_MULTIPLE_PASSKEYS` abgebrochen.

---

## 4. Vollständige Offline-Tests ausführen

```bash
./tests/run_tests.sh
```

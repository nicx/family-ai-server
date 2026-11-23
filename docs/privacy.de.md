# Datenschutz & Sicherheit

*[English version](privacy.md)*

Family AI Server ist für Familien gebaut, die ihre Daten möglichst bei sich behalten wollen. Die App und alle Daten laufen auf **eurem** Server (einem Mac oder dem [Docker-Image](docker.de.md)). Nur das, was für eine Antwort nötig ist, geht an OpenRouter und das Modell. Diese Seite beschreibt genau, was das ist, was die App selbst zum Schutz tut und **was du als Familien-Admin bei OpenRouter einstellen solltest**.

## Was bleibt bei euch

Alles andere bleibt lokal auf dem Server: Konten und Passwörter, Passkeys, alle Chats, das Gedächtnis, hochgeladene Dokumente und Bilder, Einstellungen, Nutzungsdaten und die Sicherungen. Die Eltern-Ansicht und die Verwaltung greifen nur auf diese lokalen Daten zu.

## Was an OpenRouter und das Modell geht

| Funktion | Gesendet wird |
|---|---|
| Chat | die Nachrichten des Chats, Anhänge und Bilder, Systemprompt (Name der KI, nur der **Vorname** der Person, Datum, eure persönlichen Anweisungen, Gedächtnis-Einträge falls Gedächtnis an ist) |
| Dokumentensuche | Textabschnitte der Dokumente und die Suchfrage (für die Embeddings), bei Treffern die passenden Abschnitte im Chat |
| Websuche | die vom Modell formulierte Suchanfrage |
| Bilder, Vorlesen, Diktieren | Bild-Prompt, vorzulesender Text bzw. die Sprachaufnahme |
| Chat-Titel | die erste Nachricht des Chats |

**Nicht** gesendet werden: Nachname und Familienname, Passwörter, Mail-Adressen, Konto- und Verwaltungsdaten, die Chats anderer Personen und die Sicherungen.

## Was die App von sich aus tut

Das ist immer aktiv und braucht keine Einstellung:

- **Keine Speicherung angefordert:** Jede Anfrage an OpenRouter verlangt Zero Data Retention (`provider.zdr`) und keine Datensammlung beim Anbieter (`data_collection: deny`). Das gilt für Chat, Websuche, Embeddings, Bilder, Vorlesen und Diktieren und ist zentral im Code gesetzt, damit kein Aufruf fehlt. Es wirkt nur verschärfend und ergänzt die Guardrail in OpenRouter (siehe unten).
- **Nur der Vorname:** Im Systemprompt steht „Du sprichst mit <Vorname>“. Nach- und Familienname gehen nie an das Modell.
- **Pseudonyme Kennung:** Chat-Anfragen tragen im `user`-Feld einen Hash der Nutzer-ID statt eines Namens.
- **Websuche über den Modellanbieter:** Die Engine steht fest auf `native`. Die Suche läuft beim selben Anbieter wie die Antwort, ohne zusätzliche Drittanbieter wie Exa oder Firecrawl.
- **Ein Schlüssel pro Person:** Kosten und Limits sind getrennt, ein Schlüssel kann einzeln gesperrt werden. Die Schlüssel liegen im macOS-Schlüsselbund (Docker: verschlüsselte Datei, der Master-Schlüssel außerhalb des Datenvolumes).
- **Kinderschutz:** Für Kinder gilt ein fester Hinweis im Systemprompt; Bildmodelle mit Inhaltsprüfung lehnen ungeeignete Wünsche ab (z. B. getestet mit `microsoft/mai-image-2.7-flash`).

## Einstellungen bei OpenRouter (Familien-Admin)

Die App verlangt „keine Speicherung“ in jeder Anfrage. Zusätzlich solltest du es **im OpenRouter-Konto erzwingen**. Dann gilt es für jeden Schlüssel, auch für künftige oder fremde, und niemand kann es versehentlich umgehen. Die Bezeichnungen können sich bei OpenRouter ändern.

### 1. Kontoeinstellungen (`openrouter.ai/settings/privacy`)

- Weiterleitung an Anbieter, die **mit euren Eingaben trainieren** dürfen, ausschalten (für bezahlte und für kostenlose Modelle).
- **ZDR** für die Anbietergruppen einschalten, die ihr nutzt (Anthropic, OpenAI, Google, xAI, „andere“).

### 2. Guardrail im Standard-Workspace (`openrouter.ai/workspaces/default/guardrails`)

Eine Guardrail, die für alle Schlüssel des Workspaces gilt:

| Einstellung | Empfehlung |
|---|---|
| Mode | „Allow all except“ (oder eine eigene Modell-Liste, siehe unten) |
| ZDR für Anthropic, OpenAI, Google, xAI und „Other“ | **an** |
| Free training | **aus** |
| Data regions | „Any region“ – eine EU-Region gibt es nur im Business-/Enterprise-Tarif und dort ohne Websuche (siehe „Grenzen“) |
| Budget | optional pro Person (siehe 3) |

### 3. Ein Schlüssel pro Person

- Pro Person einen eigenen Schlüssel anlegen und ein **monatliches Limit** setzen. Das begrenzt die Kosten und trennt die Nutzung. Die App zeigt den Verbrauch und warnt per Mail bei 80 % und 100 %.
- Optional pro Kind eine strengere Guardrail (Modell-Liste), wenn ihr die Auswahl einschränken wollt. Dann müssen dort auch die Modelle für Bilder, Vorlesen, Diktieren und Embeddings erlaubt sein.

### 4. ZDR-fähige Modelle für die Zusatzfunktionen wählen

Nicht jedes Modell hat einen Endpunkt ohne Speicherung. Wählt ihr eines ohne, lehnt OpenRouter die Anfrage ab, und die Funktion fällt aus. Getestet im November 2026 (Stand ändert sich, bitte selbst prüfen):

| Funktion | Funktioniert mit ZDR | Nicht mit ZDR |
|---|---|---|
| Chat | Anthropic- und OpenAI-Modelle (z. B. Claude Haiku/Sonnet, GPT-6 Luna/Sol) | Google-Gemini-Chat |
| Embeddings (Dokumente) | `openai/text-embedding-3-large`/`-small`, `mistralai/mistral-embed-2312`, `qwen/qwen3-embedding-8b`, `baai/bge-m3`, `amazon/titan-embed-text-v2` | `google/gemini-embedding-*`, Cohere, Voyage |
| Bilder | `microsoft/mai-image-2.7-flash` | Google Gemini Image, `openai/gpt-image-*` |
| Vorlesen | `microsoft/mai-voice-2.1-flash` | – |
| Diktieren | `openai/whisper-large-v3-turbo` | – |

Erkennbar ist ein Modell ohne ZDR-Endpunkt an der Fehlermeldung *„ZDR violation (guardrail)“* oder *„No endpoints found matching your data policy“*. Dann in *Verwaltung → Familie & KI* ein anderes Modell wählen. Die Auswahlfelder dort zeigen alle Modelle, filtern aber nicht nach ZDR.

### 5. Danach prüfen

Nach jeder Änderung an Guardrail oder Modellen einmal testen: ein Chat mit Websuche, ein Bild, Vorlesen, Diktieren und ein Dokument hochladen. So seht ihr sofort, ob ein Modell blockiert wird.

## Grenzen – ehrlich gesagt

- **Die Verarbeitung findet bei US-Firmen statt.** OpenRouter sitzt in den USA, und die Modelle von Anthropic, OpenAI oder Microsoft laufen bei den Anbietern. ZDR bedeutet „wird nicht gespeichert“, nicht „bleibt in der EU“. Dass ein Endpunkt wirklich nichts speichert, beruht auf der Zusage des Anbieters und der Einstufung durch OpenRouter, nicht auf einer eigenen Prüfung.
- **EU-Region:** `eu.openrouter.ai` und die Region „Europa“ in der Guardrail gibt es nur im Business- oder Enterprise-Tarif. Dort sind Websuche und Server-Tools nicht verfügbar. Für eine Familie ist das meist nicht praktikabel. Wer „nur EU“ braucht, nutzt einen EU-gehosteten Anbieter oder lokale Modelle (derzeit nicht Teil der App).
- **Websuche:** ZDR gilt für die Modell-Anfrage. Wie lange der Suchanbieter die Anfrage aufbewahrt, entscheidet dessen eigene Richtlinie. Wer es ganz strikt will, schaltet den Schalter „Websuche“ bei den Kindern aus (*Verwaltung → Personen*).
- **Gedächtnis:** Gedächtnis-Einträge gehen als Teil des Systemprompts an das Modell. Für Kinder kann der Schalter „Gedächtnis“ in *Verwaltung → Personen* pro Person ausgeschaltet werden.
- **Lokal ist nicht automatisch sicher:** Der Schutz hängt an eurem Netzwerk, dem Mac-Login und den Passwörtern der Familie. Nutzt HTTPS und möglichst ein VPN, aktiviert „Verwaltung nur aus Heimnetz/VPN“ (*Verwaltung → Familie & KI*) und prüft die Zugriffsrechte der Sicherungen.

## Wenn dir noch etwas auffällt

Der Quelltext ist offen. Fehler oder Vorschläge bitte als Issue im Repository melden.

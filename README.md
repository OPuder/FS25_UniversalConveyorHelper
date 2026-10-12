# FS25 Universal Conveyor Helper

**Ein Helfer für Förderbänder in Farming Simulator 25**\
Zentrale Verwaltung, AutoStart, automatische Übergabe und spezielle
Unterstützung für den SL 80-22 Quantum.

[⬇️ **Universal Conveyor Helper
herunterladen**](https://github.com/OPuder/FS25_UniversalConveyorHelper/releases)

> **Installation:** Lade unter **Releases → Assets** die aktuelle
> Mod-ZIP herunter und kopiere sie direkt in deinen `mods`-Ordner.
> **Nicht entpacken!**

Standardpfad:

``` text
Dokumente/My Games/FarmingSimulator2025/mods
```

------------------------------------------------------------------------

## 🇩🇪 Deutsch

## 🚜 Funktionen

### Zentrale Förderband-Verwaltung

-   Automatische Erkennung und zentrale Verwaltung unterstützter
    Förderbänder
-   Übersicht aller erkannten Förderbänder
-   Förderbänder individuell benennen, damit auch mehrere gleiche Geräte
    unterscheidbar bleiben
-   Förderbänder gezielt auswählen und direkt zu ihnen teleportieren
-   Einstellungen pro Förderband speichern und beim Laden des
    Spielstands wiederherstellen
-   Aktivierung und tatsächlicher Betriebszustand werden getrennt
    behandelt

### ⚙️ AutoStart und Betrieb

-   **AutoStart pro Förderband:** Für jedes unterstützte Förderband
    separat aktivierbar oder deaktivierbar
-   Der AutoStart-Manager arbeitet unabhängig davon, ob der Spieler
    direkt neben dem Förderband steht
-   Motorstart und tatsächliches Einschalten des Förderbands werden
    getrennt behandelt
-   Unterstützung für automatisierte Abläufe, bei denen Förderbänder
    selbstständig vorbereitet und betrieben werden

**Hinweis:** Die UCH-AutoStart-Einstellung ist nicht dasselbe wie die
globale Einstellung für den automatischen Motorstart im Spiel. Bei
unerwartetem Verhalten bitte beide Einstellungen kontrollieren.

### 📦 Automatische Übergabe und Entladung

-   Automatische Erkennung geeigneter Übergabe- bzw. Entladeziele
-   Prüfung von FillType und verfügbarer Kapazität
-   Begrenzter Erkennungsbereich von ungefähr **3 Metern**, damit nicht
    versehentlich weiter entfernte Objekte ausgewählt werden
-   Automatisierte Materialübergabe für unterstützte Förderbandtypen

### 🏎️ Förderband-Geschwindigkeit

-   Unterstützung für Förderbänder, deren Konfiguration eine höhere
    Fahrgeschwindigkeit erlaubt
-   Für entsprechend angepasste Förderbänder ist eine
    Höchstgeschwindigkeit von bis zu **25 km/h** vorgesehen, sofern das
    jeweilige Fahrzeug bzw. dessen Konfiguration dies unterstützt

> Die Höchstgeschwindigkeit ist nicht automatisch für jedes beliebige
> Förderband garantiert. Das jeweilige Fahrzeug muss die entsprechende
> Motorisierung und Geschwindigkeitskonfiguration unterstützen.

### 🎮 SL 80-22 Quantum -- nativer KI-Job

-   Den nativen Förderband-KI-Job direkt im Quantum mit **H** starten
    und stoppen
-   Die H-Aktion ist auf den Quantum begrenzt und soll die normale
    H-Tastenfunktion außerhalb dieses Fahrzeugs nicht verändern
-   Einstellbarer Schwenkwinkel
-   Der KI-Ablauf verwendet eine Geschwindigkeit von **1 km/h**
-   Der native KI-Job übernimmt die eigentliche Schwenkbewegung des
    Förderbands

### 🧰 Unterstützung unterschiedlicher Förderbandtypen

UCH berücksichtigt Besonderheiten einzelner Förderbandtypen, statt für
alle Geräte denselben Ablauf zu erzwingen. Dazu gehören unter anderem
die vorhandene S710-Unterstützung und die spezielle Integration des SL
80-22 Quantum.

------------------------------------------------------------------------

## ⚠️ Wichtig: Förderband während des Beladens nicht ausschalten

Wenn ein Förderband gerade Material aufnimmt oder ein Beladevorgang
läuft, muss es **eingeschaltet bleiben, bis der Vorgang vollständig
abgeschlossen ist**.

**Falsch:**

``` text
Förderband belädt
       ↓
Förderband ausschalten
       ↓
Beladevorgang möglicherweise unterbrochen
```

**Richtig:**

``` text
Förderband belädt
       ↓
Beladevorgang vollständig abschließen
       ↓
Förderband ausschalten
```

> 🔴 Während eines laufenden Beladevorgangs das Förderband nicht
> ausschalten.\
> 🟢 Erst ausschalten, wenn der Vorgang vollständig abgeschlossen ist.

------------------------------------------------------------------------

## 📥 Installation

1.  Öffne die
    [GitHub-Releases-Seite](https://github.com/OPuder/FS25_UniversalConveyorHelper/releases).
2.  Lade unter **Assets** die aktuelle
    `FS25_UniversalConveyorHelper.zip` herunter.
3.  Kopiere die ZIP-Datei in den `mods`-Ordner.
4.  **Entpacke die ZIP-Datei nicht.**
5.  Starte Farming Simulator 25 und aktiviere den **Universal Conveyor
    Helper** im Mod-Auswahlbildschirm.
6.  Lade deinen Spielstand und öffne die UCH-Verwaltung.

Verwende möglichst nur eine installierte Version der Mod.

------------------------------------------------------------------------

## 💡 Tipps zur Verwendung

Wenn du mehrere Förderbänder desselben Typs verwendest, vergib
eindeutige Namen, zum Beispiel:

``` text
S710 Eingang
S710 Lager 1
S710 Lager 2
S710 Ausgang
```

Wenn AutoStart oder ein automatisierter Ablauf nicht wie erwartet
funktioniert, prüfe: - die UCH-Einstellung für das jeweilige
Förderband, - die globale Einstellung für den automatischen
Motorstart, - ob das Förderband tatsächlich eingeschaltet ist, - ob das
Ziel den passenden FillType unterstützt und ausreichend Kapazität hat.

------------------------------------------------------------------------

## ⚠️ Kompatibilität

-   Entwickelt für **Farming Simulator 25**
-   Die Kompatibilität und verfügbaren Funktionen können vom
    Förderbandtyp, dessen Konfiguration, der Spielversion und anderen
    installierten Mods abhängen.
-   Funktionen wie 25 km/h sind nur möglich, wenn die jeweilige
    Fahrzeugkonfiguration diese Geschwindigkeit unterstützt.

------------------------------------------------------------------------

## 🐛 Fehler melden

Wenn ein Problem auftritt, melde es bitte über die
[GitHub-Issues](https://github.com/OPuder/FS25_UniversalConveyorHelper/issues)
und gib möglichst Folgendes an:

-   UCH-Version
-   betroffenes Förderband
-   weitere verwendete Mods
-   genaue Schritte zur Reproduktion
-   erwartetes und tatsächliches Verhalten
-   `log.txt` von Farming Simulator 25

Bitte den Log möglichst vollständig anhängen. Fehler anderer Mods können
ebenfalls darin erscheinen und stammen nicht zwingend von UCH.

------------------------------------------------------------------------

## 📦 Releases und Projekt

-   [⬇️ Aktuelle Version
    herunterladen](https://github.com/OPuder/FS25_UniversalConveyorHelper/releases)
-   [GitHub-Repository](https://github.com/OPuder/FS25_UniversalConveyorHelper)
-   [Fehler melden / Verbesserung
    vorschlagen](https://github.com/OPuder/FS25_UniversalConveyorHelper/issues)

Die aktuelle Versionsnummer findest du auf der Releases-Seite.

------------------------------------------------------------------------

## 🇬🇧 English

## Overview

**FS25 Universal Conveyor Helper (UCH)** adds centralized management and
automation features for supported conveyor vehicles in Farming Simulator
25. It provides per-conveyor settings, AutoStart, automatic
transfer-target detection, and dedicated support for the SL 80-22
Quantum.

[⬇️ **Download Universal Conveyor
Helper**](https://github.com/OPuder/FS25_UniversalConveyorHelper/releases)

> **Installation:** Download the latest mod ZIP under **Releases →
> Assets** and copy it directly into your `mods` folder. **Do not
> extract it!**

Default path:

``` text
Documents/My Games/FarmingSimulator2025/mods
```

------------------------------------------------------------------------

## 🚜 Features

### Central conveyor management

-   Automatic detection and centralized management of supported
    conveyors
-   Overview of detected conveyor vehicles
-   Custom names to distinguish multiple conveyors of the same type
-   Select a conveyor directly and teleport to it
-   Save settings per conveyor and restore them when loading a savegame
-   Separate handling of a feature being enabled and the conveyor's
    actual operating state

### ⚙️ AutoStart and operation

-   **AutoStart per conveyor:** Enable or disable it individually for
    each supported conveyor
-   The AutoStart manager works without requiring the player to stand
    next to the conveyor
-   Engine start requests and the actual conveyor operating state are
    handled separately
-   Supports automated workflows that prepare and operate conveyors

**Note:** UCH AutoStart is separate from the game's global automatic
engine-start setting. If a conveyor behaves unexpectedly, check both
settings.

### 📦 Automatic transfer and unloading

-   Automatic detection of suitable transfer or unloading targets
-   FillType and available-capacity checks
-   A limited detection range of approximately **3 metres** to avoid
    selecting distant objects unintentionally
-   Automated material transfer for supported conveyor types

### 🏎️ Conveyor speed

-   Supports higher driving speeds for conveyors whose configurations
    allow them
-   A maximum speed of up to **25 km/h** is intended for suitably
    configured conveyors, where supported by the vehicle and its
    configuration

> A 25 km/h maximum is not guaranteed for every conveyor. The vehicle
> configuration must support the required motorization and speed
> settings.

### 🎮 SL 80-22 Quantum -- native AI job

-   Start and stop the Quantum's native conveyor AI job using **H**
-   The H action is intended for the Quantum only and should not change
    normal H-key behaviour outside that vehicle
-   Adjustable sweep angle
-   The UCH AI workflow uses a speed of **1 km/h**
-   The native AI job handles the conveyor's actual sweeping movement

### 🧰 Support for different conveyor types

UCH accounts for differences between supported conveyor vehicles instead
of forcing every device through the same workflow. This includes the
existing S710 support and the dedicated SL 80-22 Quantum integration.

------------------------------------------------------------------------

## ⚠️ Important: Do not switch off a conveyor during loading

If a conveyor is currently loading material or a loading operation is in
progress, **keep it switched on until the operation has fully
completed**.

**Incorrect:**

``` text
Conveyor is loading
       ↓
Switch conveyor off
       ↓
Loading operation may be interrupted
```

**Correct:**

``` text
Conveyor is loading
       ↓
Finish the loading operation
       ↓
Switch conveyor off
```

> 🔴 Do not switch off a conveyor during an active loading operation.\
> 🟢 Switch it off only after the operation is complete.

------------------------------------------------------------------------

## 📥 Installation

1.  Open the [GitHub Releases
    page](https://github.com/OPuder/FS25_UniversalConveyorHelper/releases).
2.  Download the latest `FS25_UniversalConveyorHelper.zip` under
    **Assets**.
3.  Copy the ZIP file into your `mods` folder.
4.  **Do not extract the ZIP file.**
5.  Start Farming Simulator 25 and enable **Universal Conveyor Helper**
    in the mod selection screen.
6.  Load your savegame and open the UCH management interface.

If possible, keep only one installed copy of the mod.

------------------------------------------------------------------------

## 💡 Usage tips

If you use multiple conveyors of the same type, give them unique names,
for example:

``` text
S710 Infeed
S710 Storage 1
S710 Storage 2
S710 Outfeed
```

If AutoStart or an automated workflow does not behave as expected,
check: - the UCH setting for the individual conveyor, - the game's
global automatic engine-start setting, - whether the conveyor is
actually switched on, - whether the target supports the required
FillType and has enough capacity.

------------------------------------------------------------------------

## ⚠️ Compatibility

-   Designed for **Farming Simulator 25**
-   Compatibility and available features may depend on the conveyor
    type, its configuration, the game version, and other installed mods.
-   Features such as 25 km/h are only available when the relevant
    vehicle configuration supports that speed.

------------------------------------------------------------------------

## 🐛 Reporting issues

If you encounter a problem, report it through [GitHub
Issues](https://github.com/OPuder/FS25_UniversalConveyorHelper/issues)
and include as much of the following as possible:

-   UCH version
-   affected conveyor
-   other installed mods
-   exact reproduction steps
-   expected and actual behaviour
-   Farming Simulator 25 `log.txt`

Please attach the log as completely as possible. Other mods may also
produce errors, so not every message in the log necessarily comes from
UCH.

------------------------------------------------------------------------

## 📦 Releases and project

-   [⬇️ Download the latest
    version](https://github.com/OPuder/FS25_UniversalConveyorHelper/releases)
-   [GitHub
    repository](https://github.com/OPuder/FS25_UniversalConveyorHelper)
-   [Report a bug / suggest an
    improvement](https://github.com/OPuder/FS25_UniversalConveyorHelper/issues)

Check the Releases page for the current version number.

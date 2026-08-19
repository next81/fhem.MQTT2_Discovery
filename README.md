# MQTT2_DISCOVERY

`MQTT2_DISCOVERY` verarbeitet Home-Assistant-MQTT-Discovery und das native
Tasmota-Discovery-Protokoll in FHEM. Daraus erzeugt es konservativ verwaltete
`MQTT2_DEVICE`-Definitionen. 

## Architektur und Discovery-Formate

Eingehende Konfigurationen werden zuerst durch eine geordnete Format-Registry
klassifiziert. Spezifische Adapter wie Tasmota stehen vor dem allgemeinen
Home-Assistant-Adapter. Ein Adapter, der ein Topic beansprucht, liefert entweder
ein gueltiges Ergebnis oder einen sichtbaren Fehler; fehlerhafte Nachrichten
fallen nicht versuchsweise auf ein anderes Format zurueck.

Jeder Adapter normalisiert sein Protokoll in das versionierte kanonische Modell
`mqtt2-discovery/1`. Es trennt Device-Identitaet, lesbare `signals`, schreibbare
`commands`, `availability` und die sie verbindenden `capabilities`. Erst danach
erzeugt der allgemeine Mapper FHEM-`readingList`, `setList` und konservative
Semantic-Metadaten. Der Mapper kennt weder Home-Assistant-Kurzformen noch native
Tasmota-Discovery-Payloads. Das Modell und die Erweiterung um weitere Adapter
sind in [docs/canonical-model.md](docs/canonical-model.md) beschrieben.

Normale MQTT-State-Nachrichten werden nicht als Discovery beansprucht. Ein Topic
wie `zigbee2mqtt/wohnzimmer` erreicht weiterhin das passende `MQTT2_DEVICE`; nur
die zugehoerige Konfiguration unter `homeassistant/.../config` wird vom
Discovery-Modul verarbeitet (und gefiltert).

## Installation und Updates

Das Modul kann ueber das FHEM-Controlfile installiert werden:

```text
update all https://raw.githubusercontent.com/next81/fhem.MQTT2_Discovery/main/controls_MQTT2_DISCOVERY.txt
shutdown restart
```

Danach wird das Discovery-Device angelegt und aktiviert:

```text
define mqttDiscovery MQTT2_DISCOVERY <mqttServer>
set mqttDiscovery activate
```

`<mqttServer>` ist hierbei das Device fuer die MQTT2-Schnittstelle
(`MQTT2_SERVER` oder `MQTT2_CLIENT`). `activate` ergaenzt
`MQTT2_DISCOVERY` in `clientOrder`, ohne andere Parser zu entfernen.

Damit regulaere FHEM-Updates dieses Repository automatisch beruecksichtigen,
wird es einmalig als zusaetzliche Updatequelle registriert:

```text
update add https://raw.githubusercontent.com/next81/fhem.MQTT2_Discovery/main/controls_MQTT2_DISCOVERY.txt
```

Anschliessend zeigen `update check` bzw. `update` auch neue Versionen dieses
Moduls an. Nach einem Modulupdate ist `shutdown restart` erforderlich.

## Konfiguration

- `discoveryPrefixes`: kommaseparierte Prefixe, Default
  `homeassistant,tasmota/discovery`
- `deviceNamePrefix`: optionaler Prefix fuer neu angelegte Device-Namen. Ohne das
  Attribut wird nichts vorangestellt, beispielsweise entsteht der Name `Node`.
  Mit `attr mqttDiscovery deviceNamePrefix Tasmota_` wird daraus `Tasmota_Node`.
- `existingDevice`: `conservative`, `ignore` oder `replace`
- `autoCreate`: `0` oder `1`, Default `1`
- `autoDelete`: `0` oder `1`, Default `0`
- `disable`: `0` oder `1`, Default `0`; bei `1` werden Discovery-Nachrichten ohne Aenderungen konsumiert

Die Zielauflösung folgt dabei der Geräteidentität des FHEM-`MQTT2_DEVICE`-
Autocreate: Ein bereits unter derselben CID/`DEF` registriertes `MQTT2_DEVICE`
wird unabhängig von seinem aktuellen FHEM-Namen wiederverwendet. Damit bleiben
auch umbenannte Devices ihrem MQTT-Client zugeordnet. Vor der CID-Suche werden
vorhandene `bridgeRegexp`-Regeln gegen die von Discovery angekündigten
State-Topics ausgewertet; die daraus entstehende virtuelle CID wird wie beim
FHEM-Autocreate als `DEF` eines neuen Bridge-Unterdevices verwendet. Bereits
anderen Discovery-Identitäten zugeordnete Targets werden nicht erneut verwendet,
da eine Transport-CID bei einer Bridge mehrere logische Geräte vertreten kann.

Eine Aenderung von `deviceNamePrefix` gilt fuer Devices, die danach erstmals
entdeckt und angelegt werden.

Mit `attr mqttDiscovery disable 1` kann das Modul bereits beim FHEM-Start kontrolliert
deaktiviert bleiben. Nach `deleteattr mqttDiscovery disable` verarbeitet es wieder neue
Discovery-Nachrichten. Retained Nachrichten eines `MQTT2_SERVER` koennen danach gezielt
mit `set mqttDiscovery rescan` verarbeitet werden.

`rescan` verarbeitet beim `MQTT2_SERVER` dessen lokalen Retain-Cache. `MQTT2_CLIENT` besitzt keinen entsprechenden Cache; dort muessen retained Discovery-Nachrichten durch Broker-Replay bzw. Reconnect eintreffen.

Fehler bleiben pro Discovery-Topic sichtbar, bis genau dieses Topic korrigiert
oder geloescht wird. `errorCount`, `lastError`, `lastErrorAdapter` und
`lastErrorTopic` zeigen abgelehnte Konfigurationen. Entsprechend dokumentieren
`warningCount`, `lastWarning`, `lastWarningAdapter` und `lastWarningTopic`
weiterhin bestehende Teilabbildungen. Eine erfolgreiche Nachricht eines anderen
Geraets verdeckt einen vorhandenen Fehler nicht.

## Home-Assistant Discovery

Der Home-Assistant-Adapter verarbeitet sowohl klassische Entity-Discovery unter
`homeassistant/<component>/[<node_id>/]<object_id>/config` als auch
Device-Discovery unter `homeassistant/device/<object_id>/config`. Unterstuetzte
Komponenten sind `sensor`, `binary_sensor`, `switch`, `button`, `number`,
`select`, `text`, `light`, `cover`, `fan`, `lock`, `climate`, `device_tracker`,
`event` und `device_automation`. Dabei werden sowohl ausgeschriebene
Konfigurationsfelder als auch die von Home Assistant definierten Kurzformen
erkannt.

Angekuendigte State-Topics werden als FHEM-Readings in die `readingList`
uebernommen, schreibbare Command-Topics mit ihren Wertebereichen und Optionen in
die `setList`. Availability, Templates, Einheiten, Geraete- und Zustandsklassen
sowie weitere Komponenteneigenschaften fliessen in die Abbildung und die
Semantic-Metadaten ein. Zusammengehoerige Entities werden anhand der von
Discovery gelieferten Geraeteidentitaet einem gemeinsamen `MQTT2_DEVICE`
zugeordnet. Ein leerer retained Config-Payload entfernt die zuvor ueber dieses
Topic angekuendigte Entity beziehungsweise das gesamte Device aus der
Discovery-Verwaltung.

## Tasmota Discovery

Aktuelle Tasmota-Versionen senden standardmaessig keine klassischen
`homeassistant/.../config`-Nachrichten mehr. Stattdessen werden je Geraet die
beiden retained Topics `tasmota/discovery/<MAC>/config` und
`tasmota/discovery/<MAC>/sensors` veroeffentlicht. Home Assistant und Tasmota
Discovery sind deshalb standardmaessig aktiv. Falls `discoveryPrefixes` bereits
abweichend gesetzt ist, laesst sich der Default so wiederherstellen:

```text
deleteattr mqttDiscovery discoveryPrefixes
set mqttDiscovery rescan
```

Der Adapter fuehrt beide Nachrichten anhand der MAC-Adresse zusammen. Unterstuetzt
werden Relais/Schalter, dimmbare und farbige Leuchten mit Farbtemperatur und
Effekten, Rolllaeden inklusive Position und Tilt, iFan-Geschwindigkeit, physische
Switches als Binary-Sensoren, Button-/Switch-Aktionen als Event-Readings sowie die
in der `sensors`-Nachricht enthaltenen skalaren Telemetriesensoren. Ein gemeldeter
Kamerastream wird als Warnung ausgewiesen, weil er kein MQTT-State/Command-Paar
fuer ein `MQTT2_DEVICE` darstellt.

Bei mehrkanaligen Tasmota-Messwerten werden Klasse und Einheit auch fuer einzelne
Arraykanaele uebernommen, beispielsweise `Power[0]` als `power` in `W`,
`ApparentPower[0]` als `apparent_power` in `VA`, `ReactivePower[0]` als
`reactive_power` in `var` und `Current[0]` als `current` in `A`. Der von Tasmota
zwischen `0` und `1` gelieferte Leistungsfaktor bleibt dimensionslos.

Live eintreffende Discovery-Konfigurationen werden ueber eine kurze interne Queue
in getrennten Topic- und Device-Schritten verarbeitet. Pro Timer-Tick wird hoechstens
ein Topic ausgewertet oder ein Zieldevice aktualisiert. Die Registry wird fuer einen
kompletten Schub nur einmal kopiert und persistiert. Dadurch blockiert ein Schub vieler
retained Topics FHEMs Event-Loop nicht fuer die Dauer des gesamten Schubs. Mehrere noch
nicht verarbeitete Nachrichten desselben Config-Topics werden auf den zuletzt
empfangenen Stand zusammengefasst.

## Lesbare Reading-Auswertung

Native Tasmota-JSON-State-Topics wie `RESULT` und `SENSOR` verwenden wie
MQTT2-Autocreate jeweils genau eine kurze Zeile
`{ json2nameValue($EVENT,'',$JSONMAP) }`. Dadurch entstehen die von FHEM
abgeflachten Reading-Namen unveraendert, beispielsweise `POWER`, `Dimmer` oder
`ENERGY_Power_1`, und ein vorhandenes geraeteweites `jsonMap` bleibt wirksam.
Discovery-IDs und Set-Namen bleiben davon getrennt; SemanticUI liest aus den
tatsaechlich erzeugten Rohreadings. Da jeweils der komplette Payload ausgewertet
wird, koennen auch weitere von Tasmota gesendete Felder als Readings erscheinen.

Einfache Home-Assistant-Templates wie `{{ value_json.ENERGY.Power[0] }}` werden
nicht als eigene Runtime-Aufrufe gespeichert. Alle einfachen JSON-Pfade desselben
State-Topics werden in einer einzigen `json2nameValue()`-Zeile zusammengefasst.
Dasselbe gilt fuer die gleichwertige Jinja-Schreibweise mit literalem Schluessel,
beispielsweise `{{ value_json.get('battery') }}`.
Das inline sichtbare Mapping enthaelt nur echte Abweichungen zwischen JSON-Schluessel
und dem von Discovery abgeleiteten Reading-Namen. Identische Namen bleiben bei
`json2nameValue()` auch ohne Eintrag unveraendert. Gibt es keine echte Umbenennung,
verwendet die Zeile deshalb nur `json2nameValue($EVENT)`. Ein Filter wird bewusst
nicht gesetzt, damit beim Anlegen eines Devices alle Felder des JSON-Payloads als
Readings erscheinen. Topic-lokale Umbenennungen vermeiden weiterhin Kollisionen
zwischen gleichnamigen JSON-Schluesseln verschiedener Topics. Komplexe Templates
mit Filtern oder Bedingungen verwenden weiterhin die sichere Template-Engine; das
Template steht dabei lesbar im Aufruf statt als Base64-Text. Auch komplexe
`setList`-Fallbacks enthalten Topics, Payloads, Command-Templates und
Auswahl-Mappings als sicher escapeten Klartext. Erzeugte `readingList`- und
`setList`-Attribute verwenden kein Base64.

Besitzt eine schreibbare Entity ein Zustandsreading, verwendet ihr Setter exakt
dessen endgueltigen FHEM-Namen. Das gilt protokollunabhaengig fuer Home-Assistant-
und Tasmota-Discovery einschliesslich Gross-/Kleinschreibung; beispielsweise wird
ein Reading `POWER1` auch mit `set <device> POWER1 ...` geschaltet.

Entity-Namen verwenden innerhalb eines Zieldevices den kuerzesten eindeutigen
Suffix ihres logischen Discovery-Pfads. Eine allein vorkommende Komponente
`sensor_battery` erzeugt deshalb `battery`. Erst bei gleichnamigen Komponenten
werden die kollidierenden Namen qualifiziert, beispielsweise `sensor_battery`
und `device_battery`. Die Regel gilt einheitlich fuer Readings, Setter und die
darauf verweisenden SemanticUI-Metadaten.

## SemanticUI

Automatisch angelegte `MQTT2_DEVICE`-Devices erhalten direkt am Device strukturierte
`SEMANTIC_METADATA`. Klassen, Capabilities, Lese-/Schreibpfade, Wertebereiche,
Einheiten und Home-Assistant-`device_class`/`state_class` werden aus den Discovery-Daten
abgeleitet. Das Semantic-Modul erkennt diese Metadaten als externe Quelle mit hoher
Konfidenz; die Devices erscheinen dadurch ohne zusaetzliche Attribute automatisch in
SemanticUI. Ohne vorhandenes `room` bzw. `semanticRoom` werden sie unter
`Nicht zugeordnet` einsortiert. Manuell gesetzte Semantic-Attribute haben weiterhin
Vorrang.

Schaltzustaende bleiben dabei exakt so erhalten, wie sie im erzeugten FHEM-Device
stehen. Liefert `setList` beispielsweise `POWER1:ON,OFF`, enthalten auch die
Semantic-Metadaten `options: ["ON", "OFF"]`; es findet keine Umbenennung in
`on`/`off` statt. `activeValue` und `inactiveValue` kennzeichnen ausschliesslich die
Darstellung und veraendern weder Reading- noch Set-Werte.

`readingList` und `setList` bleiben von der Semantic-Auswahl vollstaendig getrennt:
Discovery bildet dort weiterhin alle sicher auswertbaren Topics und Befehle ab.
SemanticUI erhaelt dagegen bewusst nur eine konservative Teilmenge. Automatisch
sichtbar werden sicher abgebildete Setter sowie typische Read-only-Sensoren mit einer
expliziten, zugelassenen Home-Assistant-`device_class`, etwa Temperatur,
Luftfeuchtigkeit, Batterie, Leistung, Druck, Beleuchtungsstaerke oder relevante
Binaerzustaende. Unklassifizierte Werte und `entity_category=diagnostic` bleiben als
normale FHEM-Readings erhalten, erscheinen aber nicht automatisch in SemanticUI.
Manuelle Semantic-Attribute koennen diese Auswahl erweitern.

Die Semantic-Auswahl leitet keine Bedeutung aus Hersteller-, Topic- oder Entitynamen
ab. Bei genau einer ueber eine starke Geraeteidentitaet gruppierten Climate-Entity
werden schreibbare atomare Geschwister allgemein komponiert: `switch`, `select`,
`number`, `text` und `button` werden zu frei benannten Capabilities mit einer
expliziten Darstellungsart. Gibt es keine oder mehrere Climate-Hauptentities, bleiben
alle Entities getrennt. Dasselbe gilt fuer schwach zugeordnete sowie als `config` oder
`diagnostic` kategorisierte Geschwister. Ein bereits im Geraetenamen enthaltener
Praefix wird lediglich allgemein aus dem Anzeigenamen der Semantic-Entity entfernt.

Die Metadaten werden nur an Devices angebracht, die `MQTT2_DISCOVERY` selbst angelegt
hat. Im `replace`-Modus uebernommene Bestandsdevices bleiben davon unberuehrt.

Das Semantic-Modul beginnt die Integrationsmarkierung bei `DEFINED` automatisch. Wenn
es das optionale Fertig-Signal bereitstellt, meldet Discovery nach dem vollstaendigen
Anwenden von `devicetopic`, `readingList`, `setList` und `SEMANTIC_METADATA` den
Abschluss. SemanticUI kann die Lade-Karte dadurch sofort ausblenden; ohne Fertig-Signal
greift der automatisch verlaengerte Ruhe-Timer. Ohne Semantic-Modul bleibt der gesamte
Discovery-Ablauf unveraendert funktionsfaehig.

`device_automation`-Discoveries werden als eingehende, auf Topic und optionales
Payload gefilterte Readings abgebildet. Sie stellen Ereignisse des physischen
Geraets dar und werden deshalb nicht in SemanticUI angezeigt.
Bei MQTT-`number` gilt fuer ein fehlendes `step` der Home-Assistant-Default `1`.
MQTT-`text` kennzeichnet seine schreibbare Semantic-Capability als Texteingabe
und uebergibt eine vorhandene maximale Laenge an SemanticUI.
Das Home-Assistant-Feld `retain` (Kurzform `ret`) wird fuer ausgehende Befehle
uebernommen. Dadurch erreichen retained Sollwerte auch schlafende MQTT-Geraete wie
HomeButtons beim naechsten Aufwachen.

## Logging

Verbose:
- `1` - Verarbeitungs-, Parser- und Konfigurationsfehler
- `2` - Lifecycle, Warnungen sowie angelegte, uebernommene oder entfernte Devices
- `3` - allgemeiner Ablauf von Sets, Rescan und Discovery-Verarbeitung
- `4` - Diagnosewerte zu Nachrichten, Mapping, Entities und erzeugten Zeilen
- `5` - gekuerzte Discovery-Payloads; sensible Felder werden geschwaerzt


## Unittests

```text
cpanm --installdeps --with-develop .
prove -I tests/lib -lv tests
PERL5OPT=-Mwarnings=FATAL prove -I tests/lib -lv tests
```

Coverage kann lokal mit `Devel::Cover` erzeugt werden:

```text
cover -delete
PERL5OPT=-MDevel::Cover prove -I tests/lib tests
cover
```

Die Schichten, injizierbaren Abhaengigkeiten und Grenzen der simulierten
FHEM-Umgebung sind in [`docs/testing-architecture.md`](docs/testing-architecture.md)
beschrieben. Dieselben Tests laufen in der CI gegen mehrere Perl-Versionen.

Vor einer Veroeffentlichung muss das FHEM-Controlfile nach allen Aenderungen an
Produktionsmodulen neu erzeugt und anschliessend die Testsuite ausgefuehrt werden:

```text
perl tools/generate_controls.pl
PERL5OPT=-Mwarnings=FATAL prove -I tests/lib -lv tests
```

Der mitgelieferte Pre-Commit-Hook erzeugt das Controlfile bei jedem Commit neu
und nimmt es automatisch in den Commit auf. Er wird pro lokaler Arbeitskopie
einmalig aktiviert:

```text
git config core.hooksPath .githooks
```

Auf Systemen mit Unix-Dateirechten muss `.githooks/pre-commit` ausfuehrbar sein.
Die Aktivierung laesst sich mit `git config --get core.hooksPath` pruefen. Der
Hook bricht den Commit ab, wenn das Controlfile nicht erzeugt oder nicht zum
Commit hinzugefuegt werden kann.

## Copyright

Copyright (C) 2026 Andreas Planer. Weitere Angaben zum Autor und Projekt stehen
in [`LICENSE.md`](LICENSE.md).

# Testarchitektur

Die Produktionslogik ist in drei Schichten aufgeteilt:

1. Formatadapter normalisieren MQTT-Discovery-Nachrichten in das kanonische Modell.
2. Der Mapper erzeugt daraus deklarative Reading-, Set- und Semantic-Strukturen.
3. Das FHEM-Modul plant und uebergibt Seiteneffekte an ein Gateway.

## Isolierte Bausteine

- `MQTT2_Discovery::Parser::HomeAssistant` verarbeitet ausschliesslich
  Home-Assistant-MQTT-Discovery.
- `MQTT2_Discovery::Parser::Tasmota` verarbeitet ausschliesslich native
  Tasmota-Discovery-Nachrichten.
- `MQTT2_Discovery::Mapper::Common` normalisiert gemeinsam verwendete
  Auswahlwerte, Capability-Namen und numerische Metadaten.
- `MQTT2_Discovery::Mapper::NameResolver` loest kollidierende Entity-Namen auf.
- `MQTT2_Discovery::Mapper::Renderer` rendert deklarative Eintraege in FHEM-Attribute.
- `MQTT2_Discovery::Mapper::Semantics` erzeugt semantische Metadaten.
- `MQTT2_Discovery::DevicePlanner` berechnet Topic-, Konflikt- und Attributplaene
  ohne selbst FHEM zu veraendern.
- `MQTT2_Discovery::ActionPlan` beschreibt zusammengehoerige Aenderungen und rollt
  bereits ausgefuehrte Aktionen bei einem Fehler rueckwaerts zurueck.
- `MQTT2_Discovery::FHEMGateway` kapselt FHEM-Kommandos, Readings, Timer, Logs
  und die vom `MQTT2_DEVICE`-Autocreate gefuehrte CID-Zuordnung.

Formatadapter koennen ueber das Argument `adapters` von `FormatRegistry::consume`
injiziert werden. Fuer Modultests koennen ein Gateway ueber
`$hash->{helper}{gateway}` und Adapter ueber `$hash->{helper}{format_adapters}`
eingesetzt werden. Produktion verwendet jeweils die Standardimplementierungen.

## Teststufen

- `00` bis `40`: reine Unit- und Vertragstests ohne FHEM-Laufzeit.
- `50` und `55`: Tests des FHEM-Moduls und seiner Queue gegen das lokale Gateway.
- `90`: Komponententests der vollstaendigen Verarbeitung mit simulierter FHEM-API.

Die Tests unter `90` sind keine Tests gegen eine reale FHEM-Installation. Die
beobachteten FHEM-Vertraege sind deshalb zusaetzlich in
`docs/verified-fhem-interfaces.md` dokumentiert.

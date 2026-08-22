# Kanonisches Discovery-Modell

`MQTT2_DISCOVERY` trennt Protokollerkennung, Normalisierung und FHEM-Abbildung.
Formatadapter duerfen keine fertigen `readingList`- oder `setList`-Zeilen
erzeugen. Sie liefern ausschliesslich Modellversion 1 an den gemeinsamen Mapper.

## Verarbeitung

```text
MQTT-Nachricht
  -> FormatRegistry
  -> Format::<Adapter>
  -> Model Version 1 + Validator
  -> Mapper
  -> FHEM-Renderer und atomare Anwendung
```

Die Registry prueft spezifische Formate zuerst. Der Home-Assistant-Adapter steht
zuletzt. Ein Adapter kann eine Nachricht ablehnen (`error`) oder als nicht
zustaendig kennzeichnen (`next`). Sobald ein Adapter ein Topic beansprucht hat,
gibt es nach einem Parserfehler keinen Fallback auf ein anderes Format.

## Modellstruktur

Jedes Event ist ein Hash mit diesen Pflichtfeldern:

```perl
{
  schema_version => 1,
  operation      => 'upsert',       # upsert, delete, delete_device

  source => {
    adapter => 'homeassistant',
    prefix  => 'homeassistant',
    topic   => 'homeassistant/sensor/node/temperature/config',
    key     => 'homeassistant/sensor/node/temperature/config|',
    layout  => 'entity',            # entity oder device
  },

  device => {
    identifiers  => ['node'],
    connections  => [],
    name         => 'Node',
    manufacturer => 'Example',
    model        => 'TH-1',
  },

  entity => {
    id            => 'temperature',
    kind          => 'sensor',
    name          => 'Temperature',
    category      => undef,
    configuration => { ... },
  },

  signals      => [ ... ],
  commands     => [ ... ],
  capabilities => { ... },
  availability => [ ... ],
  extensions   => {},
}
```

`source` ist Herkunft und stabile Ownership. Der Mapper darf daraus keine
geraetespezifische Semantik erraten. `entity.configuration` enthaelt nur bereits
normalisierte, ausgeschriebene Domainfelder; Rohabkuerzungen eines
Discovery-Protokolls gehoeren nicht in diese Ebene.

## Signals und Commands

Ein Signal beschreibt einen lesbaren MQTT-Kanal:

```perl
{
  id       => 'state',
  topic    => 'node/state',
  template => '{{ value_json.temperature }}',
}
```

Ein Command beschreibt einen schreibbaren Kanal getrennt davon:

```perl
{
  id       => 'command',
  topic    => 'node/command/temperature',
  template => '{{ value }}',
}
```

Falls ein Protokoll mehrere Werte in einem JSON-Payload zusammenfasst,
normalisiert bereits der Adapter das betreffende Command-Binding:

```perl
{
  id    => 'brightness',
  topic => 'node/light/set',
  name  => 'brightness',
  codec => {
    format     => 'json',
    key        => 'brightness',
    value_type => 'number',
  },
}
```

Der Mapper unterscheidet damit nur zwischen skalaren und typisierten
JSON-Commands. Protokollregeln wie Home Assistants `schema=json` und dessen
Felder `state` oder `brightness` werden ausschliesslich im jeweiligen Adapter
ausgewertet und gelangen nicht als Mapper-Sonderfall hinter die Modellgrenze.

Templates werden weiterhin ausschliesslich durch den sicheren eingeschraenkten
Template-Compiler verarbeitet. Nicht unterstuetzte Ausdruecke erzeugen eine
Warnung oder verhindern die unsichere Teilabbildung.

Native Protokolle koennen zusaetzliche generische Signale liefern. Derzeit sind
`payload`, `json_flatten` und `json_sequence` definiert. Dadurch kann der
Tasmota-Adapter seine vollstaendige Standard-Telemetrie beschreiben, ohne dass
das Modell oder der allgemeine Mapper Tasmota-Payloads oder Tasmota-Topicbasen
kennen muss.

## Capabilities

Capabilities verknuepfen Signal und Command explizit:

```perl
capabilities => {
  power => {
    read  => 'state',
    write => 'command',
    value => {
      type         => 'boolean',
      device_class => undef,
    },
  },
}
```

Alle sicher abbildbaren Signals erreichen die FHEM-`readingList`, alle Commands
die `setList`. SemanticUI erhaelt davon nur die konservative Positivmenge. Ein
Signal muss deshalb nicht automatisch in SemanticUI erscheinen.

## Neuer Formatadapter

Ein Adapter implementiert mindestens:

```perl
sub id;
sub claims;
sub consume;
```

`claims(topic => ..., prefixes => ...)` darf keinen Adapterzustand veraendern.
`consume(...)` darf mehrere Nachrichten im uebergebenen Adapterzustand sammeln
und liefert null oder mehr kanonische Events. Vor der Rueckgabe wird jedes Event
mit `MQTT2_Discovery::Model::validate()` validiert.

Protokollspezifisch bleiben insbesondere:

- Topic- und Payloadschema
- Versionspruefung
- Abkuerzungen und Rohfelder
- Zusammenfuehrung mehrerer Discovery-Nachrichten
- stabile Quell- und Entity-IDs
- Loesch- und Birth/Death-Semantik

Zentral bleiben Namenskollisionen, manuelle FHEM-Zeilen, Registry, atomare
Updates, FHEM-Rendering und Semantic-Positivlisten.

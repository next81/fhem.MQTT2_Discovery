# Verifizierte FHEM-Schnittstellen

Geprueft wurde am 18.08.2026 der taeglich aktualisierte Read-only-Mirror `fhem/fhem-mirror` des offiziellen FHEM-SVN.

- `MQTT2_SERVER` und `MQTT2_CLIENT` setzen `ClientsKeepOrder`, `Clients` und `MatchList`. Das Attribut `clientOrder` ersetzt diese geordnete Liste und invalidiert `.clientArray`.
- Beide IO-Module dispatchen `autocreate=<mode>\0<client-id>\0<topic>\0<payload`.
- `ignoreRegexp` wird vor `Dispatch()` gegen `topic:payload` ausgewertet. Passende Discovery-Nachrichten koennen das Discovery-Modul daher nicht erreichen.
- `Dispatch()` ruft Parser in der berechneten Reihenfolge auf. `[NEXT]` setzt die Kette fort. Eine leere Liste setzt die Kette ebenfalls fort; ein einzelner definierter Leerstring stoppt sie ohne Device-Ereignis. `MQTT2_DISCOVERY` konsumiert deshalb mit `return ""`.
- `computeClientArray()` behaelt bei `ClientsKeepOrder` die Reihenfolge aus `Clients` bei und nimmt nur geladene Module mit `Match` auf.
- `MQTT2_DEVICE_Parse` zerlegt den MQTT-Dispatch mit `split("\0", ..., 3)`, sodass Nullzeichen oder Trennzeichen im Payload nicht unabsichtlich weiter zerlegt werden.
- `MQTT2_DEVICE_Parse` gleicht `readingList`-Ausdruecke sowohl gegen `topic:payload` als auch gegen `client-id:topic:payload` ab. Die von `MQTT2_DISCOVERY` erzeugten Zeilen verwenden deshalb nur das innerhalb des IODev eindeutige Topic und bleiben von Aenderungen der Client-ID unabhaengig.
- `MQTT2_SERVER` pflegt den Retain-Cache nur bei gesetztem Retain-Flag und aktivem `respectRetain`. `MQTT2_CLIENT` abonniert nach Connect standardmaessig `#`, besitzt aber keinen gleichwertigen lokalen Retain-Cache.
- `readingList` besteht aus Zeilen `regexp reading` oder `regexp {perl-expression}`. `setList` besteht aus `command[:widget] publish-expression`; Perl-Ausdruecke werden vor dem Publish ausgewertet. Endet das Publish-Topic auf `:r`, entfernt `MQTT2_DEVICE` diesen Zusatz und setzt beim Senden das MQTT-Retain-Flag.
- `MQTT2_DEVICE` ersetzt `$JSONMAP` in einer `readingList`-Expression durch den aus dem Attribut `jsonMap` aufgebauten Hash. `json2nameValue()` akzeptiert alternativ auch einen Hash direkt als drittes Argument; dies erlaubt topic-lokale Zuordnungen ohne Kollisionen zwischen gleichnamigen JSON-Schluesseln verschiedener Topics. Nicht im Hash enthaltene Schluessel behalten ihren Namen, sodass nur echte Umbenennungen angegeben werden muessen. Ohne Umbenennung reicht `json2nameValue($EVENT)`. Ohne optionalen Filter liefert die Funktion alle im JSON-Payload enthaltenen Felder als Readings.
- `json2nameValue()` verbindet verschachtelte Objektschluessel mit Unterstrichen und nummeriert JSON-Arrays ab `1`. Ein Template-Pfad `ENERGY.Power[0]` entspricht deshalb dem Rohreading `ENERGY_Power_1`.

Diese Beobachtungen sind in `tests/90_integration.t` als lokale Vertragstests festgeschrieben. FHEM-Kernmodule werden von diesem Projekt weder kopiert noch veraendert.

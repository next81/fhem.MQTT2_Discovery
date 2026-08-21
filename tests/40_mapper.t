# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use JSON::PP ();
use lib 'lib/FHEM';
use MQTT2_Discovery::Mapper ();
use MQTT2_Discovery::Mapper::Semantics ();

# Erzeugt eine kanonische Test-Entity mit gezielt ueberschreibbaren Feldern.
sub entity {
	my ($component, %extra) = @_;
	return {
		operation => 'upsert', component => $component, object_id => $extra{object_id} || $component,
		entity_key => "topic|$component", discovery_topic => 'homeassistant/device/node/config',
		unique_id => "node_$component", state_topic => "node/$component/state",
		command_topic => "node/$component/set", device => { identifiers => ['node'], name => 'Node' },
		raw_metadata => {}, %extra,
	};
}

my %extra = (
	sensor         => {},
	binary_sensor  => { payload_on => 'YES', payload_off => 'NO' },
	switch         => { payload_on => '1', payload_off => '0' },
	button         => { raw_metadata => { payload_press => 'PRESS' } },
	number         => { min => -10, max => 50, step => 0.5 },
	select         => { options => ['Auto', 'Eco mode', 'A,B'] },
	text           => {},
	light          => { brightness_command_topic => 'node/light/brightness/set', brightness_state_topic => 'node/light/brightness' },
	cover          => { position_command_topic => 'node/cover/position/set', position_topic => 'node/cover/position' },
	climate        => {
		current_temperature_topic => 'node/climate/current',
		temperature_state_topic => 'node/climate/target', temperature_command_topic => 'node/climate/target/set',
		min_temp => 16, max_temp => 30, temp_step => 0.5,
		mode_state_topic => 'node/climate/mode', mode_command_topic => 'node/climate/mode/set', modes => [qw(off auto heat)],
	},
	fan            => { percentage_command_topic => 'node/fan/percentage/set', percentage_state_topic => 'node/fan/percentage' },
	lock           => {},
	device_tracker => {},
	event          => { event_types => [qw(single double)] },
	device_automation => {
		state_topic => 'node/button_1', payload => 'PRESS', type => 'button_short_press', subtype => 'button_1',
	},
);

for my $component (sort keys %extra) {
	my $result = MQTT2_Discovery::Mapper::map_entity(
		entity => entity($component, %{ $extra{$component} }), io_name => 'mqtt', cid => 'client',
	);
	ok($result->{ok}, "$component wird gemappt");
	is($result->{identity}, 'mqtt|id|node', "$component verwendet die starke Device-ID");
	is($result->{proposed_name}, 'Node', "$component ergibt standardmaessig einen Devicenamen ohne Prefix");
	ok(@{ $result->{reading_lines} } || @{ $result->{set_lines} }, "$component erzeugt keine leere Aenderung");
}

my $pac = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', device => { identifiers => ['dc1ed51b96f8'], name => 'pac-1b96f8' }),
	io_name => 'mqtt', cid => 'client',
);
is($pac->{proposed_name}, 'pac_1b96f8', 'Devicename mit Bindestrich wird FHEM-konform normalisiert');

my $prefixed = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor'), io_name => 'mqtt', cid => 'client', name_prefix => 'Tasmota_',
);
is($prefixed->{proposed_name}, 'Tasmota_Node', 'ein optionaler eigener Prefix wird vorangestellt');

subtest 'optionale Features' => sub {
	my $light = MQTT2_Discovery::Mapper::map_entity(entity => entity('light'), io_name => 'mqtt', cid => 'c');
	ok(!grep({ $_->{name} =~ /brightness/ } @{ $light->{set_lines} }), 'Light ohne Brightness-Topic erzeugt keinen Brightness-Setter');
	my $cover = MQTT2_Discovery::Mapper::map_entity(entity => entity('cover'), io_name => 'mqtt', cid => 'c');
	ok(!grep({ $_->{name} =~ /position/ } @{ $cover->{set_lines} }), 'Cover ohne Position-Topic erzeugt keinen Position-Setter');
	my $fan = MQTT2_Discovery::Mapper::map_entity(entity => entity('fan'), io_name => 'mqtt', cid => 'c');
	ok(!grep({ $_->{name} =~ /percentage/ } @{ $fan->{set_lines} }), 'Fan ohne Percentage-Topic erzeugt keinen Percentage-Setter');
	my $json_light = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('light', schema => 'json', raw_metadata => { brightness => 1 }), io_name => 'mqtt', cid => 'c');
	ok(grep({ $_->{name} =~ /brightness/ } @{ $json_light->{set_lines} }), 'JSON-Light erhaelt Brightness-Setter auf dem Command-Topic');
};

subtest 'Auswahlwerte werden einheitlich normalisiert' => sub {
	my $select = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('select', options => ['eco', 'eco', 'A B', 'A,B']),
		io_name => 'mqtt', cid => 'c',
	);
	my @set_tokens = split /,/, $select->{set_lines}[0]{spec};
	is(scalar @set_tokens, 3, 'doppelte Select-Option wird nur einmal angeboten');
	is([@set_tokens[0, 1]], ['eco', 'A_B'], 'gueltige und normalisierte Tokens bleiben stabil');
	like($set_tokens[2], qr/^A_B_[0-9a-f]{4,}$/, 'kollidierende Select-Option erhaelt einen Suffix');
	is($select->{semantic_entity}{capabilities}{value}{options}, \@set_tokens,
		'Sets und semantische Metadaten verwenden dieselben Tokens');
	is($select->{semantic_entity}{capabilities}{value}{valueMap}{read}{'A,B'}, $set_tokens[2],
		'semantische Rueckabbildung zeigt auf den kollisionsfreien Token');
};

subtest 'Jinja-dict.get wird als einfaches JSON-Reading gruppiert' => sub {
	my $battery = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'sensor_battery', state_topic => 'findmy/person/device/state',
			value_template => "{{ value_json.get('battery') }}"),
		io_name => 'mqtt', cid => 'fm_person_device');
	ok($battery->{ok}, 'FindMy-Sensor wird sicher gemappt');
	is($battery->{reading_lines}[0]{kind}, 'json_reading',
		'dict.get wird nicht als komplexes Runtime-Template behandelt');
	is($battery->{reading_lines}[0]{json_key}, 'battery', 'JSON-Schluessel bleibt erhalten');
	like($battery->{reading_lines}[0]{line}, qr/json2nameValue/, 'lesbare FHEM-JSON-Auswertung wird erzeugt');
	unlike($battery->{reading_lines}[0]{line}, qr/runtimeReading/, 'kein Runtime-Fallback erforderlich');
};

subtest 'kuerzeste eindeutige logische Entity-Namen' => sub {
	my $battery = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', format => 'device', component_key => 'sensor_battery',
			object_id => 'sensor_battery', entity_key => 'device|sensor_battery',
			state_topic => 'node/state', value_template => '{{ value_json.battery }}',
			device_class => 'battery'),
		io_name => 'mqtt', cid => 'client');
	is($battery->{reading_name}, 'battery',
		'Plattformprefix einer eindeutigen Device-Discovery-Komponente entfaellt');
	is(MQTT2_Discovery::Mapper::resolve_mapping_names([$battery])->[0]{reading_name}, 'battery',
		'eindeutiger kurzer Name bleibt unveraendert');

	my $device_battery = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', format => 'device', component_key => 'device_battery',
			object_id => 'device_battery', entity_key => 'device|device_battery',
			state_topic => 'node/state', value_template => '{{ value_json.battery }}',
			device_class => 'battery'),
		io_name => 'mqtt', cid => 'client');
	my $resolved = MQTT2_Discovery::Mapper::resolve_mapping_names([$battery, $device_battery]);
	my %by_key = map { $_->{entity_key} => $_ } @$resolved;
	is($by_key{'device|sensor_battery'}{reading_name}, 'sensor_battery',
		'erste Kollision wird mit dem naechsten logischen Pfadelement qualifiziert');
	is($by_key{'device|device_battery'}{reading_name}, 'device_battery',
		'zweite Kollision wird ebenfalls symmetrisch qualifiziert');
	is($by_key{'device|sensor_battery'}{reading_lines}[0]{name}, 'sensor_battery',
		'Reading-Eintrag verwendet den aufgeloesten Namen');
	is($by_key{'device|sensor_battery'}{semantic_entity}{capabilities}{value}{read}, 'sensor_battery',
		'SemanticUI-Verweis verwendet denselben aufgeloesten Namen');
};

subtest 'Retained Command-Publishes' => sub {
	my $text = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('text', retain => 'true'), io_name => 'mqtt', cid => 'c');
	is($text->{set_lines}[0]{line}, 'text node/text/set:r',
		'HA-retain markiert ein direktes Command-Topic fuer MQTT2_DEVICE');

	my $templated = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('text', retain => JSON::PP::true(),
			command_template => '{{ value | upper }}'), io_name => 'mqtt', cid => 'c');
	like($templated->{set_lines}[0]{line},
		qr/runtimeTemplatePublish\("node\/text\/set:r", "\{\{ value \| upper \}\}", \$EVENT\)/,
		'Runtime-Publish zeigt Retain-Topic und Command-Template im Klartext');
	unlike($templated->{set_lines}[0]{line}, qr/bm9|e3sg/,
		'Runtime-Publish verwendet kein Base64');

	my $not_retained = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('text', retain => 'false'), io_name => 'mqtt', cid => 'c');
	is($not_retained->{set_lines}[0]{line}, 'text node/text/set',
		'retain=false veraendert das Command-Topic nicht');
};

subtest 'lesbare Runtime-Command-Fallbacks' => sub {
	my $choice = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('switch', command_topic => 'node/{switch}', payload_on => 'YES', payload_off => 'NO'),
		io_name => 'mqtt', cid => 'c');
	like($choice->{set_lines}[0]{line},
		qr/runtimeChoice\("node\/\{switch\}", \{"off" => "NO", "on" => "YES"\}, \$EVENT\)/,
		'Choice-Fallback zeigt Topic und Payload-Mapping im Klartext');

	my $button = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('button', command_topic => 'node/{button}', raw_metadata => { payload_press => 'PRESS' }),
		io_name => 'mqtt', cid => 'c');
	like($button->{set_lines}[0]{line}, qr/runtimePublish\("node\/\{button\}", "PRESS"\)/,
		'Button-Fallback zeigt Topic und Payload im Klartext');

	my $json = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('light', command_topic => 'node/{light}', schema => 'json',
			raw_metadata => { brightness => 1 }), io_name => 'mqtt', cid => 'c');
	like(join("\n", map { $_->{line} } @{ $json->{set_lines} }),
		qr/runtimeJSONPublish\("node\/\{light\}", "brightness", \$EVENT\)/,
		'JSON-Fallback zeigt Topic und JSON-Schluessel im Klartext');
};

subtest 'Validierung und Determinismus' => sub {
	my $bad_number = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('number', min => 10, max => 1, step => 0), io_name => 'mqtt', cid => 'c');
	like(join(' ', @{ $bad_number->{warnings} }), qr/min\/max\/step/, 'ungueltiger Slider wird gemeldet');
	is($bad_number->{set_lines}, [], 'ungueltiger Slider erzeugt keinen Setter');
	my $default_step = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('number', min => 5, max => 1800, step => undef), io_name => 'mqtt', cid => 'c');
	is($default_step->{set_lines}[0]{line}, 'number:slider,5,1,1800 node/number/set',
		'fehlendes Number-step verwendet den HA-Default 1');
	is($default_step->{semantic_entity}{capabilities}{value}{step}, 1,
		'Number-Default steht auch in den Semantic-Metadaten');
	my $first = MQTT2_Discovery::Mapper::map_entity(entity => entity('switch'), io_name => 'mqtt', cid => 'c');
	my $second = MQTT2_Discovery::Mapper::map_entity(entity => entity('switch'), io_name => 'mqtt', cid => 'c');
	is($first, $second, 'gleiches Modell erzeugt deterministisch dasselbe Mapping');

	my $escaped = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', state_topic => 'node-v1/sensor+temp:state'), io_name => 'mqtt', cid => 'client.1');
	is($escaped->{reading_lines}[0]{line}, 'node-v1/sensor\\+temp:state:.* sensor',
		'readingList ist CID-unabhaengig und maskiert echte Regex-Sonderzeichen im Topic');
};

subtest 'Device-Automation und Texteingabe-Metadaten' => sub {
	my $trigger = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('device_automation', object_id => 'button_1_double',
			state_topic => 'node/button_1_double', payload => 'PRESS',
			type => 'button_double_press', subtype => 'button_1'),
		io_name => 'mqtt', cid => 'c');
	is($trigger->{reading_lines}[0]{line}, 'node/button_1_double:PRESS$ button_1_double',
		'Trigger-Reading filtert Topic und Payload exakt');
	is($trigger->{semantic_entity}, undef,
		'eingehender Trigger bleibt als Reading erhalten, wird aber nicht in SemanticUI angezeigt');
	my $unsafe_trigger = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('device_automation', state_topic => 'node/button', payload => "PRESS\nset injected"),
		io_name => 'mqtt', cid => 'c');
	ok(!$unsafe_trigger->{ok}, 'Trigger-Payload kann keine readingList-Zeile einschleusen');

	my $text = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('text', max => 56), io_name => 'mqtt', cid => 'c');
	is($text->{semantic_entity}{capabilities}{value}{input}, 'text',
		'Text-Entity fordert ein Texteingabefeld an');
	is($text->{semantic_entity}{capabilities}{value}{maxLength}, 56,
		'maximale Textlaenge wird an SemanticUI uebergeben');
};

subtest 'Climate bildet alle State- und Command-Kanaele ab' => sub {
	my $climate = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('climate', object_id => 'pac-1d797c', state_topic => undef, command_topic => undef,
			device => { identifiers => ['dc1ed51d797c'], name => 'pac-1d797c' },
			current_temperature_topic => 'pac-1d797c/state/current_temperature',
			temperature_state_topic => 'pac-1d797c/state/target_temperature',
			temperature_command_topic => 'pac-1d797c/command/target_temperature',
			mode_state_topic => 'pac-1d797c/state/mode', mode_command_topic => 'pac-1d797c/command/mode',
			fan_mode_state_topic => 'pac-1d797c/state/fan_mode', fan_mode_command_topic => 'pac-1d797c/command/fan_mode',
			swing_mode_state_topic => 'pac-1d797c/state/swing_mode', swing_mode_command_topic => 'pac-1d797c/command/swing_mode',
			preset_mode_state_topic => 'pac-1d797c/state/preset', preset_mode_command_topic => 'pac-1d797c/command/preset',
			min_temp => 16, max_temp => 30, temp_step => 0.5,
			modes => [qw(off auto cool heat fan_only dry)], fan_modes => ['Automatic', qw(1 2 3 4 5)],
			swing_modes => [qw(off both vertical horizontal)], preset_modes => [qw(Normal Powerful Quiet)]),
		io_name => 'mqtt', cid => 'c');
	ok($climate->{ok}, 'Climate wird gemappt');
	my $readings = join("\n", map { $_->{line} } @{ $climate->{reading_lines} });
	my $sets = join("\n", map { $_->{line} } @{ $climate->{set_lines} });
	is([sort map { $_->{name} } @{ $climate->{reading_lines} }],
		[qw(current_temperature fan_mode mode preset swing_mode target_temperature)],
		'Climate-State-Readings verwenden die Namen hinter state');
	like($readings, qr{pac-1d797c/state/current_temperature:\.\* current_temperature},
		'Isttemperatur wird als Reading angelegt');
	like($readings, qr{pac-1d797c/state/target_temperature:\.\* target_temperature},
		'Solltemperatur wird als Reading angelegt');
	like($sets, qr{target_temperature:slider,16,0\.5,30 pac-1d797c/command/target_temperature},
		'Solltemperatur wird mit kurzem Capability-Namen als Slider angelegt');
	like($sets, qr{mode:off,auto,cool,heat,fan_only,dry pac-1d797c/command/mode},
		'Betriebsmodi werden mit kurzem Capability-Namen angelegt');
	like($sets, qr{fan_mode:Automatic,1,2,3,4,5 pac-1d797c/command/fan_mode},
		'numerische Fan-Modi bleiben unter fan_mode direkt bedienbar');
	like($sets, qr{swing_mode:off,both,vertical,horizontal pac-1d797c/command/swing_mode},
		'Swing-Modi werden mit kurzem Capability-Namen angelegt');
	like($sets, qr{preset_mode:Normal,Powerful,Quiet pac-1d797c/command/preset},
		'Preset-Modi werden mit kurzem Capability-Namen angelegt');
	is(scalar @{ $climate->{set_lines} }, 5, 'genau die fuenf angebotenen Climate-Commands werden angelegt');
	is($climate->{semantic_entity}{capabilities}{targetTemperature}{write}, 'target_temperature',
		'optionale Semantik verweist auf den realen FHEM-Setter');
	is($climate->{semantic_entity}{capabilities}{power}{read}, 'mode',
		'Power-Zustand wird aus dem Climate-Modus gelesen');
	ok(!exists($climate->{semantic_entity}{capabilities}{power}{write}),
		'ohne expliziten Power-Command bleibt die abgeleitete Capability nur lesbar');
	is($climate->{semantic_entity}{capabilities}{power}{valueMap}{read}, {
			off => 'OFF', auto => 'ON', cool => 'ON', heat => 'ON', fan_only => 'ON', dry => 'ON',
		}, 'alle aktiven Climate-Modi werden fuer Power auf ON abgebildet');
};

subtest 'State-Pfad und Availability-Topic bestimmen kurze Reading-Namen' => sub {
	my $sensor = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'pac_ip_address',
			state_topic => 'pac-1d797c/state/ip', availability_topic => 'pac-1d797c/status'),
		io_name => 'mqtt', cid => 'c');
	my $readings = join("\n", map { $_->{line} } @{ $sensor->{reading_lines} });
	like($readings, qr{pac-1d797c/state/ip:\.\* ip},
		'Name hinter state wird als Reading verwendet');
	like($readings, qr{pac-1d797c/status:\.\* status},
		'Availability verwendet den wirklichen Topic-Namen');

	my $classic = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', object_id => 'temperature', state_topic => 'node/temperature/state'),
		io_name => 'mqtt', cid => 'c');
	is($classic->{reading_lines}[0]{name}, 'temperature',
		'generisches abschliessendes state bleibt kollisionsfrei bei der Entity-ID');
};

subtest 'Climate bildet optionale Standardkanaele und Templates ab' => sub {
	my $climate = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('climate', object_id => 'hvac', state_topic => undef, command_topic => undef,
			value_template => '{{ value }}',
			current_humidity_topic => 'hvac/humidity/current',
			target_humidity_state_topic => 'hvac/humidity/target',
			target_humidity_command_topic => 'hvac/humidity/target/set', min_humidity => 35, max_humidity => 80,
			swing_horizontal_mode_state_topic => 'hvac/swing_horizontal',
			swing_horizontal_mode_command_topic => 'hvac/swing_horizontal/set',
			swing_horizontal_modes => [qw(on off)],
			mode_command_topic => 'hvac/mode/set', modes => [qw(off heat)],
			mode_command_template => '{{ value | upper }}',
			power_command_topic => 'hvac/power/set', payload_on => 'START', payload_off => 'STOP'),
		io_name => 'mqtt', cid => 'c');
	ok($climate->{ok}, 'optionale Climate-Kanaele werden gemappt');
	my $readings = join("\n", map { $_->{line} } @{ $climate->{reading_lines} });
	my $sets = join("\n", map { $_->{line} } @{ $climate->{set_lines} });
	like($readings, qr/hvac\/humidity\/current:\.\*.*hvac_current_humidity/,
		'aktuelle Luftfeuchte wird angelegt und verwendet das allgemeine State-Template');
	like($sets, qr/hvac_target_humidity:slider,35,1,80 hvac\/humidity\/target\/set/,
		'Ziel-Luftfeuchte wird als Slider angelegt');
	like($sets, qr/hvac_swing_horizontal_mode:on,off hvac\/swing_horizontal\/set/,
		'horizontaler Swing wird angelegt');
	like($sets, qr/hvac_power:on,off \{my %map=.*hvac\/power\/set/s,
		'separates Power-Command mit eigenen Payloads wird angelegt');
	like($sets, qr/hvac_mode:off,heat \{ MQTT2_DISCOVERY_runtimeTemplateChoice\("hvac\/mode\/set", "\{\{ value \| upper \}\}"/,
		'Choice-Command-Template bleibt im Setter wirksam');
};

my $unknown = MQTT2_Discovery::Mapper::map_entity(entity => entity('vacuum'), io_name => 'mqtt', cid => 'c');
ok(!$unknown->{ok} && $unknown->{unsupported}, 'unbekannte Komponente erzeugt kein Device-Mapping');

my $template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', value_template => '{{ value_json.temperature }}'), io_name => 'mqtt', cid => 'client');
like($template->{reading_lines}[0]{line}, qr/json2nameValue/, 'einfacher JSON-Pfad verwendet FHEMs Standardauswertung');
like($template->{reading_lines}[0]{line}, qr/'temperature'\s*=>\s*'sensor'/,
	'JSON-Schluessel und Zielreading bleiben im Mapping lesbar');
unlike($template->{reading_lines}[0]{line}, qr/runtimeReading|e3sg/,
	'einfacher JSON-Pfad benoetigt weder Runtime-Wrapper noch Base64');

my $complex_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', value_template => '{{ value_json.temperature | round(1) }}'), io_name => 'mqtt', cid => 'client');
like($complex_template->{reading_lines}[0]{line},
	qr/MQTT2_DISCOVERY_runtimeReading\("\{\{ value_json\.temperature \| round\(1\) \}\}"/,
	'komplexes Template verwendet einen lesbaren Runtime-Fallback');
unlike($complex_template->{reading_lines}[0]{line}, qr/e3sg/,
	'auch der Runtime-Fallback verbirgt das Template nicht in Base64');

my $defined_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', state_topic => 'home/+/BTtoMQTT/device',
		value_template => '{{ value_json.temperature | is_defined }}'), io_name => 'mqtt', cid => 'client');
like($defined_template->{reading_lines}[0]{line}, qr{home/\[\^/\]\*/BTtoMQTT/device:\.\*},
	'eine einzelne MQTT-Wildcard wird als genau ein Topicsegment gerendert');
like($defined_template->{reading_lines}[0]{line}, qr/json2nameValue/,
	'is_defined behaelt die kompakte JSON-Auswertung fuer direkte Pfade');
is($defined_template->{warnings}, [], 'is_defined erzeugt keine Mappingwarnung');
my ($single_filter) = split /\s+/, $defined_template->{reading_lines}[0]{line}, 2;
like('home/gateway/BTtoMQTT/device:{"temperature":21}', qr/^$single_filter$/,
	'eine konkrete Nachricht trifft den gerenderten Einsegmentfilter');
unlike('home/gateway/extra/BTtoMQTT/device:{"temperature":21}', qr/^$single_filter$/,
	'die Einsegment-Wildcard akzeptiert keine zusaetzliche Topicebene');

my $multi_wildcard = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', state_topic => 'home/gateway/433toMQTT/#'), io_name => 'mqtt', cid => 'client');
is($multi_wildcard->{reading_lines}[0]{line},
	'home/gateway/433toMQTT(?:/.*)?:.* sensor',
	'eine abschliessende MQTT-Mehrsegment-Wildcard umfasst Topic und Untertopics');
my ($multi_filter) = split /\s+/, $multi_wildcard->{reading_lines}[0]{line}, 2;
like('home/gateway/433toMQTT/15524904:{"value":15524904}', qr/^$multi_filter$/,
	'eine konkrete Nachricht trifft den gerenderten Mehrsegmentfilter');
like('home/gateway/433toMQTT:{}', qr/^$multi_filter$/,
	'der Mehrsegmentfilter umfasst gemaess MQTT auch sein Elterntopic');

my $literal_wildcard = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', state_topic => 'home/sensor+backup/state'), io_name => 'mqtt', cid => 'client');
like($literal_wildcard->{reading_lines}[0]{line}, qr{sensor\\\+backup},
	'Wildcardzeichen innerhalb eines Segments bleiben sichere Literale');

my $trigger_context = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('device_automation', state_topic => 'home/gateway/433toMQTT/42', payload => undef,
		value_template => '{{ trigger.value.raw }}'), io_name => 'mqtt', cid => 'client');
like($trigger_context->{reading_lines}[0]{line}, qr/MQTT2_DISCOVERY_runtimeTriggerReading/,
	'Device-Automation verwendet den eigenen sicheren Triggerkontext');

my $multiline_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', value_template => "{{ value_json.temperature\n  | round(1) }}"), io_name => 'mqtt', cid => 'client');
like($multiline_template->{reading_lines}[0]{line}, qr/\\x\{0a\}/,
	'mehrzeiliges Template wird lesbar escapet statt Base64-kodiert');
unlike($multiline_template->{reading_lines}[0]{line}, qr/e3sg/,
	'mehrzeiliges Template verwendet ebenfalls kein Base64');

my $second_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', object_id => 'humidity', value_template => '{{ value_json.humidity }}'),
	io_name => 'mqtt', cid => 'client');
my $grouped = MQTT2_Discovery::Mapper::render_entries(
	[$template->{reading_lines}[0], $second_template->{reading_lines}[0]], undef);
is(scalar(@$grouped), 1, 'mehrere einfache JSON-Pfade desselben Topics werden zusammengefasst');
like($grouped->[0]{line}, qr/\{'temperature'\s*=>\s*'sensor'\}/,
	'gruppierte JSON-Auswertung enthaelt nur die abweichende Zuordnung');
unlike($grouped->[0]{line}, qr/'humidity'\s*=>/,
	'identische JSON- und Reading-Namen werden nicht wiederholt');
unlike($grouped->[0]{line}, qr/\^\(\?:/,
	'gruppierte JSON-Auswertung filtert zusaetzliche Payload-Felder nicht aus');
like($second_template->{reading_lines}[0]{line}, qr/\{ json2nameValue\(\$EVENT\) \}$/,
	'reine Eins-zu-eins-Namen verwenden die kuerzeste JSON-Auswertung');
my $array_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', object_id => 'energy_power_0',
		value_template => '{{ value_json.ENERGY.Power[0] }}'), io_name => 'mqtt', cid => 'client');
like($array_template->{reading_lines}[0]{line}, qr/'ENERGY_Power_1'\s*=>\s*'energy_power_0'/,
	'nullbasierter Template-Index wird auf FHEMs einbasierten JSON-Namen abgebildet');
my $autocreate_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', object_id => 'energy_power_0', state_topic => 'node/data',
		value_template => '{{ value_json.ENERGY.Power[0] }}', device_class => 'power',
		raw_metadata => { json_autocreate => 1 }), io_name => 'mqtt', cid => 'client');
is($autocreate_template->{reading_lines}[0]{line},
	q{node/data:.* { json2nameValue($EVENT,'',$JSONMAP) }},
	'Autocreate-Modus verwendet FHEMs kurze JSONMAP-Auswertung');
is($autocreate_template->{reading_lines}[0]{name}, 'ENERGY_Power_1',
	'Autocreate-Modus behaelt den von FHEM abgeflachten Reading-Namen');
is($autocreate_template->{semantic_entity}{id}, 'energy_power_0',
	'Discovery-ID bleibt unabhaengig vom rohen FHEM-Reading stabil');
is($autocreate_template->{semantic_entity}{capabilities}{value}{read}, 'ENERGY_Power_1',
	'SemanticUI liest das tatsaechlich von Autocreate erzeugte Reading');
my $autocreate_switch = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('switch', object_id => 'power', state_topic => 'node/result',
		value_template => '{{ value_json.POWER }}', payload_on => 'ON', payload_off => 'OFF',
		raw_metadata => { json_autocreate => 1 }), io_name => 'mqtt', cid => 'client');
is($autocreate_switch->{reading_lines}[0]{line},
	q{node/result:.* { json2nameValue($EVENT,'',$JSONMAP) }},
	'Autocreate gilt auch fuer native JSON-Aktorzustaende');
is($autocreate_switch->{semantic_entity}{capabilities}{power}{read}, 'POWER',
	'SemanticUI liest beim Aktor das rohe JSON-Reading');
is($autocreate_switch->{set_lines}[0]{line}, 'POWER:ON,OFF node/switch/set',
	'Set-Name entspricht auch allgemein exakt dem Rohreading');
is($autocreate_switch->{semantic_entity}{capabilities}{power}{write}, 'POWER',
	'SemanticUI schreibt denselben Namen, den sie liest');
my $numbered_autocreate_switch = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('switch', object_id => 'power', state_topic => 'node/result',
		value_template => '{{ value_json.POWER1 }}', payload_on => 'ON', payload_off => 'OFF',
		raw_metadata => { json_autocreate => 1 }), io_name => 'mqtt', cid => 'client');
is($numbered_autocreate_switch->{semantic_entity}{capabilities}{power}{read}, 'POWER1',
	'SemanticUI uebernimmt den finalen Readingnamen statt ihn aus der Entity-ID abzuleiten');
is($numbered_autocreate_switch->{set_lines}[0]{line}, 'POWER1:ON,OFF node/switch/set',
	'abgeleiteter Set-Name entspricht exakt dem Rohreading');
is($numbered_autocreate_switch->{semantic_entity}{capabilities}{power}{write}, 'POWER1',
	'SemanticUI schreibt denselben Namen, den sie als Reading liest');
my $unsafe_template = MQTT2_Discovery::Mapper::map_entity(
	entity => entity('sensor', value_template => '{{ states("sensor.secret") }}'), io_name => 'mqtt', cid => 'client');
ok(!$unsafe_template->{ok}, 'Entity mit ausschliesslich unsicherem Template erzeugt kein leeres Mapping');

subtest 'Semantic-Metadaten' => sub {
	my $switch = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('switch', payload_on => '1', payload_off => '0'), io_name => 'mqtt', cid => 'c');
	is($switch->{semantic_entity}{class}, 'switch', 'HA-Komponente wird Semantic-Klasse');
	is($switch->{semantic_entity}{capabilities}{power}{read}, 'switch', 'Power liest das generierte Reading');
	is($switch->{semantic_entity}{capabilities}{power}{write}, 'switch', 'Power schreibt den generierten Set-Namen');
	is($switch->{semantic_entity}{capabilities}{power}{options}, ['1', '0'],
		'SemanticUI erhaelt die nativen FHEM-Set-Zustaende');
	is([$switch->{semantic_entity}{capabilities}{power}{activeValue},
			$switch->{semantic_entity}{capabilities}{power}{inactiveValue}], ['1', '0'],
		'aktive und inaktive native Werte bleiben als Darstellungsmetadaten erhalten');
	ok(!exists($switch->{semantic_entity}{capabilities}{power}{valueMap}),
		'Power-Payloads werden nicht semantisch umbenannt');

	my $sensor = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', name => 'Temperatur', device_class => 'temperature',
			state_class => 'measurement', unit_of_measurement => "\x{b0}C"), io_name => 'mqtt', cid => 'c');
	is($sensor->{semantic_entity}{name}, 'Temperatur', 'Entity-Anzeigename bleibt erhalten');
	is($sensor->{semantic_entity}{device_class}, 'temperature', 'device_class wird uebernommen');
	is($sensor->{semantic_entity}{state_class}, 'measurement', 'state_class wird uebernommen');
	is($sensor->{semantic_entity}{capabilities}{value}{unit}, "\x{b0}C", 'Einheit wird uebernommen');

	my $unclassified = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', name => 'IP address'), io_name => 'mqtt', cid => 'c');
	is($unclassified->{semantic_entity}, undef,
		'unklassifiziertes Read-only-Reading bleibt ausserhalb der automatischen SemanticUI');

	my $diagnostic = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', name => 'Internal temperature', device_class => 'temperature',
			entity_category => 'diagnostic'), io_name => 'mqtt', cid => 'c');
	is($diagnostic->{semantic_entity}, undef,
		'explizite Diagnostic-Entity bleibt trotz typischer device_class ausserhalb der SemanticUI');

	my $carbon_dioxide = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', device_class => 'carbon_dioxide'), io_name => 'mqtt', cid => 'c');
	ok($carbon_dioxide->{semantic_entity},
		'kanonische Home-Assistant-device_class carbon_dioxide wird zugelassen');
	my $noncanonical_co2 = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', device_class => 'co2'), io_name => 'mqtt', cid => 'c');
	is($noncanonical_co2->{semantic_entity}, undef,
		'nicht kanonisches co2 wird nicht als device_class erraten');
	my $wrong_case = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('sensor', device_class => 'Temperature'), io_name => 'mqtt', cid => 'c');
	is($wrong_case->{semantic_entity}, undef,
		'device_class muss die Positivliste auch in der Schreibweise exakt treffen');

	my $pac_switch = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('switch', object_id => 'pac_mild_dry_switch', name => 'pac mild dry switch',
			state_topic => 'pac-1d797c/state/mild_dry',
			device => { identifiers => ['dc1ed51d797c'], name => 'pac-1d797c' }),
		io_name => 'mqtt', cid => 'c');
	is($pac_switch->{semantic_entity}{name}, 'mild dry switch',
		'redundanter Geraetepraefix wird aus dem Semantic-Anzeigenamen entfernt');

	my $pac_climate = MQTT2_Discovery::Mapper::map_entity(
		entity => entity('climate', object_id => 'pac-1d797c', name => 'pac', state_topic => undef,
			current_temperature_topic => 'pac-1d797c/state/current_temperature',
			device => { identifiers => ['dc1ed51d797c'], name => 'pac-1d797c' }),
		io_name => 'mqtt', cid => 'c');
	is($pac_climate->{semantic_entity}{name}, 'climate',
		'reiner Geraetepraefix faellt auf die Semantic-Klasse zurueck');
};

subtest 'Geraeteweite Semantic-Komposition' => sub {
	my $climate = {
		entity_key => 'climate', strong_identity => 1, metadata => { component => 'climate' },
		semantic_entity => { id => 'climate', class => 'climate', capabilities => {
			mode => { read => 'mode', write => 'mode', options => [qw(off cool)] },
		} },
	};
	my $switch = {
		entity_key => 'mild-dry', strong_identity => 1, metadata => { component => 'switch' },
		semantic_entity => { id => 'mild_dry', class => 'switch', capabilities => {
			power => { read => 'mild_dry', write => 'mild_dry', options => [qw(ON OFF)] },
		} },
	};
	my $select = {
		entity_key => 'vertical-swing', strong_identity => 1, metadata => { component => 'select' },
		semantic_entity => { id => 'vertical_swing_mode', class => 'select', capabilities => {
			value => { read => 'vertical_swing_mode', write => 'vertical_swing_mode', options => [qw(auto up down)] },
		} },
	};
	my @items = map {{
		entity_key => $_->{entity_key}, mapping => $_,
		entry => JSON::PP->new->decode(JSON::PP->new->encode($_->{semantic_entity})),
	}} ($climate, $switch, $select);
	my $composed = MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@items);
	is(scalar @$composed, 1, 'eine eindeutige Climate-Hauptentity nimmt atomare Geschwister auf');
	my $capabilities = $composed->[0]{entry}{capabilities};
	is($capabilities->{mildDry}, {
			read => 'mild_dry', write => 'mild_dry', options => [qw(ON OFF)], kind => 'boolean',
		}, 'Switch wird ohne Namensheuristik zur typisierten booleschen Capability');
	is($capabilities->{verticalSwingMode}, {
			read => 'vertical_swing_mode', write => 'vertical_swing_mode',
			options => [qw(auto up down)], kind => 'enum',
		}, 'Select wird zur typisierten Enum-Capability');

	my @without_primary = @items[1, 2];
	is(scalar @{ MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@without_primary) }, 2,
		'mehrere atomare Switch-/Select-Entities ohne Hauptentity bleiben getrennt');

	my $weak_switch = {
		entity_key => 'weak-switch', mapping => {
			strong_identity => 0, metadata => { component => 'switch' },
		},
		entry => { id => 'weak_switch', class => 'switch', capabilities => {
			power => { read => 'weak_switch', write => 'weak_switch', options => [qw(ON OFF)] },
		} },
	};
	my @weak_identity = ($items[0], $weak_switch);
	is(scalar @{ MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@weak_identity) }, 2,
		'schwach zugeordnete Geschwister werden nicht komponiert');

	my $diagnostic_switch = {
		entity_key => 'diagnostic-switch', mapping => {
			strong_identity => 1,
			metadata => { component => 'switch', entity_category => 'diagnostic' },
		},
		entry => { id => 'diagnostic_switch', class => 'switch', capabilities => {
			power => { read => 'diagnostic_switch', write => 'diagnostic_switch', options => [qw(ON OFF)] },
		} },
	};
	my @diagnostic = ($items[0], $diagnostic_switch);
	is(scalar @{ MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@diagnostic) }, 2,
		'Diagnose- und Konfigurations-Entities bleiben eigenstaendig');

	my $second_climate = {
		entity_key => 'climate-zone-2', mapping => $climate,
		entry => { id => 'climate_zone_2', class => 'climate', capabilities => { mode => { read => 'mode_2' } } },
	};
	my @ambiguous = ($items[0], $second_climate, $items[1]);
	is(scalar @{ MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@ambiguous) }, 3,
		'bei mehreren Climate-Entities wird keine mehrdeutige Zuordnung vorgenommen');
};

done_testing;

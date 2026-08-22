# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::Parser::HomeAssistant ();

# Parst einen HA-Testpayload unter einem reproduzierbaren Config-Topic.
sub parse_config {
	my ($topic, $payload, $prefixes) = @_;
	return MQTT2_Discovery::Parser::HomeAssistant::parse(
		topic => $topic, payload => $payload,
		prefixes => $prefixes || ['homeassistant'],
	);
}

subtest 'klassische Discovery und Abkuerzungen' => sub {
	my $short = parse_config(
		'homeassistant/switch/node42/power/config',
		'{"~":"node42/power","name":"Power","uniq_id":"node42_power","stat_t":"~/state","cmd_t":"~/set","pl_on":"1","pl_off":"0","ret":"true","dev":{"ids":"node42","name":"Node 42","mf":"Acme"}}',
	);
	is($short->{status}, 'ok', 'Payload akzeptiert');
	my $entity = $short->{entities}[0];
	is($entity->{component}, 'switch', 'Komponente');
	is($entity->{node_id}, 'node42', 'Node-ID');
	is($entity->{object_id}, 'power', 'Object-ID');
	is($entity->{state_topic}, 'node42/power/state', 'Basistopic expandiert');
	is($entity->{command_topic}, 'node42/power/set', 'Commandtopic expandiert');
	is($entity->{retain}, 'true', 'Retain-Kurzform wird normalisiert');
	is($entity->{device}{identifiers}, ['node42'], 'skalare Device-ID normalisiert');
	is($entity->{device}{manufacturer}, 'Acme', 'Device-Abkuerzung normalisiert');

	my $sensor = parse_config(
		'homeassistant/sensor/node42/temperature/config',
		'{"stat_t":"node42/temperature","dev_cla":"temperature","stat_cla":"measurement","ent_cat":"diagnostic"}',
	);
	is($sensor->{entities}[0]{device_class}, 'temperature', 'device_class wird normalisiert');
	is($sensor->{entities}[0]{state_class}, 'measurement', 'state_class wird normalisiert');
	is($sensor->{entities}[0]{entity_category}, 'diagnostic', 'entity_category wird normalisiert');

	my $long = parse_config(
		'homeassistant/switch/node42/power/config',
		'{"name":"Power","unique_id":"node42_power","state_topic":"node42/power/state","command_topic":"node42/power/set","payload_on":"1","payload_off":"0","device":{"identifiers":["node42"],"name":"Node 42","manufacturer":"Acme"}}',
	);
	is($long->{entities}[0]{unique_id}, $entity->{unique_id}, 'Kurz- und Langform ergeben dieselbe Unique-ID');
	is($long->{entities}[0]{state_topic}, $entity->{state_topic}, 'Kurz- und Langform ergeben dasselbe State-Topic');

	my $json_light = parse_config(
		'homeassistant/light/node42/light/config',
		'{"schema":"json","stat_t":"node42/light","cmd_t":"node42/light/set","stat_val_tpl":"{{ value_json.state }}","brightness":true}',
	);
	is($json_light->{entities}[0]{value_template}, '{{ value_json.state }}',
		'stat_val_tpl wird als HA-state_value_template uebernommen');
	is($json_light->{entities}[0]{command_codec},
		{ format => 'json', key => 'state', value_type => 'string' },
		'HA-JSON-State wird im HA-Parser als allgemeiner JSON-Command normalisiert');
	is([$json_light->{entities}[0]{preferred_reading_name}, $json_light->{entities}[0]{command_set_name}],
		['state', 'state'], 'HA-Parser normalisiert den gemeinsamen State-Namen');
	is([$json_light->{entities}[0]{brightness_state_topic},
			$json_light->{entities}[0]{brightness_command_topic},
			$json_light->{entities}[0]{brightness_value_template}],
		['node42/light', 'node42/light/set', '{{ value_json.brightness }}'],
		'HA-Parser zerlegt das gemeinsame JSON-Light-Payload in normale Brightness-Bindings');
	is($json_light->{entities}[0]{brightness_command_codec},
		{ format => 'json', key => 'brightness', value_type => 'number' },
		'HA-Parser beschreibt Brightness als numerischen JSON-Command');

	my $modern_json_light = parse_config(
		'homeassistant/light/node42/modern/config',
		'{"schema":"json","stat_t":"node42/modern","cmd_t":"node42/modern/set","supported_color_modes":["brightness"]}',
	);
	is($modern_json_light->{entities}[0]{brightness_command_topic}, 'node42/modern/set',
		'modernes supported_color_modes aktiviert Helligkeit ebenfalls im HA-Parser');

	my $select = parse_config(
		'homeassistant/select/node42/mode/config',
		'{"ops":["auto","manual"],"opt":true,"stat_t":"node42/mode","cmd_t":"node42/mode/set"}',
	);
	is($select->{entities}[0]{options}, ['auto', 'manual'],
		'ESPHome-Select-Kurzform ops wird als options normalisiert');
	ok($select->{entities}[0]{optimistic},
		'Home-Assistant-Kurzform opt bleibt eindeutig optimistic');
};

subtest 'Topicvarianten und Prefixe' => sub {
	my $without_node = parse_config('ha/sensor/temperature/config', '{"stat_t":"room/temp"}', ['homeassistant', 'ha']);
	is($without_node->{status}, 'ok', 'zweiter Prefix passt');
	is($without_node->{entities}[0]{node_id}, undef, 'Node-ID ist optional');
	is(parse_config('homeassistant2/sensor/x/config', '{}')->{status}, 'next', 'aehnlicher Prefix passt nicht');
	is(parse_config('homeassistant/sensor/x/state', '{}')->{status}, 'error', 'ungueltiges Discovery-Topic wird innerhalb des Prefix gemeldet');
	is(parse_config('homeassistant/sensor/bad.name/config', '{}')->{error_class}, 'topic',
		'HA-fremde Zeichen in object_id werden abgelehnt');
};

subtest 'Delete und JSON-Fehler' => sub {
	my $delete = parse_config('homeassistant/sensor/node/temp/config', '');
	is($delete->{entities}[0]{operation}, 'delete', 'leerer Payload ist Delete');
	is(parse_config('homeassistant/sensor/node/temp/config', '{')->{error_class}, 'json', 'JSON-Fehler klassifiziert');
	is(parse_config('homeassistant/sensor/node/temp/config', '[]')->{error_class}, 'schema', 'Array ist kein Discovery-Objekt');
	is(parse_config('homeassistant/sensor/node/temp/config', '{"dev":[]}')->{error_class}, 'schema',
		'ungueltige Device-Struktur wird vor dem Mapper abgelehnt');
};

subtest 'Device-Discovery' => sub {
	my $result = parse_config(
		'homeassistant/device/node42/config',
		'{"~":"node42","dev":{"ids":["node42"],"name":"Node 42"},"o":{"name":"fixture"},"cmps":{"temperature":{"p":"sensor","stat_t":"~/state","val_tpl":"{{ value_json.temperature }}","unit_of_meas":"C"},"power":{"p":"switch","stat_t":"~/power","cmd_t":"~/power/set"},"bad":{"p":"vacuum"}}}',
	);
	is($result->{status}, 'ok', 'Device-Payload akzeptiert');
	is([ map { $_->{component} } @{ $result->{entities} } ], [qw(switch sensor)], 'unterstuetzte Komponenten stabil sortiert');
	is($result->{entities}[0]{device}{identifiers}, ['node42'], 'Device-Kontext geteilt');
	like($result->{warnings}[0], qr/vacuum/, 'nicht unterstuetzte Komponente wird gemeldet');
	my $delete = parse_config('homeassistant/device/node42/config', '');
	is($delete->{entities}[0]{operation}, 'delete_device', 'leerer Device-Payload loescht Topic-Komponenten');
};

subtest 'Climate-Kurzformen und Mehrkanal-Topics' => sub {
	my $result = parse_config(
		'homeassistant/climate/pac-1d797c/config',
		'{"name":"pac","uniq_id":"dc1ed51d797c-climate-pac","avty_t":"pac-1d797c/status","mode_stat_t":"pac-1d797c/state/mode","mode_cmd_t":"pac-1d797c/command/mode","curr_temp_t":"pac-1d797c/state/current_temperature","temp_stat_t":"pac-1d797c/state/target_temperature","temp_cmd_t":"pac-1d797c/command/target_temperature","fan_mode_stat_t":"pac-1d797c/state/fan_mode","fan_mode_cmd_t":"pac-1d797c/command/fan_mode","swing_mode_stat_t":"pac-1d797c/state/swing_mode","swing_mode_cmd_t":"pac-1d797c/command/swing_mode","preset_mode_stat_t":"pac-1d797c/state/preset","preset_mode_cmd_t":"pac-1d797c/command/preset","min_temp":16,"max_temp":30,"temp_step":0.5,"modes":["off","auto","cool"],"fan_modes":["Automatic","1"],"swing_modes":["off","vertical"],"preset_modes":["Normal","Quiet"],"dev":{"ids":["dc1ed51d797c"],"name":"pac-1d797c"}}',
	);
	is($result->{status}, 'ok', 'Climate-Payload wird akzeptiert');
	my $entity = $result->{entities}[0];
	is($entity->{component}, 'climate', 'Climate-Komponente bleibt erhalten');
	is($entity->{current_temperature_topic}, 'pac-1d797c/state/current_temperature',
		'Isttemperatur-Topic wird normalisiert');
	is($entity->{temperature_command_topic}, 'pac-1d797c/command/target_temperature',
		'Solltemperatur-Command-Topic wird normalisiert');
	is($entity->{fan_modes}, ['Automatic', '1'], 'Fan-Modi bleiben typ- und reihenfolgetreu');
	is([$entity->{min_temp}, $entity->{max_temp}, $entity->{temp_step}], [16, 30, 0.5],
		'Temperaturbereich bleibt erhalten');
};

subtest 'Availability und Payload-Erhalt' => sub {
	my $payload = '{"~":"node","stat_t":"~/state","avty":[{"t":"~/online"}],"name":"A:B C"}';
	my $result = parse_config('homeassistant/sensor/x/config', $payload);
	is($result->{status}, 'ok', 'Payload mit Doppelpunkten und Leerzeichen bleibt gueltig');
	is($result->{entities}[0]{raw_metadata}{name}, 'A:B C', 'JSON-Text unveraendert dekodiert');
};

subtest 'MQTT Device-Automation-Trigger' => sub {
	my $result = parse_config(
		'homeassistant/device_automation/HBTNS-2510-091-423828/button_1_double/config',
		'{"atype":"trigger","t":"homebuttons/homebuttons423828/button_1_double","pl":"PRESS","type":"button_double_press","stype":"button_1","dev":{"ids":["HBTNS-2510-091-423828"],"name":"homebuttons423828"}}',
	);
	is($result->{status}, 'ok', 'Device-Automation wird akzeptiert');
	my $entity = $result->{entities}[0];
	is($entity->{component}, 'device_automation', 'Komponente bleibt eindeutig');
	is($entity->{state_topic}, 'homebuttons/homebuttons423828/button_1_double',
		'Trigger-Topic wird als eingehendes State-Topic normalisiert');
	is($entity->{payload}, 'PRESS', 'Payload-Abkuerzung wird normalisiert');
	is($entity->{automation_type}, 'trigger', 'Automation-Typ wird normalisiert');
	is($entity->{subtype}, 'button_1', 'Subtype-Abkuerzung wird normalisiert');
};

is([MQTT2_Discovery::Parser::HomeAssistant::supported_components()],
	[qw(binary_sensor button climate cover device_automation device_tracker event fan light lock number select sensor switch text)],
	'alle unterstuetzten Komponenten sind registriert');

done_testing;

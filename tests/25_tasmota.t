# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::Parser::Tasmota ();

my $prefixes = ['homeassistant', 'tasmota/discovery'];
my $config_topic = 'tasmota/discovery/AABBCCDDEEFF/config';
my $sensor_topic = 'tasmota/discovery/AABBCCDDEEFF/sensors';
my $config = '{"ip":"192.0.2.10","dn":"Workshop Plug","fn":["Soldering Iron",null],"hn":"workshop-plug","mac":"AABBCCDDEEFF","md":"Generic","ofln":"Offline","onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.4.0","t":"workshop_plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1,0],"so":{"4":0,"30":0},"ver":1}';
my $sensors = '{"sn":{"Time":"2026-08-18T12:00:00","ENERGY":{"Total":12.5,"Power":42,"Voltage":230.1,"Current":0.18},"DS18B20":{"Temperature":23.4},"TempUnit":"C"},"ver":1}';

# Parst einen Tasmota-Testpayload unter dem standardisierten Discovery-Prefix.
sub parse_tasmota {
	my ($state, $topic, $payload) = @_;
	return MQTT2_Discovery::Parser::Tasmota::parse(
		state => $state, topic => $topic, payload => $payload, prefixes => $prefixes,
	);
}

subtest 'config und sensors werden in beliebiger Reihenfolge zusammengefuehrt' => sub {
	my %state;
	my $early_sensors = parse_tasmota(\%state, $sensor_topic, $sensors);
	is($early_sensors->{status}, 'ok', 'sensors wird zwischengespeichert');
	is($early_sensors->{entities}, [], 'ohne config wird noch kein unvollstaendiges Device erzeugt');

	my $result = parse_tasmota(\%state, $config_topic, $config);
	is($result->{status}, 'ok', 'config vervollstaendigt das Device');
	is($result->{entities}[0]{operation}, 'delete_device', 'Update beginnt mit atomarem Neuaufbau');
	my ($switch) = grep { ($_->{component} || '') eq 'switch' } @{ $result->{entities} };
	ok($switch, 'Relay wird als Switch normalisiert');
	is($switch->{state_topic}, 'stat/workshop_plug/RESULT', 'Statustopic aus ft/t/tp expandiert');
	is($switch->{command_topic}, 'cmnd/workshop_plug/POWER', 'Commandtopic aus ft/t/tp expandiert');
	is($switch->{value_template}, '{{ value_json.POWER }}', 'RESULT-Payload wird sicher gelesen');
	is($switch->{device}{identifiers}, ['tasmota_AABBCCDDEEFF'], 'MAC liefert stabile Device-Identitaet');
	my ($signal_owner) = grep { ref($_->{supplemental_signals}) eq 'ARRAY' } @{ $result->{entities} };
	is([map { $_->{type} } @{ $signal_owner->{supplemental_signals} }],
		[qw(payload json_flatten json_flatten json_flatten json_sequence json_flatten payload)],
		'Tasmota-Parser liefert seine Standardtelemetrie bereits als allgemeine Zusatzsignale');

	my %sensor_by_id = map { $_->{object_id} => $_ }
		grep { ($_->{component} || '') eq 'sensor' } @{ $result->{entities} };
	is([sort keys %sensor_by_id], [qw(ds18b20_temperature energy_current energy_power energy_total energy_voltage)],
		'skalare Sensorblaetter werden einzeln normalisiert');
	is($sensor_by_id{energy_power}{state_topic}, 'tele/workshop_plug/SENSOR', 'Telemetrietopic stimmt');
	is($sensor_by_id{energy_power}{value_template}, '{{ value_json.ENERGY.Power }}', 'verschachtelter JSON-Pfad stimmt');
	is($sensor_by_id{energy_power}{raw_metadata}{json_reading_name}, 'ENERGY_Power',
		'Tasmota-Sensor merkt sich FHEMs abgeflachten Reading-Namen');
	is($sensor_by_id{energy_power}{json_reading_name}, 'ENERGY_Power',
		'Tasmota-Parser normalisiert den abgeflachten Reading-Namen vor der Modellgrenze');
	is($sensor_by_id{ds18b20_temperature}{unit_of_measurement}, "\x{b0}C", 'TempUnit wird uebernommen');
};

subtest 'alternative FullTopic-Reihenfolge und SetOption4' => sub {
	my %state;
	my $payload = '{"dn":"Desk","fn":["Desk"],"t":"desk","ft":"%topic%/%prefix%/","tp":["cmd","state","telemetry"],"rl":[1],"state":["0","1"],"so":{"4":1},"ver":1}';
	my $result = parse_tasmota(\%state, $config_topic, $payload);
	my ($switch) = grep { ($_->{component} || '') eq 'switch' } @{ $result->{entities} };
	is($switch->{command_topic}, 'desk/cmd/POWER', 'FullTopic-Platzhalter werden positionsunabhaengig expandiert');
	is($switch->{state_topic}, 'desk/state/POWER', 'SetOption4 verwendet das direkte Statustopic');
	ok(!exists($switch->{value_template}), 'direktes Statustopic braucht kein JSON-Template');
	is($switch->{state_reading_name}, 'POWER',
		'Tasmota-Parser normalisiert den skalaren State-Namen vor der Modellgrenze');
	is([$switch->{payload_off}, $switch->{payload_on}], ['0', '1'], 'konfigurierte State-Payloads bleiben erhalten');
};

subtest 'Power-Kanalnamen folgen der Tasmota-Ausgabe bei stabilen Entity-IDs' => sub {
	my %multi_state;
	my $multi = '{"dn":"Dual Relay","fn":["Channel 1","Channel 2"],"mac":"AABBCCDDEEFF","state":["OFF","ON"],"t":"dual","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1,1],"so":{"4":0,"26":0},"ver":1}';
	my $multi_result = parse_tasmota(\%multi_state, $config_topic, $multi);
	my %multi_switch = map { $_->{object_id} => $_ }
		grep { ($_->{component} || '') eq 'switch' } @{ $multi_result->{entities} };

	is([sort keys %multi_switch], [qw(power power2)],
		'interne Entity-IDs bleiben unabhaengig von der MQTT-Nummerierung stabil');
	is([$multi_switch{power}{value_template}, $multi_switch{power2}{value_template}],
		['{{ value_json.POWER1 }}', '{{ value_json.POWER2 }}'],
		'mehrere Power-Ausgaenge verwenden durchgehend nummerierte JSON-Schluessel');
	is([$multi_switch{power}{command_topic}, $multi_switch{power2}{command_topic}],
		['cmnd/dual/POWER1', 'cmnd/dual/POWER2'],
		'Commandtopics verwenden dieselbe Kanalnummerierung wie die Statuswerte');

	my %single_state;
	my $single_numbered = '{"dn":"Single Relay","fn":["Channel 1"],"mac":"AABBCCDDEEFF","state":["OFF","ON"],"t":"single","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1],"so":{"4":0,"26":1},"ver":1}';
	my $single_result = parse_tasmota(\%single_state, $config_topic, $single_numbered);
	my ($single_switch) = grep { ($_->{component} || '') eq 'switch' } @{ $single_result->{entities} };
	is($single_switch->{object_id}, 'power', 'SetOption26 aendert die stabile Entity-ID nicht');
	is($single_switch->{value_template}, '{{ value_json.POWER1 }}',
		'SetOption26 nummeriert auch den einzigen Power-Ausgang');
};

subtest 'mehrkanalige Energiemesswerte erben Klasse und Einheit' => sub {
	my %state;
	parse_tasmota(\%state, $config_topic, $config);
	my $multi_channel = '{"sn":{"ENERGY":{"Power":[1688,0],"ApparentPower":[1700,0],"ReactivePower":[200,0],"Current":[7.3,0],"Factor":[0.99,0]}},"ver":1}';
	my $result = parse_tasmota(\%state, $sensor_topic, $multi_channel);
	my %sensor_by_id = map { $_->{object_id} => $_ }
		grep { ($_->{component} || '') eq 'sensor' } @{ $result->{entities} };

	is([$sensor_by_id{energy_power_0}{device_class}, $sensor_by_id{energy_power_0}{unit_of_measurement},
			$sensor_by_id{energy_power_0}{state_class}],
		['power', 'W', 'measurement'], 'Power-Arrayelement ist Wirkleistung in W');
	is($sensor_by_id{energy_power_0}{raw_metadata}{json_reading_name}, 'ENERGY_Power_1',
		'erster Arraykanal verwendet FHEMs einbasierten Reading-Namen');
	is([$sensor_by_id{energy_apparentpower_0}{device_class},
			$sensor_by_id{energy_apparentpower_0}{unit_of_measurement},
			$sensor_by_id{energy_apparentpower_0}{state_class}],
		['apparent_power', 'VA', 'measurement'], 'ApparentPower-Arrayelement ist Scheinleistung in VA');
	is([$sensor_by_id{energy_reactivepower_0}{device_class},
			$sensor_by_id{energy_reactivepower_0}{unit_of_measurement},
			$sensor_by_id{energy_reactivepower_0}{state_class}],
		['reactive_power', 'var', 'measurement'], 'ReactivePower-Arrayelement ist Blindleistung in var');
	is([$sensor_by_id{energy_current_0}{device_class}, $sensor_by_id{energy_current_0}{unit_of_measurement},
			$sensor_by_id{energy_current_0}{state_class}],
		['current', 'A', 'measurement'], 'Current-Arrayelement ist Strom in A');
	is([$sensor_by_id{energy_factor_0}{device_class}, $sensor_by_id{energy_factor_0}{state_class}],
		['power_factor', 'measurement'], 'Factor-Arrayelement ist dimensionsloser Leistungsfaktor');
	ok(!exists($sensor_by_id{energy_factor_0}{unit_of_measurement}),
		'Leistungsfaktor erhaelt ohne Skalierung keine falsche Prozent-Einheit');
};

subtest 'Sensor- und Device-Delete sowie Validierung' => sub {
	my %state;
	parse_tasmota(\%state, $config_topic, $config);
	parse_tasmota(\%state, $sensor_topic, $sensors);
	my $without_sensors = parse_tasmota(\%state, $sensor_topic, '');
	is(scalar(grep { ($_->{component} || '') eq 'sensor' } @{ $without_sensors->{entities} }), 0,
		'leeres sensors-Topic entfernt nur Sensoren');
	is(scalar(grep { ($_->{component} || '') eq 'switch' } @{ $without_sensors->{entities} }), 1,
		'Aktoren bleiben beim Sensor-Delete erhalten');
	my $delete = parse_tasmota(\%state, $config_topic, '');
	is($delete->{entities}[0]{operation}, 'delete_device', 'leeres config-Topic entfernt das ganze Device');

	is(parse_tasmota({}, $config_topic, '{')->{error_class}, 'json', 'ungueltiges JSON wird klassifiziert');
	is(parse_tasmota({}, $config_topic, '{"ver":2}')->{error_class}, 'version', 'unbekannte Protokollversion wird abgelehnt');
	is(parse_tasmota({}, 'tasmota/discovery/AABBCCDDEEFF/config/extra', $config)->{status}, 'next',
		'zusaetzliche Topicsegmente werden nicht beansprucht');
	my $wrong_mac = $config;
	$wrong_mac =~ s/AABBCCDDEEFF/001122334455/;
	is(parse_tasmota({}, $config_topic, $wrong_mac)->{error_class}, 'identity',
		'abweichende MAC in Topic und Payload wird abgelehnt');
};

subtest 'Light, Fan, Binary-Switch, Trigger, Shutter und Kamera' => sub {
	my %state;
	my $payload = '{"ip":"192.0.2.11","dn":"All Classes","fn":["Color Light","Shutter",""],"hn":"all-classes","mac":"AABBCCDDEEFF","md":"ESP32","ofln":"Offline","onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.4.0","t":"all_classes","ft":"%hostname%/%prefix%/%topic%/%id%/","tp":["cmnd","stat","tele"],"rl":[2,3,3],"swc":[5,13],"swn":["Door","Motion"],"btn":[1,0],"so":{"4":0,"11":0,"13":0,"30":0,"68":0,"73":1,"82":1,"114":1},"if":1,"cam":1,"ty":0,"lk":1,"lt_st":5,"sho":[0],"sht":[[0,90,10]],"ver":1}';
	my $result = parse_tasmota(\%state, $config_topic, $payload);
	is($result->{status}, 'ok', 'erweiterte Config wird akzeptiert');
	my @components = sort map { $_->{component} || '' } grep { ($_->{operation} || '') eq 'upsert' } @{ $result->{entities} };
	is(\@components,
		[qw(binary_sensor binary_sensor cover device_automation device_automation fan light)],
		'alle MQTT-seitig abbildbaren Klassen werden erzeugt');

	my ($light) = grep { ($_->{component} || '') eq 'light' } @{ $result->{entities} };
	ok($light->{raw_metadata}{json_autocreate},
		'native Tasmota-Aktoren markieren JSON-State fuer Autocreate-Auswertung');
	is($light->{brightness_command_topic}, 'all-classes/cmnd/all_classes/DDEEFF/Dimmer', 'Brightness-Topic mit hostname/id expandiert');
	is($light->{brightness_scale}, 100, 'Tasmota-Dimmerbereich bleibt 0..100');
	is($light->{rgb_command_topic}, 'all-classes/cmnd/all_classes/DDEEFF/Color2', 'RGB-Befehl vorhanden');
	is($light->{color_temp_command_topic}, 'all-classes/cmnd/all_classes/DDEEFF/CT', 'Farbtemperatur-Befehl vorhanden');
	is([$light->{min_mireds}, $light->{max_mireds}], [200, 380], 'SetOption82 reduziert den CT-Bereich');
	is($light->{effect_command_topic}, 'all-classes/cmnd/all_classes/DDEEFF/Scheme', 'Effekt-Befehl vorhanden');

	my ($fan) = grep { ($_->{component} || '') eq 'fan' } @{ $result->{entities} };
	is($fan->{percentage_command_topic}, 'all-classes/cmnd/all_classes/DDEEFF/FanSpeed', 'iFan-Speed wird abgebildet');
	is([$fan->{percentage_min}, $fan->{percentage_max}], [0, 3], 'Tasmota-FanSpeed-Bereich bleibt 0..3');
	my ($binary) = grep { ($_->{component} || '') eq 'binary_sensor' } @{ $result->{entities} };
	is($binary->{value_template}, '{{ value_json.Door.Action }}', 'physischer Switch liest seinen Action-Pfad');
	my @triggers = grep { ($_->{component} || '') eq 'device_automation' } @{ $result->{entities} };
	is([sort map { $_->{object_id} } @triggers], [qw(button_1_action switch_1_action)],
		'Button und triggerfaehiger Switch liefern Event-Readings');

	my ($cover) = grep { ($_->{component} || '') eq 'cover' } @{ $result->{entities} };
	is($cover->{position_template}, '{{ value_json.Shutter1.Position }}', 'Shutter-Position wird aus RESULT gelesen');
	is($cover->{tilt_command_topic}, 'all-classes/cmnd/all_classes/DDEEFF/ShutterTilt1', 'Shutter-Tilt wird abgebildet');
	like(join('; ', @{ $result->{warnings} }), qr/Kamera/, 'Kamera wird als nicht abbildbarer Stream gemeldet');
};

done_testing;

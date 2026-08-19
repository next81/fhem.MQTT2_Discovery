# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value command_log);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined $loaded;

# Setzt eine vollstaendig isolierte FHEM-Testumgebung mit Discovery-Device auf.
sub setup {
	my (%args) = @_;
	reset_env();
	add_iodev('mqtt', $args{type} || 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	$main::attr{discovery}{discoveryPrefixes} = $args{prefixes} if $args{prefixes};
	$main::attr{discovery}{deviceNamePrefix} = 'MQTT2_' if !exists $args{device_name_prefix};
	$main::attr{discovery}{deviceNamePrefix} = $args{device_name_prefix}
		if exists($args{device_name_prefix}) && $args{device_name_prefix} ne '';
	my $activate_error = main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'activate');
	die $activate_error if $activate_error;
	return $hash;
}

# Erzeugt einen typischen HA-Schalterpayload fuer wiederverwendbare Integrationstests.
sub switch_payload {
	my (%args) = @_;
	my $id = $args{id} || 'node';
	my $object = $args{object} || 'power';
	my $state = $args{state} || "$id/$object/state";
	my $command = $args{command} || "$id/$object/set";
	return qq({"name":"$object","uniq_id":"${id}_$object","stat_t":"$state","cmd_t":"$command","pl_on":"1","pl_off":"0","dev":{"ids":["$id"],"name":"Node $id"}});
}

subtest 'klassischer Switch und Dispatch-Konsum' => sub {
	setup();
	my $seen = dispatch_message('mqtt', 'client1', 'homeassistant/switch/node/power/config', switch_payload());
	is($seen, ['MQTT2_DISCOVERY'], 'Discovery wird konsumiert und erreicht MQTT2_DEVICE/Bridge nicht');
	ok($main::defs{MQTT2_Node_node}, 'MQTT2_DEVICE wurde angelegt');
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/\$DEVICETOPIC\/state/,
		'readingList verwendet das gemeinsame MQTT2-Devicetopic');
	like(attr_value('MQTT2_Node_node', 'setList'), qr/power:on,off/, 'setList enthaelt Switch-Setter');
	is($main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{confidence}, 0.95,
		'neu angelegtes Device liefert Semantic-Metadaten mit hoher Konfidenz');
	is($main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{entities}[0]{class}, 'switch',
		'Semantic-Klasse wird am Device bereitgestellt');
	is($main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{entities}[0]{capabilities}{power}{write}, 'power',
		'Semantic-Capability verweist auf den tatsaechlichen Set-Namen');
	is(reading_value('discovery', 'discoveredDevices'), 1, 'ein Device erkannt');
	is(reading_value('discovery', 'discoveredEntities'), 1, 'eine Entity erkannt');

	my $normal = dispatch_message('mqtt', 'client1', 'node/power/state', '1');
	is($normal, ['MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'], 'normales Topic laeuft an nachfolgende Consumer weiter');
};

subtest 'HA-Switch verwendet fuer Lesen und Schreiben exakt denselben Namen' => sub {
	setup();
	dispatch_message('mqtt', 'client1', 'homeassistant/switch/node/power/config',
		'{"name":"Power","uniq_id":"node_power","stat_t":"node/state/POWER1","cmd_t":"node/command/power1","pl_on":"ON","pl_off":"OFF","dev":{"ids":["node"],"name":"Node node"}}');

	like(attr_value('MQTT2_Node_node', 'readingList'),
		qr{^\$DEVICETOPIC/state/POWER1:\.\* POWER1$}m,
		'HA-State wird als POWER1 gelesen');
	like(attr_value('MQTT2_Node_node', 'setList'),
		qr{^POWER1:ON,OFF \$DEVICETOPIC/command/power1$}m,
		'HA-Setter heisst ebenfalls exakt POWER1');
	my $power = $main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{entities}[0]{capabilities}{power};
	is([$power->{read}, $power->{write}], ['POWER1', 'POWER1'],
		'SemanticUI verwendet fuer Lesen und Schreiben denselben Namen');
	is($power->{options}, ['ON', 'OFF'],
		'SemanticUI verwendet die nativen FHEM-Set-Zustaende');
	ok(!exists($power->{valueMap}), 'Power-Zustaende werden nicht umbenannt');
};

subtest 'Device-Namen werden standardmaessig ohne Prefix angelegt' => sub {
	setup(device_name_prefix => '');
	dispatch_message('mqtt', 'client1', 'homeassistant/switch/node/power/config', switch_payload());
	ok($main::defs{Node_node}, 'ohne deviceNamePrefix wird der Discovery-Name verwendet');
	ok(!$main::defs{MQTT2_Node_node}, 'MQTT2_ wird nicht implizit vorangestellt');
};

subtest 'native Tasmota-Discovery fuehrt config und sensors zusammen' => sub {
	setup();
	my $config = '{"dn":"Workshop Plug","fn":["Soldering Iron"],"mac":"AABBCCDDEEFF","md":"Generic","state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.4.0","t":"workshop_plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1],"so":{"4":0,"30":0},"ver":1}';
	my $sensors = '{"sn":{"Time":"2026-08-18T12:00:00","ENERGY":{"Power":42,"Voltage":230.1}},"ver":1}';

	is(dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCDDEEFF/config', $config),
		['MQTT2_DISCOVERY'], 'Tasmota config wird konsumiert');
	is(dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCDDEEFF/sensors', $sensors),
		['MQTT2_DISCOVERY'], 'Tasmota sensors wird konsumiert');
	ok($main::defs{MQTT2_Workshop_Plug}, 'ein gemeinsames MQTT2_DEVICE wurde angelegt');
	like(attr_value('MQTT2_Workshop_Plug', 'readingList'), qr{stat/workshop_plug/RESULT},
		'Relay-Status ist enthalten');
	my ($result_line) = grep { /^stat\/workshop_plug\/RESULT:/ }
		split /\n/, attr_value('MQTT2_Workshop_Plug', 'readingList');
	is($result_line, q{stat/workshop_plug/RESULT:.* { json2nameValue($EVENT,'',$JSONMAP) }},
		'Tasmota-RESULT verwendet ebenfalls die kurze JSON-Auswertung');
	like(attr_value('MQTT2_Workshop_Plug', 'readingList'), qr{tele/workshop_plug/SENSOR},
		'Telemetriesensoren sind enthalten');
	my ($sensor_line) = grep { /^tele\/workshop_plug\/SENSOR:/ }
		split /\n/, attr_value('MQTT2_Workshop_Plug', 'readingList');
	is($sensor_line, q{tele/workshop_plug/SENSOR:.* { json2nameValue($EVENT,'',$JSONMAP) }},
		'Tasmota-SENSOR verwendet dieselbe kurze JSON-Auswertung wie MQTT2-Autocreate');
	is(scalar(() = attr_value('MQTT2_Workshop_Plug', 'readingList') =~ /tele\/workshop_plug\/SENSOR/g), 1,
		'alle Tasmota-Telemetriewerte teilen sich eine JSON-Auswertung');
	like(attr_value('MQTT2_Workshop_Plug', 'setList'), qr{POWER:ON,OFF\s+cmnd/workshop_plug/POWER},
		'Relay-Befehl verwendet exakt den Reading-Namen');
	is(reading_value('discovery', 'discoveredDevices'), 1, 'Tasmota ergibt ein Device');
	is(reading_value('discovery', 'discoveredEntities'), 3, 'Relay und zwei Sensoren sind registriert');
};

subtest 'native Tasmota-Klassen werden bis readingList und setList abgebildet' => sub {
	setup(prefixes => 'homeassistant,tasmota/discovery');
	my $config = '{"ip":"192.0.2.12","dn":"All Classes","fn":["Color Light","Shutter",""],"hn":"all-classes","mac":"112233445566","md":"ESP32","ofln":"Offline","onln":"Online","state":["OFF","ON","TOGGLE","HOLD"],"sw":"15.4.0","t":"all_classes","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[2,3,3],"swc":[5,13],"swn":["Door","Motion"],"btn":[1,0],"so":{"4":0,"11":0,"13":0,"30":0,"68":0,"73":1,"82":1,"114":1},"if":1,"cam":0,"ty":0,"lk":1,"lt_st":5,"sho":[0],"sht":[[0,90,10]],"ver":1}';
	is(dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/112233445566/config', $config),
		['MQTT2_DISCOVERY'], 'erweiterte Tasmota config wird konsumiert');
	ok($main::defs{MQTT2_All_Classes}, 'alle Klassen werden in einem MQTT2_DEVICE gruppiert');
	my $reading_list = attr_value('MQTT2_All_Classes', 'readingList');
	my $set_list = attr_value('MQTT2_All_Classes', 'setList');

	like($set_list, qr{power_brightness:slider,0,1,100\s+cmnd/all_classes/Dimmer}, 'Dimmer wird schreibbar');
	like($set_list, qr{power_colorTemp:slider,200,1,380\s+cmnd/all_classes/CT}, 'Farbtemperatur wird schreibbar');
	like($set_list, qr{power_color\s+cmnd/all_classes/Color2}, 'RGB-Farbe wird schreibbar');
	like($set_list, qr{power_effect:}, 'Lichteffekte werden schreibbar');
	like($set_list, qr{fan_percentage:slider,0,1,3\s+cmnd/all_classes/FanSpeed}, 'iFan-Speed wird schreibbar');
	like($set_list, qr{shutter_action:open,close,stop}, 'Shutter-Aktionen werden schreibbar');
	like($set_list, qr{shutter_position:slider,0,1,100\s+cmnd/all_classes/ShutterPosition1}, 'Shutter-Position wird schreibbar');
	like($set_list, qr{shutter_tilt:slider,0,1,90\s+cmnd/all_classes/ShutterTilt1}, 'Shutter-Tilt wird schreibbar');

	my ($result_line) = grep { m{^stat/all_classes/RESULT:} } split /\n/, $reading_list;
	is($result_line, q{stat/all_classes/RESULT:.* { json2nameValue($EVENT,'',$JSONMAP) }},
		'alle JSON-Zustaende aus RESULT teilen sich die Autocreate-Auswertung');
	is(scalar(() = $reading_list =~ m{stat/all_classes/RESULT}g), 1,
		'RESULT wird trotz vieler Tasmota-Komponenten nur einmal ausgewertet');
	my %semantic = map { $_->{id} => $_ } @{ $main::defs{MQTT2_All_Classes}{SEMANTIC_METADATA}{entities} };
	is($semantic{power}{capabilities}{power}{read}, 'POWER1',
		'Lichtstatus liest bei mehreren Ausgaengen das nummerierte Rohreading');
	is($semantic{power}{capabilities}{power}{write}, 'POWER1',
		'Lichtstatus schreibt ueber denselben Namen wie das Rohreading');
	is($semantic{power}{capabilities}{brightness}{read}, 'Dimmer',
		'Helligkeit liest das rohe Dimmer-Reading');
	ok(!exists($semantic{switch_1}),
		'unklassifizierter physischer Eingang bleibt als Reading ausserhalb der SemanticUI');
	is($semantic{shutter}{capabilities}{position}{read}, 'Shutter1_Position',
		'Shutter liest die abgeflachte Tasmota-Position');
	is($semantic{fan}{capabilities}{percentage}{read}, 'FanSpeed',
		'Fan liest das rohe FanSpeed-Reading');
	is(reading_value('discovery', 'discoveredEntities'), 7, 'alle sieben Entities sind registriert');
};

subtest 'SemanticUI filtert mehrkanalige Tasmota-Messwerte konservativ' => sub {
	setup(prefixes => 'homeassistant,tasmota/discovery');
	my $config = '{"dn":"Meter","fn":["Channel 1","Channel 2"],"mac":"A1B2C3D4E5F6","state":["OFF","ON","TOGGLE","HOLD"],"t":"meter","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1,1],"so":{"4":0},"ver":1}';
	my $sensors = '{"sn":{"ENERGY":{"Power":[1688,0],"ApparentPower":[1700,0],"ReactivePower":[200,0],"Current":[7.3,0],"Factor":[0.99,0]}},"ver":1}';
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/A1B2C3D4E5F6/config', $config);
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/A1B2C3D4E5F6/sensors', $sensors);

	my %semantic = map { $_->{id} => $_ } @{ $main::defs{MQTT2_Meter}{SEMANTIC_METADATA}{entities} };
	is($semantic{power}{capabilities}{power}{read}, 'POWER1',
		'erster Aktorkanal liest das tatsaechlich erzeugte nummerierte Reading');
	is($semantic{power}{capabilities}{power}{write}, 'POWER1',
		'erster Aktorkanal schreibt ueber denselben Namen wie sein Reading');
	is($semantic{power2}{capabilities}{power}{read}, 'POWER2',
		'zweiter Aktorkanal liest sein nummeriertes Reading');
	is([$semantic{energy_power_0}{device_class},
			$semantic{energy_power_0}{capabilities}{value}{unit}],
		['power', 'W'], 'Wirkleistung erreicht SemanticUI mit W');
	ok(!exists($semantic{energy_apparentpower_0}),
		'Scheinleistung bleibt als spezialisiertes Reading ausserhalb der SemanticUI');
	ok(!exists($semantic{energy_reactivepower_0}),
		'Blindleistung bleibt als spezialisiertes Reading ausserhalb der SemanticUI');
	ok(!exists($semantic{energy_current_0}),
		'Strom bleibt als spezialisiertes Reading ausserhalb der SemanticUI');
	ok(!exists($semantic{energy_factor_0}),
		'Leistungsfaktor bleibt als spezialisiertes Reading ausserhalb der SemanticUI');
};

subtest 'Tasmota-Zweikanalgeraet erhaelt die vollstaendige Standard-readingList' => sub {
	setup(prefixes => 'homeassistant,tasmota/discovery');
	my $config = '{"dn":"SchwimmbadEntfeuchter","fn":["Entfeuchter","Luefter"],"mac":"AABBCCCF9A44","state":["OFF","ON"],"t":"tasmota_CF9A44","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1,1],"so":{"4":0,"26":0},"ver":1}';
	my $sensors = '{"sn":{"Time":"2026-08-19T12:00:00","ENERGY":{"Power":42}},"ver":1}';
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCCF9A44/config', $config);
	dispatch_message('mqtt', 'tasmota', 'tasmota/discovery/AABBCCCF9A44/sensors', $sensors);

	my $reading_list = attr_value('MQTT2_SchwimmbadEntfeuchter', 'readingList');
	my @expected = (
		q{tele/tasmota_CF9A44/LWT:.* LWT},
		q{tele/tasmota_CF9A44/STATE:.* { json2nameValue($EVENT,'',$JSONMAP) }},
		q{tele/tasmota_CF9A44/SENSOR:.* { json2nameValue($EVENT,'',$JSONMAP) }},
		q{tele/tasmota_CF9A44/INFO(?:1|2|3):.* { $EVENT =~ m,^..Info(?:1|2|3)..(.+).$, ?  json2nameValue($1,'',$JSONMAP) : json2nameValue($EVENT,'',$JSONMAP) }},
		q{tele/tasmota_CF9A44/UPTIME:.* { json2nameValue($EVENT,'',$JSONMAP) }},
		q{stat/tasmota_CF9A44/POWER1:.* POWER1},
		q{stat/tasmota_CF9A44/POWER2:.* POWER2},
		q{stat/tasmota_CF9A44/RESULT:.* { json2nameValue($EVENT,'',$JSONMAP) }},
	);
	for my $line (@expected) {
		is(scalar(grep { $_ eq $line } split /\n/, $reading_list), 1,
			"readingList enthaelt genau einmal: $line");
	}
	my $set_list = attr_value('MQTT2_SchwimmbadEntfeuchter', 'setList');
	like($set_list, qr{^POWER1:ON,OFF\s+cmnd/tasmota_CF9A44/POWER1$}m,
		'erster Set-Befehl entspricht exakt POWER1');
	like($set_list, qr{^POWER2:ON,OFF\s+cmnd/tasmota_CF9A44/POWER2$}m,
		'zweiter Set-Befehl entspricht exakt POWER2');
};

subtest 'Tasmota-Power-readings folgen allgemein der rl-Kanalposition' => sub {
	my @cases = (
		{
			label => 'ein Kanal ohne SetOption26', mac => 'AABBCC000001', topic => 'one',
			relays => '[1]', options => '{"4":0,"26":0}',
			expected => ['stat/one/POWER:.* POWER'], forbidden => ['stat/one/POWER1:.* POWER1'],
		},
		{
			label => 'ein Kanal mit direkter Befehlsantwort', mac => 'AABBCC000002', topic => 'one_direct',
			relays => '[1]', options => '{"4":1,"26":0}',
			expected => ['stat/one_direct/POWER:.* POWER'],
			forbidden => ['stat/one_direct/POWER:.* power'],
		},
		{
			label => 'drei Kanaele', mac => 'AABBCC000003', topic => 'three',
			relays => '[1,1,1]', options => '{"4":0,"26":0}',
			expected => [
				'stat/three/POWER1:.* POWER1',
				'stat/three/POWER2:.* POWER2',
				'stat/three/POWER3:.* POWER3',
			],
		},
		{
			label => 'erster Steckplatz leer', mac => 'AABBCC000004', topic => 'sparse',
			relays => '[0,1]', options => '{"4":0,"26":0}',
			expected => ['stat/sparse/POWER2:.* POWER2'],
			forbidden => ['stat/sparse/POWER2:.* state'],
		},
	);

	for my $case (@cases) {
		setup(prefixes => 'homeassistant,tasmota/discovery');
		my $config = '{"dn":"' . $case->{label} . '","fn":[],"mac":"' . $case->{mac}
			. '","state":["OFF","ON"],"t":"' . $case->{topic}
			. '","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":'
			. $case->{relays} . ',"so":' . $case->{options} . ',"ver":1}';
		dispatch_message('mqtt', 'tasmota', "tasmota/discovery/$case->{mac}/config", $config);
		my ($name) = grep { ($_->{TYPE} || '') eq 'MQTT2_DEVICE' } values %main::defs;
		my $reading_list = attr_value($name->{NAME}, 'readingList');
		my %lines = map { $_ => 1 } split /\n/, $reading_list;
		ok($lines{$_}, "$case->{label}: $_") for @{ $case->{expected} };
		ok(!$lines{$_}, "$case->{label}: nicht $_") for @{ $case->{forbidden} || [] };
	}
};

subtest 'disable verhindert Verarbeitung bis zum Loeschen des Attributs' => sub {
	my $hash = setup();
	$main::attr{discovery}{disable} = 1;
	main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'disable', '1');
	my $payload = switch_payload(id => 'disabled_node');
	is(dispatch_message('mqtt', 'c', 'homeassistant/switch/disabled_node/power/config', $payload),
		['MQTT2_DISCOVERY'], 'deaktivierte Discovery-Nachricht wird ohne Folgewirkung konsumiert');
	ok(!$main::defs{MQTT2_Node_disabled_node}, 'disable=1 legt kein MQTT2_DEVICE an');
	is(reading_value('discovery', 'state'), 'disabled', 'Status zeigt disabled');

	delete $main::attr{discovery}{disable};
	main::MQTT2_DISCOVERY_Attr('del', 'discovery', 'disable');
	is(reading_value('discovery', 'state'), 'active', 'Loeschen von disable aktiviert den vorbereiteten Parser');
	is(dispatch_message('mqtt', 'c', 'homeassistant/switch/disabled_node/power/config', $payload),
		['MQTT2_DISCOVERY'], 'nach dem Loeschen wird Discovery wieder verarbeitet');
	ok($main::defs{MQTT2_Node_disabled_node}, 'danach wird das MQTT2_DEVICE angelegt');
};

subtest 'lesbare Standard-setList mit devicetopic' => sub {
	setup();
	my $base = 'homebuttons/homebuttons423828';
	my $device = '"dev":{"ids":["homebuttons423828"],"name":"Homebuttons 423828"}';
	dispatch_message('mqtt', 'c', 'homeassistant/switch/homebuttons/awake_mode/config',
		qq({"~":"$base","stat_t":"~/state/awake_mode","cmd_t":"~/cmd/awake_mode","pl_on":"ON","pl_off":"OFF",$device}));
	dispatch_message('mqtt', 'c', 'homeassistant/text/homebuttons/button_1_label/config',
		qq({"~":"$base","stat_t":"~/state/btn_1_label","cmd_t":"~/cmd/btn_1_label","ret":"true",$device}));
	dispatch_message('mqtt', 'c', 'homeassistant/text/homebuttons/user_message/config',
		qq({"~":"$base","stat_t":"~/state/disp_msg","cmd_t":"~/cmd/disp_msg",$device}));

	is(attr_value('MQTT2_Homebuttons_423828', 'devicetopic'), $base,
		'HA-Topicbasis wird als devicetopic gesetzt');
	my $set_list = attr_value('MQTT2_Homebuttons_423828', 'setList');
	like($set_list,
		qr/^awake_mode:ON,OFF \$DEVICETOPIC\/cmd\/awake_mode$/m,
		'on/off-Payloadmapping verwendet die HA-Payloads ohne Perl-Ausdruck');
	like($set_list,
		qr/^btn_1_label \$DEVICETOPIC\/cmd\/btn_1_label:r$/m,
		'retained Textbefehl wird direkt mit MQTT2_DEVICE-Retain-Suffix publiziert');
	like($set_list,
		qr/^disp_msg \$DEVICETOPIC\/cmd\/disp_msg$/m,
		'freier Text verwendet die normale MQTT2_DEVICE-Syntax');
	unlike($set_list, qr/runtime(?:TemplatePublish|Choice)/,
		'triviale Setter benoetigen keinen Runtime-Wrapper');
};

subtest 'HomeButtons Number-Defaults und Device-Automation' => sub {
	setup();
	my $base = 'homebuttons/homebuttons423828';
	my $device = '"dev":{"ids":["HBTNS-2510-091-423828"],"name":"homebuttons423828"}';
	dispatch_message('mqtt', 'c', 'homeassistant/number/HBTNS-2510-091-423828/schedule_wakeup/config',
		qq({"name":"Schedule wakeup","cmd_t":"$base/cmd/schedule_wakeup","stat_t":"$base/schedule_wakeup","min":5,"max":1800,$device}));
	dispatch_message('mqtt', 'c', 'homeassistant/device_automation/HBTNS-2510-091-423828/button_1/config',
		qq({"atype":"trigger","t":"$base/button_1","pl":"PRESS","type":"button_short_press","stype":"button_1",$device}));

	like(attr_value('MQTT2_homebuttons423828', 'setList'),
		qr/^schedule_wakeup:slider,5,1,1800 \$DEVICETOPIC\/cmd\/schedule_wakeup$/m,
		'Number ohne step erhaelt einen schreibbaren Setter mit Default 1');
	like(attr_value('MQTT2_homebuttons423828', 'readingList'),
		qr/^\$DEVICETOPIC\/button_1:PRESS\$ button_1$/m,
		'Device-Automation wird als payload-gefiltertes Reading integriert');
	is([map { $_->{id} } @{ $main::defs{MQTT2_homebuttons423828}{SEMANTIC_METADATA}{entities} }],
		['schedule_wakeup'],
		'Device-Automation wird nicht als Wertanzeige an SemanticUI uebergeben');
	is(reading_value('discovery', 'discoveredEntities'), 2,
		'Number und Trigger werden beide registriert');
};

subtest 'externes Availability-Topic verhindert PAC-devicetopic nicht' => sub {
	setup();
	my $base = 'pac-1b844c';
	my $device = '"dev":{"ids":["pac-1b844c"],"name":"pac-1b844c"}';
	dispatch_message('mqtt', 'fhem_raspi02_discovery_test',
		'homeassistant/sensor/pac/pac_outside_temperature/config',
		qq({"stat_t":"$base/sensor/pac_outside_temperature/state","avty_t":"pac/status",$device}));
	dispatch_message('mqtt', 'fhem_raspi02_discovery_test',
		'homeassistant/switch/pac/pac_mild_dry_switch/config',
		qq({"stat_t":"$base/switch/pac_mild_dry_switch/state","cmd_t":"$base/switch/pac_mild_dry_switch/command","pl_on":"ON","pl_off":"OFF",$device}));

	is(attr_value('MQTT2_pac_1b844c', 'devicetopic'), $base,
		'gemeinsame PAC-Topicbasis wird als devicetopic gesetzt');
	my $reading_list = attr_value('MQTT2_pac_1b844c', 'readingList');
	like($reading_list, qr/^pac\/status:\.\* status$/m,
		'externes Availability-Topic bleibt vollstaendig und verwendet seinen Topic-Namen');
	like($reading_list, qr/^\$DEVICETOPIC\/sensor\/pac_outside_temperature\/state:\.\*/m,
		'PAC-State-Topic verwendet DEVICETOPIC ohne CID-Praefix');
	like(attr_value('MQTT2_pac_1b844c', 'setList'),
		qr/^pac_mild_dry_switch:ON,OFF \$DEVICETOPIC\/switch\/pac_mild_dry_switch\/command$/m,
		'PAC-Setter verwendet die direkten HA-Payloads und DEVICETOPIC');
};

subtest 'ESPHome-PAC behaelt bestehende Setter und ergaenzt Climate vollstaendig' => sub {
	setup();
	my $id = 'dc1ed51d797c';
	my $base = 'pac-1d797c';
	my $device = qq("dev":{"ids":"$id","name":"$base","sw":"2026.7.4","mdl":"esp32-c3-devkitm-1","mf":"Espressif"});

	dispatch_message('mqtt', $base,
		"homeassistant/select/$base/pac_vertical_swing_mode/config",
		qq({"ops":["swing","auto","up","up_center","center","down_center","down"],"name":"pac vertical swing mode","stat_t":"$base/state/vertical_swing_mode","cmd_t":"$base/command/vertical_swing_mode","avty_t":"$base/status","uniq_id":"$id-select-760edd2a",$device}));
	dispatch_message('mqtt', $base,
		"homeassistant/switch/$base/pac_mild_dry_switch/config",
		qq({"name":"pac mild dry switch","stat_t":"$base/state/mild_dry","cmd_t":"$base/command/mild_dry","avty_t":"$base/status","uniq_id":"$id-switch-daa26a14",$device}));

	my $name = 'MQTT2_pac_1d797c';
	is(attr_value($name, 'setList'), join("\n",
			'mild_dry:ON,OFF $DEVICETOPIC/command/mild_dry',
			'vertical_swing_mode:swing,auto,up,up_center,center,down_center,down $DEVICETOPIC/command/vertical_swing_mode'),
		'Select und Switch verwenden die Namen ihres direkten Command-Topics');

	dispatch_message('mqtt', $base,
		"homeassistant/climate/$base/config",
		qq({"name":"pac","unique_id":"$id-climate-pac","availability_topic":"$base/status","mode_state_topic":"$base/state/mode","mode_command_topic":"$base/command/mode","power_command_topic":"$base/command/power","payload_on":"on","payload_off":"off","current_temperature_topic":"$base/state/current_temperature","temperature_state_topic":"$base/state/target_temperature","temperature_command_topic":"$base/command/target_temperature","fan_mode_state_topic":"$base/state/fan_mode","fan_mode_command_topic":"$base/command/fan_mode","swing_mode_state_topic":"$base/state/swing_mode","swing_mode_command_topic":"$base/command/swing_mode","preset_mode_state_topic":"$base/state/preset","preset_mode_command_topic":"$base/command/preset","min_temp":16,"max_temp":30,"temp_step":0.5,"precision":0.1,"modes":["off","auto","cool","heat","fan_only","dry"],"fan_modes":["Automatic","1","2","3","4","5"],"swing_modes":["off","both","vertical","horizontal"],"preset_modes":["Normal","Powerful","Quiet"],"device":{"identifiers":["$id"],"name":"$base","manufacturer":"Panasonic / ESPHome","model":"CN-CNT air conditioner"}}));

	is(attr_value($name, 'devicetopic'), $base, 'PAC-Basistopic wird als devicetopic verwendet');
	is(attr_value($name, 'setList'), join("\n",
			'fan_mode:Automatic,1,2,3,4,5 $DEVICETOPIC/command/fan_mode',
			'mild_dry:ON,OFF $DEVICETOPIC/command/mild_dry',
			'mode:off,auto,cool,heat,fan_only,dry $DEVICETOPIC/command/mode',
			'power:on,off $DEVICETOPIC/command/power',
			'preset_mode:Normal,Powerful,Quiet $DEVICETOPIC/command/preset',
			'swing_mode:off,both,vertical,horizontal $DEVICETOPIC/command/swing_mode',
			'target_temperature:slider,16,0.5,30 $DEVICETOPIC/command/target_temperature',
			'vertical_swing_mode:swing,auto,up,up_center,center,down_center,down $DEVICETOPIC/command/vertical_swing_mode'),
		'alle PAC-Setter verwenden kurze geraetelokale Command-Namen');
	my $reading_list = attr_value($name, 'readingList');
	like($reading_list, qr/^\$DEVICETOPIC\/state\/current_temperature:\.\* current_temperature$/m,
		'Climate-Isttemperatur wird als Reading angelegt');
	like($reading_list, qr/^\$DEVICETOPIC\/state\/target_temperature:\.\* target_temperature$/m,
		'Climate-Solltemperatur wird als Reading angelegt');
	my $entities = $main::defs{$name}{SEMANTIC_METADATA}{entities};
	is(scalar @$entities, 1, 'Semantic-Metadaten enthalten eine komponierte Climate-Hauptentity');
	my $semantic = $entities->[0];
	is($semantic->{name}, 'climate',
		'Geraetehauptfunktion verwendet die allgemeine Komponenten-ID');
	is($semantic->{capabilities}{power}{read}, 'mode',
		'Power liest den Modus als einzige Zustandsquelle');
	is($semantic->{capabilities}{power}{write}, 'power',
		'Power schreibt den explizit entdeckten Power-Setter');
	is($semantic->{capabilities}{power}{valueMap}{read}, {
			off => 'off', auto => 'on', cool => 'on', heat => 'on', fan_only => 'on', dry => 'on',
		}, 'Power-Zustand wird vollstaendig aus allen Climate-Modi normalisiert');
	is($semantic->{capabilities}{mildDry}{kind}, 'boolean',
		'zusaetzlicher Switch wird als boolesche Climate-Capability beschrieben');
	is([$semantic->{capabilities}{mildDry}{read}, $semantic->{capabilities}{mildDry}{write}],
		[qw(mild_dry mild_dry)], 'Mild-Dry-Capability verwendet die realen FHEM-Pfade');
	is($semantic->{capabilities}{verticalSwingMode}{kind}, 'enum',
		'zusaetzliches Select wird als Enum-Capability beschrieben');
	is($semantic->{capabilities}{verticalSwingMode}{options},
		[qw(swing auto up up_center center down_center down)],
		'vertikale Lamellenposition behaelt alle entdeckten Optionen');
	is(reading_value('discovery', 'discoveredEntities'), 3,
		'Select, Switch und Climate bleiben intern drei Discovery-Entities');
};

subtest 'mehrere Entities gruppieren sich und Updates bleiben idempotent' => sub {
	setup();
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	my $sensor = '{"uniq_id":"node_temp","stat_t":"node/power/temperature","dev":{"ids":["node"],"name":"Node node"}}';
	my $before_sensor = scalar @{ command_log() };
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temperature/config', $sensor);
	my @sensor_commands = @{ command_log() }[$before_sensor .. $#{ command_log() }];
	is(scalar(grep { /^attr MQTT2_Node_node readingList / } @sensor_commands), 1,
		'neue klassische Entity schreibt readingList genau einmal');
	is(scalar(grep { /^attr MQTT2_Node_node setList / } @sensor_commands), 0,
		'neue Sensor-Entity schreibt unveraenderte setList nicht erneut');
	is(reading_value('discovery', 'discoveredDevices'), 1, 'gemeinsame Device-ID gruppiert Entities');
	is(reading_value('discovery', 'discoveredEntities'), 2, 'zwei Entities registriert');
	is(scalar @{ $main::defs{MQTT2_Node_node}{SEMANTIC_METADATA}{entities} }, 1,
		'unklassifizierter Read-only-Sensor bleibt trotz vollstaendiger readingList aus SemanticUI heraus');
	my $before = attr_value('MQTT2_Node_node', 'readingList');
	my $before_repeat = scalar @{ command_log() };
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temperature/config', $sensor);
	is(attr_value('MQTT2_Node_node', 'readingList'), $before, 'identisches Update erzeugt keine Duplikate');
	my @repeat_commands = @{ command_log() }[$before_repeat .. $#{ command_log() }];
	is(scalar(grep { /^attr MQTT2_Node_node (?:readingList|setList) / } @repeat_commands), 0,
		'identisches Update schreibt keine Listenattribute erneut');
};

subtest 'reines Readings-Device bleibt fuer manuelle Semantic-Attribute offen' => sub {
	setup();
	my $payload = '{"name":"IP address","uniq_id":"node_ip","stat_t":"node/state/ip","dev":{"ids":["node"],"name":"Node"}}';
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/ip/config', $payload);
	like(attr_value('MQTT2_Node', 'readingList'), qr{/state/ip:\.\* ip},
		'unklassifizierter Wert bleibt vollstaendig in der readingList');
	ok(!exists($main::defs{MQTT2_Node}{SEMANTIC_METADATA}),
		'leere automatische Metadaten blockieren keine manuellen Semantic-Attribute');
};

subtest 'Device-Discovery ist atomar abbildbar' => sub {
	setup();
	my $payload = '{"~":"node","dev":{"ids":["node"],"name":"Node node"},"o":{"name":"fixture"},"cmps":{"power":{"p":"switch","stat_t":"~/power","cmd_t":"~/power/set"},"temperature":{"p":"sensor","stat_t":"~/temperature","val_tpl":"{{ value_json.temperature }}"}}}';
	my $before = scalar @{ command_log() };
	my $seen = dispatch_message('mqtt', 'c', 'homeassistant/device/node/config', $payload);
	my @commands = @{ command_log() }[$before .. $#{ command_log() }];
	is($seen, ['MQTT2_DISCOVERY'], 'Device-Discovery konsumiert');
	is(reading_value('discovery', 'discoveredEntities'), 2, 'beide Komponenten registriert');
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/json2nameValue/,
		'einfaches Template verwendet die lesbare FHEM-JSON-Auswertung');
	unlike(attr_value('MQTT2_Node_node', 'readingList'), qr/runtimeReading|e3sg/,
		'einfaches Template erzeugt keinen kryptischen Runtime-Aufruf');
	is(scalar(grep { /^attr MQTT2_Node_node readingList / } @commands), 1,
		'mehrere Komponenten schreiben readingList gemeinsam genau einmal');
	is(scalar(grep { /^attr MQTT2_Node_node setList / } @commands), 1,
		'mehrere Komponenten schreiben setList gemeinsam genau einmal');
};

subtest 'kollidierende Device-Discovery-Namen werden symmetrisch qualifiziert' => sub {
	setup();
	my $payload = <<'JSON';
{"device":{"identifiers":["collision"],"name":"Collision"},"components":{"sensor_battery":{"p":"sensor","name":"Sensor battery","state_topic":"collision/state","value_template":"{{ value_json.battery }}","device_class":"battery"},"device_battery":{"p":"sensor","name":"Device battery","state_topic":"collision/state","value_template":"{{ value_json.battery }}","device_class":"battery"}}}
JSON
	dispatch_message('mqtt', 'collision', 'homeassistant/device/collision/config', $payload);

	my $reading_list = attr_value('MQTT2_Collision', 'readingList');
	like($reading_list, qr/runtimeReading\("\{\{ value_json\.battery \}\}", \$EVENT, ['"]sensor_battery['"]\)/,
		'Sensor-Pfad erhaelt bei einer Kollision den qualifizierten Namen');
	like($reading_list, qr/runtimeReading\("\{\{ value_json\.battery \}\}", \$EVENT, ['"]device_battery['"]\)/,
		'Device-Pfad erhaelt bei einer Kollision ebenfalls den qualifizierten Namen');
	unlike($reading_list, qr/["']battery["']\s*\)/,
		'kein kollidierendes unqualifiziertes battery-Reading bleibt uebrig');
	is([sort map { $_->{id} } @{ $main::defs{MQTT2_Collision}{SEMANTIC_METADATA}{entities} }],
		[qw(device_battery sensor_battery)],
		'SemanticUI verwendet dieselben eindeutigen Namen');
};

subtest 'FindMy-Device-Discovery befuellt readingList trotz Jinja-dict.get' => sub {
	setup();
	my $payload = <<'JSON';
{"device":{"identifiers":["findmy2mqtt:person_1:ABCDEF123456"],"name":"Person1 iPhone","manufacturer":"Apple"},"origin":{"name":"findmy2mqtt","sw_version":"0.9.6"},"components":{"sensor_name":{"p":"sensor","name":"Name","unique_id":"fm_person_name","state_topic":"findmy/person_1/ABCDEF123456/state","value_template":"{{ value_json.get('name') }}"},"sensor_battery":{"p":"sensor","name":"Battery","unique_id":"fm_person_battery","state_topic":"findmy/person_1/ABCDEF123456/state","value_template":"{{ value_json.get('battery') }}","device_class":"battery","state_class":"measurement","unit_of_measurement":"%"},"binary_sensor_locationOld":{"p":"binary_sensor","name":"Location old","unique_id":"fm_person_locationOld","state_topic":"findmy/person_1/ABCDEF123456/state","value_template":"{{ value_json.get('locationOld') }}","payload_on":"1","payload_off":"0","device_class":"problem"},"button_locate":{"p":"button","name":"Locate","unique_id":"fm_person_locate","command_topic":"findmy/person_1/ABCDEF123456/locate","payload_press":"1"},"text_message":{"p":"text","name":"Message","unique_id":"fm_person_message","command_topic":"findmy/person_1/ABCDEF123456/message","min":1,"max":255}},"qos":1}
JSON
	dispatch_message('mqtt', 'fm_person_device', 'homeassistant/device/fm_person_device/config', $payload);

	my $reading_list = attr_value('MQTT2_Person1_iPhone', 'readingList');
	my $set_list = attr_value('MQTT2_Person1_iPhone', 'setList');
	like($reading_list, qr/^\$DEVICETOPIC\/state:\.\* \{ json2nameValue/m,
		'gemeinsames FindMy-State-JSON wird in readingList aufgenommen');
	like($reading_list, qr/json2nameValue\(\$EVENT\)/,
		'reine Eins-zu-eins-Namen verwenden die kuerzeste JSON-Auswertung');
	unlike($reading_list, qr/'(?:battery|locationOld|name)'\s*=>/,
		'identische JSON- und Reading-Namen werden nicht wiederholt');
	unlike($reading_list, qr/\^\(\?:battery\|locationOld\|name\)/,
		'FindMy-State filtert zusaetzliche Payload-Felder nicht aus');
	unlike($reading_list, qr/runtimeReading/, 'einfache FindMy-Templates benoetigen keinen Runtime-Fallback');
	like($set_list, qr/^locate:noArg \$DEVICETOPIC\/locate 1$/m, 'Locate-Setter verwendet den kurzen Namen');
	like($set_list, qr/^message \$DEVICETOPIC\/message$/m, 'Message-Setter verwendet den kurzen Namen');
	is([sort map { $_->{id} } @{ $main::defs{MQTT2_Person1_iPhone}{SEMANTIC_METADATA}{entities} }],
		[qw(battery locate message)],
		'SemanticUI enthaelt nur Setter und den explizit klassifizierten Battery-Sensor');
	is(reading_value('discovery', 'lastError'), 'none', 'FindMy-Discovery wird fehlerfrei verarbeitet');
};

subtest 'fremder Prefix und fehlerhaftes JSON' => sub {
	setup(prefixes => 'homeassistant');
	my $foreign = dispatch_message('mqtt', 'c', 'ha/switch/node/power/config', switch_payload());
	is($foreign, ['MQTT2_DISCOVERY', 'MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'], 'fremder Prefix wird mit NEXT weitergereicht');
	my $invalid = dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', '{');
	is($invalid, ['MQTT2_DISCOVERY'], 'ungueltiges Discovery-JSON wird trotzdem konsumiert');
	like(reading_value('discovery', 'lastError'), qr/Ungueltiges JSON/, 'Parserfehler ist sichtbar');
};

subtest 'manuelle Zeilen bleiben konservativ erhalten' => sub {
	setup();
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	$main::attr{MQTT2_Node_node}{setList} .= "\nreboot:noArg node/reboot 1\npower:on,off manual/topic value";
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload(command => 'node/power/newset'));
	my $set_list = attr_value('MQTT2_Node_node', 'setList');
	like($set_list, qr/reboot:noArg node\/reboot 1/, 'nicht kollidierende manuelle Zeile bleibt');
	like($set_list, qr/power:on,off manual\/topic value/, 'manuelle Kollision gewinnt');
	unlike($set_list, qr/newset/, 'kollidierende Discovery-Zeile wird ausgelassen');
	like(reading_value('discovery', 'conflicts'), qr/power/, 'Konflikt wird gemeldet');
};

subtest 'manuelles Reading gewinnt auch gegen gruppierte JSON-Auswertung' => sub {
	setup();
	my $sensor = '{"stat_t":"node/data","val_tpl":"{{ value_json.temperature }}","uniq_id":"node_temperature","dev":{"ids":["node"],"name":"Node node"}}';
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temperature/config', $sensor);
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/json2nameValue/,
		'Ausgangszustand verwendet die gruppierbare JSON-Auswertung');
	$main::attr{MQTT2_Node_node}{readingList} .= "\nmanual/topic:.* temperature";
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temperature/config', $sensor);
	is(attr_value('MQTT2_Node_node', 'readingList'), 'manual/topic:.* temperature',
		'manuelle Reading-Zeile ersetzt im konservativen Modus nur ihre JSON-Zuordnung');
	like(reading_value('discovery', 'conflicts'), qr/temperature/,
		'Konflikt der JSON-Zuordnung wird sichtbar gemeldet');
};

subtest 'Delete entfernt nur eigene Entity und Default behaelt Device' => sub {
	setup();
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temp/config', '{"stat_t":"node/temp","uniq_id":"node_temp","dev":{"ids":["node"],"name":"Node node"}}');
	$main::attr{MQTT2_Node_node}{readingList} .= "\nmanual/topic:.* manual";
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', '');
	is(reading_value('discovery', 'discoveredEntities'), 1, 'nur Switch-Entity entfernt');
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/\$DEVICETOPIC\/temp/, 'Sensor-Entity bleibt');
	like(attr_value('MQTT2_Node_node', 'readingList'), qr/manual\/topic/, 'manuelles Reading bleibt');
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/node/temp/config', '');
	ok($main::defs{MQTT2_Node_node}, 'letzte Entity loescht Device bei Default nicht');
	is(reading_value('discovery', 'discoveredEntities'), 0, 'keine aktive Entity mehr');
};

subtest 'autoDelete loescht nur rein automatisch verwaltetes Device' => sub {
	setup();
	$main::attr{discovery}{autoDelete} = 1;
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', '');
	ok(!$main::defs{MQTT2_Node_node}, 'unveraendertes Auto-Device wurde geloescht');

	setup();
	$main::attr{discovery}{autoDelete} = 1;
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	$main::attr{MQTT2_Node_node}{setList} .= "\nreboot:noArg node/reboot 1";
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', '');
	ok($main::defs{MQTT2_Node_node}, 'Device mit manueller Zeile wird nicht geloescht');
};

subtest 'zwei IODevs mit getrennten Prefixen' => sub {
	reset_env();
	add_iodev('mqttA');
	add_iodev('mqttB');
	my ($a) = define_discovery('discoveryA', 'mqttA');
	my ($b) = define_discovery('discoveryB', 'mqttB');
	$main::attr{discoveryA}{discoveryPrefixes} = 'haA';
	$main::attr{discoveryB}{discoveryPrefixes} = 'haB';
	main::MQTT2_DISCOVERY_Set($a, 'discoveryA', 'activate');
	main::MQTT2_DISCOVERY_Set($b, 'discoveryB', 'activate');
	dispatch_message('mqttA', 'a', 'haA/switch/nodeA/power/config', switch_payload(id => 'nodeA'));
	dispatch_message('mqttB', 'b', 'haB/switch/nodeB/power/config', switch_payload(id => 'nodeB'));
	is(reading_value('discoveryA', 'discoveredEntities'), 1, 'IODev A hat eigene Entity');
	is(reading_value('discoveryB', 'discoveredEntities'), 1, 'IODev B hat eigene Entity');
	is(dispatch_message('mqttA', 'a', 'haB/switch/x/power/config', switch_payload(id => 'x')),
		['MQTT2_DISCOVERY', 'MQTT2_DEVICE', 'MQTT_GENERIC_BRIDGE'], 'Prefix B wird auf IODev A nicht beansprucht');
};

subtest 'Runtime-Template und Command-Payload' => sub {
	my $reading = main::MQTT2_DISCOVERY_runtimeReading('{{ value_json.temperature | round(1) }}', '{"temperature":23.46}', 'temperature');
	is($reading, { temperature => '23.5' }, 'lesbares Runtime-Reading wertet ein komplexes Template sicher aus');
	is(main::MQTT2_DISCOVERY_runtimeReading('e3sgdmFsdWVfanNvbi50ZW1wZXJhdHVyZSB9fQ==', '{"temperature":23.5}', 'temperature'),
		{}, 'Base64 wird nicht mehr als Runtime-Template akzeptiert');
	my $command = main::MQTT2_DISCOVERY_runtimeTemplatePublish('node/set', '{{ value }}', 'level 42');
	is($command, 'node/set 42', 'Command-Wrapper trennt Set-Namen vom Wert');
	is(main::MQTT2_DISCOVERY_runtimeChoice('node/set', { eco => 'ECO' }, 'mode eco'),
		'node/set ECO', 'Choice-Wrapper verwendet ein sichtbares Mapping');
	is(main::MQTT2_DISCOVERY_runtimeTemplateChoice(
			'node/set', '{{ value | lower }}', { eco => 'ECO' }, 'mode eco'),
		'node/set eco', 'Choice-Template verarbeitet erst das sichtbare Mapping und dann das Template');
	is(main::MQTT2_DISCOVERY_runtimePublish('node/set', 'PRESS'),
		'node/set PRESS', 'Publish-Wrapper verwendet Klartextargumente');
	is(main::MQTT2_DISCOVERY_runtimeJSONPublish('node/set', 'brightness', 'brightness 128'),
		'node/set {"brightness":128}', 'JSON-Command wird kanonisch und ohne Stringverkettungs-Injection erzeugt');

	is(main::MQTT2_DISCOVERY_runtimeTemplatePublish('x', 'x', 'state value'), undef,
		'Template-Publish lehnt ein ungueltiges Klartext-Template ab');
	is(main::MQTT2_DISCOVERY_runtimeChoice('x', 'x', 'state on'), undef,
		'Choice-Publish lehnt ein ungueltiges Mapping ab');
	is(main::MQTT2_DISCOVERY_runtimeTemplateChoice('x', 'x', { on => 'ON' }, 'state on'), undef,
		'Choice-Template lehnt ein ungueltiges Template ab');
	is(main::MQTT2_DISCOVERY_runtimeJSONPublish('x', 'key', 'brightness invalid'), undef,
		'JSON-Publish lehnt einen nichtnumerischen Wert ab');
};

subtest 'uebernommenes Bestandsdevice erhaelt keine impliziten Semantic-Metadaten' => sub {
	setup();
	$main::defs{MQTT2_Node_node} = { NAME => 'MQTT2_Node_node', TYPE => 'MQTT2_DEVICE', READINGS => {} };
	$main::attr{discovery}{existingDevice} = 'replace';
	dispatch_message('mqtt', 'c', 'homeassistant/switch/node/power/config', switch_payload());
	ok(!exists $main::defs{MQTT2_Node_node}{SEMANTIC_METADATA},
		'manuell vorhandenes Device bleibt semantisch unberuehrt');
};

subtest 'unsicheres Template erzeugt kein leeres Device' => sub {
	setup();
	my $payload = '{"stat_t":"node/secret","val_tpl":"{{ states(\"sensor.secret\") }}","uniq_id":"secret","dev":{"ids":["secret"],"name":"Secret"}}';
	dispatch_message('mqtt', 'c', 'homeassistant/sensor/secret/value/config', $payload);
	ok(!$main::defs{MQTT2_Secret}, 'abgelehntes Template legt kein leeres MQTT2_DEVICE an');
	like(reading_value('discovery', 'lastWarning'), qr/keine sicher abbildbare Funktion/, 'Ablehnung wird sichtbar gemeldet');
};

unlike(join("\n", @{ command_log() }), qr/(?:^|\s)save(?:\s|$)/, 'kein Integrationspfad ruft save auf');

done_testing;

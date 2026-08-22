# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv qw(reset_env add_iodev define_discovery attr_value reading_value command_log log_entries);

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined $loaded;

subtest 'Initialize und Define' => sub {
	reset_env();
	my $module = $main::modules{MQTT2_DISCOVERY};
	is($module->{DefFn}, 'MQTT2_DISCOVERY_Define', 'DefFn registriert');
	ok(!exists $module->{GetFn}, 'kein GetFn registriert');
	is($module->{ParseFn}, 'MQTT2_DISCOVERY_Parse', 'ParseFn registriert');
	is($module->{FW_deviceOverview}, 1, 'kontextbezogene FHEMWEB-Hilfe ist aktiviert');
	like($module->{Match}, qr/config/, 'globales Match erfasst Config-Topics');
	like($module->{Match}, qr/sensors/, 'globales Match erfasst native Tasmota-Sensor-Topics');
	like($module->{AttrList}, qr/(?:^| )disable:0,1(?: |$)/, 'disable ist als Standardattribut registriert');
	like($module->{AttrList}, qr/(?:^| )deviceNamePrefix(?: |$)/, 'optionaler Device-Namensprefix ist registriert');

	my ($missing, $missing_error) = define_discovery('bad', 'missing');
	like($missing_error, qr/existiert nicht/, 'fehlendes IODev wird abgelehnt');
	$main::defs{dummy} = { NAME => 'dummy', TYPE => 'dummy' };
	my ($wrong, $wrong_error) = define_discovery('wrong', 'dummy');
	like($wrong_error, qr/weder MQTT2_SERVER noch MQTT2_CLIENT/, 'falscher IO-Typ wird abgelehnt');

	add_iodev('server', 'MQTT2_SERVER');
	my ($first, $first_error) = define_discovery('discovery', 'server');
	is($first_error, undef, 'Server-Discovery wird definiert');
	is(main::MQTT2_DISCOVERY_prefixes($first), ['homeassistant', 'tasmota/discovery'],
		'Home Assistant und Tasmota Discovery sind standardmaessig aktiv');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{server}, $first, 'Registry enthaelt IODev-Zuordnung');
	my ($second, $second_error) = define_discovery('discovery2', 'server');
	like($second_error, qr/bereits discovery definiert/, 'zweite Instanz am selben IODev wird abgelehnt');

	add_iodev('client', 'MQTT2_CLIENT');
	my ($other, $other_error) = define_discovery('discoveryClient', 'client');
	is($other_error, undef, 'anderes IODev darf eigene Instanz haben');
	is(main::MQTT2_DISCOVERY_Undef($other, 'discoveryClient'), undef, 'Undef erfolgreich');
	ok(!exists $main::modules{MQTT2_DISCOVERY}{defptr}{client}, 'Undef entfernt nur eigenen Registry-Eintrag');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{server}, $first, 'andere Registry-Zuordnung bleibt erhalten');
};

subtest 'modify wechselt IODev ohne veraltete Registrierung' => sub {
	reset_env();
	add_iodev('serverA', 'MQTT2_SERVER');
	add_iodev('serverB', 'MQTT2_SERVER');
	my ($hash, $define_error) = define_discovery('discovery', 'serverA');
	is($define_error, undef, 'Ausgangsdefinition ist gueltig');
	$hash->{helper}{queue} = { order => [], messages => {}, scheduled => 1 };

	$hash->{OLDDEF} = 'serverA';
	my $modify_error = main::MQTT2_DISCOVERY_Define(
		$hash, 'discovery MQTT2_DISCOVERY serverB'
	);
	delete $hash->{OLDDEF};

	is($modify_error, undef, 'Wechsel auf anderes IODev ist erfolgreich');
	ok(!exists $main::modules{MQTT2_DISCOVERY}{defptr}{serverA},
		'alte IODev-Registrierung wurde entfernt');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{serverB}, $hash,
		'neue IODev-Registrierung zeigt auf dasselbe Device');
	is($hash->{IODevName}, 'serverB', 'interne IODev-Zuordnung wurde aktualisiert');
	ok(!exists $hash->{helper}{queue}, 'ausstehende Arbeit des alten IODev wurde verworfen');
};

subtest 'fehlgeschlagenes modify erhaelt bisherige Registrierung' => sub {
	reset_env();
	add_iodev('serverA', 'MQTT2_SERVER');
	add_iodev('serverB', 'MQTT2_SERVER');
	my ($hash, $define_error) = define_discovery('discoveryA', 'serverA');
	my ($occupied, $occupied_error) = define_discovery('discoveryB', 'serverB');
	is($define_error, undef, 'erste Ausgangsdefinition ist gueltig');
	is($occupied_error, undef, 'zweite Ausgangsdefinition ist gueltig');

	$hash->{OLDDEF} = 'serverA';
	my $modify_error = main::MQTT2_DISCOVERY_Define(
		$hash, 'discoveryA MQTT2_DISCOVERY serverB'
	);
	delete $hash->{OLDDEF};

	like($modify_error, qr/bereits discoveryB definiert/,
		'belegtes Ziel-IODev wird abgelehnt');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{serverA}, $hash,
		'bisherige Registrierung bleibt nach Fehler erhalten');
	is($main::modules{MQTT2_DISCOVERY}{defptr}{serverB}, $occupied,
		'bestehende Registrierung des Ziel-IODev bleibt unveraendert');
	is($hash->{IODevName}, 'serverA', 'interne IODev-Zuordnung bleibt unveraendert');
};

subtest 'Kontextbezogene Commandref-Hilfe' => sub {
	reset_env();
	add_iodev('server');
	define_discovery('discovery', 'server');

	open my $module_file, '<', 'FHEM/10_MQTT2_DISCOVERY.pm'
		or die "Moduldatei kann nicht gelesen werden: $!";
	my $commandref = do { local $/; <$module_file> };
	close $module_file;
	for my $anchor (qw(
		MQTT2_DISCOVERY-set-activate MQTT2_DISCOVERY-set-deactivate MQTT2_DISCOVERY-set-rescan
		MQTT2_DISCOVERY-attr-discoveryPrefixes MQTT2_DISCOVERY-attr-deviceNamePrefix
		MQTT2_DISCOVERY-attr-existingDevice MQTT2_DISCOVERY-attr-autoCreate
		MQTT2_DISCOVERY-attr-autoDelete MQTT2_DISCOVERY-attr-disable
	)) {
		like($commandref, qr/id="\Q$anchor\E"/, "$anchor ist dokumentiert");
	}
};

subtest 'Attributvalidierung' => sub {
	reset_env();
	add_iodev('server');
	define_discovery('discovery', 'server');
	is(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'discoveryPrefixes', 'homeassistant, ha,homeassistant'), undef, 'mehrere Prefixe sind gueltig');
	like(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'discoveryPrefixes', 'homeassistant,,ha'), qr/nicht leer/, 'leerer Prefix wird abgelehnt');
	like(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'discoveryPrefixes', 'homeassistant/#'), qr/Ungueltiger/, 'Wildcard wird abgelehnt');
	is(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'existingDevice', 'replace'), undef, 'replace ist gueltig');
	like(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'existingDevice', 'force'), qr/muss/, 'unbekannter Modus wird abgelehnt');
	like(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'autoDelete', 'yes'), qr/0 oder 1/, 'Boolean wird validiert');
	is(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'deviceNamePrefix', 'MQTT2_'), undef, 'sicherer Device-Prefix ist gueltig');
	like(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'deviceNamePrefix', 'bad prefix'), qr/darf nur/, 'Leerzeichen im Device-Prefix werden abgelehnt');
	like(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'deviceNamePrefix', '2bad'), qr/beginnen/, 'ungueltiger Anfang im Device-Prefix wird abgelehnt');
	like(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'disable', 'yes'), qr/0 oder 1/, 'disable wird validiert');
	is(main::MQTT2_DISCOVERY_Attr('set', 'discovery', 'disable', '1'), undef, 'disable=1 ist gueltig');
	is(reading_value('discovery', 'state'), 'disabled', 'disable=1 wird im Status sichtbar');
	is(main::MQTT2_DISCOVERY_Attr('del', 'discovery', 'disable'), undef, 'disable kann geloescht werden');
	is(reading_value('discovery', 'state'), 'inactive', 'Loeschen stellt den Parserstatus wieder her');
};

subtest 'gespeichertes disable gilt bereits beim Define' => sub {
	reset_env();
	add_iodev('server');
	$main::attr{startupDiscovery}{disable} = 1;
	my ($hash, $error) = define_discovery('startupDiscovery', 'server');
	is($error, undef, 'Device wird mit vorhandenem disable-Attribut definiert');
	is(reading_value('startupDiscovery', 'state'), 'disabled', 'Startzustand ist disabled');
	is(main::MQTT2_DISCOVERY_Set($hash, 'startupDiscovery', 'activate'), undef,
		'Parserposition kann trotz disable vorbereitet werden');
	is(reading_value('startupDiscovery', 'state'), 'disabled', 'activate umgeht disable nicht');
};

subtest 'activate und deactivate erhalten fremde Clients' => sub {
	reset_env();
	my $io = add_iodev('server');
	$io->{Clients} = ':CUSTOM:MQTT2_DEVICE:MQTT_GENERIC_BRIDGE:';
	my ($hash) = define_discovery('discovery', 'server');
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'activate'), undef, 'activate erfolgreich');
	is(attr_value('server', 'clientOrder'), 'CUSTOM MQTT2_DISCOVERY MQTT2_DEVICE MQTT_GENERIC_BRIDGE', 'Discovery wird vor MQTT2_DEVICE eingefuegt');
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'activate'), undef, 'zweites activate erfolgreich');
	is(attr_value('server', 'clientOrder'), 'CUSTOM MQTT2_DISCOVERY MQTT2_DEVICE MQTT_GENERIC_BRIDGE', 'activate ist idempotent');
	is(reading_value('discovery', 'state'), 'active', 'Status ist active');
	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'deactivate'), undef, 'deactivate erfolgreich');
	is(attr_value('server', 'clientOrder'), 'CUSTOM MQTT2_DEVICE MQTT_GENERIC_BRIDGE', 'nur eigener Eintrag wird entfernt');
};

subtest 'Rescan-Grenzen' => sub {
	reset_env();
	add_iodev('client', 'MQTT2_CLIENT');
	my ($client_hash) = define_discovery('clientDiscovery', 'client');
	like(main::MQTT2_DISCOVERY_Set($client_hash, 'clientDiscovery', 'rescan'), qr/keinen lokalen Retain-Cache/, 'Client meldet ehrliche Grenze');

	my $server = add_iodev('server', 'MQTT2_SERVER');
	$server->{retain}{'homeassistant/sensor/node/temp/config'} = {
		val => '{"stat_t":"node/temp","uniq_id":"temp","dev":{"ids":["node"],"name":"Node"}}',
	};
	$server->{retain}{'homeassistant/sensor/node/humidity/config'} = {
		val => '{"stat_t":"node/humidity","uniq_id":"humidity","dev":{"ids":["node"],"name":"Node"}}',
	};
	my ($server_hash) = define_discovery('serverDiscovery', 'server');
	my $before_rescan = scalar @{ command_log() };
	is(main::MQTT2_DISCOVERY_Set($server_hash, 'serverDiscovery', 'rescan'), undef, 'Server-Rescan verarbeitet Cache');
	my @rescan_commands = @{ command_log() }[$before_rescan .. $#{ command_log() }];
	is(reading_value('serverDiscovery', 'discoveredEntities'), 2, 'Rescan hat beide Entities registriert');
	is(reading_value('serverDiscovery', 'lastRescan'), 'processed=2 failed=0', 'Rescan-Ergebnis ist nachvollziehbar');
	is(scalar(grep { /^attr Node readingList / } @rescan_commands), 1,
		'Rescan schreibt readingList pro Zieldevice nur einmal');

	$main::attr{serverDiscovery}{disable} = 1;
	like(main::MQTT2_DISCOVERY_Set($server_hash, 'serverDiscovery', 'rescan'), qr/deaktiviert/,
		'deaktiviertes Modul fuehrt keinen Rescan aus');
};

subtest 'Rescan verarbeitet retained Tasmota config und sensors gemeinsam' => sub {
	reset_env();
	my $server = add_iodev('server', 'MQTT2_SERVER');
	$server->{retain}{'tasmota/discovery/AABBCCDDEEFF/config'} = {
		val => '{"dn":"Retained Plug","fn":["Relay"],"mac":"AABBCCDDEEFF","t":"retained_plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1],"state":["OFF","ON"],"so":{"4":0},"ver":1}',
	};
	$server->{retain}{'tasmota/discovery/AABBCCDDEEFF/sensors'} = {
		val => '{"sn":{"ENERGY":{"Power":18,"Voltage":229}},"ver":1}',
	};
	my ($hash, $error) = define_discovery('tasmotaDiscovery', 'server');
	is($error, undef, 'Tasmota-Discovery wird definiert');

	my $before_rescan = scalar @{ command_log() };
	is(main::MQTT2_DISCOVERY_Set($hash, 'tasmotaDiscovery', 'rescan'), undef,
		'Server-Rescan verarbeitet beide Tasmota-Topics');
	my @rescan_commands = @{ command_log() }[$before_rescan .. $#{ command_log() }];

	ok($main::defs{Retained_Plug}, 'retained Tasmota-Discovery verwendet standardmaessig keinen Prefix');
	is(reading_value('tasmotaDiscovery', 'discoveredEntities'), 3,
		'Relay und beide Telemetriesensoren sind registriert');
	is(reading_value('tasmotaDiscovery', 'lastRescan'), 'processed=2 failed=0',
		'beide retained Tasmota-Nachrichten wurden erfolgreich verarbeitet');
	is(scalar(grep { /^attr Retained_Plug readingList / } @rescan_commands), 1,
		'Tasmota-Rescan schreibt die finale readingList nur einmal');
	is(scalar(grep { /^attr Retained_Plug setList / } @rescan_commands), 1,
		'Tasmota-Rescan schreibt die finale setList nur einmal');
};

subtest 'Bestandsmodi und autoCreate' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$main::attr{discovery}{autoCreate} = 0;
	my $payload = '{"stat_t":"node/state","cmd_t":"node/set","uniq_id":"node_power","dev":{"ids":["node"],"name":"Node"}}';
	main::MQTT2_DISCOVERY_process($hash, 'c', 'homeassistant/switch/node/power/config', $payload);
	ok(!$main::defs{Node}, 'autoCreate=0 legt kein Device an');
	like(reading_value('discovery', 'lastError'), qr/autoCreate/, 'autoCreate-Konflikt ist sichtbar');

	reset_env();
	add_iodev('server');
	($hash) = define_discovery('discovery', 'server');
	$main::defs{Node} = { NAME => 'Node', TYPE => 'MQTT2_DEVICE', READINGS => {} };
	$main::attr{discovery}{existingDevice} = 'ignore';
	main::MQTT2_DISCOVERY_process($hash, 'c', 'homeassistant/switch/node/power/config', $payload);
	like(reading_value('discovery', 'lastError'), qr/ignore-Modus/, 'ignore veraendert bestehendes Device nicht');
	ok(!attr_value('Node', 'setList'), 'ignore erzeugt keine Attribute');

	reset_env();
	add_iodev('server');
	($hash) = define_discovery('discovery', 'server');
	$main::defs{Node} = { NAME => 'Node', TYPE => 'MQTT2_DEVICE', READINGS => {} };
	$main::attr{Node}{setList} = "power:on,off manual/topic value\nreboot:noArg manual/reboot 1";
	$main::attr{discovery}{existingDevice} = 'replace';
	is(main::MQTT2_DISCOVERY_process($hash, 'c', 'homeassistant/switch/node/power/config', $payload), 'consumed', 'replace uebernimmt vorhandenes MQTT2_DEVICE');
	like(attr_value('Node', 'setList'), qr/reboot:noArg manual\/reboot 1/, 'replace erhaelt nicht kollidierende manuelle Zeile');
	unlike(attr_value('Node', 'setList'), qr/manual\/topic/, 'replace ersetzt kollidierende manuelle Zeile');
};

subtest 'FHEM-Autocreate-Identitaet folgt CID und bridgeRegexp statt Device-Name' => sub {
	my $payload = '{"stat_t":"sonos/state","cmd_t":"sonos/set","uniq_id":"sonos_power","dev":{"ids":["sonos"],"name":"Neuer Anzeigename"}}';

	reset_env();
	my $io = add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$main::defs{'Sonos.Wintergarten'} = {
		NAME => 'Sonos.Wintergarten', TYPE => 'MQTT2_DEVICE',
		CID => 'RINCON_804AF2CB96C201400', DEF => 'RINCON_804AF2CB96C201400',
		IODev => $io, READINGS => {},
	};
	is(main::MQTT2_DISCOVERY_process(
		$hash, 'RINCON_804AF2CB96C201400',
		'homeassistant/switch/sonos/power/config', $payload,
	), 'consumed', 'vorhandene FHEM-CID wird unabhaengig vom Namen erkannt');
	ok(!$main::defs{Neuer_Anzeigename}, 'kein zweites Device aus dem Discovery-Namen angelegt');
	like(attr_value('Sonos.Wintergarten', 'setList'), qr/sonos\/set/,
		'Discovery erweitert das vorhandene CID-Device konservativ');

	my $old_name = 'Sonos.Wintergarten';
	my $new_name = 'Audio.Wintergarten';
	my $renamed = delete $main::defs{$old_name};
	$renamed->{NAME} = $new_name;
	$main::defs{$new_name} = $renamed;
	$main::attr{$new_name} = delete($main::attr{$old_name}) || {};
	is(main::MQTT2_DISCOVERY_process(
		$hash, 'RINCON_804AF2CB96C201400',
		'homeassistant/switch/sonos/power/config', $payload,
	), 'consumed', 'umbenanntes MQTT2_DEVICE wird ueber seine CID wiedergefunden');
	is($hash->{helper}{registry}{devices}{'server|id|sonos'}{name}, $new_name,
		'Registry uebernimmt den aktuellen FHEM-Namen');
	ok(!$main::defs{$old_name} && !$main::defs{Neuer_Anzeigename},
		'Rename erzeugt kein weiteres Device');

	reset_env();
	$io = add_iodev('server');
	($hash) = define_discovery('discovery', 'server');
	$main::modules{MQTT2_DEVICE}{defptr}{bridge} = {
		'zigbee2mqtt/([^/:]+)(?:/[^:]*)?:.*' => {
			name => '"zigbee_" . $1', parent => 'zigbee2mqtt',
		},
	};
	my $zigbee_payload = '{"stat_t":"zigbee2mqtt/0x00124b/state","uniq_id":"z2m_temp","dev":{"ids":["z2m_0x00124b"],"name":"Temperatursensor"}}';
	is(main::MQTT2_DISCOVERY_process(
		$hash, 'zigbee2mqtt',
		'homeassistant/sensor/z2m_0x00124b/temperature/config', $zigbee_payload,
	), 'consumed', 'bridgeRegexp wird auf das Discovery-State-Topic angewandt');
	is($main::defs{Temperatursensor}{DEF}, 'zigbee_0x00124b',
		'virtuelle Bridge-CID wird wie beim FHEM-Autocreate als DEF verwendet');
	is($main::modules{MQTT2_DEVICE}{defptr}{cid}{'zigbee_0x00124b'},
		[$main::defs{Temperatursensor}],
		'Bridge-Unterdevice ist unter derselben newCid registriert, die FHEM spaeter prueft');
};

subtest 'MQTT2_CLIENT erhaelt stabile virtuelle Discovery-CIDs' => sub {
	reset_env();
	add_iodev('client', 'MQTT2_CLIENT');
	my ($hash) = define_discovery('discovery', 'client');
	my $node = '{"stat_t":"node/state","uniq_id":"node_state","dev":{"ids":["node"],"name":"Node"}}';
	my $other = '{"stat_t":"other/state","uniq_id":"other_state","dev":{"ids":["other"],"name":"Other"}}';

	is(main::MQTT2_DISCOVERY_process(
		$hash, 'shared_client', 'homeassistant/sensor/node/state/config', $node,
	), 'consumed', 'erstes Client-Device wird verarbeitet');
	is(main::MQTT2_DISCOVERY_process(
		$hash, 'shared_client', 'homeassistant/sensor/other/state/config', $other,
	), 'consumed', 'zweites Client-Device wird verarbeitet');

	my $node_cid = $main::defs{Node}{DEF};
	my $other_cid = $main::defs{Other}{DEF};
	like($node_cid, qr/^mqtt2_discovery_[0-9a-f]{16}$/,
		'Client-Device verwendet eine erkennbare virtuelle CID');
	like($other_cid, qr/^mqtt2_discovery_[0-9a-f]{16}$/,
		'zweites Client-Device verwendet ebenfalls eine virtuelle CID');
	isnt($node_cid, $other_cid, 'unterschiedliche Discovery-Identitaeten teilen keine CID');
	ok(!$main::modules{MQTT2_DEVICE}{defptr}{cid}{shared_client},
		'gemeinsame MQTT2_CLIENT-Transport-CID registriert kein Discovery-Ziel');

	my $first_cid = $node_cid;
	is(main::MQTT2_DISCOVERY_process(
		$hash, 'changed_transport', 'homeassistant/sensor/node/state/config', $node,
	), 'consumed', 'wiederholte Discovery bleibt trotz anderer Transport-CID gueltig');
	is($main::defs{Node}{DEF}, $first_cid,
		'virtuelle CID bleibt aus der stabilen Discovery-Identitaet reproduzierbar');

	reset_env();
	add_iodev('client', 'MQTT2_CLIENT');
	($hash) = define_discovery('discovery', 'client');
	$main::modules{MQTT2_DEVICE}{defptr}{bridge} = {
		'node/state:.*' => { name => '"bridge_node"', parent => 'general_bridge' },
	};
	is(main::MQTT2_DISCOVERY_process(
		$hash, 'shared_client', 'homeassistant/sensor/node/state/config', $node,
	), 'consumed', 'Client-Discovery mit passender Bridge-Regel wird verarbeitet');
	is($main::defs{Node}{DEF}, 'bridge_node',
		'vorhandene bridgeRegexp besitzt Vorrang vor der gehashten Fallback-CID');

	reset_env();
	add_iodev('server', 'MQTT2_SERVER');
	($hash) = define_discovery('discovery', 'server');
	is(main::MQTT2_DISCOVERY_process(
		$hash, '', 'homeassistant/sensor/node/state/config', $node,
	), 'consumed', 'Discovery ohne Transport-CID wird verarbeitet');
	like($main::defs{Node}{DEF}, qr/^mqtt2_discovery_[0-9a-f]{16}$/,
		'fehlende Server-CID verwendet denselben sicheren Identity-Fallback');
};

subtest 'optionales SemanticUI-Fertig-Signal folgt dem Device-Aufbau' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	my @integration;
	my $payload = '{"stat_t":"node/state","cmd_t":"node/set","uniq_id":"node_power","dev":{"ids":["node"],"name":"Node"}}';
	$hash->{helper}{gateway} = MQTT2_Discovery::FHEMGateway->new(
		semantic_integration_end => sub {
			my ($name) = @_;
			push @integration, [
				'end', $name,
				attr_value($name, 'readingList') ? 1 : 0,
				attr_value($name, 'setList') ? 1 : 0,
				$main::defs{$name}{SEMANTIC_METADATA} ? 1 : 0,
			];
			return 1;
		},
	);
	is(main::MQTT2_DISCOVERY_process(
		$hash, 'c', 'homeassistant/switch/node/power/config', $payload,
	), 'consumed', 'Discovery mit optionaler SemanticUI-Schnittstelle ist erfolgreich');
	is(\@integration, [
		['end', 'Node', 1, 1, 1],
	], 'Fertig-Signal folgt erst auf Attribute und Metadaten');
};

subtest 'Registry roundtrippt als nicht ausfuehrbares JSON' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	my $payload = '{"stat_t":"node/state","uniq_id":"node_state","unit_of_meas":"\\u00b0C","dev":{"ids":["node"],"name":"Node"}}';
	is(main::MQTT2_DISCOVERY_process($hash, 'c', 'homeassistant/sensor/node/state/config', $payload),
		'consumed', 'Unicode-Metadaten werden verarbeitet');
	my $stored = reading_value('discovery', '.registry');
	like($stored, qr/^\{/, 'Registry ist JSON');
	delete $hash->{helper}{registry};
	my $restored = main::MQTT2_DISCOVERY_registry($hash);
	is($restored->{version}, 1, 'Registry wird aus Reading wiederhergestellt');
	is(scalar keys %{ $restored->{devices} }, 1, 'Registry mit Unicode bleibt beim Roundtrip erhalten');
	my ($record) = values %{ $restored->{devices} };
	my ($mapping) = values %{ $record->{entities} };
	is($mapping->{metadata}{unit}, "\x{b0}C", 'Unicode-Zeichenstring bleibt unveraendert');

	my $stored_bytes = $stored;
	utf8::encode($stored_bytes);
	$hash->{READINGS}{'.registry'}{VAL} = $stored_bytes;
	delete $hash->{helper}{registry};
	my $restored_bytes = main::MQTT2_DISCOVERY_registry($hash);
	($record) = values %{ $restored_bytes->{devices} };
	($mapping) = values %{ $record->{entities} };
	is($mapping->{metadata}{unit}, "\x{b0}C", 'UTF-8-Bytefolge bleibt nach Neustart unveraendert');
};

subtest 'Registry wird beim Start erst nach dem statefile gecacht' => sub {
	reset_env();
	add_iodev('server');
	my ($running) = define_discovery('discovery', 'server');
	my $payload = '{"stat_t":"node/data","val_tpl":"{{ value_json.temperature }}","uniq_id":"node_temperature","dev":{"ids":["node"],"name":"Node"}}';
	is(main::MQTT2_DISCOVERY_process(
		$running, 'c', 'homeassistant/sensor/node/temperature/config', $payload,
	), 'consumed', 'Ausgangszustand fuer den simulierten Neustart wird erzeugt');
	my $stored_registry = reading_value('discovery', '.registry');
	my $reading_list = attr_value('Node', 'readingList');
	my $set_list = attr_value('Node', 'setList');
	my $device_topic = attr_value('Node', 'devicetopic');
	my $cid = $main::defs{Node}{DEF};

	# Beim Neustart werden Config-Definitionen vor den Readings des statefile geladen.
	reset_env();
	add_iodev('server');
	main::CommandDefine(undef, "Node MQTT2_DEVICE $cid server");
	$main::attr{Node}{readingList} = $reading_list;
	$main::attr{Node}{setList} = $set_list;
	$main::attr{Node}{devicetopic} = $device_topic;
	$main::init_done = 0;
	my ($restarted, $define_error) = define_discovery('discovery', 'server');
	is($define_error, undef, 'Discovery-Definition waehrend des Starts ist gueltig');
	ok(!exists($restarted->{helper}{registry}),
		'leerer Vor-statefile-Stand wird nicht im Helper gecacht');
	$restarted->{READINGS}{'.registry'} = { VAL => $stored_registry, TIME => '2026-08-22 12:00:00' };
	$main::init_done = 1;

	is(main::MQTT2_DISCOVERY_process(
		$restarted, 'c', 'homeassistant/sensor/node/temperature/config', $payload,
	), 'consumed', 'retained Discovery wird nach INITIALIZED erneut verarbeitet');
	is(attr_value('Node', 'readingList'), $reading_list,
		'komplexe JSON-readingList-Zeile wird nach dem Neustart nicht dupliziert');
	my $registry = main::MQTT2_DISCOVERY_registry($restarted);
	my ($record) = values %{ $registry->{devices} };
	ok($record->{created}, 'urspruenglicher Besitzstatus bleibt aus dem statefile erhalten');
};

subtest 'Registry-Klonfehler wird kontrolliert behandelt' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$hash->{helper}{registry}{ungueltig} = sub { return };
	my $status = eval {
		main::MQTT2_DISCOVERY_process(
			$hash, 'c', 'homeassistant/sensor/node/state/config',
			'{"stat_t":"node/state","uniq_id":"node_state","dev":{"ids":["node"],"name":"Node"}}',
		);
	};
	is($@, '', 'JSON-Exception verlaesst den Verarbeitungsweg nicht');
	is($status, 'error', 'Verarbeitung meldet einen kontrollierten Fehler');
	like(reading_value('discovery', 'lastError'), qr/Registry konnte nicht kopiert werden/,
		'Decoderfehler ist im Reading sichtbar');
	ok(!$main::defs{Node}, 'vor dem Fehler wird kein MQTT2_DEVICE angelegt');
};

subtest 'Unerwartete Verarbeitungsfehler bleiben innerhalb des Moduls' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	my ($status, $exception);
	{
		no warnings qw(once redefine);
		local *MQTT2_Discovery::Mapper::map_model = sub { die "simulierter Mapperfehler\n" };
		$status = eval {
			main::MQTT2_DISCOVERY_process(
				$hash, 'c', 'homeassistant/sensor/node/state/config',
				'{"stat_t":"node/state","uniq_id":"node_state","dev":{"ids":["node"],"name":"Node"}}',
			);
		};
		$exception = $@;
	}
	is($exception, '', 'unerwartete Exception erreicht FHEM nicht');
	is($status, 'error', 'Exception wird in einen kontrollierten Status uebersetzt');
	like(reading_value('discovery', 'lastError'), qr/Unerwarteter Fehler in der MQTT-Verarbeitung/,
		'unerwarteter Fehler ist im Reading sichtbar');
	ok(!$main::defs{Node}, 'fehlgeschlagene Abbildung legt kein Device an');
};

subtest 'Logging- und Registry-Schutz' => sub {
	{
		no warnings qw(once redefine);
		local *main::MQTT2_DISCOVERY_log_redacted = sub { die "simulierter Loggingfehler\n" };
		is(main::MQTT2_DISCOVERY_log_payload('{}'), '<invalid or unloggable JSON; length=2>',
			'Loggingfehler wird durch einen sicheren Platzhalter ersetzt');
	}

	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$hash->{READINGS}{'.registry'}{VAL} = '{"version":1,"devices":{"defekt":"kein Objekt"}}';
	delete $hash->{helper}{registry};
	my $registry = main::MQTT2_DISCOVERY_registry($hash);
	is($registry->{devices}, {}, 'strukturell defekte Registry wird verworfen');
	is(eval { main::MQTT2_DISCOVERY_update_counts($hash); 1 }, 1,
		'Zaehler bleiben bei defekter gespeicherter Registry stabil');
};

subtest 'Discovery-Fehler bleiben ihrem Topic zugeordnet' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	is(main::MQTT2_DISCOVERY_process(
			$hash, 'c', 'homeassistant/sensor/node/bad/config', '{'),
		'error', 'defekte HA-Discovery wird abgelehnt');
	is(reading_value('discovery', 'errorCount'), 1, 'Fehlerzaehler wird gesetzt');
	is(reading_value('discovery', 'lastErrorAdapter'), 'homeassistant', 'Adapter ist sichtbar');
	is(reading_value('discovery', 'lastErrorTopic'),
		'homeassistant/sensor/node/bad/config', 'fehlerhaftes Topic ist sichtbar');

	is(main::MQTT2_DISCOVERY_process(
			$hash, 'c', 'homeassistant/sensor/node/good/config',
			'{"stat_t":"node/good","dev":{"ids":["node"],"name":"Node"}}'),
		'consumed', 'anderes gueltiges Topic wird verarbeitet');
	is(reading_value('discovery', 'errorCount'), 1,
		'fremder Erfolg verdeckt den bestehenden Fehler nicht');
	isnt(reading_value('discovery', 'lastError'), 'none', 'Fehlerstatus bleibt sichtbar');

	is(main::MQTT2_DISCOVERY_process(
			$hash, 'c', 'homeassistant/sensor/node/bad/config',
			'{"stat_t":"node/bad","dev":{"ids":["node"],"name":"Node"}}'),
		'consumed', 'korrigiertes Topic wird verarbeitet');
	is(reading_value('discovery', 'errorCount'), 0, 'Korrektur entfernt genau diesen Fehler');
	is(reading_value('discovery', 'lastError'), 'none', 'Fehlerstatus ist wieder sauber');
};

subtest 'Logging folgt verbose 1 bis 5 und schwärzt Payloads' => sub {
	reset_env();
	add_iodev('server');
	my ($hash) = define_discovery('discovery', 'server');
	$main::attr{discovery}{verbose} = 1;
	@{ log_entries() } = ();
	is(main::MQTT2_DISCOVERY_process($hash, 'c', 'homeassistant/sensor/node/temp/config', '{'), 'error',
		'Parserfehler wird verarbeitet');
	is(scalar(@{ log_entries() }), 1, 'verbose 1 schreibt nur den Fehler');
	is(log_entries()->[0][1], 1, 'Fehler verwendet Log-Level 1');
	like(log_entries()->[0][2], qr/MQTT2_DISCOVERY discovery: parser error/, 'Logzeile hat einheitlichen Prefix');

	for my $verbose (2 .. 5) {
		reset_env();
		add_iodev('server');
		($hash) = define_discovery('discovery', 'server');
		$main::attr{discovery}{verbose} = $verbose;
		@{ log_entries() } = ();
		my $payload = '{"stat_t":"node/temp","uniq_id":"temp","password":"very-secret",'
			. '"dev":{"ids":["node"],"name":"Node","api_token":"also-secret"}}';
		is(main::MQTT2_DISCOVERY_process($hash, 'client', 'homeassistant/sensor/node/temp/config', $payload),
			'consumed', "verbose $verbose verarbeitet Discovery");
		ok(!(grep { $_->[1] > $verbose } @{ log_entries() }), "verbose $verbose unterdrueckt hoehere Stufen");
		ok((grep { $_->[1] == $verbose } @{ log_entries() }), "verbose $verbose erzeugt Meldungen seiner Stufe");
	}
	my $log = join("\n", map { $_->[2] } @{ log_entries() });
	like($log, qr/discovery payload=/, 'verbose 5 protokolliert den bereinigten Payload');
	like($log, qr/\[REDACTED\]/, 'sensible Felder werden geschwaerzt');
	unlike($log, qr/very-secret|also-secret/, 'Geheimnisse erscheinen nicht im Log');
};

subtest 'keine save-Aufrufe' => sub {
	my $commands = join("\n", @{ command_log() });
	unlike($commands, qr/(?:^|\s)save(?:\s|$)/, 'Testumgebung sah niemals save');
};

done_testing;

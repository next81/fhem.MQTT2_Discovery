# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Mapper ();

my $prefixes = ['homeassistant', 'tasmota/discovery'];

# Liefert ein kontrolliertes Adapterergebnis fuer Format- und Modellvertragstests.
sub consume {
	my ($topic, $payload, $states) = @_;
	return MQTT2_Discovery::FormatRegistry::consume(
		topic => $topic, payload => $payload, prefixes => $prefixes,
		states => $states || {},
	);
}

subtest 'gemeinsame Parser-Modell-Grenze validiert Ergebnisse' => sub {
	my $missing = MQTT2_Discovery::Model::from_parser_result(
		adapter => 'test', parsed => undef,
	);
	is([$missing->{status}, $missing->{adapter}, $missing->{error_class}],
		['error', 'test', 'format'], 'unstrukturiertes Parserergebnis wird kontrolliert abgewiesen');

	my $invalid = MQTT2_Discovery::Model::from_parser_result(
		adapter => 'test', parsed => { status => 'ok', entities => [{}] },
	);
	is([$invalid->{status}, $invalid->{adapter}, $invalid->{error_class}],
		['error', 'test', 'canonical'], 'ungueltige Parser-Entity scheitert an der kanonischen Grenze');
};

subtest 'grobe Formaterkennung trennt Discovery von State' => sub {
	is(consume('zigbee2mqtt/wohnzimmer', '{"temperature":21}')->{status}, 'next',
		'normales Zigbee2MQTT-State-Topic wird nicht beansprucht');
	is(consume('homeassistant/sensor/node/temperature/state', '21')->{status}, 'next',
		'HA-aehnliches State-Topic wird nicht als Discovery behandelt');
	my $bad = consume('homeassistant/sensor/node/temperature/config', '{');
	is([$bad->{status}, $bad->{adapter}, $bad->{error_class}],
		['error', 'homeassistant', 'json'],
		'erkannte, aber defekte HA-Discovery faellt nicht auf ein anderes Format zurueck');
};

subtest 'Home Assistant normalisiert in Modellversion 1' => sub {
	my $result = consume(
		'homeassistant/switch/node/power/config',
		'{"stat_t":"node/state/power","cmd_t":"node/command/power","pl_on":"1","pl_off":"0","dev":{"ids":["node"],"name":"Node"}}',
	);
	is([$result->{status}, $result->{adapter}], ['ok', 'homeassistant'], 'HA-Adapter wurde ausgewaehlt');
	my $event = $result->{events}[0];
	is($event->{schema_version}, 1, 'kanonische Modellversion ist explizit');
	is($event->{entity}{kind}, 'switch', 'Geraeteklasse ist normalisiert');
	is($event->{signals}[0]{topic}, 'node/state/power', 'State-Kanal ist als Signal beschrieben');
	is($event->{commands}[0]{topic}, 'node/command/power', 'Command-Kanal ist separat beschrieben');
	is([$event->{capabilities}{power}{read}, $event->{capabilities}{power}{write}],
		['state', 'command'], 'Capability verbindet Signal und Command ausdruecklich');
	is(MQTT2_Discovery::Model::validate($event), undef, 'kanonisches Modell ist gueltig');
	my $mapping = MQTT2_Discovery::Mapper::map_model(model => $event, io_name => 'mqtt');
	ok($mapping->{ok}, 'allgemeiner Mapper verarbeitet das Modell ohne Formatparser');
};

subtest 'Tasmota gewinnt vor dem HA-Fallback und liefert generische Zusatzsignale' => sub {
	my %states;
	my $config = '{"dn":"Plug","mac":"AABBCCDDEEFF","state":["OFF","ON"],"t":"plug","ft":"%prefix%/%topic%/","tp":["cmnd","stat","tele"],"rl":[1],"ver":1}';
	my $result = consume('tasmota/discovery/AABBCCDDEEFF/config', $config, \%states);
	is([$result->{status}, $result->{adapter}], ['ok', 'tasmota'], 'spezifischer Tasmota-Adapter wurde ausgewaehlt');
	my ($upsert) = grep { $_->{operation} eq 'upsert' } @{ $result->{events} };
	ok($upsert, 'Tasmota liefert ein kanonisches Upsert');
	is($upsert->{schema_version}, 1, 'auch Tasmota verwendet dieselbe Modellversion');
	is([map { $_->{type} } @{ $upsert->{extensions}{supplemental_signals} }],
		[qw(payload json_flatten json_flatten json_flatten json_sequence json_flatten payload)],
		'Tasmota-Profil ist als allgemeine Signaltypen normalisiert');
};

done_testing;

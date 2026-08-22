# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::DevicePlanner ();

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => { one => { device_topic => 'node' } } },
	[{ topic => 'node/state' }, { topic => 'node/command' }],
), 'node', 'gemeinsames Devicetopic wird ohne FHEM-Zustand bestimmt');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} }, [{ topic => 'home/+/RTL_433toMQTT/model/42' }],
), 'home', 'Devicetopic endet vor einer MQTT-Wildcard');
is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} }, [{ topic => '+/+/RTL_433toMQTT/model/42' }],
), undef, 'fuehrende MQTT-Wildcards werden nicht als Devicetopic verwendet');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => { light => { device_topic => 'zigbee2mqtt' } } },
	[
		{ topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT' },
		{ topic => 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT/set' },
		{ topic => 'zigbee2mqtt/bridge/state', role => 'availability' },
	],
), 'zigbee2mqtt/WZ_LIGHTSTRIP_LICHT',
	'tiefer gemeinsamer Nutzdatenstamm gewinnt gegen einen allgemeineren Parser-Vorschlag');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} },
	[
		{ topic => 'tele/plug/STATE' },
		{ topic => 'stat/plug/RESULT' },
		{ topic => 'cmnd/plug/POWER' },
	],
), undef, 'Tasmota-Standardtopics erhalten kein kuenstliches gemeinsames Prefix');

is(MQTT2_Discovery::DevicePlanner::device_topic(
	{ entities => {} },
	[
		{ topic => 'plug/tele/STATE' },
		{ topic => 'plug/stat/RESULT' },
		{ topic => 'plug/cmnd/POWER' },
	],
), 'plug', 'ein device-first Tasmota-FullTopic kann den sicheren gemeinsamen Stamm nutzen');

my @conflicts;
my ($prepared, $current) = MQTT2_Discovery::DevicePlanner::prepare_json_readings(
	'conservative', 'manual/topic:.* temperature', [],
	[{ kind => 'json_reading', name => 'temperature', topic => 'node/state' }],
	\@conflicts,
);
is($prepared, [], 'manuelle JSON-Kollision gewinnt im konservativen Modus');
is($current, 'manual/topic:.* temperature', 'manuelle Konfiguration bleibt unveraendert');
is(\@conflicts, ['temperature'], 'Konflikt wird deklarativ gemeldet');

my $plan = MQTT2_Discovery::DevicePlanner::attribute_plan(
	device => 'node', manage_device_topic => 1, device_topic => 'node',
	previous_device_topic_exists => 0,
	reading_list => 'state', previous_reading_list_exists => 1,
	previous_reading_list => 'old-state',
	set_list => 'power', previous_set_list_exists => 0,
);
is([map { $_->{attribute} } @{ $plan->actions }],
	[qw(devicetopic readingList setList)],
	'Device-Plan beschreibt die atomare Schreibreihenfolge');

done_testing;

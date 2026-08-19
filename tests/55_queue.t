# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM', 'tests/lib';
use FHEMTestEnv qw(reset_env add_iodev define_discovery reading_value);

our @TIMERS;

# Liefert eine feste Zeitbasis fuer reproduzierbare Timertermine.
sub main::gettimeofday { return 1_700_000_000 }
# Speichert geplante FHEM-Timer, ohne einen echten Event-Loop zu starten.
sub main::InternalTimer {
	my ($when, $function, $argument, $wait_if_init_not_done) = @_;
	push @TIMERS, [$when, $function, $argument, $wait_if_init_not_done];
	return;
}
# Entfernt passende Timer aus der simulierten Timerwarteschlange.
sub main::RemoveInternalTimer {
	my ($argument, $function) = @_;
	@TIMERS = grep { $_->[2] != $argument || $_->[1] ne $function } @TIMERS;
	return;
}

my $loaded = do './FHEM/10_MQTT2_DISCOVERY.pm';
die $@ if $@;
die $! if !defined $loaded;

# Fuehrt den zeitlich naechsten gespeicherten Timer synchron im Test aus.
sub run_next_timer {
	my $timer = shift @TIMERS or die 'Kein Timer eingeplant';
	my $function = $timer->[1];
	no strict 'refs';
	&{ "main::$function" }($timer->[2]);
}

# Erstellt fuer jeden Queue-Test eine frische Discovery- und IODev-Umgebung.
sub setup {
	@TIMERS = ();
	reset_env();
	my $io = add_iodev('mqtt', 'MQTT2_SERVER');
	my ($hash, $error) = define_discovery('discovery', 'mqtt');
	die $error if $error;
	$main::attr{discovery}{deviceNamePrefix} = 'MQTT2_';
	return ($hash, $io);
}

# Verpackt Topic und Payload im von FHEMs MQTT-Dispatch verwendeten Nullbyteformat.
sub mqtt_message {
	my ($topic, $payload) = @_;
	return "autocreate=simple\0client\0$topic\0$payload";
}

subtest 'Parse legt Arbeit ab und konsumiert Discovery sofort' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/temp","dev":{"ids":["node"],"name":"Node"}}';

	is(main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload)), '',
		'Discovery wird konsumiert');
	ok(!$main::defs{MQTT2_Node}, 'Device wird nicht im MQTT-Dispatch angelegt');
	is(scalar(@TIMERS), 1, 'genau ein Worker-Timer ist eingeplant');

	run_next_timer();
	ok($main::defs{MQTT2_Node}, 'erster Timer bereitet die Discovery-Nachricht vor');
	ok(!$main::attr{MQTT2_Node}{readingList}, 'Device-Attribute warten auf einen eigenen Timer-Tick');
	is($main::modules{MQTT2_DEVICE}{defptr}{cid}{client}, [$main::defs{MQTT2_Node}],
		'Define registriert das Ziel sofort in FHEMs CID-Index');
	is(scalar(@TIMERS), 1, 'Attributphase ist separat eingeplant');

	run_next_timer();
	like($main::attr{MQTT2_Node}{readingList}, qr/(?:\$DEVICETOPIC|node)\/temp/,
		'zweiter Timer schreibt die vorbereiteten Device-Attribute');
	my ($reading_regexp) = split /\s+/, $main::attr{MQTT2_Node}{readingList}, 2;
	$reading_regexp =~ s/\$DEVICETOPIC/node/g;
	ok("node/temp:{\"temperature\":21}" =~ m/^$reading_regexp$/s,
		'fertige readingList setzt FHEMs fnd vor dem Autocreate-Zweig');
	is(reading_value('discovery', 'discoveredEntities'), 1, 'Zaehler ist nach Batch-Abschluss aktuell');
	is(scalar(@TIMERS), 0, 'leere Queue plant keinen weiteren Timer');
};

subtest 'regulaeres Autocreate vor dem Discovery-Worker wird uebernommen' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/temp","dev":{"ids":["node"],"name":"Node"}}';

	is(main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload)), '',
		'Discovery wird vor MQTT2_DEVICE konsumiert und eingeplant');
	is(main::CommandDefine(undef, 'client MQTT2_DEVICE client mqtt'), undef,
		'simuliertes State-Autocreate legt die Transport-CID vor dem Worker an');

	run_next_timer() while @TIMERS;
	ok(!$main::defs{MQTT2_Node}, 'Discovery legt kein zweites vorgeschlagenes Device an');
	like($main::attr{client}{readingList}, qr/(?:\$DEVICETOPIC|node)\/temp/,
		'Discovery uebernimmt und erweitert das zwischenzeitlich autocreated Device');
	is($hash->{helper}{registry}{devices}{'mqtt|id|node'}{name}, 'client',
		'Discovery-Registry zeigt auf das bereits vorhandene CID-Device');
};

subtest 'Burst wird portioniert und identische Topics werden zusammengefasst' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $first = '{"uniq_id":"node_temp","stat_t":"node/old","dev":{"ids":["node"],"name":"Node"}}';
	my $latest = '{"uniq_id":"node_temp","stat_t":"node/latest","dev":{"ids":["node"],"name":"Node"}}';
	my $other = '{"uniq_id":"other_temp","stat_t":"other/temp","dev":{"ids":["other"],"name":"Other"}}';

	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $first));
	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $latest));
	main::MQTT2_DISCOVERY_Parse($io,
		mqtt_message('homeassistant/sensor/other/temp/config', $other));
	is(scalar(@TIMERS), 1, 'Burst plant nur einen Start-Timer');

	run_next_timer();
	ok($main::defs{MQTT2_Node}, 'erstes Topic wurde vorbereitet');
	ok(!$main::attr{MQTT2_Node}{readingList}, 'erstes Topic schreibt noch keine Attribute');
	ok(!$main::defs{MQTT2_Other}, 'zweites Topic wartet auf den naechsten Tick');
	is(scalar(@TIMERS), 1, 'naechster Tick ist eingeplant');

	run_next_timer();
	ok($main::defs{MQTT2_Other}, 'zweites Topic wird im naechsten Tick vorbereitet');
	ok(!$main::attr{MQTT2_Node}{readingList} && !$main::attr{MQTT2_Other}{readingList},
		'nach der Topic-Phase sind noch keine Device-Attribute geschrieben');

	run_next_timer();
	is(scalar(grep { $main::attr{$_}{readingList} } qw(MQTT2_Node MQTT2_Other)), 1,
		'ein Timer-Tick aktualisiert hoechstens ein Zieldevice');
	is(scalar(@TIMERS), 1, 'zweites Zieldevice bleibt eingeplant');

	run_next_timer();
	like($main::attr{MQTT2_Node}{readingList}, qr/(?:\$DEVICETOPIC|node)\/latest/,
		'nur der neueste Stand des zusammengefassten Topics wird verwendet');
	ok($main::attr{MQTT2_Other}{readingList}, 'zweites Zieldevice wurde aktualisiert');
	is(reading_value('discovery', 'discoveredEntities'), 2, 'beide Topic-Staende sind registriert');
};

subtest 'ein Burst persistiert die Registry nur einmal' => sub {
	my ($hash, $io) = setup();
	my $original = \&main::readingsSingleUpdate;
	my $registry_writes = 0;

	{
		no warnings qw(redefine);
		local *main::readingsSingleUpdate = sub($$$$) {
			++$registry_writes if $_[1] eq '.registry';
			return $original->(@_);
		};
		for my $index (1 .. 20) {
			my $payload = qq({"uniq_id":"node_$index","stat_t":"node/$index",)
				. qq("dev":{"ids":["node"],"name":"Node"}});
			main::MQTT2_DISCOVERY_Parse($io,
				mqtt_message("homeassistant/sensor/node/value_$index/config", $payload));
		}
		run_next_timer() while @TIMERS;
	}

	is($registry_writes, 1, 'Registry wird nicht mehr fuer jedes einzelne Topic serialisiert');
	is(reading_value('discovery', 'discoveredEntities'), 20, 'der gesamte Burst wurde uebernommen');
};

subtest 'retained Delete wird ebenfalls portioniert' => sub {
	my ($hash, $io) = setup();
	my $topic = 'homeassistant/sensor/node/temp/config';
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/temp","dev":{"ids":["node"],"name":"Node"}}';
	$main::attr{discovery}{autoDelete} = 1;

	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, $payload));
	run_next_timer() while @TIMERS;
	ok($main::defs{MQTT2_Node}, 'Ausgangsdevice wurde angelegt');

	main::MQTT2_DISCOVERY_Parse($io, mqtt_message($topic, ''));
	run_next_timer();
	ok($main::defs{MQTT2_Node}, 'Topic-Tick entfernt das Device noch nicht im selben Event-Loop-Lauf');
	is(scalar(@TIMERS), 1, 'Device-Aktualisierung des Deletes ist separat eingeplant');

	run_next_timer();
	ok(!$main::defs{MQTT2_Node}, 'Device-Tick fuehrt autoDelete kontrolliert aus');
	is(reading_value('discovery', 'discoveredEntities'), 0, 'Registry ist nach Delete leer');
};

subtest 'deactivate verwirft noch nicht verarbeitete Arbeit' => sub {
	my ($hash, $io) = setup();
	my $payload = '{"uniq_id":"node_temp","stat_t":"node/temp","dev":{"ids":["node"],"name":"Node"}}';
	main::MQTT2_DISCOVERY_Parse($io,
		mqtt_message('homeassistant/sensor/node/temp/config', $payload));

	is(main::MQTT2_DISCOVERY_Set($hash, 'discovery', 'deactivate'), undef,
		'deactivate ist erfolgreich');
	is(scalar(@TIMERS), 0, 'Queue-Timer wurde entfernt');
	ok(!$main::defs{MQTT2_Node}, 'verworfene Arbeit hat keine Nebenwirkung');
};

done_testing;

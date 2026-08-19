# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::Mapper::Common qw(
	capability_set_name choice_values is_device_root_entity is_numeric temperature_unit
);

my ($tokens, $mapping, $read_mapping) = choice_values([
	'eco', 'eco', 'A B', 'A,B', undef, {}, "ungueltig\n",
]);
is($tokens->[0], 'eco', 'erster gueltiger Auswahlwert bleibt unveraendert');
is(scalar(grep { $_ eq 'eco' } @$tokens), 1, 'identische Auswahlwerte werden entfernt');
is($tokens->[1], 'A_B', 'unsichere Zeichen werden in einen stabilen Token uebersetzt');
like($tokens->[2], qr/^A_B_[0-9a-f]{4,}$/, 'Token-Kollision erhaelt einen stabilen Suffix');
is($mapping->{ $tokens->[2] }, 'A,B', 'kollidierender Token behaelt seinen Originalwert');
is($read_mapping->{'A,B'}, $tokens->[2], 'Rueckabbildung verwendet denselben Kollisions-Token');
is(scalar(keys %$mapping), 3, 'nur eindeutige gueltige Werte werden abgebildet');

ok(is_numeric('-1.5'), 'Dezimalzahl wird erkannt');
ok(is_numeric('.5'), 'Dezimalzahl ohne fuehrende Null wird erkannt');
ok(!is_numeric('1e3'), 'Exponentialschreibweise bleibt ausgeschlossen');
ok(!is_numeric([]), 'Referenzen sind keine numerischen Metadaten');

is(temperature_unit(undef), "\x{b0}C", 'fehlende Temperatureinheit verwendet Celsius');
is(temperature_unit('F'), "\x{b0}F", 'Fahrenheit wird normalisiert');
is(temperature_unit('K'), 'K', 'andere skalare Einheiten bleiben erhalten');

my $root = { _canonical_root => 1 };
ok(is_device_root_entity($root), 'kanonische Root-Entity wird erkannt');
is(capability_set_name($root, 'climate', 'target-temperature'), 'target_temperature',
	'Root-Capability verwendet einen eigenstaendigen sicheren Set-Namen');
is(capability_set_name({}, 'climate', 'mode'), 'climate_mode',
	'Unter-Entity qualifiziert den Set-Namen mit dem Reading');

done_testing;

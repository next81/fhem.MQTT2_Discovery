# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::Helper qw(
	trim stable_unique safe_name stable_suffix split_lines line_key merge_generated_lines
);

is(trim(" \t Hallo \n"), 'Hallo', 'trim entfernt Rand-Whitespace');
is([ stable_unique(qw(a b a c b)) ], [qw(a b c)], 'Deduplizierung ist stabil');
is(safe_name(' Küche / Licht ', 'device'), 'K_che_Licht', 'unsichere Zeichen werden ersetzt');
is(safe_name('42', 'device'), 'd_42', 'Name beginnt sicher');
is(safe_name('pac-1b96f8', 'device'), 'pac_1b96f8', 'Bindestrich wird fuer FHEM-Devicenamen ersetzt');
is(length(stable_suffix('identitaet')), 8, 'stabiler Suffix hat Defaultlaenge');
is([ split_lines("a\r\nb\n") ], [qw(a b)], 'Zeilen werden portabel zerlegt');
is(line_key('set', 'power:on,off topic value'), 'power', 'Set-Schluessel wird erkannt');
is(line_key('reading', 'topic:.* state'), 'state', 'Reading-Schluessel wird erkannt');
is(line_key('reading', "topic:.* { MQTT2_DISCOVERY_runtimeReading('{{ value | upper }}', \$EVENT, 'state') }"),
	'state', 'Reading-Schluessel wird aus lesbarem Runtime-Aufruf erkannt');

subtest 'konservativer Merge' => sub {
	my $result = merge_generated_lines(
		kind => 'set', mode => 'conservative',
		current => "reboot:noArg device/reboot 1\npower:on,off old/topic value",
		previous_owned => ['power:on,off old/topic value'],
		generated => [
			{ name => 'power', line => 'power:on,off new/topic value' },
			{ name => 'reboot', line => 'reboot:noArg generated/topic 1' },
		],
	);
	is($result->{value}, "reboot:noArg device/reboot 1\npower:on,off new/topic value", 'alte eigene Zeile wird ersetzt');
	is($result->{conflicts}, ['reboot'], 'manuelle Kollision wird gemeldet');
};

subtest 'replace entfernt nur kollidierende manuelle Zeile' => sub {
	my $result = merge_generated_lines(
		kind => 'set', mode => 'replace', current => "reboot:noArg manual 1\nkeep:noArg manual 2",
		generated => [{ name => 'reboot', line => 'reboot:noArg generated 1' }],
	);
	is($result->{value}, "keep:noArg manual 2\nreboot:noArg generated 1", 'nicht kollidierende Zeile bleibt erhalten');
	is($result->{conflicts}, [], 'replace meldet keinen Konflikt');
};

done_testing;

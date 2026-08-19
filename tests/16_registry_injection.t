# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::FormatRegistry ();

{
	package Local::FormatAdapter;
	# Kennzeichnet den lokalen Testadapter eindeutig in Registry-Ergebnissen.
	sub id { return 'local'; }
	# Beansprucht ausschliesslich Topics des lokalen Testnamensraums.
	sub claims { my (%args) = @_; return ($args{topic} || '') =~ m{^local/}; }
	# Liefert ein minimales erfolgreiches Adapterergebnis fuer die Registry-Tests.
	sub consume {
		my (%args) = @_;
		++$args{state}{calls};
		return { status => 'ok', events => [{ operation => 'upsert' }] };
	}
}

{
	package Local::BrokenAdapter;
	# Kennzeichnet den absichtlich unvollstaendigen Adapter fuer Vertragstests.
	sub id { return 'broken'; }
}

my $states = {};
my $result = MQTT2_Discovery::FormatRegistry::consume(
	topic => 'local/config', payload => '{}', states => $states,
	adapters => ['Local::FormatAdapter'],
);
is($result->{adapter}, 'local', 'injizierter Adapter wird verwendet');
is($states->{local}{calls}, 1, 'zustandsbehafteter Adapter erhaelt seinen isolierten Zustand');

is(MQTT2_Discovery::FormatRegistry::consume(
	topic => 'other/config', adapters => ['Local::FormatAdapter'],
), { status => 'next' }, 'nicht beanspruchtes Topic wird weitergereicht');

like(MQTT2_Discovery::FormatRegistry::consume(
	topic => 'broken/config', adapters => ['Local::BrokenAdapter'],
)->{error}, qr/implementiert/, 'unvollstaendiger Adapter wird kontrolliert abgelehnt');

done_testing;

# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::FormatRegistry;

use strict;
use warnings;
use MQTT2_Discovery::Format::Tasmota ();
use MQTT2_Discovery::Format::HomeAssistant ();


# Spezifische Formate stehen vor dem allgemeineren HA-Discovery-Adapter.
my @ADAPTERS = (
	'MQTT2_Discovery::Format::Tasmota',
	'MQTT2_Discovery::Format::HomeAssistant',
);

# Loest eine Adaptermethode nur auf, wenn Adaptername und Implementierung gueltig sind.
sub _method {
	my ($adapter, $method) = @_;
	return undef if !defined($adapter) || ref($adapter);
	return $adapter->can($method);
}

# Die Registry ist die einzige Stelle, die Adapter auswaehlt. Parser und
# Mapper bleiben dadurch vom konkreten Discovery-Format entkoppelt.
sub consume {
	my (%args) = @_;
	my $states = ref($args{states}) eq 'HASH' ? $args{states} : {};
	my @adapters = ref($args{adapters}) eq 'ARRAY' ? @{ delete $args{adapters} } : @ADAPTERS;

	for my $adapter (@adapters) {
		# Jeder Adapter muss denselben kleinen Vertrag vollstaendig erfuellen.
		my $claims = _method($adapter, 'claims');
		my $id_method = _method($adapter, 'id');
		my $consume = _method($adapter, 'consume');
		return {
			status => 'error', adapter => 'registry', error_class => 'format',
			error => 'Formatadapter implementiert id, claims oder consume nicht vollstaendig',
		} if !$claims || !$id_method || !$consume;

		# Nur der erste Adapter, der das Topic beansprucht, darf es verarbeiten.
		next if !$claims->(%args);
		my $id = $id_method->();
		my $state = $states->{$id} ||= {};
		my $result = $consume->(%args, state => $state);
		return {
			status => 'error', adapter => $id, error_class => 'format',
			error => "$id lieferte kein strukturiertes Ergebnis",
		} if ref($result) ne 'HASH';

		# Nach einem positiven claims waere "next" mehrdeutig und koennte einen
		# defekten Formatadapter still an den naechsten Parser weiterreichen.
		if (($result->{status} || '') eq 'next') {
			return {
				status => 'error', adapter => $id, error_class => 'format',
				error => "$id hat das Topic beansprucht, aber nicht verarbeitet",
			};
		}
		$result->{adapter} ||= $id;
		return $result;
	}

	return { status => 'next' };
}

1;

# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::ActionPlan;

use strict;
use warnings;


# Ein ActionPlan sammelt zusammengehoerige FHEM-Aenderungen, bevor die erste
# davon ausgefuehrt wird. Dadurch kann ein Fehler den vorherigen Stand
# bestmoeglich wiederherstellen.
sub new {
	my ($class) = @_;
	return bless { actions => [] }, $class;
}

# Liefert eine defensive Kopie aller geplanten Aenderungen zur Diagnose oder Kontrolle.
sub actions {
	my ($self) = @_;

	# Aufrufer erhalten Kopien und koennen den internen Plan nicht veraendern.
	return [ map { +{ %$_ } } @{ $self->{actions} } ];
}

# Haengt eine validierte Attributaenderung samt Ruecksprungwert an den Plan an.
sub set_attribute {
	my ($self, %args) = @_;

	# Fehler im Plan sollen vor dem ersten FHEM-Kommando auffallen.
	die 'device fehlt' if !defined($args{device}) || ref($args{device}) || $args{device} eq '';
	die 'attribute fehlt' if !defined($args{attribute}) || ref($args{attribute}) || $args{attribute} eq '';
	push @{ $self->{actions} }, {
		type            => 'set_attribute',
		device          => $args{device},
		attribute       => $args{attribute},
		value           => $args{value},
		previous_exists => $args{previous_exists} ? 1 : 0,
		previous_value  => $args{previous_value},
	};
	return $self;
}

# Fuehrt den Plan der Reihe nach aus und rollt erfolgreiche Schritte bei Fehlern zurueck.
sub execute {
	my ($self, $gateway) = @_;
	die 'gateway fehlt' if !ref($gateway) || !$gateway->can('set_attribute');
	my @applied;

	for my $action (@{ $self->{actions} }) {
		my $error = $gateway->set_attribute(
			$action->{device}, $action->{attribute}, $action->{value},
		);

		# Jeder Teilfehler macht den gesamten Plan ungueltig und startet den
		# Rollback der bereits erfolgreich ausgefuehrten Attribute.
		if ($error) {
			# Rueckwaerts rollen, damit abhaengige Aenderungen in umgekehrter
			# Reihenfolge zurueckgenommen werden.
			my @rollback_errors;

			for my $rollback (reverse @applied) {
				my $rollback_error = $gateway->set_attribute(
					$rollback->{device}, $rollback->{attribute},
					$rollback->{previous_exists} ? $rollback->{previous_value} : '',
				);
				push @rollback_errors, $rollback_error if $rollback_error;
			}

			return @rollback_errors
				? "$error; Rollback fehlgeschlagen: " . join('; ', @rollback_errors)
				: $error;
		}
		push @applied, $action;
	}

	return undef;
}

1;

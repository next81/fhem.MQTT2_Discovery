# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::ActionPlan ();

{
	package Local::PlanGateway;
	# Erzeugt ein Gateway-Double mit Attributzustand, Aufrufprotokoll und Fehlerpunkt.
	sub new { return bless { values => $_[1] || {}, calls => [], fail => $_[2] }, $_[0]; }
	# Simuliert idempotente Attributaenderungen und einen konfigurierbaren Teilfehler.
	sub set_attribute {
		my ($self, $device, $attribute, $value) = @_;
		push @{ $self->{calls} }, [$device, $attribute, $value];
		return 'simulierter Schreibfehler' if defined($self->{fail}) && $attribute eq $self->{fail};
		if (defined($value) && $value ne '') {
			$self->{values}{$device}{$attribute} = $value;
		} else {
			delete $self->{values}{$device}{$attribute};
		}
		return undef;
	}
}

subtest 'Plan beschreibt Seiteneffekte ohne sie auszufuehren' => sub {
	my $plan = MQTT2_Discovery::ActionPlan->new()
		->set_attribute(
			device => 'device', attribute => 'readingList', value => 'new',
			previous_exists => 1, previous_value => 'old',
		);
	is($plan->actions, [{
		type => 'set_attribute', device => 'device', attribute => 'readingList', value => 'new',
		previous_exists => 1, previous_value => 'old',
	}], 'Aktionsplan ist vor der Ausfuehrung vollstaendig inspizierbar');
};

subtest 'erfolgreicher Plan wird in Reihenfolge ausgefuehrt' => sub {
	my $gateway = Local::PlanGateway->new({ device => { readingList => 'old' } });
	my $plan = MQTT2_Discovery::ActionPlan->new()
		->set_attribute(
			device => 'device', attribute => 'readingList', value => 'new',
			previous_exists => 1, previous_value => 'old',
		)
		->set_attribute(
			device => 'device', attribute => 'setList', value => 'setter',
			previous_exists => 0,
		);
	is($plan->execute($gateway), undef, 'Plan ist erfolgreich');
	is($gateway->{values}{device}, { readingList => 'new', setList => 'setter' },
		'alle Aenderungen wurden angewendet');
};

subtest 'Fehler rollt bereits ausgefuehrte Aktionen zurueck' => sub {
	my $gateway = Local::PlanGateway->new(
		{ device => { readingList => 'old' } }, 'setList',
	);
	my $plan = MQTT2_Discovery::ActionPlan->new()
		->set_attribute(
			device => 'device', attribute => 'readingList', value => 'new',
			previous_exists => 1, previous_value => 'old',
		)
		->set_attribute(
			device => 'device', attribute => 'setList', value => 'setter',
			previous_exists => 0,
		);
	like($plan->execute($gateway), qr/Schreibfehler/, 'Fehler wird an den Aufrufer gemeldet');
	is($gateway->{values}{device}, { readingList => 'old' },
		'vorheriger Zustand ist wiederhergestellt');
	is($gateway->{calls}, [
		['device', 'readingList', 'new'],
		['device', 'setList', 'setter'],
		['device', 'readingList', 'old'],
	], 'Rollback erfolgt in umgekehrter Reihenfolge');
};

done_testing;

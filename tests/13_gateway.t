# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
use MQTT2_Discovery::FHEMGateway ();

my (%attributes, @commands, @readings, @timers, @integrations, @cid_lookups);
my $gateway = MQTT2_Discovery::FHEMGateway->new(
	attr_value => sub {
		my ($device, $attribute, $default) = @_;
		return exists($attributes{$device}{$attribute}) ? $attributes{$device}{$attribute} : $default;
	},
	attribute_state => sub {
		my ($device, $attribute) = @_;
		return exists($attributes{$device}{$attribute})
			? (1, $attributes{$device}{$attribute}) : (0, undef);
	},
	command_attr => sub {
		my ($definition) = @_;
		push @commands, "attr $definition";
		my ($device, $attribute, $value) = split /\s+/, $definition, 3;
		$attributes{$device}{$attribute} = $value;
		return undef;
	},
	command_delete_attr => sub {
		my ($definition) = @_;
		push @commands, "deleteattr $definition";
		my ($device, $attribute) = split /\s+/, $definition, 2;
		delete $attributes{$device}{$attribute};
		return undef;
	},
	update_reading => sub { push @readings, [@_]; return undef; },
	schedule => sub { push @timers, [@_]; return undef; },
	semantic_integration_end => sub { push @integrations, ['end', @_]; return 1; },
	mqtt2_devices_for_cid => sub {
		push @cid_lookups, $_[0];
		return [{ NAME => 'UmbenanntesDevice', TYPE => 'MQTT2_DEVICE', CID => $_[0] }];
	},
);

is($gateway->attr_value('device', 'missing', 'fallback'), 'fallback',
	'Lesezugriff ist injizierbar');
is($gateway->mqtt2_devices_for_cid('client-id')->[0]{NAME}, 'UmbenanntesDevice',
	'FHEM-CID-Zuordnung ist ueber das Gateway injizierbar');
is(\@cid_lookups, ['client-id'], 'CID wird unveraendert an die Zielaufloesung uebergeben');
is($gateway->set_attribute('device', 'mode', 'auto'), undef, 'Attribut wird geschrieben');
is($gateway->set_attribute('device', 'mode', 'auto'), undef, 'identischer Wert ist ein No-op');
is($gateway->set_attribute('device', 'mode', ''), undef, 'Attribut wird geloescht');
is(\@commands, ['attr device mode auto', 'deleteattr device mode'],
	'Gateway dedupliziert und kapselt konkrete FHEM-Kommandos');

$gateway->update_reading({ NAME => 'discovery' }, 'state', 'active', 1);
$gateway->schedule(0.01, { NAME => 'discovery' }, 'callback');
is($readings[0][1], 'state', 'Reading-Callback erhaelt den Reading-Namen');
is($timers[0][2], 'callback', 'Timer-Callback erhaelt die Zielfunktion');
ok($gateway->can_schedule, 'injizierter Scheduler ist erkennbar');
$gateway->semantic_integration_end('NeuesDevice');
is(\@integrations, [
	['end', 'NeuesDevice'],
], 'optionales Fertig-Signal ist injizierbar');

done_testing;

# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Format::HomeAssistant;

use strict;
use warnings;
use MQTT2_Discovery::Parser::HomeAssistant ();
use MQTT2_Discovery::Model ();


# Liefert die stabile Kennung fuer Registry, Status und Fehlerzuordnung.
sub id { return 'homeassistant'; }

# Erkennt Home-Assistant-Config-Topics innerhalb der konfigurierten Prefixe.
sub claims {
	my (%args) = @_;
	my $topic = $args{topic};
	return 0 if !defined($topic) || ref($topic) || $topic !~ m{/config$};

	for my $prefix (@{ $args{prefixes} || ['homeassistant'] }) {
		next if !defined($prefix) || ref($prefix) || $prefix eq '';
		return 1 if index($topic, "$prefix/") == 0;
	}

	return 0;
}

# Parst das beanspruchte Topic und uebergibt die gemeinsame Modellbildung an Model.
sub consume {
	my (%args) = @_;
	my $parsed = MQTT2_Discovery::Parser::HomeAssistant::parse(%args);
	return MQTT2_Discovery::Model::from_parser_result(adapter => id(), parsed => $parsed);
}

1;

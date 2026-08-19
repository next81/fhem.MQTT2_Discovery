# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Format::Tasmota;

use strict;
use warnings;
use MQTT2_Discovery::Parser::Tasmota ();
use MQTT2_Discovery::Model ();


# Liefert die stabile Kennung fuer Registry, Status und Fehlerzuordnung.
sub id { return 'tasmota'; }

# Delegiert die Topic-Erkennung an den Tasmota-Parser und normalisiert das Ergebnis.
sub claims {
	my (%args) = @_;
	return MQTT2_Discovery::Parser::Tasmota::matches(%args) ? 1 : 0;
}

# Parst das beanspruchte Topic und uebergibt die gemeinsame Modellbildung an Model.
sub consume {
	my (%args) = @_;
	my $parsed = MQTT2_Discovery::Parser::Tasmota::parse(%args);
	return MQTT2_Discovery::Model::from_parser_result(adapter => id(), parsed => $parsed);
}

1;

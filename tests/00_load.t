# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use lib 'lib/FHEM';
no warnings qw(once);

# FHEM declares Log3 with a prototype; keep that contract visible while
# compiling the gateway so variadic forwarding cannot hide load-time errors.
# Deklariert FHEMs Logfunktion vor, damit das Hauptmodul im isolierten Test kompiliert.
sub Log3($$$);

ok(eval { require MQTT2_Discovery::Helper; 1 }, 'Helper laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Parser::HomeAssistant; 1 }, 'Home-Assistant-Parser laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Parser::Tasmota; 1 }, 'Tasmota-Parser laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Template; 1 }, 'Template laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Mapper; 1 }, 'Mapper laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Model; 1 }, 'Kanonisches Modell laedt') or diag $@;
ok(eval { require MQTT2_Discovery::FormatRegistry; 1 }, 'Format-Registry laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Format::HomeAssistant; 1 }, 'HA-Formatadapter laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Format::Tasmota; 1 }, 'Tasmota-Formatadapter laedt') or diag $@;
ok(eval { require MQTT2_Discovery::FHEMGateway; 1 }, 'FHEM-Gateway laedt') or diag $@;
ok(eval { require MQTT2_Discovery::ActionPlan; 1 }, 'Aktionsplan laedt') or diag $@;
ok(eval { require MQTT2_Discovery::DevicePlanner; 1 }, 'Device-Planer laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Mapper::NameResolver; 1 }, 'Namensaufloesung laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Mapper::Common; 1 }, 'Gemeinsame Mapper-Hilfen laden') or diag $@;
ok(eval { require MQTT2_Discovery::Mapper::Renderer; 1 }, 'Renderer laedt') or diag $@;
ok(eval { require MQTT2_Discovery::Mapper::Semantics; 1 }, 'Semantic-Mapper laedt') or diag $@;

is($MQTT2_Discovery::Model::SCHEMA_VERSION, 1, 'Version des kanonischen Modells');
ok(!$INC{'Test/More.pm'}, 'Produktionsmodule laden Test::More nicht');

done_testing;

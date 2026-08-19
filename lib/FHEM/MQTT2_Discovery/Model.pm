# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Model;

use strict;
use warnings;

our $SCHEMA_VERSION = 1;

# Diese Mengen bilden die bewusst kleine, validierbare Aussengrenze des
# kanonischen Modells. Neue Operationen oder Klassen muessen hier freigegeben
# und anschliessend vom Mapper unterstuetzt werden.
my %OPERATION = map { $_ => 1 } qw(upsert delete delete_device);
my %KIND = map { $_ => 1 } qw(
	sensor binary_sensor switch button number select text light cover fan lock climate
	device_tracker event device_automation
);

my %INTERNAL = map { $_ => 1 } qw(
	operation prefix format component node_id object_id discovery_topic entity_key
	component_key unique_id name device raw_metadata
);

# Die Tabellen beschreiben, welche Discovery-Felder ein logisches Lese- oder
# Schreibsignal speisen. Damit bleibt from_entity frei von langen Sonderfaellen.
my @SIGNAL_BINDINGS = (
	[state => 'state_topic', 'value_template'],
	[action => 'action_topic', 'action_template'],
	[brightness => 'brightness_state_topic', 'brightness_value_template'],
	[color_temperature => 'color_temp_state_topic', 'color_temp_value_template'],
	[rgb => 'rgb_state_topic', 'rgb_value_template'],
	[effect => 'effect_state_topic', 'effect_value_template'],
	[white => 'white_state_topic', 'white_value_template'],
	[position => 'position_topic', 'position_template'],
	[tilt => 'tilt_status_topic', 'tilt_status_template'],
	[percentage => 'percentage_state_topic', 'percentage_value_template'],
	[current_temperature => 'current_temperature_topic', 'current_temperature_template'],
	[current_humidity => 'current_humidity_topic', 'current_humidity_template'],
	[target_temperature => 'temperature_state_topic', 'temperature_state_template'],
	[target_temperature_high => 'temperature_high_state_topic', 'temperature_high_state_template'],
	[target_temperature_low => 'temperature_low_state_topic', 'temperature_low_state_template'],
	[target_humidity => 'target_humidity_state_topic', 'target_humidity_state_template'],
	[mode => 'mode_state_topic', 'mode_state_template'],
	[fan_mode => 'fan_mode_state_topic', 'fan_mode_state_template'],
	[swing_mode => 'swing_mode_state_topic', 'swing_mode_state_template'],
	[swing_horizontal_mode => 'swing_horizontal_mode_state_topic', 'swing_horizontal_mode_state_template'],
	[preset_mode => 'preset_mode_state_topic', 'preset_mode_value_template'],
);

my @COMMAND_BINDINGS = (
	[command => 'command_topic', 'command_template'],
	[brightness => 'brightness_command_topic', undef],
	[color_temperature => 'color_temp_command_topic', undef],
	[rgb => 'rgb_command_topic', undef],
	[effect => 'effect_command_topic', undef],
	[white => 'white_command_topic', undef],
	[position => 'position_command_topic', undef],
	[tilt => 'tilt_command_topic', undef],
	[percentage => 'percentage_command_topic', undef],
	[target_temperature => 'temperature_command_topic', 'temperature_command_template'],
	[target_temperature_high => 'temperature_high_command_topic', 'temperature_high_command_template'],
	[target_temperature_low => 'temperature_low_command_topic', 'temperature_low_command_template'],
	[target_humidity => 'target_humidity_command_topic', 'target_humidity_command_template'],
	[mode => 'mode_command_topic', 'mode_command_template'],
	[fan_mode => 'fan_mode_command_topic', 'fan_mode_command_template'],
	[swing_mode => 'swing_mode_command_topic', 'swing_mode_command_template'],
	[swing_horizontal_mode => 'swing_horizontal_mode_command_topic', 'swing_horizontal_mode_command_template'],
	[preset_mode => 'preset_mode_command_topic', 'preset_mode_command_template'],
	[power => 'power_command_topic', 'power_command_template'],
);

# Normalisiert einzelne oder mehrere Topic-Bindings in eine kanonische Liste.
sub _binding_list {
	my ($configuration, $specs) = @_;
	my @bindings;

	for my $spec (@$specs) {
		my ($id, $topic_key, $template_key) = @$spec;
		my $topic = $configuration->{$topic_key};
		next if !defined($topic) || ref($topic) || $topic eq '';
		my %binding = (id => $id, topic => $topic);

		# Ein Template gehoert nur dann ins Binding, wenn das Format dafuer ein
		# konkretes Feld definiert hat.
		$binding{template} = $configuration->{$template_key}
			if defined($template_key) && defined($configuration->{$template_key});
		push @bindings, \%binding;
	}

	return \@bindings;
}

# Ueberfuehrt komponentenspezifische Eigenschaften in ein einheitliches Capability-Modell.
sub _capabilities {
	my ($kind, $signals, $commands, $configuration) = @_;
	$kind = '' if !defined $kind;
	my %read = map { ($_->{id} => 1) } @$signals;
	my %write = map { ($_->{id} => 1) } @$commands;
	my %capabilities;

	# Die Closure legt eine Capability nur an, wenn mindestens eine ihrer
	# Richtungen im Entity-Modell tatsaechlich vorhanden ist.
	my $add = sub {
		my ($name, $read_id, $write_id) = @_;
		my %capability;
		$capability{read} = $read_id if defined($read_id) && $read{$read_id};
		$capability{write} = $write_id if defined($write_id) && $write{$write_id};
		return if !%capability;
		$capability{value} = {
			type => $kind eq 'binary_sensor' || $kind eq 'switch' ? 'boolean'
				: $kind eq 'number' ? 'number'
				: $kind eq 'select' ? 'enum' : 'string',
			(defined($configuration->{unit_of_measurement})
				? (unit => $configuration->{unit_of_measurement}) : ()),
			(defined($configuration->{device_class})
				? (device_class => $configuration->{device_class}) : ()),
			(defined($configuration->{state_class})
				? (state_class => $configuration->{state_class}) : ()),
		};

		for my $key (qw(min max step options)) {
			$capability{value}{$key} = $configuration->{$key} if defined($configuration->{$key});
		}

		$capabilities{$name} = \%capability;
	};

	# Die Geraeteklasse bestimmt das fachliche Capability-Vokabular und damit,
	# welche vorhandenen Signal-/Command-Bindings miteinander verknuepft werden.
	if ($kind eq 'sensor' || $kind eq 'text' || $kind eq 'event'
			|| $kind eq 'number' || $kind eq 'select') {
		$add->('value', 'state', 'command');
	} elsif ($kind eq 'binary_sensor' || $kind eq 'device_tracker') {
		$add->('state', 'state', undef);
	} elsif ($kind eq 'switch') {
		$add->('power', 'state', 'command');
	} elsif ($kind eq 'button') {
		$add->('press', undef, 'command');
	} elsif ($kind eq 'climate') {

		for my $id (qw(current_temperature current_humidity target_temperature
				target_temperature_high target_temperature_low target_humidity mode fan_mode
				swing_mode swing_horizontal_mode preset_mode action power)) {
			$add->($id, $id, $id);
		}

	} elsif ($kind eq 'light') {
		$add->('power', 'state', 'command');
		$add->($_, $_, $_) for qw(brightness color_temperature rgb effect white);
	} elsif ($kind eq 'cover') {
		$add->('state', 'state', undef);
		$add->('action', undef, 'command');
		$add->($_, $_, $_) for qw(position tilt);
	} elsif ($kind eq 'fan') {
		$add->('power', 'state', 'command');
		$add->('percentage', 'percentage', 'percentage');
	} elsif ($kind eq 'lock') {
		$add->('state', 'state', undef);
		$add->('action', undef, 'command');
	}
	return \%capabilities;
}

# Bereinigt optionale Reading-Metadaten auf die vom Mapper verstandenen Felder.
sub _normalise_reading_profile {
	my ($profile) = @_;
	return undef if ref($profile) ne 'HASH';
	my ($telemetry_base, $stat_base) = @{$profile}{qw(telemetry_base stat_base)};
	return undef if !defined($telemetry_base) || ref($telemetry_base) || $telemetry_base eq ''
		|| !defined($stat_base) || ref($stat_base) || $stat_base eq '';

	# Das Profil beschreibt Tasmota-Standardtelemetrie deklarativ. Der Mapper
	# muss dadurch keine Tasmota-Topicstruktur kennen.
	my @signals = (
		{ type => 'payload', topic => "$telemetry_base/LWT", name => 'LWT' },
		(map { +{ type => 'json_flatten', topic => "$telemetry_base/$_", name => $_ } }
			qw(STATE SENSOR UPTIME)),
		{
			type => 'json_sequence', topic => "$telemetry_base/INFO", name => 'INFO',
			key_prefix => 'Info', parts => [1, 2, 3], unwrap_single_property => 1,
		},
		{ type => 'json_flatten', topic => "$stat_base/RESULT", name => 'RESULT' },
	);

	for my $power (@{ ref($profile->{power_readings}) eq 'ARRAY' ? $profile->{power_readings} : [] }) {
		next if ref($power) ne 'HASH';
		my ($command, $reading) = @{$power}{qw(command reading)};
		next if !defined($command) || ref($command) || $command !~ /^POWER\d*$/
			|| !defined($reading) || ref($reading) || $reading !~ /^POWER\d*$/;
		push @signals, { type => 'payload', topic => "$stat_base/$command", name => $reading };
	}

	return \@signals;
}

# Konvertiert eine Parser-Entity in ein formatunabhaengiges kanonisches Event.
sub from_entity {
	my (%args) = @_;
	my $source = $args{entity};
	return undef if ref($source) ne 'HASH';
	my $operation = $source->{operation} || 'upsert';
	my $raw = ref($source->{raw_metadata}) eq 'HASH' ? $source->{raw_metadata} : {};
	my %configuration = map { ($_ => $source->{$_}) }
		grep { !$INTERNAL{$_} } keys %$source;

	# Einzelne Discovery-Felder wurden historisch nur im Rohobjekt benoetigt.
	for my $key (qw(payload_press brightness json_autocreate json_reading_name state_reading_name)) {
		$configuration{$key} = $raw->{$key} if exists($raw->{$key}) && !exists($configuration{$key});
	}

	my $layout = $source->{format} || 'entity';
	my $component = $source->{component};
	my $signals = _binding_list(\%configuration, \@SIGNAL_BINDINGS);
	my $commands = _binding_list(\%configuration, \@COMMAND_BINDINGS);

	# Ab diesem Punkt werden Protokolldetails nur noch als Source/Extensions
	# transportiert; die Kernfelder haben fuer alle Adapter dieselbe Bedeutung.
	my $model = {
		schema_version => $SCHEMA_VERSION,
		operation => $operation,
		source => {
			adapter => $args{adapter} || 'unknown',
			prefix  => $source->{prefix},
			topic   => $source->{discovery_topic},
			key     => $source->{entity_key},
			layout  => $layout,
		},
		device => ref($source->{device}) eq 'HASH' ? { %{ $source->{device} } } : {},
		entity => {
			id            => $source->{object_id},
			component_key => $source->{component_key},
			kind          => $component,
			node_id       => $source->{node_id},
			unique_id     => $source->{unique_id},
			name          => $source->{name},
			category      => $source->{entity_category},
			configuration => \%configuration,
		},
		signals => $signals,
		commands => $commands,
		capabilities => _capabilities($component, $signals, $commands, \%configuration),
		availability => [],
		extensions => {},
	};

	push @{ $model->{availability} }, { topic => $configuration{availability_topic} }
		if defined($configuration{availability_topic}) && !ref($configuration{availability_topic});
	push @{ $model->{availability} }, map { ref($_) eq 'HASH' ? { %$_ } : $_ }
		@{ $configuration{availability} }
			if ref($configuration{availability}) eq 'ARRAY';

	$model->{extensions}{device_topic} = $raw->{'~'}
		if defined($raw->{'~'}) && !ref($raw->{'~'});

	for my $key (qw(json_autocreate json_reading_name state_reading_name)) {
		$model->{extensions}{$key} = $configuration{$key} if exists($configuration{$key});
	}

	my $profile = _normalise_reading_profile($raw->{tasmota_reading_profile});
	$model->{extensions}{supplemental_signals} = $profile if $profile;

	# Die Root-Markierung ist eine Adapterentscheidung. Der Mapper muss weder
	# object_id noch protokollspezifische Device-Namen interpretieren.
	my $device_name = $model->{device}{name};

	# Nur zwei skalare Namen erlauben einen stabilen Vergleich; bei fehlenden
	# Angaben bleibt die Entity vorsichtshalber eine normale Unter-Entity.
	if (defined($source->{object_id}) && !ref($source->{object_id})
			&& defined($device_name) && !ref($device_name)) {
		require MQTT2_Discovery::Helper;
		$model->{entity}{root} = MQTT2_Discovery::Helper::safe_name($source->{object_id}, 'entity')
			eq MQTT2_Discovery::Helper::safe_name($device_name, 'device') ? 1 : 0;
	}

	return $model;
}

# Validiert Struktur und Pflichtfelder eines kanonischen Events ohne Seiteneffekte.
sub validate {
	my ($model) = @_;
	return 'Kanonisches Discovery-Modell fehlt' if ref($model) ne 'HASH';
	return 'Nicht unterstuetzte Modellversion'
		if !defined($model->{schema_version}) || $model->{schema_version} != $SCHEMA_VERSION;
	return 'Ungueltige kanonische Operation'
		if !defined($model->{operation}) || !$OPERATION{$model->{operation}};
	return 'Kanonische Quelle fehlt' if ref($model->{source}) ne 'HASH';
	return 'Kanonischer Quellschluessel fehlt'
		if !defined($model->{source}{key}) || ref($model->{source}{key}) || $model->{source}{key} eq '';
	return undef if $model->{operation} ne 'upsert';

	# Delete-Events benoetigen nur ihre Quelle. Die strengeren Entity-Pruefungen
	# gelten ausschliesslich fuer neu anzulegende oder zu aktualisierende Daten.
	return 'Kanonische Entity fehlt' if ref($model->{entity}) ne 'HASH';
	return 'Nicht unterstuetzte kanonische Geraeteklasse'
		if !defined($model->{entity}{kind}) || !$KIND{$model->{entity}{kind}};
	return 'Kanonische Konfiguration fehlt' if ref($model->{entity}{configuration}) ne 'HASH';
	return 'Kanonische Signals-Liste fehlt' if ref($model->{signals}) ne 'ARRAY';
	return 'Kanonische Commands-Liste fehlt' if ref($model->{commands}) ne 'ARRAY';
	return 'Kanonische Capabilities fehlen' if ref($model->{capabilities}) ne 'HASH';

	for my $collection (qw(signals commands availability)) {
		return "Ungueltiger Eintrag in $collection"
			if grep { ref($_) ne 'HASH' } @{ $model->{$collection} || [] };
	}

	my %signal = map { ($_->{id} => 1) } @{ $model->{signals} };
	my %command = map { ($_->{id} => 1) } @{ $model->{commands} };

	# Capabilities duerfen nur auf zuvor deklarierte Bindings verweisen.
	for my $name (keys %{ $model->{capabilities} }) {
		my $capability = $model->{capabilities}{$name};
		return "Ungueltige Capability $name" if ref($capability) ne 'HASH';
		return "Capability $name verweist auf unbekanntes Signal"
			if defined($capability->{read}) && !$signal{$capability->{read}};
		return "Capability $name verweist auf unbekannten Command"
			if defined($capability->{write}) && !$command{$capability->{write}};
	}

	return undef;
}

# Uebersetzt ein erfolgreiches Parserergebnis an einer Stelle in kanonische Events.
sub from_parser_result {
	my (%args) = @_;
	my $parsed = $args{parsed};
	my $adapter = $args{adapter} || 'unknown';
	return {
		status => 'error', adapter => $adapter, error_class => 'format',
		error => "$adapter lieferte kein strukturiertes Parserergebnis",
	} if ref($parsed) ne 'HASH';
	return $parsed if ($parsed->{status} || '') ne 'ok';

	my @events = map { from_entity(adapter => $adapter, entity => $_) }
		@{ $parsed->{entities} || [] };
	for my $event (@events) {
		my $error = validate($event);
		return {
			status => 'error', adapter => $adapter,
			error_class => 'canonical', error => $error,
		} if $error;
	}

	return {
		status => 'ok', adapter => $adapter, events => \@events,
		warnings => $parsed->{warnings} || [],
	};
}

# Rekonstruiert die Entity-Sicht fuer bestehende Delete- und Kompatibilitaetspfade.
sub to_entity {
	my ($model) = @_;
	my $error = validate($model);
	return (undef, $error) if $error;
	my $source = $model->{source};
	my $entity = $model->{entity} || {};
	my %configuration = %{ $entity->{configuration} || {} };

	# Der Mapper verarbeitet aus Kompatibilitaetsgruenden weiterhin die flache
	# Entity-Darstellung. Diese Projektion ist die einzige Rueckuebersetzung.
	my %legacy = (
		%configuration,
		operation       => $model->{operation},
		prefix          => $source->{prefix},
		format          => 'canonical',
		component       => $entity->{kind},
		node_id         => $entity->{node_id},
		object_id       => $entity->{id},
		component_key   => $entity->{component_key},
		unique_id       => $entity->{unique_id},
		name            => $entity->{name},
		discovery_topic => $source->{topic},
		entity_key      => $source->{key},
		device          => ref($model->{device}) eq 'HASH' ? { %{ $model->{device} } } : {},
		_canonical_root => $entity->{root} ? 1 : 0,
		_canonical_layout => $source->{layout},
		_canonical_extensions => $model->{extensions} || {},
	);
	return (\%legacy, undef);
}

1;

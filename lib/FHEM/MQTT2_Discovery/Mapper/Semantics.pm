# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Mapper::Semantics;

use strict;
use warnings;
use Scalar::Util qw(refaddr);
use MQTT2_Discovery::Helper qw(safe_name stable_suffix stable_unique);
use MQTT2_Discovery::Mapper::Common qw(
	capability_set_name choice_values is_device_root_entity is_numeric temperature_unit
);

# Sammelt die expliziten Zielnamen eines abstrakten Mapping-Eintrags.
sub _entry_names {
	my ($entries) = @_;
	return map { (($_->{name} // '') => 1) } grep { ref($_) eq 'HASH' } @{ $entries || [] };
}

# Liefert nur dann einen Set-Namen, wenn der Eintrag genau ein eindeutiges Ziel besitzt.
sub _single_set_name {
	my ($entries, $fallback) = @_;
	my @names = stable_unique(map { $_->{name} }
		grep { ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} ne '' }
			@{ $entries || [] });
	return @names == 1 ? $names[0] : $fallback;
}

# Ermittelt alle Readings, die ein einzelner Mapping-Eintrag erzeugen kann.
sub _entry_read_names {
	my ($entries) = @_;
	my %names;

	for my $entry (grep { ref($_) eq 'HASH' } @{ $entries || [] }) {
		my $semantic_name = $entry->{semantic_name} // $entry->{name} // '';
		next if $semantic_name eq '' || !defined($entry->{name}) || $entry->{name} eq '';
		$names{$semantic_name} //= $entry->{name};
	}

	return %names;
}

# Waehlt den benutzerfreundlichsten verfuegbaren Anzeigenamen fuer eine Entity.
sub _semantic_display_name {
	my ($entity, $reading_name, $component) = @_;
	my $name = $entity->{name};
	my $device_name = ref($entity->{device}) eq 'HASH' ? $entity->{device}{name} : undef;

	# Ein expliziter Entity-Name ist fuer Menschen aussagekraeftiger als ein
	# technischer Reading-Fallback und wird daher bevorzugt sowie gekuerzt.
	if (defined($name) && !ref($name) && $name ne '') {
		# Ein Entity-Name wie "Wohnzimmer Thermostat Temperatur" soll innerhalb
		# des bereits benannten Devices nur noch "Temperatur" anzeigen.
		if (defined($device_name) && !ref($device_name) && $device_name ne '') {
			my @name_parts = grep { $_ ne '' } split /[\s_.-]+/, $name;
			my @device_parts = grep { $_ ne '' } split /[\s_.-]+/, $device_name;
			my $common = 0;
			++$common while $common < @name_parts && $common < @device_parts
				&& lc($name_parts[$common]) eq lc($device_parts[$common]);
			return join(' ', @name_parts[$common .. $#name_parts])
				if $common && $common < @name_parts;
			$name = undef if $common && $common == @name_parts;
		}
		return $name if defined($name) && $name ne '';
	}
	my $fallback = $reading_name;
	$fallback = $component if !defined($fallback) || $fallback eq ''
		|| (defined($device_name) && !ref($device_name)
			&& safe_name($fallback, $component) eq safe_name($device_name, $component));
	$fallback =~ s/[_-]+/ /g;
	return $fallback;
}

# Baut eine einheitliche Ein/Aus-Capability aus den vorhandenen Befehlswerten.
sub _power_capability {
	my (%args) = @_;
	my %capability = (kind => 'boolean');
	$capability{read} = $args{read} if defined $args{read};
	$capability{write} = $args{write} if defined $args{write};
	my $on = $args{payload_on} // 'ON';
	my $off = $args{payload_off} // 'OFF';
	$capability{options} = [$on, $off];
	$capability{activeValue} = $on;
	$capability{inactiveValue} = $off;
	return \%capability;
}

# Erstellt eine tiefe kanonische Kopie reiner Metadaten fuer sichere Komposition.
sub _clone_data {
	my ($value) = @_;
	return { map { $_ => _clone_data($value->{$_}) } keys %$value } if ref($value) eq 'HASH';
	return [ map { _clone_data($_) } @$value ] if ref($value) eq 'ARRAY';
	return $value;
}

# Erzeugt eine stabile ID fuer beim Device-Zusammenfuehren abgeleitete Capabilities.
sub _composed_capability_id {
	my ($value) = @_;
	$value = '' if !defined($value) || ref($value);
	$value =~ s/[^A-Za-z0-9]+/_/g;
	$value =~ s/^_+|_+$//g;
	my @parts = grep { $_ ne '' } split /_+/, $value;
	my $id = @parts ? lc(shift @parts) . join('', map { ucfirst(lc($_)) } @parts) : 'feature';
	$id = 'feature' . ucfirst($id) if $id !~ /^[A-Za-z]/;
	return substr($id, 0, 64);
}

# Fuehrt zusammengehoerige Entity-Capabilities zu einem konsistenten Devicevertrag zusammen.
sub compose_device_entities {
	my ($items) = @_;
	return $items if ref($items) ne 'ARRAY' || !@$items;

	# Nur ein eindeutig identifiziertes Climate-Device darf atomare
	# Neben-Entities als zusaetzliche Capabilities aufnehmen.
	my @primary = grep {
		ref($_) eq 'HASH' && ref($_->{entry}) eq 'HASH'
			&& ($_->{entry}{class} // '') eq 'climate'
			&& ref($_->{mapping}) eq 'HASH' && $_->{mapping}{strong_identity}
	} @$items;
	return $items if @primary != 1;

	my $primary = $primary[0];
	my $target = $primary->{entry}{capabilities};
	return $items if ref($target) ne 'HASH';
	my %used = map { $_ => 1 } keys %$target;
	my %atomic = (
		switch => ['power', 'boolean'],
		select => ['value', 'enum'],
		number => ['value', 'number'],
		text   => ['value', 'text'],
		button => ['press', 'action'],
	);
	my @result;

	for my $item (@$items) {

		# Das primaere Climate-Entity bleibt als sichtbarer Traeger erhalten;
		# nur geeignete Neben-Entities koennen darin aufgehen.
		if (ref($item) eq 'HASH' && refaddr($item) == refaddr($primary)) {
			push @result, $item;
			next;
		}
		my $mapping = ref($item) eq 'HASH' ? $item->{mapping} : undef;
		my $entry = ref($item) eq 'HASH' ? $item->{entry} : undef;
		my $metadata = ref($mapping) eq 'HASH' && ref($mapping->{metadata}) eq 'HASH'
			? $mapping->{metadata} : {};
		my $category = $metadata->{entity_category};
		my $component = $metadata->{component} // (ref($entry) eq 'HASH' ? $entry->{class} : '');
		my $spec = $atomic{$component // ''};
		my $capabilities = ref($entry) eq 'HASH' ? $entry->{capabilities} : undef;
		my @names = ref($capabilities) eq 'HASH' ? keys %$capabilities : ();

		# Diagnose/Config-Entities, nur lesbare Entities oder komplexe Entities
		# bleiben eigenstaendig und werden nicht in das Climate-Device eingezogen.
		if (!ref($mapping) || !$mapping->{strong_identity} || !$spec
				|| (defined($category) && !ref($category) && $category =~ /^(?:config|diagnostic)$/i)
				|| @names != 1 || $names[0] ne $spec->[0]
				|| ref($capabilities->{$spec->[0]}) ne 'HASH'
				|| !defined($capabilities->{$spec->[0]}{write})) {
			push @result, $item;
			next;
		}

		my $id = _composed_capability_id($entry->{id});

		# Eine Kollision wird stabil anhand des Entity-Schluessels aufgeloest.
		$id .= '_' . stable_suffix($item->{entity_key} // $entry->{id} // $component, 6)
			if $used{$id};
		$used{$id} = 1;
		my $capability = _clone_data($capabilities->{$spec->[0]});
		$capability->{kind} = $spec->[1];
		$target->{$id} = $capability;
	}

	return \@result;
}

my %SEMANTIC_SENSOR_DEVICE_CLASS = map { $_ => 1 } qw(
	temperature humidity absolute_humidity battery pressure atmospheric_pressure
	illuminance moisture power aqi carbon_dioxide carbon_monoxide
	pm1 pm25 pm10 gas water
);

my %SEMANTIC_BINARY_SENSOR_DEVICE_CLASS = map { $_ => 1 } qw(
	door garage_door gas lock moisture motion occupancy opening presence safety
	smoke tamper vibration window
);

# Nicht jede technisch gueltige Entity ist fuer eine Bedienoberflaeche
# hilfreich. Schreibbare Funktionen sind erlaubt, reine Sensoren nur mit
# aussagekraeftiger Device-Class; Diagnosewerte bleiben ausgeschlossen.
sub _semantic_entity_is_allowed {
	my ($entity, $sets) = @_;
	my $category = $entity->{entity_category};
	return 0 if defined($category) && !ref($category) && lc($category) eq 'diagnostic';
	return 1 if grep { ref($_) eq 'HASH' && defined($_->{name}) && $_->{name} ne '' }
		@{ $sets || [] };

	my $component = $entity->{component} || '';
	return 1 if $component eq 'climate';
	my $device_class = $entity->{device_class};
	return 0 if !defined($device_class) || ref($device_class) || $device_class eq '';
	return $SEMANTIC_SENSOR_DEVICE_CLASS{$device_class} ? 1 : 0
		if $component eq 'sensor';
	return $SEMANTIC_BINARY_SENSOR_DEVICE_CLASS{$device_class} ? 1 : 0
		if $component eq 'binary_sensor';
	return 0;
}

# Leitet aus Mapping, Komponententyp und Capabilities eine semantische Entity ab.
sub _semantic_entity {
	my ($entity, $reading_name, $readings, $sets) = @_;
	my %read_name = _entry_read_names($readings);
	my %has_set = _entry_names($sets);
	my $component = $entity->{component} || '';
	return undef if $component eq 'device_automation';

	# Protokollspezifische Klassen werden auf die Klassen des semantischen
	# Modells normalisiert.
	my $class = $component eq 'text' || $component eq 'event' ? 'sensor'
		: $component eq 'device_tracker' ? 'binary_sensor' : $component;
	my $semantic_id = is_device_root_entity($entity)
		? safe_name($component, 'entity') : $reading_name;
	my $semantic = {
		id => $semantic_id,
		class => $class,
		name => _semantic_display_name($entity, $reading_name, $component),
		capabilities => {},
	};
	$semantic->{device_class} = $entity->{device_class}
		if defined($entity->{device_class}) && !ref($entity->{device_class}) && $entity->{device_class} ne '';
	$semantic->{state_class} = $entity->{state_class}
		if defined($entity->{state_class}) && !ref($entity->{state_class}) && $entity->{state_class} ne '';
	my $capabilities = $semantic->{capabilities};

	# Jeder Zweig verbindet die bereits gerenderten Reading-/Set-Namen mit den
	# generischen Capabilities. Es werden keine neuen FHEM-Namen erfunden.
	if ($component eq 'sensor' || $component eq 'text' || $component eq 'event') {
		my %value;
		$value{read} = $read_name{$reading_name} if defined($read_name{$reading_name});

		# Nur Text-Entities besitzen in dieser Gruppe einen freien Schreibkanal;
		# Sensor- und Eventwerte bleiben bewusst rein lesbar.
		if ($component eq 'text') {
			my $set_name = _single_set_name($sets, $reading_name);
			$value{write} = $set_name if $has_set{$set_name};
		}
		$value{unit} = $entity->{unit_of_measurement}
			if defined($entity->{unit_of_measurement}) && !ref($entity->{unit_of_measurement});

		# Textfelder erhalten Eingabetyp und optionale Laengenbegrenzung, damit die
		# Oberflaeche keinen unpassenden generischen Werteeditor verwendet.
		if ($component eq 'text') {
			$value{input} = 'text';
			$value{maxLength} = 0 + $entity->{max}
				if defined($entity->{max}) && !ref($entity->{max}) && $entity->{max} =~ /^\d+$/ && $entity->{max} > 0;
		}
		$capabilities->{value} = \%value if keys %value;
	} elsif ($component eq 'binary_sensor' || $component eq 'device_tracker') {

		# Eine binaere Capability ist nur sinnvoll, wenn ihr aktueller Zustand auf
		# ein tatsaechlich erzeugtes Reading verweist.
		if (defined($read_name{$reading_name})) {
			my ($on, $off) = $component eq 'device_tracker'
				? ($entity->{payload_home} // 'home', $entity->{payload_not_home} // 'not_home')
				: ($entity->{payload_on} // 'ON', $entity->{payload_off} // 'OFF');
			$capabilities->{state} = {
				read => $read_name{$reading_name},
				options => [$on, $off], activeValue => $on, inactiveValue => $off,
			};
		}
	} elsif ($component eq 'switch') {
		my $set_name = _single_set_name($sets, $reading_name);
		$capabilities->{power} = _power_capability(
			read => $read_name{$reading_name},
			write => $has_set{$set_name} ? $set_name : undef,
			payload_on => $entity->{payload_on}, payload_off => $entity->{payload_off},
		) if defined($read_name{$reading_name}) || $has_set{$set_name};
	} elsif ($component eq 'button') {
		$capabilities->{press} = { write => $reading_name, argument => 0 } if $has_set{$reading_name};
	} elsif ($component eq 'number') {
		my %value;
		$value{read} = $read_name{$reading_name} if defined($read_name{$reading_name});
		my $set_name = _single_set_name($sets, $reading_name);
		$value{write} = $set_name if $has_set{$set_name};

		for my $key (qw(min max step)) {
			$value{$key} = 0 + $entity->{$key}
				if defined($entity->{$key}) && !ref($entity->{$key}) && $entity->{$key} =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
		}

		$value{unit} = $entity->{unit_of_measurement}
			if defined($entity->{unit_of_measurement}) && !ref($entity->{unit_of_measurement});
		$capabilities->{value} = \%value if exists($value{read}) || exists($value{write});
	} elsif ($component eq 'select') {
		my $set_name = _single_set_name($sets, $reading_name);
		my %value;
		$value{read} = $read_name{$reading_name} if defined($read_name{$reading_name});
		$value{write} = $set_name if $has_set{$set_name};

		# Die erlaubten Auswahlwerte werden in UI-sichere Tokens uebersetzt und
		# fuer eingehende Originalwerte mit einer Rueckabbildung versehen.
		my ($tokens, undef, $read_map) = choice_values($entity->{options});
		if (@$tokens) {
			$value{options} = $tokens;
			$value{valueMap}{read} = $read_map;
		}
		$capabilities->{value} = \%value if exists($value{read}) || exists($value{write});
	} elsif ($component eq 'climate') {
		my $unit = temperature_unit($entity->{temperature_unit});
		my $current = "${reading_name}_current_temperature";
		$capabilities->{currentTemperature} = { read => $read_name{$current}, unit => $unit }
			if defined($read_name{$current});
		my $current_humidity = "${reading_name}_current_humidity";
		$capabilities->{humidity} = { read => $read_name{$current_humidity}, unit => '%' }
			if defined($read_name{$current_humidity});

		for my $spec (
			['targetTemperature', 'target_temperature', 'min_temp', 'max_temp', 'temp_step'],
			['targetTemperatureHigh', 'target_temperature_high', 'min_temp', 'max_temp', 'temp_step'],
			['targetTemperatureLow', 'target_temperature_low', 'min_temp', 'max_temp', 'temp_step'],
		) {
			my ($capability, $suffix, $min_key, $max_key, $step_key) = @$spec;
			my $read_name = "${reading_name}_$suffix";
			my $set_name = capability_set_name($entity, $reading_name, $suffix);
			my %value;
			$value{read} = $read_name{$read_name} if defined($read_name{$read_name});
			$value{write} = $set_name if $has_set{$set_name};
			next if !%value;
			$value{min} = is_numeric($entity->{$min_key}) ? 0 + $entity->{$min_key} : 7;
			$value{max} = is_numeric($entity->{$max_key}) ? 0 + $entity->{$max_key} : 35;
			$value{step} = is_numeric($entity->{$step_key}) ? 0 + $entity->{$step_key} : 1;
			$value{unit} = $unit;
			$capabilities->{$capability} = \%value;
		}

		my $target_humidity = "${reading_name}_target_humidity";
		my $target_humidity_set = capability_set_name($entity, $reading_name, 'target_humidity');

		# Ziel-Luftfeuchte wird angelegt, sobald mindestens eine Lese- oder
		# Schreibrichtung existiert; rein fehlende Discovery-Felder erzeugen nichts.
		if (defined($read_name{$target_humidity}) || $has_set{$target_humidity_set}) {
			my %value = (unit => '%');
			$value{read} = $read_name{$target_humidity} if defined($read_name{$target_humidity});
			$value{write} = $target_humidity_set if $has_set{$target_humidity_set};
			$value{min} = is_numeric($entity->{min_humidity}) ? 0 + $entity->{min_humidity} : 30;
			$value{max} = is_numeric($entity->{max_humidity}) ? 0 + $entity->{max_humidity} : 99;
			$value{step} = 1;
			$capabilities->{targetHumidity} = \%value;
		}

		for my $spec (
			['mode', 'mode', 'modes'],
			['fanMode', 'fan_mode', 'fan_modes'],
			['swingMode', 'swing_mode', 'swing_modes'],
			['swingHorizontalMode', 'swing_horizontal_mode', 'swing_horizontal_modes'],
			['presetMode', 'preset_mode', 'preset_modes'],
		) {
			my ($capability, $suffix, $values_key) = @$spec;
			my $read_name = "${reading_name}_$suffix";
			my $set_name = capability_set_name($entity, $reading_name, $suffix);
			my %value;
			$value{read} = $read_name{$read_name} if defined($read_name{$read_name});
			$value{write} = $set_name if $has_set{$set_name};
			next if !%value;
			my ($tokens, undef, $read_mapping) = choice_values($entity->{$values_key});

			# Nur bekannte Optionen begrenzen die semantische Enum; ohne Liste bleibt
			# die Capability zwar bedienbar, aber bewusst ohne erfundene Werte.
			if (@$tokens) {
				$value{options} = $tokens;
				$value{valueMap}{read} = $read_mapping;
			}
			$capabilities->{$capability} = \%value;
		}

		my $action = "${reading_name}_action";
		$capabilities->{action} = { read => $read_name{$action} }
			if defined($read_name{$action});
		my $power = capability_set_name($entity, $reading_name, 'power');
		my $mode_read = "${reading_name}_mode";
		my @modes = ref($entity->{modes}) eq 'ARRAY'
			? grep { defined($_) && !ref($_) && $_ !~ /[\x00-\x1f]/ } @{ $entity->{modes} }
			: ();
		my $has_off_mode = grep { $_ eq 'off' } @modes;

		# Climate-Power kann aus einem eigenen Set oder aus dem lesbaren off-Modus
		# abgeleitet werden; ohne beides gaebe es keine belastbare Richtung.
		if ($has_set{$power} || ($has_off_mode && defined($read_name{$mode_read}))) {
			my $power_capability = _power_capability(
				read => $has_off_mode ? $read_name{$mode_read} : undef,
				write => $has_set{$power} ? $power : undef,
				payload_on => $entity->{payload_on}, payload_off => $entity->{payload_off},
			);

			# Wenn off Teil der Modusliste ist, werden alle anderen Modi als aktiv
			# interpretiert und auf die konfigurierten Power-Payloads normalisiert.
			if ($has_off_mode && defined($read_name{$mode_read})) {
				my $on = $entity->{payload_on} // 'ON';
				my $off = $entity->{payload_off} // 'OFF';
				$power_capability->{valueMap}{read} = {
					map { ("$_" => ($_ eq 'off' ? $off : $on)) } @modes
				};
			}
			$capabilities->{power} = $power_capability;
		}
	} elsif ($component eq 'light') {
		my $state_set = $read_name{$reading_name} // "${reading_name}_state";
		$capabilities->{power} = _power_capability(
			read => $read_name{$reading_name},
			write => $has_set{$state_set} ? $state_set : undef,
			payload_on => $entity->{payload_on}, payload_off => $entity->{payload_off},
		) if defined($read_name{$reading_name}) || $has_set{$state_set};
		my $brightness = "${reading_name}_brightness";
		my %capability;
		$capability{read} = $read_name{$brightness} if defined($read_name{$brightness});
		$capability{write} = $brightness if $has_set{$brightness};

		# Helligkeitsgrenzen werden nur publiziert, wenn mindestens Reading oder
		# Set existiert; andernfalls waere die Capability nicht erreichbar.
		if (%capability) {
			my $maximum = defined($entity->{brightness_scale}) && !ref($entity->{brightness_scale})
				&& $entity->{brightness_scale} =~ /^\d+(?:\.\d+)?$/ && $entity->{brightness_scale} > 0
				? 0 + $entity->{brightness_scale} : 255;
			@capability{qw(min max step)} = (0, $maximum, 1);
			$capabilities->{brightness} = \%capability;
		}
	} elsif ($component eq 'cover') {
		$capabilities->{state} = { read => $read_name{$reading_name} }
			if defined($read_name{$reading_name});
		my $action = "${reading_name}_action";

		# Ein gemeinsames Action-Set wird in drei argumentlose Bedienaktionen
		# aufgeteilt, damit open, close und stop separat aufrufbar sind.
		if ($has_set{$action}) {
			$capabilities->{$_} = { write => $action, valueMap => { write => { 1 => $_ } } }
				for qw(open close stop);
		}
		my $position = "${reading_name}_position";
		my %capability;
		$capability{read} = $read_name{$position} if defined($read_name{$position});
		$capability{write} = $position if $has_set{$position};

		# Position erhaelt nur mit mindestens einer vorhandenen Richtung den
		# festen Prozentbereich eines Covers.
		if (%capability) {
			@capability{qw(min max step unit)} = (0, 100, 1, '%');
			$capabilities->{position} = \%capability;
		}
	} elsif ($component eq 'fan') {
		my $state_set = $read_name{$reading_name} // "${reading_name}_state";
		$capabilities->{power} = _power_capability(
			read => $read_name{$reading_name},
			write => $has_set{$state_set} ? $state_set : undef,
			payload_on => $entity->{payload_on}, payload_off => $entity->{payload_off},
		) if defined($read_name{$reading_name}) || $has_set{$state_set};
		my $percentage = "${reading_name}_percentage";
		my %capability;
		$capability{read} = $read_name{$percentage} if defined($read_name{$percentage});
		$capability{write} = $percentage if $has_set{$percentage};

		# Die prozentuale Fan-Capability uebernimmt ihren Bereich nur fuer eine
		# tatsaechlich les- oder schreibbare Funktion.
		if (%capability) {
			my $minimum = defined($entity->{percentage_min}) && $entity->{percentage_min} =~ /^\d+$/
				? 0 + $entity->{percentage_min} : 0;
			my $maximum = defined($entity->{percentage_max}) && $entity->{percentage_max} =~ /^\d+$/
				? 0 + $entity->{percentage_max} : 100;
			my $step = defined($entity->{percentage_step}) && $entity->{percentage_step} =~ /^\d+$/
				? 0 + $entity->{percentage_step} : 1;
			@capability{qw(min max step)} = ($minimum, $maximum, $step);
			$capability{unit} = '%' if $maximum == 100;
			$capabilities->{percentage} = \%capability;
		}
	} elsif ($component eq 'lock') {
		$capabilities->{state} = { read => $read_name{$reading_name} }
			if defined($read_name{$reading_name});
		my $set_name = _single_set_name($sets, $reading_name);

		# Lock und Unlock werden nur aus einem vorhandenen Set abgeleitet, damit
		# keine scheinbar bedienbaren Aktionen ohne MQTT-Ziel entstehen.
		if ($has_set{$set_name}) {
			$capabilities->{$_} = { write => $set_name, valueMap => { write => { 1 => $_ } } }
				for qw(lock unlock);
		}
	}

	# Leere oder fuer Semantik ungeeignete Entities werden nicht publiziert.
	return undef if !keys(%$capabilities) || !_semantic_entity_is_allowed($entity, $sets);
	return $semantic;
}

# Oeffentliche Grenze zur Erzeugung semantischer Metadaten aus einem Mapping.
sub from_mapping { return _semantic_entity(@_); }
# Oeffentliche Grenze zur Ermittlung der von einem Mapping-Eintrag erzeugten Readings.
sub entry_read_names { return _entry_read_names(@_); }

1;

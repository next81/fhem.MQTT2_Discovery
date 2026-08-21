# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Mapper;

use strict;
use warnings;
use JSON::PP qw(encode_json);
use MQTT2_Discovery::Helper qw(safe_name stable_suffix stable_unique);
use MQTT2_Discovery::Template ();
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Mapper::Common qw(capability_set_name choice_values is_numeric);
use MQTT2_Discovery::Mapper::NameResolver ();
use MQTT2_Discovery::Mapper::Renderer ();
use MQTT2_Discovery::Mapper::Semantics ();


# Unterstuetzte Komponenten werden einmal zentral definiert. Die eigentliche
# Mappingroutine konzentriert sich danach auf ihre jeweiligen Besonderheiten.
my %SUPPORTED_COMPONENT = map { $_ => 1 } qw(
	sensor binary_sensor switch button number select text light cover fan lock
	climate device_tracker event device_automation
);

# Erzeugt die stabile Device-Identitaet aus Herstellerkennung und Verbindungsdaten.
sub _identity {
	my ($entity, $io_name) = @_;
	my $device = $entity->{device} || {};

	# Starke Device-Merkmale haben Vorrang. Topic/Entity-Daten sind nur der
	# stabile Fallback fuer Discovery-Payloads ohne Device-Block.
	if (ref($device->{identifiers}) eq 'ARRAY' && @{ $device->{identifiers} }) {
		return join('|', $io_name, 'id', sort map { ref($_) ? encode_json($_) : $_ } @{ $device->{identifiers} });
	}

	# Fehlen explizite Identifier, sind Transportverbindungen noch immer ein
	# geraeteweiter und damit staerkerer Schluessel als einzelne Entity-Topics.
	if (ref($device->{connections}) eq 'ARRAY' && @{ $device->{connections} }) {
		return join('|', $io_name, 'connection', sort map { ref($_) ? encode_json($_) : $_ } @{ $device->{connections} });
	}
	return join('|', $io_name, 'entity', grep { defined($_) && $_ ne '' }
		($entity->{unique_id}, $entity->{node_id}, $entity->{discovery_topic}));
}

# Normalisiert einen fachlichen Namen zu einem gueltigen FHEM-Readingnamen.
sub _reading_name {
	my ($entity) = @_;
	my $fallback = safe_name($entity->{object_id} || $entity->{name} || $entity->{component}, 'state');
	return _state_path_reading_name($entity->{state_topic}, $fallback);
}

# Leitet aus Entity und Binding einen kollisionsarmen logischen Readingpfad ab.
sub _logical_reading_path {
	my ($entity) = @_;
	my $component = safe_name($entity->{component}, 'entity');
	my $fallback = _reading_name($entity);

	# Device-Discovery-Komponentenschluessel sind ueblicherweise mit ihrer
	# Plattform qualifiziert (z. B. sensor_battery). Der Plattformteil ist ein
	# Namensraum und wird nur benoetigt, wenn der eigentliche Name kollidiert.
	if (($entity->{_canonical_layout} || '') eq 'device'
			&& defined($entity->{component_key}) && !ref($entity->{component_key})) {
		my $key = safe_name($entity->{component_key}, $fallback);
		my $json_name;

		# Ein einfacher value_json-Pfad liefert den fachlichen Blattnamen genauer
		# als der oft mit Plattformpraefix versehene Komponentenschluessel.
		if (defined($entity->{value_template}) && !ref($entity->{value_template})) {
			my $compiled = MQTT2_Discovery::Template::compile($entity->{value_template});
			$json_name = MQTT2_Discovery::Mapper::Renderer::simple_json_key(
				$entity->{value_template}, $compiled,
			) if $compiled->{ok};
			$json_name = safe_name($json_name, '') if defined($json_name) && $json_name ne '';
		}

		# Wenn Komponentenschluessel und JSON-Blatt zusammenpassen, bleibt ihr
		# Plattformanteil nur als Namensraum erhalten und nicht im Reading selbst.
		if (defined($json_name) && $json_name ne ''
				&& ($key eq $json_name || $key =~ /_\Q$json_name\E\z/)) {
			my $namespace = $key eq $json_name
				? $component : substr($key, 0, length($key) - length($json_name) - 1);
			return [safe_name($namespace, $component), $json_name];
		}
		my $prefix = $component . '_';
		my $leaf = index($key, $prefix) == 0 && length($key) > length($prefix)
			? substr($key, length($prefix)) : $key;
		return [$component, safe_name($leaf, $fallback)];
	}

	return [$component, $fallback];
}

# Loest Reading- und Set-Namenskollisionen ueber einen ganzen Device-Satz auf.
sub resolve_mapping_names {
	return MQTT2_Discovery::Mapper::NameResolver::resolve(@_);
}

# Nutzt das letzte Topicsegment als Fallbacknamen fuer einfache skalare Zustaende.
sub _topic_leaf_reading_name {
	my ($topic, $fallback) = @_;
	return $fallback if !defined($topic) || ref($topic) || $topic eq '';
	return safe_name($1, $fallback) if $topic =~ m{/([^/]+)$};
	return safe_name($topic, $fallback);
}

# Bestimmt den Readingnamen bevorzugt aus dem JSON-Pfad des State-Bindings.
sub _state_path_reading_name {
	my ($topic, $fallback) = @_;
	return $fallback if !defined($topic) || ref($topic);
	return safe_name($1, $fallback) if $topic =~ m{(?:^|/)state/([^/]+)$};
	return $fallback;
}

# Leitet einen stabilen Set-Namen aus dem letzten Segment eines Command-Topics ab.
sub _command_topic_set_name {
	my ($entity, $fallback) = @_;
	my $topic = $entity->{command_topic};
	return $fallback if !defined($topic) || ref($topic);
	return safe_name($1, $fallback) if $topic =~ m{/(?:cmd|command)/([^/]+)$};
	return $fallback;
}

# Rendert und gruppiert eine Liste abstrakter Mapping-Eintraege.
sub render_entries { return MQTT2_Discovery::Mapper::Renderer::render_entries(@_); }


# Erzeugt einen abstrakten Reading-Eintrag aus Topic, Template und Zielnamen.
sub _reading {
	my ($topic, $template, $name, $payload, $json_autocreate, $json_reading_name, $semantic_name) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	return { error => 'Trigger-Payload muss ein Skalar ohne Steuerzeichen sein' }
		if defined($payload) && (ref($payload) || $payload =~ /[\x00-\x1f]/);
	my $entry = {
		kind          => 'reading',
		topic         => $topic,
		template      => $template,
		name          => $name,
		semantic_name => defined($semantic_name) ? $semantic_name : $name,
		payload       => $payload,
	};

	# Templates werden bereits beim Mapping kompiliert, damit unsichere oder
	# nicht unterstuetzte Konstruktionen nie in eine FHEM-Zeile gelangen.
	if (defined($template) && $template ne '') {
		my $compiled = MQTT2_Discovery::Template::compile($template);
		return { error => $compiled->{error} } if !$compiled->{ok};
		my $json_key = MQTT2_Discovery::Mapper::Renderer::simple_json_key($template, $compiled);

		# Direkte value_json-Pfade koennen gemeinsam mit json2nameValue gerendert
		# werden; komplexere Templates bleiben sichere Runtime-Auswertungen.
		if (!defined($payload) && ($json_autocreate || defined($json_key))) {
			$entry->{kind} = $json_autocreate ? 'json_autocreate' : 'json_reading';
			$entry->{json_key} = defined($json_key) ? $json_key : $name;

			# Beim Autocreate darf ein vom Adapter ermittelter Rohname den generischen
			# Namen ersetzen, sofern er als FHEM-Reading sicher darstellbar ist.
			if ($json_autocreate) {
				my $raw_name = defined($json_reading_name) ? $json_reading_name : $json_key;
				$entry->{name} = $raw_name
					if defined($raw_name) && !ref($raw_name) && $raw_name =~ /^[A-Za-z0-9_.\/-]+$/;
			}
		}
	}
	$entry->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry($entry, undef);
	return $entry;
}

# Erzeugt einen direkten oder templatebasierten MQTT-Publish-Set-Eintrag.
sub _publish {
	my ($name, $spec, $topic, $template) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	$template = '{{ value }}' if !defined($template) || $template eq '';
	my $compiled = MQTT2_Discovery::Template::compile($template);
	return { error => $compiled->{error} } if !$compiled->{ok};
	my $entry = {
		kind => 'publish', name => $name, spec => $spec, topic => $topic, template => $template,
		identity => MQTT2_Discovery::Mapper::Renderer::identity_template($compiled) ? 1 : 0,
	};
	$entry->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry($entry, undef);
	return $entry;
}

# Baut einen Set-Eintrag fuer eine begrenzte Auswahl mit Hin- und Rueckabbildung.
sub _choice {
	my ($name, $spec, $topic, $mapping, $template) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';

	# Ein Choice-Template transformiert den bereits gemappten Auswahlwert und
	# muss deshalb denselben sicheren Sprachumfang wie Publish verwenden.
	if (defined($template) && $template ne '') {
		my $compiled = MQTT2_Discovery::Template::compile($template);
		return { error => $compiled->{error} } if !$compiled->{ok};
	}
	my $entry = {
		kind => 'choice', name => $name, spec => $spec, topic => $topic,
		mapping => $mapping, template => $template,
	};
	$entry->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry($entry, undef);
	return $entry;
}

# Erzeugt einen zustandslosen Button-Set-Eintrag fuer ein festes MQTT-Kommando.
sub _button {
	my ($name, $topic, $payload) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	my $entry = { kind => 'button', name => $name, spec => 'noArg', topic => $topic, payload => $payload };
	$entry->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry($entry, undef);
	return $entry;
}

# Baut einen numerischen JSON-Publish-Eintrag fuer einen einzelnen Payloadschluessel.
sub _json_publish {
	my ($name, $spec, $topic, $key) = @_;
	return undef if !defined($topic) || ref($topic) || $topic eq '';
	my $entry = { kind => 'json', name => $name, spec => $spec, topic => $topic, key => $key };
	$entry->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry($entry, undef);
	return $entry;
}

# Haengt einen gueltigen Eintrag an Reading- oder Set-Zielliste des Mappings an.
sub _add_entry {
	my ($list, $warnings, $entry, $context) = @_;
	return if !$entry;

	# Ein fehlerhafter Eintrag wird als lokale Mappingwarnung gesammelt, damit
	# andere sichere Funktionen derselben Entity weiterhin nutzbar bleiben.
	if ($entry->{error}) {
		push @$warnings, "$context: $entry->{error}";
		return;
	}
	push @$list, $entry;
}

# Ergaenzt zusaetzliche Parser-Signale um passende Readings oder Sets.
sub _add_supplemental_signals {
	my ($list, $warnings, $signals) = @_;
	return if ref($signals) ne 'ARRAY';

	# Supplemental Signals stammen aus Adapter-Erweiterungen, werden ab hier
	# aber wie normale formatunabhaengige Reading-Eintraege behandelt.
	for my $signal (@$signals) {
		next if ref($signal) ne 'HASH';
		my ($type, $topic, $name) = @{$signal}{qw(type topic name)};

		# Ohne stabiles Topic und Reading-Namen waere das Zusatzsignal weder
		# renderbar noch spaeter eindeutig als Discovery-eigen erkennbar.
		if (!defined($topic) || ref($topic) || $topic eq ''
				|| !defined($name) || ref($name) || $name eq '') {
			push @$warnings, 'Zusaetzliches Signal ohne gueltiges Topic oder Namen';
			next;
		}

		# Der deklarierte Signaltyp entscheidet, ob ein einzelner Payload, ein
		# flaches JSON oder eine nummerierte JSON-Sequenz gerendert wird.
		if (($type || '') eq 'payload') {
			_add_entry($list, $warnings, _reading($topic, undef, $name), "Zusatzsignal $name");
		} elsif (($type || '') eq 'json_flatten') {
			_add_entry($list, $warnings, {
				kind => 'json_autocreate', topic => $topic, name => $name,
			}, "JSON-Zusatzsignal $name");
		} elsif (($type || '') eq 'json_sequence') {
			_add_entry($list, $warnings, {
				kind => 'json_sequence', topic => $topic, name => $name,
				key_prefix => $signal->{key_prefix}, parts => $signal->{parts},
				unwrap_single_property => $signal->{unwrap_single_property},
			}, "JSON-Sequenz $name");
		} else {
			push @$warnings, "Nicht unterstuetzter Zusatzsignaltyp: " . ($type // '');
		}
	}

}

# Validiert ein kanonisches Event und bildet es auf die gemeinsame Mapper-Ausgabe ab.
sub map_model {
	my (%args) = @_;
	my ($source_entity, $model_error) = MQTT2_Discovery::Model::to_entity($args{model});
	return {
		ok => 0,
		($model_error && $model_error =~ /Nicht unterstuetzte kanonische Geraeteklasse/
			? (unsupported => 1) : ()),
		error => $model_error,
	} if $model_error;

	# Erst nach erfolgreicher Modellvalidierung beginnt das eigentliche Mapping.
	return _map_canonical_entity(%args, entity => $source_entity);
}

# Ueberfuehrt eine Legacy-Parser-Entity ueber das kanonische Modell in ein Mapping.
sub map_entity {
	my (%args) = @_;
	my $model = MQTT2_Discovery::Model::from_entity(
		adapter => 'compatibility', entity => $args{entity},
	);
	return { ok => 0, error => 'Entity fehlt' } if !$model;
	return map_model(%args, model => $model);
}

# Erzeugt Identitaet, FHEM-Namen, Readings, Sets und Semantik fuer eine Entity.
sub _map_canonical_entity {
	my (%args) = @_;
	my $source_entity = $args{entity};
	return { ok => 0, error => 'Entity fehlt' } if ref($source_entity) ne 'HASH';
	my $entity = { %$source_entity };
	return { ok => 0, error => 'Delete-Ereignisse werden nicht gemappt' }
		if ($entity->{operation} || '') ne 'upsert';
	my $component = $entity->{component} || '';
	return { ok => 0, unsupported => 1, error => "Nicht unterstuetzte Komponente: $component" }
		if !$SUPPORTED_COMPONENT{$component};

	# Identitaet, Zielname und Reading-Pfad werden vor den Komponentenregeln
	# festgelegt, damit alle Zweige dieselben stabilen Namen verwenden.
	my $io_name = $args{io_name} || '';
	my $identity = _identity($entity, $io_name);
	my $device = $entity->{device} || {};
	my $base = $device->{name} || $entity->{node_id} || $entity->{unique_id} || $entity->{object_id} || $component;
	my $name_prefix = defined($args{name_prefix}) ? $args{name_prefix} : '';
	my $proposed_name = safe_name($name_prefix . $base, 'device');
	my $reading_path = _logical_reading_path($entity);
	my $reading_name = $reading_path->[-1];
	my $command_set_name = _command_topic_set_name($entity, $reading_name);
	my $extensions = ref($entity->{_canonical_extensions}) eq 'HASH'
		? $entity->{_canonical_extensions} : {};
	my $json_autocreate = $extensions->{json_autocreate};
	my $json_reading_name = $json_autocreate ? $extensions->{json_reading_name} : undef;
	my $state_reading_name = defined($extensions->{state_reading_name})
		&& !ref($extensions->{state_reading_name})
		&& $extensions->{state_reading_name} =~ /^[A-Za-z0-9_.\/-]+$/
			? $extensions->{state_reading_name} : $reading_name;
	my (@readings, @sets, @warnings, @set_state);

	# Number-Entities ohne Grenzen erhalten einen vollstaendigen Standardbereich,
	# weil FHEMs Slider keine teilweise definierte Skala darstellen kann.
	if ($component eq 'number') {
		my $all_missing = !defined($entity->{min}) && !defined($entity->{max}) && !defined($entity->{step});
		@{$entity}{qw(min max step)} = (0, 100, 1) if $all_missing;
		$entity->{step} = 1 if !defined($entity->{step});
	}

	my $state_entry = _reading($entity->{state_topic}, $entity->{value_template}, $state_reading_name,
		$component eq 'device_automation' ? $entity->{payload} : undef,
		$json_autocreate, $json_reading_name, $reading_name);

	# HA-Device-Automationen duerfen in ihren Templates auf den strukturierten
	# Triggerwert zugreifen; normale State-Entities behalten ihren bisherigen Kontext.
	if (ref($state_entry) eq 'HASH' && !$state_entry->{error}
			&& $component eq 'device_automation' && defined($entity->{value_template})) {
		$state_entry->{template_context} = 'trigger';
		$state_entry->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry($state_entry, undef);
	}
	_add_entry(\@readings, \@warnings, $state_entry, 'state');

	_add_supplemental_signals(\@readings, \@warnings, $extensions->{supplemental_signals});

	# JSON-Autocreate kann den sichtbaren Reading-Namen veraendern. Set-Befehle
	# muessen den danach tatsaechlich vorhandenen Namen verwenden.
	my %primary_read_name = MQTT2_Discovery::Mapper::Semantics::entry_read_names(\@readings);
	my $actual_reading_name = $primary_read_name{$reading_name};
	$command_set_name = $actual_reading_name if defined $actual_reading_name;

	# Die Komponente bestimmt, welche fachlichen Set- und Zusatz-Readings aus den
	# bereits normalisierten Topics und Payloads entstehen.
	if ($component eq 'binary_sensor') {
		# Das rohe Payload bleibt erhalten; HA-spezifische Payloads werden als Metadaten dokumentiert.
	} elsif ($component eq 'switch') {
		my %mapping = (on => ($entity->{payload_on} // 'ON'), off => ($entity->{payload_off} // 'OFF'));
		_add_entry(\@sets, \@warnings, _choice($command_set_name, 'on,off', $entity->{command_topic}, \%mapping), 'switch');
		push @set_state, $command_set_name;
	} elsif ($component eq 'button') {
		_add_entry(\@sets, \@warnings, _button($reading_name, $entity->{command_topic}, $entity->{payload_press} // 'PRESS'), 'button');
	} elsif ($component eq 'number') {
		my ($min, $max, $step) = map { $entity->{$_} } qw(min max step);

		# Nur ein positiver Schritt innerhalb eines aufsteigenden Zahlenbereichs
		# ergibt eine bedienbare und vorhersagbare Slider-Spezifikation.
		if (!defined($min) || !defined($max) || !defined($step) || $min !~ /^-?\d+(?:\.\d+)?$/
				|| $max !~ /^-?\d+(?:\.\d+)?$/ || $step !~ /^\d+(?:\.\d+)?$/ || $min >= $max || $step <= 0) {
			push @warnings, 'number: ungueltige min/max/step-Kombination';
		} else {
			_add_entry(\@sets, \@warnings, _publish($actual_reading_name // $reading_name, "slider,$min,$step,$max", $entity->{command_topic}, $entity->{command_template}), 'number');
		}
	} elsif ($component eq 'select') {

		# Eine Select-Entity ohne Optionen koennte keinen gueltigen FHEM-Befehl
		# anbieten und wird daher als unvollstaendig gemeldet.
		my ($tokens, $mapping) = choice_values($entity->{options});
		if (!@$tokens) {
			push @warnings, 'select: options fehlen';
		} else {
			_add_entry(\@sets, \@warnings,
				_choice($command_set_name, join(',', @$tokens), $entity->{command_topic}, $mapping),
				'select');
		}
	} elsif ($component eq 'climate') {

		for my $spec (
			['action', 'action_topic', 'action_template'],
			['current_temperature', 'current_temperature_topic', 'current_temperature_template'],
			['current_humidity', 'current_humidity_topic', 'current_humidity_template'],
			['target_temperature', 'temperature_state_topic', 'temperature_state_template'],
			['target_temperature_high', 'temperature_high_state_topic', 'temperature_high_state_template'],
			['target_temperature_low', 'temperature_low_state_topic', 'temperature_low_state_template'],
			['mode', 'mode_state_topic', 'mode_state_template'],
			['fan_mode', 'fan_mode_state_topic', 'fan_mode_state_template'],
			['swing_mode', 'swing_mode_state_topic', 'swing_mode_state_template'],
			['swing_horizontal_mode', 'swing_horizontal_mode_state_topic', 'swing_horizontal_mode_state_template'],
			['preset_mode', 'preset_mode_state_topic', 'preset_mode_value_template'],
			['target_humidity', 'target_humidity_state_topic', 'target_humidity_state_template'],
		) {
			my ($suffix, $topic_key, $template_key) = @$spec;
			my $semantic_name = "${reading_name}_$suffix";
			_add_entry(\@readings, \@warnings,
				_reading($entity->{$topic_key},
					defined($entity->{$template_key}) ? $entity->{$template_key} : $entity->{value_template},
					_state_path_reading_name($entity->{$topic_key}, $semantic_name),
					undef, undef, undef, $semantic_name),
				"climate $suffix state");
		}

		my $min_temp = is_numeric($entity->{min_temp}) ? $entity->{min_temp} : 7;
		my $max_temp = is_numeric($entity->{max_temp}) ? $entity->{max_temp} : 35;
		my $temp_step = is_numeric($entity->{temp_step}) ? $entity->{temp_step} : 1;

		# Ungueltige Temperaturgrenzen sperren nur die Zieltemperatur-Sets; die
		# lesbaren Climate-Werte und anderen Befehle bleiben erhalten.
		if ($min_temp >= $max_temp || $temp_step <= 0) {
			push @warnings, 'climate: ungueltige min_temp/max_temp/temp_step-Kombination';
		} else {

			for my $spec (
				['target_temperature', 'temperature_command_topic', 'temperature_command_template'],
				['target_temperature_high', 'temperature_high_command_topic', 'temperature_high_command_template'],
				['target_temperature_low', 'temperature_low_command_topic', 'temperature_low_command_template'],
			) {
				my ($suffix, $topic_key, $template_key) = @$spec;
				_add_entry(\@sets, \@warnings,
					_publish(capability_set_name($entity, $reading_name, $suffix), "slider,$min_temp,$temp_step,$max_temp",
						$entity->{$topic_key}, $entity->{$template_key}),
					"climate $suffix command");
			}

		}

		my $min_humidity = is_numeric($entity->{min_humidity}) ? $entity->{min_humidity} : 30;
		my $max_humidity = is_numeric($entity->{max_humidity}) ? $entity->{max_humidity} : 99;

		# Auch der Feuchteslider benoetigt einen echten aufsteigenden Wertebereich;
		# bei fehlerhaften Metadaten wird nur diese Capability ausgelassen.
		if ($min_humidity >= $max_humidity) {
			push @warnings, 'climate: ungueltige min_humidity/max_humidity-Kombination';
		} else {
			_add_entry(\@sets, \@warnings,
				_publish(capability_set_name($entity, $reading_name, 'target_humidity'), "slider,$min_humidity,1,$max_humidity",
					$entity->{target_humidity_command_topic}, $entity->{target_humidity_command_template}),
				'climate target_humidity command');
		}

		for my $spec (
			['mode', 'modes', 'mode_command_topic', 'mode_command_template'],
			['fan_mode', 'fan_modes', 'fan_mode_command_topic', 'fan_mode_command_template'],
			['swing_mode', 'swing_modes', 'swing_mode_command_topic', 'swing_mode_command_template'],
			['swing_horizontal_mode', 'swing_horizontal_modes', 'swing_horizontal_mode_command_topic', 'swing_horizontal_mode_command_template'],
			['preset_mode', 'preset_modes', 'preset_mode_command_topic', 'preset_mode_command_template'],
		) {
			my ($suffix, $values_key, $topic_key, $template_key) = @$spec;
			next if !defined($entity->{$topic_key});
			my ($tokens, $mapping) = choice_values($entity->{$values_key});

			# Ein vorhandenes Command-Topic ohne Auswahlwerte ist nicht sicher
			# bedienbar, weil der Mapper keine erlaubten Payloads erfinden darf.
			if (!@$tokens) {
				push @warnings, "climate $suffix: Optionen fehlen";
				next;
			}
			_add_entry(\@sets, \@warnings,
				_choice(capability_set_name($entity, $reading_name, $suffix), join(',', @$tokens), $entity->{$topic_key}, $mapping,
					$entity->{$template_key}),
				"climate $suffix command");
		}

		# Power ist bei Climate optional und wird nur als eigener on/off-Befehl
		# angelegt, wenn das Discovery-Payload dafuer ein Topic bereitstellt.
		if (defined($entity->{power_command_topic})) {
			my %mapping = (
				on => ($entity->{payload_on} // 'ON'), off => ($entity->{payload_off} // 'OFF'),
			);
			_add_entry(\@sets, \@warnings,
				_choice(capability_set_name($entity, $reading_name, 'power'), 'on,off', $entity->{power_command_topic}, \%mapping,
					$entity->{power_command_template}),
				'climate power command');
		}
	} elsif ($component eq 'text') {
		_add_entry(\@sets, \@warnings, _publish($actual_reading_name // $reading_name, '', $entity->{command_topic}, $entity->{command_template}), 'text');
	} elsif ($component eq 'light') {
		my %mapping = (on => ($entity->{payload_on} // 'ON'), off => ($entity->{payload_off} // 'OFF'));
		my $state_set_name = $actual_reading_name // "${reading_name}_state";
		_add_entry(\@sets, \@warnings, _choice($state_set_name, 'on,off', $entity->{command_topic}, \%mapping), 'light state');
		my $brightness_topic = $entity->{brightness_command_topic};
		my $brightness_scale = defined($entity->{brightness_scale}) && !ref($entity->{brightness_scale})
			&& $entity->{brightness_scale} =~ /^\d+(?:\.\d+)?$/ && $entity->{brightness_scale} > 0
			? 0 + $entity->{brightness_scale} : 255;
		_add_entry(\@sets, \@warnings, _publish("${reading_name}_brightness", "slider,0,1,$brightness_scale", $brightness_topic, '{{ value }}'), 'light brightness')
			if defined $brightness_topic;
		_add_entry(\@readings, \@warnings,
			_reading($entity->{brightness_state_topic}, $entity->{brightness_value_template}, "${reading_name}_brightness",
				undef, $json_autocreate), 'light brightness state');

		# Beim JSON-Light-Schema steckt Helligkeit im gemeinsamen Command-/State-
		# Payload und benoetigt daher statt eines separaten Topics JSON-Mapping.
		if (!defined($brightness_topic) && ($entity->{schema} || '') eq 'json' && $entity->{brightness}) {
			_add_entry(\@sets, \@warnings,
				_json_publish("${reading_name}_brightness", 'slider,0,1,255', $entity->{command_topic}, 'brightness'), 'light JSON brightness');
			_add_entry(\@readings, \@warnings,
				_reading($entity->{state_topic}, $entity->{brightness_value_template} || '{{ value_json.brightness }}',
					"${reading_name}_brightness", undef, $json_autocreate),
				'light JSON brightness state');
		}
		_add_entry(\@sets, \@warnings,
			_publish("${reading_name}_colorTemp", 'slider,' . ($entity->{min_mireds} // 153)
				. ',1,' . ($entity->{max_mireds} // 500), $entity->{color_temp_command_topic}, '{{ value }}'),
			'light color temperature');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{color_temp_state_topic}, $entity->{color_temp_value_template}, "${reading_name}_colorTemp",
				undef, $json_autocreate),
			'light color temperature state');
		_add_entry(\@sets, \@warnings,
			_publish("${reading_name}_color", '', $entity->{rgb_command_topic}, '{{ value }}'), 'light RGB color');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{rgb_state_topic}, $entity->{rgb_value_template}, "${reading_name}_color",
				undef, $json_autocreate), 'light RGB state');

		# Effekte werden nur angeboten, wenn Discovery eine konkrete Liste liefert;
		# ihre sicheren Tokens werden auf die von HA erwarteten Indizes abgebildet.
		if (ref($entity->{effect_list}) eq 'ARRAY' && @{ $entity->{effect_list} }) {
			my (%effect_mapping, @effect_tokens);

			for my $index (0 .. $#{ $entity->{effect_list} }) {
				my $effect = $entity->{effect_list}[$index];
				next if !defined($effect) || ref($effect);
				my $token = safe_name(lc($effect), 'effect');
				$token .= '_' . stable_suffix($effect, 4) if exists $effect_mapping{$token};
				$effect_mapping{$token} = $index;
				push @effect_tokens, $token;
			}

			_add_entry(\@sets, \@warnings,
				_choice("${reading_name}_effect", join(',', @effect_tokens), $entity->{effect_command_topic}, \%effect_mapping),
				'light effect') if @effect_tokens;
		}
		_add_entry(\@readings, \@warnings,
			_reading($entity->{effect_state_topic}, $entity->{effect_value_template}, "${reading_name}_effect",
				undef, $json_autocreate), 'light effect state');
		_add_entry(\@sets, \@warnings,
			_publish("${reading_name}_white", 'slider,0,1,100', $entity->{white_command_topic}, '{{ value }}'), 'light white');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{white_state_topic}, $entity->{white_value_template}, "${reading_name}_white",
				undef, $json_autocreate), 'light white state');
	} elsif ($component eq 'cover') {
		my %mapping = (
			open => ($entity->{payload_open} // 'OPEN'), close => ($entity->{payload_close} // 'CLOSE'),
			stop => ($entity->{payload_stop} // 'STOP'),
		);
		_add_entry(\@sets, \@warnings, _choice("${reading_name}_action", 'open,close,stop', $entity->{command_topic}, \%mapping), 'cover');
		_add_entry(\@sets, \@warnings, _publish("${reading_name}_position", 'slider,0,1,100', $entity->{position_command_topic}, '{{ value }}'), 'cover position');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{position_topic}, $entity->{position_template}, "${reading_name}_position",
				undef, $json_autocreate), 'cover position state');

		# Tilt ist eine optionale Cover-Funktion und darf ohne Command-Topic weder
		# Slider noch zugehoeriges Status-Reading erzeugen.
		if (defined($entity->{tilt_command_topic})) {
			my $tilt_min = defined($entity->{tilt_min}) && $entity->{tilt_min} =~ /^-?\d+$/ ? $entity->{tilt_min} : 0;
			my $tilt_max = defined($entity->{tilt_max}) && $entity->{tilt_max} =~ /^-?\d+$/ ? $entity->{tilt_max} : 100;
			_add_entry(\@sets, \@warnings,
				_publish("${reading_name}_tilt", "slider,$tilt_min,1,$tilt_max", $entity->{tilt_command_topic}, '{{ value }}'),
				'cover tilt');
			_add_entry(\@readings, \@warnings,
				_reading($entity->{tilt_status_topic}, $entity->{tilt_status_template}, "${reading_name}_tilt",
					undef, $json_autocreate),
				'cover tilt state');
		}
	} elsif ($component eq 'fan') {
		my %mapping = (on => ($entity->{payload_on} // 'ON'), off => ($entity->{payload_off} // 'OFF'));
		_add_entry(\@sets, \@warnings, _choice($actual_reading_name // "${reading_name}_state", 'on,off', $entity->{command_topic}, \%mapping), 'fan');
		my $percentage_min = defined($entity->{percentage_min}) && $entity->{percentage_min} =~ /^\d+$/ ? $entity->{percentage_min} : 0;
		my $percentage_max = defined($entity->{percentage_max}) && $entity->{percentage_max} =~ /^\d+$/ ? $entity->{percentage_max} : 100;
		my $percentage_step = defined($entity->{percentage_step}) && $entity->{percentage_step} =~ /^\d+$/ ? $entity->{percentage_step} : 1;
		_add_entry(\@sets, \@warnings,
			_publish("${reading_name}_percentage", "slider,$percentage_min,$percentage_step,$percentage_max",
				$entity->{percentage_command_topic}, '{{ value }}'), 'fan percentage');
		_add_entry(\@readings, \@warnings,
			_reading($entity->{percentage_state_topic}, $entity->{percentage_value_template}, "${reading_name}_percentage",
				undef, $json_autocreate), 'fan percentage state');
	} elsif ($component eq 'lock') {
		my %mapping = (lock => ($entity->{payload_lock} // 'LOCK'), unlock => ($entity->{payload_unlock} // 'UNLOCK'));
		_add_entry(\@sets, \@warnings, _choice($actual_reading_name // $reading_name, 'lock,unlock', $entity->{command_topic}, \%mapping), 'lock');
	}

	my @availability;

	# Availability bleibt eine eigene Rolle, damit sie spaeter weder Device-Topic
	# noch semantische Hauptwerte beeinflusst.
	push @availability, { topic => $entity->{availability_topic} } if $entity->{availability_topic};
	push @availability, @{ $entity->{availability} } if ref($entity->{availability}) eq 'ARRAY';
	my %availability_names;

	for my $availability (@availability) {
		next if ref($availability) ne 'HASH' || !$availability->{topic};
		my $base_name = _topic_leaf_reading_name($availability->{topic}, 'status');
		my $name_index = ++$availability_names{$base_name};
		my $name = $name_index == 1 ? $base_name : "${base_name}_$name_index";
		my $entry = _reading($availability->{topic}, $availability->{value_template}, $name);
		$entry->{role} = 'availability' if $entry && !$entry->{error};
		_add_entry(\@readings, \@warnings, $entry, 'availability');
	}

	# retain veraendert die gerenderte Topic-Syntax; aktivierte Entities muessen
	# deshalb nach dem Setzen dieses Flags noch einmal gerendert werden.
	if (MQTT2_Discovery::Mapper::Renderer::retain_enabled($entity->{retain})) {
		for my $entry (@sets) {
			$entry->{retain} = 1;
			$entry->{line} = MQTT2_Discovery::Mapper::Renderer::render_entry($entry, undef);
		}

	}

	return { ok => 0, error => "$component: keine sicher abbildbare Funktion" }
		if !@readings && !@sets;
	my $semantic_entity = MQTT2_Discovery::Mapper::Semantics::from_mapping(
		$entity, $reading_name, \@readings, \@sets,
	);
	return {
		ok              => 1,
		entity_key      => $entity->{entity_key},
		discovery_topic => $entity->{discovery_topic},
		identity        => $identity,
		strong_identity => (ref($device->{identifiers}) eq 'ARRAY' && @{ $device->{identifiers} })
			|| (ref($device->{connections}) eq 'ARRAY' && @{ $device->{connections} }) ? 1 : 0,
		proposed_name   => $proposed_name,
		reading_name    => $reading_name,
		reading_path    => $reading_path,
		reading_lines   => [ stable_unique(@readings) ],
		set_lines       => [ stable_unique(@sets) ],
		set_state_list  => [ stable_unique(@set_state) ],
		device_topic    => defined($extensions->{device_topic}) && !ref($extensions->{device_topic})
			? $extensions->{device_topic} : undef,
		semantic_entity => $semantic_entity,
		warnings        => \@warnings,
		metadata        => {
			component => $component,
			unit       => $entity->{unit_of_measurement},
			device_class => $entity->{device_class},
			state_class => $entity->{state_class},
			entity_category => $entity->{entity_category},
			name       => $entity->{name},
			model      => $device->{model},
			manufacturer => $device->{manufacturer},
			suggested_area => $device->{suggested_area},
		},
	};
}

1;

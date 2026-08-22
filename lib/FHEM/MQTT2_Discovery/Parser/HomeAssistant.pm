# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Parser::HomeAssistant;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use MQTT2_Discovery::Helper qw(safe_name trim stable_unique);
use MQTT2_Discovery::Template ();


my %SUPPORTED = map { $_ => 1 } qw(
	sensor binary_sensor switch button number select text light cover fan lock climate
	device_tracker event device_automation
);

# Home Assistant verwendet fuer kleine MQTT-Payloads zahlreiche Kurzformen.
# Die Tabelle expandiert sie frueh, damit der restliche Parser nur Langnamen kennt.
my %ABBREVIATION = (
	'~'             => '~',
	act_t           => 'action_topic',
	act_tpl         => 'action_template',
	atype           => 'automation_type',
	avty            => 'availability',
	avty_mode       => 'availability_mode',
	avty_t          => 'availability_topic',
	avty_tpl        => 'availability_template',
	bri_cmd_t       => 'brightness_command_topic',
	bri_scl         => 'brightness_scale',
	bri_stat_t      => 'brightness_state_topic',
	bri_val_tpl     => 'brightness_value_template',
	clr_temp_cmd_t  => 'color_temp_command_topic',
	clr_temp_stat_t => 'color_temp_state_topic',
	clr_temp_val_tpl => 'color_temp_value_template',
	cmd_t           => 'command_topic',
	cmd_tpl         => 'command_template',
	curr_hum_t      => 'current_humidity_topic',
	curr_hum_tpl    => 'current_humidity_template',
	curr_temp_t     => 'current_temperature_topic',
	curr_temp_tpl   => 'current_temperature_template',
	dev             => 'device',
	dev_cla         => 'device_class',
	ent_cat         => 'entity_category',
	evt_typ         => 'event_types',
	fx_cmd_t        => 'effect_command_topic',
	fx_list         => 'effect_list',
	fx_stat_t       => 'effect_state_topic',
	fx_val_tpl      => 'effect_value_template',
	fan_mode_cmd_t  => 'fan_mode_command_topic',
	fan_mode_cmd_tpl => 'fan_mode_command_template',
	fan_mode_stat_t => 'fan_mode_state_topic',
	fan_mode_stat_tpl => 'fan_mode_state_template',
	fan_modes       => 'fan_modes',
	json_attr_t     => 'json_attributes_topic',
	json_attr_tpl   => 'json_attributes_template',
	max             => 'max',
	max_hum         => 'max_humidity',
	max_temp        => 'max_temp',
	min             => 'min',
	min_hum         => 'min_humidity',
	min_temp        => 'min_temp',
	mode_cmd_t      => 'mode_command_topic',
	mode_cmd_tpl    => 'mode_command_template',
	mode_stat_t     => 'mode_state_topic',
	mode_stat_tpl   => 'mode_state_template',
	modes           => 'modes',
	name            => 'name',
	obj_id          => 'object_id',
	opt             => 'optimistic',
	ops             => 'options',
	pl_avail        => 'payload_available',
	pl              => 'payload',
	pl_cls          => 'payload_close',
	pl_home         => 'payload_home',
	pl_lock         => 'payload_lock',
	pl_not_avail    => 'payload_not_available',
	pl_not_home     => 'payload_not_home',
	pl_off          => 'payload_off',
	pl_on           => 'payload_on',
	pl_open         => 'payload_open',
	pl_stop         => 'payload_stop',
	pl_unlk         => 'payload_unlock',
	pow_cmd_t       => 'power_command_topic',
	pow_cmd_tpl     => 'power_command_template',
	pos_cmd_t       => 'position_command_topic',
	pos_stat_t      => 'position_topic',
	pos_tpl         => 'position_template',
	precision       => 'precision',
	preset_mode_cmd_t => 'preset_mode_command_topic',
	preset_mode_cmd_tpl => 'preset_mode_command_template',
	preset_mode_stat_t => 'preset_mode_state_topic',
	preset_mode_stat_tpl => 'preset_mode_value_template',
	preset_mode_val_tpl => 'preset_mode_value_template',
	preset_modes    => 'preset_modes',
	pr_mode_cmd_t   => 'preset_mode_command_topic',
	pr_mode_cmd_tpl => 'preset_mode_command_template',
	pr_mode_stat_t  => 'preset_mode_state_topic',
	pr_mode_val_tpl => 'preset_mode_value_template',
	pr_modes        => 'preset_modes',
	rgb_cmd_t       => 'rgb_command_topic',
	rgb_stat_t      => 'rgb_state_topic',
	rgb_val_tpl     => 'rgb_value_template',
	pct_cmd_t       => 'percentage_command_topic',
	pct_stat_t      => 'percentage_state_topic',
	ret             => 'retain',
	schema          => 'schema',
	stat_cla        => 'state_class',
	stat_t          => 'state_topic',
	stat_tpl        => 'state_template',
	stat_val_tpl    => 'state_value_template',
	step            => 'step',
	stype           => 'subtype',
	swing_mode_cmd_t => 'swing_mode_command_topic',
	swing_mode_cmd_tpl => 'swing_mode_command_template',
	swing_mode_stat_t => 'swing_mode_state_topic',
	swing_mode_stat_tpl => 'swing_mode_state_template',
	swing_modes     => 'swing_modes',
	swing_h_mode_cmd_t => 'swing_horizontal_mode_command_topic',
	swing_h_mode_cmd_tpl => 'swing_horizontal_mode_command_template',
	swing_h_mode_stat_t => 'swing_horizontal_mode_state_topic',
	swing_h_mode_stat_tpl => 'swing_horizontal_mode_state_template',
	swing_h_modes   => 'swing_horizontal_modes',
	t               => 'topic',
	hum_cmd_t       => 'target_humidity_command_topic',
	hum_cmd_tpl     => 'target_humidity_command_template',
	hum_stat_t      => 'target_humidity_state_topic',
	hum_stat_tpl    => 'target_humidity_state_template',
	hum_state_tpl   => 'target_humidity_state_template',
	temp_cmd_t      => 'temperature_command_topic',
	temp_cmd_tpl    => 'temperature_command_template',
	temp_hi_cmd_t   => 'temperature_high_command_topic',
	temp_hi_cmd_tpl => 'temperature_high_command_template',
	temp_hi_stat_t  => 'temperature_high_state_topic',
	temp_hi_stat_tpl => 'temperature_high_state_template',
	temp_lo_cmd_t   => 'temperature_low_command_topic',
	temp_lo_cmd_tpl => 'temperature_low_command_template',
	temp_lo_stat_t  => 'temperature_low_state_topic',
	temp_lo_stat_tpl => 'temperature_low_state_template',
	temp_stat_t     => 'temperature_state_topic',
	temp_stat_tpl   => 'temperature_state_template',
	temp_step       => 'temp_step',
	temp_unit       => 'temperature_unit',
	uniq_id         => 'unique_id',
	unit_of_meas    => 'unit_of_measurement',
	val_tpl         => 'value_template',
	value_template  => 'value_template',
	whit_cmd_t      => 'white_command_topic',
	whit_stat_t     => 'white_state_topic',
	whit_val_tpl    => 'white_value_template',
	cmps            => 'components',
	p               => 'platform',
	o               => 'origin',
);

my %DEVICE_ABBREVIATION = (
	cns    => 'connections',
	ids    => 'identifiers',
	mf     => 'manufacturer',
	mdl    => 'model',
	mdl_id => 'model_id',
	name   => 'name',
	sa     => 'suggested_area',
	sn     => 'serial_number',
	sw     => 'sw_version',
	hw     => 'hw_version',
	via    => 'via_device',
);

# Oeffentliche Liste fuer Dokumentation und Tests; die Sortierung ist stabil.
sub supported_components {
	return sort keys %SUPPORTED;
}

# Erzeugt ein einheitlich strukturiertes Parserfehler-Ergebnis fuer den Formatadapter.
sub _error {
	my ($class, $message, %extra) = @_;
	return { status => 'error', error_class => $class, error => $message, %extra };
}

# Liefert die konfigurierten Discovery-Prefixe mit einem sicheren HA-Standardwert.
sub _prefixes {
	my ($input) = @_;
	my @prefixes = ref($input) eq 'ARRAY' ? @$input : ('homeassistant');

	# Leere und doppelte Prefixe werden entfernt, ohne die konfigurierte
	# Prioritaet der verbleibenden Prefixe zu veraendern.
	@prefixes = map { trim($_) } @prefixes;
	return stable_unique(grep { $_ ne '' } @prefixes);
}

# Normalisiert Kurzschluessel und verschachtelte Device-Daten des HA-Payloads.
sub _normalise_hash {
	my ($source) = @_;
	my %normalised;

	# Ab hier arbeitet der Parser unabhaengig davon, ob der Sender kurze oder
	# ausgeschriebene HA-Schluessel verwendet hat.
	for my $key (keys %$source) {
		my $long = $ABBREVIATION{$key} || $key;
		$normalised{$long} = $source->{$key};
	}

	# Nur ein gueltiger Device-Block besitzt eigene Kurzformen und kann fuer das
	# kanonische Modell weiter normalisiert werden; andere Werte validiert _entity.
	if (ref($normalised{device}) eq 'HASH') {
		my %device;

		for my $key (keys %{ $normalised{device} }) {
			$device{$DEVICE_ABBREVIATION{$key} || $key} = $normalised{device}{$key};
		}

		for my $key (qw(identifiers connections)) {
			# Das kanonische Modell erwartet Listen, HA erlaubt hier auch Skalare.
			next if !exists $device{$key};
			$device{$key} = [ $device{$key} ] if ref($device{$key}) ne 'ARRAY';
		}

		$normalised{device} = \%device;
	}
	return \%normalised;
}

# Ersetzt HA-Basistopic-Platzhalter und weist ungueltige Topic-Werte kontrolliert ab.
sub _expand_topic {
	my ($base, $topic) = @_;
	return $topic if !defined($base) || !defined($topic) || ref($topic);
	$topic =~ s/^~/$base/;
	$topic =~ s/~$/$base/;
	return $topic;
}

# Das HA-Basis-Topic "~" darf am Anfang oder Ende einzelner Topic-Felder stehen.
sub _expand_topics {
	my ($config) = @_;
	my $base = $config->{'~'};
	$base = undef if defined($base) && ref($base);

	for my $key (keys %$config) {
		next if $key !~ /_topic$/;
		$config->{$key} = _expand_topic($base, $config->{$key});
	}

	# Mehrere Availability-Quellen liegen in Unterobjekten und benoetigen dort
	# dieselbe Kurzform- und Basis-Topic-Aufloesung wie die Hauptkonfiguration.
	if (ref($config->{availability}) eq 'ARRAY') {

		for my $entry (@{ $config->{availability} }) {
			next if ref($entry) ne 'HASH';
			my $normalised = _normalise_hash($entry);
			%$entry = %$normalised;
			$entry->{topic} = _expand_topic($base, $entry->{topic});
		}

	}
}

# Erkennt einen sicheren direkten JSON-Pfad als bevorzugten FHEM-Readingnamen.
sub _preferred_json_name {
	my ($template) = @_;
	return undef if !defined($template) || ref($template) || $template eq '';
	my $compiled = MQTT2_Discovery::Template::compile($template);
	return undef if !$compiled->{ok};
	my $name = MQTT2_Discovery::Template::simple_json_key($template, $compiled);
	return defined($name) && $name ne '' ? safe_name($name, 'state') : undef;
}

# Wertet HA-Boolesche Werte aus, ohne andere JSON-Strukturen als wahr anzunehmen.
sub _ha_true {
	my ($value) = @_;
	return 0 if !defined($value);
	return $value ? 1 : 0 if !ref($value) || ref($value) eq 'JSON::PP::Boolean';
	return 0;
}

# Erkennt die von HA angegebene Helligkeitsfaehigkeit alter und neuer Payloads.
sub _supports_brightness {
	my ($config) = @_;
	return 1 if _ha_true($config->{brightness});
	return 0 if ref($config->{supported_color_modes}) ne 'ARRAY';

	for my $mode (@{ $config->{supported_color_modes} }) {
		return 1 if defined($mode) && !ref($mode) && $mode ne 'onoff';
	}

	return 0;
}

# Leitet innerhalb des HA-Adapters einen fachlichen Set-Namen aus dem Topic ab.
sub _command_name {
	my ($topic) = @_;
	return undef if !defined($topic) || ref($topic);
	return safe_name($1, 'set') if $topic =~ m{/(?:cmd|command|set)/([^/]+)$};
	return undef;
}

# Uebersetzt HA-Schemaangaben in formatunabhaengige Signal- und Command-Metadaten.
sub _normalise_bindings {
	my ($config, $component, $value_template_ref) = @_;
	my $json_light = $component eq 'light'
		&& defined($config->{schema}) && !ref($config->{schema}) && $config->{schema} eq 'json';

	# Beim HA-JSON-Light ist das state-Feld auch ohne mitgeliefertes Template die
	# verbindliche Zustandsquelle. Diese HA-Regel endet bewusst an dieser Stelle.
	$$value_template_ref = '{{ value_json.state }}'
		if $json_light && (!defined($$value_template_ref) || $$value_template_ref eq '');
	my $preferred_name = _preferred_json_name($$value_template_ref);
	$config->{preferred_reading_name} = $preferred_name if defined($preferred_name);
	$config->{state_reading_name} = $preferred_name if defined($preferred_name);
	$config->{command_set_name} = _command_name($config->{command_topic})
		if !defined($config->{command_set_name});

	return if !$json_light;
	$config->{command_set_name} = $preferred_name || 'state';
	$config->{command_codec} = {
		format => 'json', key => 'state', value_type => 'string',
	};
	return if !_supports_brightness($config);

	# HA legt im JSON-Schema Helligkeit gemeinsam mit dem Zustand auf dieselben
	# Topics. Der gemeinsame Mapper sieht danach nur getrennte Normalbindungen.
	$config->{brightness_state_topic} = $config->{state_topic}
		if !defined($config->{brightness_state_topic});
	$config->{brightness_command_topic} = $config->{command_topic}
		if !defined($config->{brightness_command_topic});
	$config->{brightness_value_template} = '{{ value_json.brightness }}'
		if !defined($config->{brightness_value_template}) || $config->{brightness_value_template} eq '';
	$config->{brightness_reading_name} = 'brightness';
	$config->{brightness_set_name} = 'brightness';
	$config->{brightness_command_codec} = {
		format => 'json', key => 'brightness', value_type => 'number',
	};
}

# Baut aus einer validierten HA-Komponente die gemeinsame Parser-Entity auf.
sub _entity {
	my (%args) = @_;
	my $config = _normalise_hash($args{config});
	_expand_topics($config);

	# Nach Normalisierung und Topic-Expansion folgt ausschliesslich die
	# strukturelle Validierung der Entity.
	return _error('schema', 'device/dev muss ein JSON-Objekt sein', topic => $args{topic})
		if defined($config->{device}) && ref($config->{device}) ne 'HASH';
	my $component = $args{component} || $config->{platform};
	return _error('schema', 'Komponente fehlt', topic => $args{topic}) if !defined($component) || ref($component);
	return {
		status    => 'unsupported',
		component => $component,
		error     => "Nicht unterstuetzte Komponente: $component",
		topic     => $args{topic},
	} if !$SUPPORTED{$component};

	my $object_id = $config->{object_id};
	$object_id = $args{object_id} if !defined($object_id) || ref($object_id);
	my $value_template = exists($config->{value_template})
		? $config->{value_template}
		: exists($config->{state_value_template})
			? $config->{state_value_template}
			: $config->{state_template};
	_normalise_bindings($config, $component, \$value_template);
	my $state_topic = $config->{state_topic};

	# Device-Automations nennen ihr Eingangs-Topic historisch nur "topic".
	$state_topic = $config->{topic} if $component eq 'device_automation' && !defined($state_topic);
	my %entity = (
		operation       => 'upsert',
		prefix          => $args{prefix},
		format          => $args{format},
		component       => $component,
		node_id         => $args{node_id},
		object_id       => $object_id,
		discovery_topic => $args{topic},
		entity_key      => join('|', $args{topic}, defined($args{component_key}) ? $args{component_key} : ''),
		component_key   => $args{component_key},
		unique_id       => $config->{unique_id},
		name            => $config->{name},
		state_topic     => $state_topic,
		command_topic   => $config->{command_topic},
		value_template  => $value_template,
		command_template => $config->{command_template},
		availability    => $config->{availability},
		availability_topic => $config->{availability_topic},
		device_topic    => $config->{'~'},
		device          => $config->{device} || {},
		raw_metadata    => $config,
	);
	for my $key (qw(
		min max step options optimistic unit_of_measurement device_class state_class entity_category schema
		brightness effect color_temp color_mode white supported_color_modes
		preferred_reading_name state_reading_name command_set_name command_codec
		brightness_reading_name brightness_set_name brightness_command_codec
		payload_on payload_off payload_available payload_not_available payload_home
		payload_not_home payload_open payload_close payload_stop payload_lock
		payload_unlock payload_press brightness_command_topic brightness_state_topic
		brightness_value_template brightness_scale color_temp_command_topic
		color_temp_state_topic color_temp_value_template min_mireds max_mireds
		rgb_command_topic rgb_state_topic rgb_value_template effect_command_topic
		effect_state_topic effect_value_template effect_list white_command_topic
		white_state_topic white_value_template position_command_topic position_topic
		position_template tilt_command_topic tilt_status_topic tilt_status_template
		tilt_min tilt_max percentage_command_topic percentage_state_topic
		percentage_value_template percentage_min percentage_max percentage_step event_types
		action_topic action_template current_temperature_topic current_temperature_template
		current_humidity_topic current_humidity_template
		mode_command_topic mode_command_template mode_state_topic mode_state_template modes
		fan_mode_command_topic fan_mode_command_template fan_mode_state_topic fan_mode_state_template fan_modes
		swing_mode_command_topic swing_mode_command_template swing_mode_state_topic swing_mode_state_template swing_modes
		swing_horizontal_mode_command_topic swing_horizontal_mode_command_template
		swing_horizontal_mode_state_topic swing_horizontal_mode_state_template swing_horizontal_modes
		preset_mode_command_topic preset_mode_command_template preset_mode_state_topic preset_mode_value_template preset_modes
		temperature_command_topic temperature_command_template temperature_state_topic temperature_state_template
		temperature_high_command_topic temperature_high_command_template temperature_high_state_topic temperature_high_state_template
		temperature_low_command_topic temperature_low_command_template temperature_low_state_topic temperature_low_state_template
		target_humidity_command_topic target_humidity_command_template target_humidity_state_topic target_humidity_state_template
		power_command_topic power_command_template
		min_temp max_temp temp_step precision temperature_unit min_humidity max_humidity
		automation_type payload retain type subtype
	)) {
		# Nur bekannte, vom kanonischen Modell benoetigte Felder werden kopiert.
		$entity{$key} = $config->{$key} if exists $config->{$key};
	}
	return { status => 'ok', entities => [ \%entity ] };
}

# Parst ein HA-Config-Topic samt JSON-Payload in Upsert- oder Delete-Entities.
sub parse {
	my (%args) = @_;
	my $topic = $args{topic};
	my $payload = $args{payload};
	return _error('arguments', 'Topic fehlt') if !defined $topic;
	$payload = '' if !defined $payload;
	my @prefixes = _prefixes($args{prefixes});
	return _error('prefix', 'Keine gueltigen Discovery-Prefixe') if !@prefixes;

	my ($prefix) = grep { $topic eq $_ || index($topic, "$_/") == 0 } @prefixes;
	return { status => 'next' } if !defined $prefix;
	my $rest = substr($topic, length($prefix) + 1);
	my @parts = split m{/}, $rest, -1;
	return _error('topic', 'Ungueltiges Discovery-Topic', topic => $topic)
		if @parts < 3 || $parts[-1] ne 'config' || grep { $_ eq '' } @parts;

	my ($format, $component, $node_id, $object_id);

	# HA kennt Entity-Topics mit optionaler node_id sowie Device-Discovery mit
	# einem components-Objekt. Die Topiclaenge unterscheidet beide Formen.
	if ($parts[0] eq 'device' && @parts == 3) {
		($format, $object_id) = ('device', $parts[1]);
	} elsif (@parts == 3) {
		($format, $component, $object_id) = ('entity', $parts[0], $parts[1]);
	} elsif (@parts == 4) {
		($format, $component, $node_id, $object_id) = ('entity', @parts[0, 1, 2]);
	} else {
		return _error('topic', 'Ungueltiges Discovery-Topic', topic => $topic);
	}
	return _error('topic', 'node_id enthaelt ungueltige Zeichen', topic => $topic)
		if defined($node_id) && $node_id !~ /^[A-Za-z0-9_-]+$/;
	return _error('topic', 'object_id enthaelt ungueltige Zeichen', topic => $topic)
		if !defined($object_id) || $object_id !~ /^[A-Za-z0-9_-]+$/;

	# Ein leerer retained Payload entfernt die zuvor unter diesem Topic
	# veroeffentlichte Entity beziehungsweise das gesamte Device.
	if ($payload eq '') {
		return {
			status => 'ok',
			entities => [{
				operation       => $format eq 'device' ? 'delete_device' : 'delete',
				prefix          => $prefix,
				format          => $format,
				component       => $component,
				node_id         => $node_id,
				object_id       => $object_id,
				discovery_topic => $topic,
				entity_key      => join('|', $topic, ''),
			}],
		};
	}

	my $decoded;
	my $ok = eval { $decoded = decode_json($payload); 1 };
	return _error('json', "Ungueltiges JSON: $@", topic => $topic) if !$ok;
	return _error('schema', 'Discovery-Payload muss ein JSON-Objekt sein', topic => $topic)
		if ref($decoded) ne 'HASH';

	# Klassische Entity-Discovery enthaelt genau eine Konfiguration und kann ohne
	# die nachfolgende Device-Komponentenzerlegung direkt normalisiert werden.
	if ($format eq 'entity') {
		return _entity(
			config => $decoded, prefix => $prefix, format => $format,
			component => $component, node_id => $node_id, object_id => $object_id,
			topic => $topic,
		);
	}

	my $top = _normalise_hash($decoded);
	my $components = $top->{components};
	return _error('schema', 'Device-Discovery benoetigt ein components/cmps-Objekt', topic => $topic)
		if ref($components) ne 'HASH' || !keys %$components;
	my @entities;
	my @unsupported;
	my %shared = %$decoded;

	# Device-weite Felder werden mit jeder Komponenten-Konfiguration kombiniert;
	# die Komponente darf gemeinsame Werte gezielt ueberschreiben.
	delete @shared{qw(cmps components dev device o origin)};

	for my $component_key (sort keys %$components) {
		my $raw = $components->{$component_key};

		# Eine defekte Einzelkomponente soll gueltige Geschwister nicht blockieren;
		# sie wird deshalb als Warnung gesammelt und separat uebersprungen.
		if (ref($raw) ne 'HASH') {
			push @unsupported, "$component_key: Komponentenkonfiguration ist kein Objekt";
			next;
		}
		my %combined = (%shared, %$raw);
		$combined{dev} = $decoded->{dev} if !exists($combined{dev}) && exists($decoded->{dev});
		$combined{device} = $decoded->{device} if !exists($combined{device}) && exists($decoded->{device});
		$combined{'~'} = $decoded->{'~'} if !exists($combined{'~'}) && exists($decoded->{'~'});
		my $result = _entity(
			config => \%combined, prefix => $prefix, format => $format,
			object_id => $component_key, component_key => $component_key, topic => $topic,
		);

		# Nur erfolgreich normalisierte Komponenten werden Events; alle anderen
		# bleiben als komponentenspezifische Warnungen im Gesamtergebnis sichtbar.
		if ($result->{status} eq 'ok') {
			push @entities, @{ $result->{entities} };
		} else {
			push @unsupported, "$component_key: $result->{error}";
		}
	}

	return _error('schema', 'Device-Discovery enthaelt keine unterstuetzte Komponente',
		topic => $topic, warnings => \@unsupported) if !@entities;
	return { status => 'ok', entities => \@entities, warnings => \@unsupported };
}

1;

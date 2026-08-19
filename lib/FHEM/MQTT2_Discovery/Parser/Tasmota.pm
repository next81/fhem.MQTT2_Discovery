# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Parser::Tasmota;

use strict;
use warnings;
use JSON::PP qw(decode_json);
use MQTT2_Discovery::Helper qw(trim stable_unique);


# Erzeugt ein strukturiertes Fehlerergebnis mit eindeutiger Parserklassifikation.
sub _error {
	my ($class, $message, %extra) = @_;
	return { status => 'error', error_class => $class, error => $message, %extra };
}

# Liefert konfigurierte Tasmota-Discovery-Prefixe oder den kompatiblen Standardwert.
sub _prefixes {
	my ($input) = @_;
	my @prefixes = ref($input) eq 'ARRAY' ? @$input : ('homeassistant');
	@prefixes = map { trim($_) } @prefixes;
	return stable_unique(grep { $_ ne '' } @prefixes);
}

# Zerlegt und validiert ein Tasmota-Discovery-Topic in Prefix, MAC und Nachrichtenart.
sub _topic_parts {
	my ($topic, $prefixes) = @_;
	return if !defined $topic;

	# Native Tasmota-Discovery verwendet exakt <prefix>/<MAC>/<config|sensors>.
	# Die strikte Form verhindert, dass der Adapter HA-Topics beansprucht.
	for my $prefix (_prefixes($prefixes)) {
		next if index($topic, "$prefix/") != 0;
		my $rest = substr($topic, length($prefix) + 1);
		my @parts = split m{/}, $rest, -1;
		next if @parts != 2;
		my ($mac, $kind) = @parts;
		next if !defined($mac) || !defined($kind) || $mac !~ /^[A-Fa-f0-9]{12}$/;
		next if $kind ne 'config' && $kind ne 'sensors';
		return ($prefix, uc($mac), $kind);
	}

	return;
}

# Erkennt, ob ein Topic syntaktisch zu einem konfigurierten Tasmota-Prefix gehoert.
sub matches {
	my (%args) = @_;
	return scalar(_topic_parts($args{topic}, $args{prefixes})) ? 1 : 0;
}

# Uebernimmt nur definierte skalare Payloadwerte als sichere Zeichenkette.
sub _scalar_string {
	my ($value) = @_;
	return undef if !defined($value) || ref($value);
	return "$value";
}

# Bestimmt den gemeinsamen Telemetrie- und Kommando-Topicstamm des Tasmota-Geraets.
sub _topic_base {
	my ($config, $index) = @_;
	my $topic = _scalar_string($config->{t});
	return (undef, 'Tasmota config: t (Topic) fehlt') if !defined($topic) || $topic eq '';
	my $configured_full = _scalar_string($config->{ft});
	my $full = defined($configured_full) ? $configured_full : '%prefix%/%topic%/';
	my $prefixes = $config->{tp};
	return (undef, 'Tasmota config: tp muss mindestens cmnd/stat/tele enthalten')
		if ref($prefixes) ne 'ARRAY' || @$prefixes < 3;
	my $prefix = _scalar_string($prefixes->[$index]);
	return (undef, 'Tasmota config: ungueltiger MQTT-Prefix')
		if !defined($prefix) || $prefix eq '';
	return (undef, 'Tasmota config: ft muss %prefix% und %topic% enthalten')
		if index($full, '%prefix%') < 0 || index($full, '%topic%') < 0;

	# Die Ersetzung entspricht Tasmotas FullTopic-Platzhaltern, ohne den Wert
	# als regulaeren Ausdruck oder Perl-Code auszuwerten.
	$full =~ s/%prefix%/$prefix/g;
	$full =~ s/%topic%/$topic/g;
	my $hostname = _scalar_string($config->{hn}) || '';
	my $id = _scalar_string($config->{mac}) || '';
	$id =~ s/[^A-Fa-f0-9]//g;
	$id = substr($id, -6) if length($id) > 6;
	$full =~ s/%hostname%/$hostname/g;
	$full =~ s/%id%/$id/g;
	$full =~ s{/+$}{};
	return (undef, 'Tasmota config: erzeugtes MQTT-Basistopic ist ungueltig')
		if $full eq '' || $full =~ /[\s\x00-\x1f{}]/;
	return ($full, undef);
}

# Baut die stabilen Device-Metadaten aus MAC, Namen und optionalen Produktangaben.
sub _device {
	my ($config, $mac) = @_;
	my $name = _scalar_string($config->{dn}) || _scalar_string($config->{hn})
		|| _scalar_string($config->{t}) || "Tasmota $mac";
	my %device = (
		identifiers  => ["tasmota_$mac"],
		connections  => [['mac', $mac]],
		name         => $name,
		manufacturer => 'Tasmota',
	);
	$device{model} = "$config->{md}" if defined(_scalar_string($config->{md}));
	$device{sw_version} = "$config->{sw}" if defined(_scalar_string($config->{sw}));
	return \%device;
}

# Erzeugt die von allen Tasmota-Entities gemeinsam benoetigten Quell- und Devicefelder.
sub _entity_base {
	my (%args) = @_;
	my $object_id = $args{object_id};

	# Gemeinsame Identitaets-, Availability- und Device-Felder werden hier
	# einmal fuer alle abgeleiteten Tasmota-Entities aufgebaut.
	return {
		operation          => 'upsert',
		prefix             => $args{prefix},
		format             => 'tasmota',
		component          => $args{component},
		node_id            => $args{mac},
		object_id          => $object_id,
		component_key      => $object_id,
		discovery_topic    => $args{discovery_topic},
		entity_key         => join('|', $args{discovery_topic}, $object_id),
		unique_id          => join('_', 'tasmota', lc($args{mac}), $object_id),
		name               => $args{name},
		availability_topic => "$args{telemetry_base}/LWT",
		payload_available  => defined($args{config}{onln}) ? "$args{config}{onln}" : 'Online',
		payload_not_available => defined($args{config}{ofln}) ? "$args{config}{ofln}" : 'Offline',
		device             => $args{device},
		raw_metadata       => {
			protocol => 'tasmota', version => $args{config}{ver}, json_autocreate => 1,
		},
	};
}

# Liefert den zur Kanalzahl passenden POWER-Schluessel fuer Status und Kommandos.
sub _power_name {
	my ($index, $numbered) = @_;
	return !$numbered && $index == 1 ? 'POWER' : "POWER$index";
}

# Sammelt numerierte POWER-Schluessel in stabiler numerischer Reihenfolge.
sub _numbered_power_names {
	my ($config, $relays) = @_;
	my $set_options = ref($config->{so}) eq 'HASH' ? $config->{so} : {};

	# SetOption26 erzwingt POWER1; mehrere aktive Kanaele benoetigen ebenfalls
	# nummerierte Namen, damit kein Relay kollidiert.
	return 1 if $set_options->{26};
	return scalar(grep {
		defined($_) && !ref($_) && /^\d+$/ && $_ != 0
	} @{ $relays || [] }) > 1;
}

# Beschreibt Topic und JSON-Pfad eines Tasmota-Statuswertes als kanonische Quelle.
sub _state_source {
	my ($config, $stat_base, $command) = @_;
	my $set_options = ref($config->{so}) eq 'HASH' ? $config->{so} : {};

	# Mit SetOption4 publiziert Tasmota einzelne stat-Topics, sonst liegen die
	# Werte gemeinsam im RESULT-JSON.
	if ($set_options->{4}) {
		return ("$stat_base/$command", undef);
	}
	return ("$stat_base/RESULT", "{{ value_json.$command }}");
}

# Leitet Farb-, Weiss-, Dimm- und Farbtemperaturfaehigkeiten eines Lichtkanals ab.
sub _light_details {
	my ($entity, $config, $offset, $first_light, $stat_base, $command_base) = @_;
	my $options = ref($config->{so}) eq 'HASH' ? $config->{so} : {};

	# LightSubType, Tuya- und SetOption-Sonderfaelle bestimmen, welche
	# Helligkeits-, Farbtemperatur- und Farbkommandos das Relay anbietet.
	my $light_type = defined($config->{lt_st}) && !ref($config->{lt_st}) && $config->{lt_st} =~ /^\d+$/
		? 0 + $config->{lt_st} : 0;
	my ($dimmer_command, $dimmer_state, $color_suffix) = ('Dimmer', 'Dimmer', '');

	# Tuya-Light-Konfigurationen verwenden Dimmer3 statt des normalen
	# Tasmota-Dimmerkommandos fuer Helligkeit und Status.
	if ($config->{ty}) {
		($dimmer_command, $dimmer_state) = ('Dimmer3', 'Dimmer3');
	}

	# SetOption68 macht aus jedem PWM-Kanal ein eigenstaendiges Monochromlicht
	# und ersetzt deshalb die kombinierte LightSubType-Auswertung.
	if ($options->{68}) {
		$light_type = 1;
		($dimmer_command, $dimmer_state) = ("Channel" . ($offset + 1), "Channel" . ($offset + 1));
	} elsif (!$config->{lk} && $light_type >= 4) {
		my $relative = $offset - $first_light;

		# Nicht gekoppelte Mehrkanallichter teilen den ersten kombinierten
		# LightSubType in getrennte Dimmer-Entities mit eigener Kanalrolle auf.
		if ($relative == 0) {
			($light_type, $dimmer_command, $dimmer_state, $color_suffix) = (3, 'Dimmer1', 'Dimmer1', '=');
		} elsif ($relative == 1) {
			$light_type = $light_type == 4 ? 1 : 2;
			($dimmer_command, $dimmer_state) = ('Dimmer2', 'Dimmer2');
		}
	}
	return if $light_type <= 0;

	my ($brightness_topic, $brightness_template) = _state_source($config, $stat_base, $dimmer_state);
	$entity->{brightness_command_topic} = "$command_base/$dimmer_command";
	$entity->{brightness_state_topic} = $brightness_topic;
	$entity->{brightness_value_template} = $brightness_template if defined $brightness_template;
	$entity->{brightness_scale} = 100;

	my ($effect_topic, $effect_template) = _state_source($config, $stat_base, 'Scheme');
	$entity->{effect_command_topic} = "$command_base/Scheme";
	$entity->{effect_state_topic} = $effect_topic;
	$entity->{effect_value_template} = $effect_template if defined $effect_template;
	$entity->{effect_list} = ['Solid', 'Wake up', 'Cycle up', 'Cycle down', 'Random'];

	# Ab LightSubType 2 steht ein eigener Farbtemperaturkanal zur Verfuegung;
	# SetOption82 schraenkt dessen physikalischen Bereich ein.
	if ($light_type >= 2) {
		my ($ct_topic, $ct_template) = _state_source($config, $stat_base, 'CT');
		$entity->{color_temp_command_topic} = "$command_base/CT";
		$entity->{color_temp_state_topic} = $ct_topic;
		$entity->{color_temp_value_template} = $ct_template if defined $ct_template;
		($entity->{min_mireds}, $entity->{max_mireds}) = $options->{82} ? (200, 380) : (153, 500);
	}

	# Ab LightSubType 3 liefert Tasmota RGB-Farbe zusaetzlich zur Helligkeit.
	if ($light_type >= 3) {
		my ($color_topic, $color_template) = _state_source($config, $stat_base, 'Color');
		$entity->{rgb_command_topic} = "$command_base/Color2";
		$entity->{rgb_state_topic} = $color_topic;
		$entity->{rgb_value_template} = $color_template if defined $color_template;
		$entity->{raw_metadata}{color_suffix} = $color_suffix if $color_suffix ne '';
	}

	# Nur RGBW-Geraete vom Typ 4 besitzen neben RGB einen separaten Weisskanal.
	if ($light_type == 4) {
		my ($white_topic, $white_template) = _state_source($config, $stat_base, 'White');
		$entity->{white_command_topic} = "$command_base/White";
		$entity->{white_state_topic} = $white_topic;
		$entity->{white_value_template} = $white_template if defined $white_template;
	}
}

# Erzeugt zusaetzliche Trigger-, Button- und Hilfs-Entities aus Options- und GPIO-Daten.
sub _supplemental_entities {
	my (%args) = @_;
	my $config = $args{config};
	my $states = ref($config->{state}) eq 'ARRAY' ? $config->{state} : [];
	my $options = ref($config->{so}) eq 'HASH' ? $config->{so} : {};
	my (@entities, @warnings);

	# Optionale Fan-, Switch- und Button-Funktionen liegen ausserhalb der
	# eigentlichen Relayliste und werden als zusaetzliche Entities erzeugt.
	if ($config->{if}) {
		my $fan = _entity_base(%args, component => 'fan', object_id => 'fan', name => 'Fan');
		my ($fan_topic, $fan_template) = _state_source($config, $args{stat_base}, 'FanSpeed');
		$fan->{percentage_command_topic} = "$args{command_base}/FanSpeed";
		$fan->{percentage_state_topic} = $fan_topic;
		$fan->{percentage_value_template} = $fan_template if defined $fan_template;
		@{$fan}{qw(percentage_min percentage_max percentage_step)} = (0, 3, 1);
		push @entities, $fan;
	}

	my $switches = ref($config->{swc}) eq 'ARRAY' ? $config->{swc} : [];
	my $switch_names = ref($config->{swn}) eq 'ARRAY' ? $config->{swn} : [];
	my %binary_mode = map { $_ => 1 } qw(1 2 3 4 5 6 9 10 13 14 15 16);
	my %trigger_mode = map { $_ => 1 } qw(0 3 4 5 6 7 8 9 10 11 12);

	for my $offset (0 .. $#$switches) {
		my $mode = $switches->[$offset];
		next if !defined($mode) || ref($mode) || $mode !~ /^-?\d+$/ || $mode < 0;
		my $index = $offset + 1;
		my $switch_name = _scalar_string($switch_names->[$offset]) || "Switch$index";
		my $template = _template_path([$switch_name, 'Action']);

		# Ein SwitchMode kann gleichzeitig einen dauerhaften Binaerzustand und
		# kurzlebige Trigger-Events liefern.
		if ($binary_mode{$mode}) {
			my $binary = _entity_base(%args, component => 'binary_sensor', object_id => "switch_$index", name => $switch_name);
			$binary->{state_topic} = "$args{stat_base}/RESULT";
			$binary->{value_template} = $template;
			$binary->{payload_off} = defined($states->[0]) && !ref($states->[0]) ? "$states->[0]" : 'OFF';
			$binary->{payload_on} = defined($states->[1]) && !ref($states->[1]) ? "$states->[1]" : 'ON';
			push @entities, $binary;
		}

		# Triggerfaehige SwitchModes erzeugen zusaetzlich kurzlebige
		# Device-Automation-Events, auch wenn bereits ein Binaersensor existiert.
		if ($trigger_mode{$mode}) {
			my $trigger = _entity_base(%args, component => 'device_automation',
				object_id => "switch_${index}_action", name => "$switch_name action");
			$trigger->{state_topic} = "$args{stat_base}/RESULT";
			$trigger->{value_template} = $template;
			$trigger->{automation_type} = 'trigger';
			$trigger->{subtype} = "switch_$index";
			push @entities, $trigger;
		}
	}

	my $buttons = ref($config->{btn}) eq 'ARRAY' ? $config->{btn} : [];

	# SetOption73 publiziert lokale Button-Aktionen per MQTT und macht erst dann
	# die entsprechenden Device-Automation-Entities sinnvoll nutzbar.
	if ($options->{73}) {

		for my $offset (0 .. $#$buttons) {
			next if !$buttons->[$offset];
			my $index = $offset + 1;
			my $trigger = _entity_base(%args, component => 'device_automation',
				object_id => "button_${index}_action", name => "Button $index action");
			$trigger->{state_topic} = "$args{stat_base}/RESULT";
			$trigger->{value_template} = _template_path(["Button$index", 'Action']);
			$trigger->{automation_type} = 'trigger';
			$trigger->{subtype} = "button_$index";
			push @entities, $trigger;
		}

	}
	push @warnings, 'Tasmota-Kamera erkannt; ein Kamerastream ist nicht als MQTT2_DEVICE-State abbildbar'
		if $config->{cam};
	return (\@entities, \@warnings);
}

# Rekonstruiert Schalter, Lichter und Rolllaeden aus dem zusammengefuehrten Configzustand.
sub _actuator_entities {
	my (%args) = @_;
	my $config = $args{config};
	my $relays = $config->{rl};
	return ([], ['Tasmota config: rl ist kein Array']) if ref($relays) ne 'ARRAY';
	my $friendly = ref($config->{fn}) eq 'ARRAY' ? $config->{fn} : [];
	my $states = ref($config->{state}) eq 'ARRAY' ? $config->{state} : [];
	my $set_options = ref($config->{so}) eq 'HASH' ? $config->{so} : {};
	my (@entities, @warnings);
	my $shutter = 0;
	my $numbered_power_names = _numbered_power_names($config, $relays);
	my ($first_light) = grep { ($relays->[$_] || 0) == 2 } 0 .. $#$relays;
	$first_light = 0 if !defined $first_light;

	# Relaytypen: 1=Switch, 2=Light, 3=Shutter-Haelfte. Unbekannte Werte werden
	# nicht geraten, sondern als Warnung weitergegeben.
	for my $offset (0 .. $#$relays) {
		my $type = $relays->[$offset];
		next if !defined($type) || ref($type) || $type !~ /^\d+$/ || !$type;
		my $index = $offset + 1;

		# Relaytyp 3 markiert den Beginn eines moeglichen Zweierpaars fuer einen
		# Shutter und wird nicht wie ein einzelner Schaltkanal behandelt.
		if ($type == 3) {
			next if $offset > 0 && ($relays->[$offset - 1] || 0) == 3;

			# Ein unvollstaendiges Paar kann weder Richtung noch Position sicher
			# steuern und wird deshalb nur als Warnung dokumentiert.
			if ($offset == $#$relays || ($relays->[$offset + 1] || 0) != 3) {
				push @warnings, "Unvollstaendiges Tasmota-Shutterpaar an Relay $index";
				next;
			}
			++$shutter;
			my $object_id = $shutter == 1 ? 'shutter' : "shutter_$shutter";
			my $name = _scalar_string($friendly->[$offset]) || "Shutter $shutter";
			my $entity = _entity_base(%args, component => 'cover', object_id => $object_id, name => $name);
			$entity->{command_topic} = "$args{command_base}/Backlog";
			$entity->{payload_open} = "ShutterOpen$shutter";
			$entity->{payload_close} = "ShutterClose$shutter";
			$entity->{payload_stop} = "ShutterStop$shutter";
			$entity->{state_topic} = "$args{stat_base}/RESULT";
			$entity->{value_template} = _template_path(["Shutter$shutter", 'Direction']);
			$entity->{position_topic} = "$args{stat_base}/RESULT";
			$entity->{position_template} = _template_path(["Shutter$shutter", 'Position']);
			$entity->{position_command_topic} = "$args{command_base}/ShutterPosition$shutter";
			my $tilts = ref($config->{sht}) eq 'ARRAY' ? $config->{sht} : [];
			my $tilt = $tilts->[$shutter - 1];

			# Tilt wird nur angeboten, wenn Tasmota die Funktion aktiviert und einen
			# echten, nichtleeren Stellbereich meldet.
			if (ref($tilt) eq 'ARRAY' && @$tilt >= 3 && $tilt->[2] && $tilt->[0] != $tilt->[1]) {
				$entity->{tilt_command_topic} = "$args{command_base}/ShutterTilt$shutter";
				$entity->{tilt_status_topic} = "$args{stat_base}/RESULT";
				$entity->{tilt_status_template} = _template_path(["Shutter$shutter", 'Tilt']);
				($entity->{tilt_min}, $entity->{tilt_max}) = @$tilt[0, 1];
			}
			my $shutter_options = ref($config->{sho}) eq 'ARRAY' ? $config->{sho} : [];
			push @warnings, "Invertierter Shutter $shutter wird mit roher Tasmota-Position abgebildet"
				if ($shutter_options->[$shutter - 1] || 0) & 1;
			push @entities, $entity;
			next;
		}

		# Unbekannte Relaytypen werden nicht als Switch geraten, weil daraus
		# falsche Kommandos an eine moeglicherweise andere Hardwarefunktion entstuenden.
		if ($type != 1 && $type != 2) {
			push @warnings, "Unbekannter Tasmota-Relaytyp $type an Position $index";
			next;
		}
		my $command = _power_name($index, $numbered_power_names);
		my ($state_topic, $value_template) = _state_source($config, $args{stat_base}, $command);
		my $component = $type == 2 || $set_options->{30} ? 'light' : 'switch';
		# Die stabile Entity-ID ist unabhaengig davon, ob Tasmota den ersten
		# MQTT-/JSON-Kanal als POWER oder POWER1 ausgibt.
		my $object_id = $index == 1 ? 'power' : "power$index";
		my $name = _scalar_string($friendly->[$offset])
			|| (($args{device}{name} || 'Tasmota') . ($index == 1 ? '' : " $index"));
		my $entity = _entity_base(%args, component => $component, object_id => $object_id, name => $name);
		$entity->{state_topic} = $state_topic;
		$entity->{value_template} = $value_template if defined $value_template;
		$entity->{raw_metadata}{state_reading_name} = $command if !defined $value_template;
		$entity->{command_topic} = "$args{command_base}/$command";
		$entity->{payload_off} = defined($states->[0]) && !ref($states->[0]) ? "$states->[0]" : 'OFF';
		$entity->{payload_on} = defined($states->[1]) && !ref($states->[1]) ? "$states->[1]" : 'ON';
		_light_details($entity, $config, $offset, $first_light, $args{stat_base}, $args{command_base})
			if $component eq 'light' && $type == 2;
		push @entities, $entity;
	}

	my ($supplemental, $supplemental_warnings) = _supplemental_entities(%args);
	push @entities, @$supplemental;
	push @warnings, @$supplemental_warnings;
	return (\@entities, \@warnings);
}

my %SENSOR_METADATA = (
	temperature   => ['temperature', undef, 'measurement'],
	dewpoint      => ['temperature', undef, 'measurement'],
	humidity      => ['humidity', '%', 'measurement'],
	pressure      => ['pressure', 'hPa', 'measurement'],
	power         => ['power', 'W', 'measurement'],
	activepower   => ['power', 'W', 'measurement'],
	apparentpower => ['apparent_power', 'VA', 'measurement'],
	reactivepower => ['reactive_power', 'var', 'measurement'],
	voltage       => ['voltage', 'V', 'measurement'],
	current       => ['current', 'A', 'measurement'],
	frequency     => ['frequency', 'Hz', 'measurement'],
	factor        => ['power_factor', undef, 'measurement'],
	total         => ['energy', 'kWh', 'total_increasing'],
	today         => ['energy', 'kWh', 'total'],
	yesterday     => ['energy', 'kWh', 'total'],
	illuminance   => ['illuminance', 'lx', 'measurement'],
	battery       => ['battery', '%', 'measurement'],
	rssi          => ['signal_strength', 'dBm', 'measurement'],
	co2           => ['carbon_dioxide', 'ppm', 'measurement'],
	eco2          => ['carbon_dioxide', 'ppm', 'measurement'],
	pm1           => ['pm1', "\x{b5}g/m\x{b3}", 'measurement'],
	'pm2.5'       => ['pm25', "\x{b5}g/m\x{b3}", 'measurement'],
	pm10          => ['pm10', "\x{b5}g/m\x{b3}", 'measurement'],
);

# Metadaten werden anhand des spezifischsten bekannten Pfadsegments bestimmt.
# So funktioniert beispielsweise ENERGY/Power ebenso wie Power auf Root-Ebene.
sub _sensor_metadata_key {
	my ($path) = @_;
	return undef if ref($path) ne 'ARRAY';

	for my $part (reverse @$path) {
		next if !defined($part) || ref($part) || "$part" =~ /^\d+$/;
		my $key = lc("$part");
		return $key if exists $SENSOR_METADATA{$key};
	}

	return undef;
}

# Uebersetzt einen JSON-Pfad in die eingeschraenkte Template-Pfadsyntax.
sub _template_path {
	my ($path) = @_;
	my $template = 'value_json';

	# Jeder Pfadteil wird in eine Form gebracht, die vom sicheren
	# Template-Parser wieder verstanden wird.
	for my $part (@$path) {

		# Numerische Teile sind Arrayindizes, einfache Bezeichner Punktzugriffe und
		# sichere Sondernamen quotierte Hashzugriffe.
		if (!ref($part) && $part =~ /^\d+$/) {
			$template .= "[$part]";
		} elsif (!ref($part) && $part =~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
			$template .= ".$part";
		} elsif (!ref($part) && $part !~ /['"\x00-\x1f]/) {
			$template .= "['$part']";
		} else {
			return undef;
		}
	}

	return "{{ $template }}";
}

# Bildet verschachtelte JSON-Pfade so auf Namen ab, wie FHEMs json2nameValue es tut.
sub _fhem_json_reading_name {
	my ($path) = @_;
	return undef if ref($path) ne 'ARRAY' || !@$path;
	my @parts;

	for my $part (@$path) {
		return undef if !defined($part) || ref($part);

		# json2nameValue zaehlt Arrayelemente ab eins; der erzeugte Reading-Name
		# muss diese Konvention statt des nullbasierten JSON-Pfads verwenden.
		if ("$part" =~ /^\d+$/) {
			push @parts, 1 + $part; # json2nameValue nummeriert Arrays ab 1.
			next;
		}
		my $name = "$part";
		$name =~ s/[^A-Za-z0-9._\-\/]/_/g; # entspricht makeReadingName fuer Tasmotas ASCII-Schluessel.
		return undef if $name eq '';
		push @parts, $name;
	}

	return join('_', @parts);
}

# Durchlaeuft Sensor-JSON rekursiv und sammelt ausschliesslich skalare Blattwerte.
sub _walk_sensor_leaves {
	my ($value, $path, $leaves, $warnings) = @_;

	# Sensor-Samples koennen beliebig verschachtelte Objekte und Arrays
	# enthalten; nur skalare Blattwerte werden zu Entities.
	if (ref($value) eq 'HASH') {
		_walk_sensor_leaves($value->{$_}, [@$path, $_], $leaves, $warnings) for sort keys %$value;
		return;
	}

	# Arrays werden positionsstabil durchlaufen, damit jeder Index Bestandteil
	# des spaeteren Entity- und Reading-Namens wird.
	if (ref($value) eq 'ARRAY') {
		_walk_sensor_leaves($value->[$_], [@$path, $_], $leaves, $warnings) for 0 .. $#$value;
		return;
	}
	return if ref($value) && ref($value) ne 'JSON::PP::Boolean';
	my $leaf = lc(defined($path->[-1]) ? "$path->[-1]" : '');

	# Zeit- und Einheitenfelder beschreiben das Sample, sind aber keine Sensoren.
	return if $leaf =~ /^(?:time|tempunit|pressureunit|totalstarttime)$/;
	my $template = _template_path($path);

	# Nicht sicher quotierbare Pfade duerfen keine ausfuehrbare Template-Zeile
	# erzeugen und werden deshalb sichtbar als Warnung verworfen.
	if (!defined $template) {
		push @$warnings, 'Tasmota-Sensorpfad kann nicht sicher abgebildet werden';
		return;
	}
	push @$leaves, [$path, $template];
}

# Wandelt alle sicheren Sensorblaetter in lesbare Tasmota-Sensor-Entities um.
sub _sensor_entities {
	my (%args) = @_;
	my $sensors = $args{sensors};
	return ([], []) if ref($sensors) ne 'HASH';
	my $sample = $sensors->{sn};
	return ([], ['Tasmota sensors: sn ist kein Objekt']) if ref($sample) ne 'HASH';
	my (@leaves, @warnings, @entities);
	_walk_sensor_leaves($sample, [], \@leaves, \@warnings);

	# Jedes Blatt erhaelt eine stabile Entity-ID und ein value_json-Template.
	for my $leaf (@leaves) {
		my ($path, $template) = @$leaf;
		my @id_parts = map { defined($_) ? lc("$_") : '' } @$path;
		my $object_id = join('_', @id_parts);
		my $name = join(' ', map { defined($_) ? "$_" : '' } @$path);
		my $entity = _entity_base(%args, component => 'sensor', object_id => $object_id, name => $name);
		$entity->{raw_metadata}{json_reading_name} = _fhem_json_reading_name($path);
		$entity->{state_topic} = "$args{telemetry_base}/SENSOR";
		$entity->{value_template} = $template;
		my $key = _sensor_metadata_key($path);

		# Bekannte Messgroessen erhalten die fachlichen Metadaten, die FHEM und die
		# semantische Oberflaeche fuer Einheit und Darstellung benoetigen.
		if (defined($key) && (my $metadata = $SENSOR_METADATA{$key})) {
			$entity->{device_class} = $metadata->[0] if defined $metadata->[0];
			my $unit = $metadata->[1];

			# Temperatur und Druck koennen geraetespezifische Einheiten im Sample
			# mitliefern; diese sind genauer als die statischen Standardwerte.
			if ($key eq 'temperature' || $key eq 'dewpoint') {
				$unit = _scalar_string($sample->{TempUnit}) || "\x{b0}C";
				$unit = "\x{b0}$unit" if $unit =~ /^[CF]$/;
			} elsif ($key eq 'pressure') {
				$unit = _scalar_string($sample->{PressureUnit}) || $unit;
			}
			$entity->{unit_of_measurement} = $unit if defined $unit;
			$entity->{state_class} = $metadata->[2] if defined $metadata->[2];
		}
		push @entities, $entity;
	}

	return (\@entities, \@warnings);
}

# Ergaenzt bekannte Sensortypen um Einheit, Rolle und benutzerfreundlichen Namen.
sub _reading_profile {
	my (%args) = @_;
	my $config = $args{config};
	my $relays = ref($config->{rl}) eq 'ARRAY' ? $config->{rl} : [];
	my $numbered = _numbered_power_names($config, $relays);
	my @power_readings;

	# Das Profil beschreibt weitere Standard-Readings fuer den spaeteren Mapper,
	# ohne hier bereits FHEM-readingList-Zeilen zu erzeugen.
	for my $offset (0 .. $#$relays) {
		my $type = $relays->[$offset];
		next if !defined($type) || ref($type) || $type !~ /^\d+$/ || ($type != 1 && $type != 2);
		my $command = _power_name($offset + 1, $numbered);
		push @power_readings, {
			command => $command,
			reading => $command,
		};
	}

	return {
		telemetry_base => $args{telemetry_base},
		stat_base      => $args{stat_base},
		power_readings => \@power_readings,
	};
}

# Baut aus dem gepufferten Config- und Sensorzustand den vollstaendigen Entitysatz neu auf.
sub _rebuild {
	my (%args) = @_;
	my $config = $args{entry}{config};
	return { status => 'ok', entities => [], warnings => [] } if ref($config) ne 'HASH';

	# config und sensors treffen auf getrennten Topics ein. Nach jeder Aenderung
	# wird aus dem gemeinsamen Cache ein vollstaendiger Device-Stand erzeugt.
	my ($command_base, $command_error) = _topic_base($config, 0);
	return _error('schema', $command_error, topic => $args{topic}) if $command_error;
	my ($stat_base, $stat_error) = _topic_base($config, 1);
	return _error('schema', $stat_error, topic => $args{topic}) if $stat_error;
	my ($telemetry_base, $telemetry_error) = _topic_base($config, 2);
	return _error('schema', $telemetry_error, topic => $args{topic}) if $telemetry_error;
	my $discovery_topic = "$args{prefix}/$args{mac}/config";
	my $device = _device($config, $args{mac});
	my %common = (
		prefix => $args{prefix}, mac => $args{mac}, config => $config,
		discovery_topic => $discovery_topic, device => $device,
		command_base => $command_base, stat_base => $stat_base,
		telemetry_base => $telemetry_base,
	);
	my ($actuators, $actuator_warnings) = _actuator_entities(%common);
	my ($sensors, $sensor_warnings) = _sensor_entities(%common, sensors => $args{entry}{sensors});
	my ($profile_owner) = (@$actuators, @$sensors);

	# Ein einziges Entity transportiert das geraeteweite Reading-Profil; beim
	# Zusammenfassen landet es trotzdem genau einmal am Zieldevice.
	$profile_owner->{raw_metadata}{tasmota_reading_profile} = _reading_profile(%common)
		if $profile_owner;
	my $delete = {
		operation => 'delete_device', prefix => $args{prefix}, format => 'tasmota',
		node_id => $args{mac}, discovery_topic => $discovery_topic,
		entity_key => join('|', $discovery_topic, ''),
	};
	return {
		status => 'ok',
		entities => [$delete, @$actuators, @$sensors],
		warnings => [@$actuator_warnings, @$sensor_warnings],
	};
}

# Verarbeitet retained Config- und Sensornachrichten zustandsbehaftet zu Discovery-Entities.
sub parse {
	my (%args) = @_;
	my ($prefix, $mac, $kind) = _topic_parts($args{topic}, $args{prefixes});
	return { status => 'next' } if !defined $prefix;
	my $state = $args{state};
	return _error('arguments', 'Tasmota-Zustand fehlt', topic => $args{topic}) if ref($state) ne 'HASH';
	my $payload = defined($args{payload}) ? $args{payload} : '';
	my $entry = $state->{$mac} ||= {};

	# Leere retained Payloads entfernen nur den jeweiligen Cacheteil. Beim
	# config-Topic wird das ganze Device, bei sensors nur die Sensorlage entfernt.
	if ($payload eq '') {
		delete $entry->{$kind};

		# Ohne Config existiert keine belastbare Geraetedefinition mehr; daher wird
		# sofort ein Delete-Device-Event statt eines Teil-Rebuilds erzeugt.
		if ($kind eq 'config') {
			delete $state->{$mac} if !keys %$entry;
			return {
				status => 'ok',
				entities => [{
					operation => 'delete_device', prefix => $prefix, format => 'tasmota',
					node_id => $mac, discovery_topic => "$prefix/$mac/config",
					entity_key => join('|', "$prefix/$mac/config", ''),
				}],
				warnings => [],
			};
		}
		return _rebuild(%args, prefix => $prefix, mac => $mac, entry => $entry);
	}

	my $decoded;
	my $ok = eval { $decoded = decode_json($payload); 1 };
	return _error('json', "Ungueltiges Tasmota-JSON: $@", topic => $args{topic}) if !$ok;
	return _error('schema', 'Tasmota-Discovery-Payload muss ein JSON-Objekt sein', topic => $args{topic})
		if ref($decoded) ne 'HASH';
	return _error('version', "Nicht unterstuetzte Tasmota-Discovery-Version: $decoded->{ver}", topic => $args{topic})
		if defined($decoded->{ver}) && (ref($decoded->{ver}) || "$decoded->{ver}" ne '1');
	return _error('schema', 'Tasmota sensors benoetigt ein sn-Objekt', topic => $args{topic})
		if $kind eq 'sensors' && ref($decoded->{sn}) ne 'HASH';

	# Wenn die Config selbst eine MAC nennt, muss sie dieselbe physische
	# Identitaet wie das Discovery-Topic beschreiben.
	if ($kind eq 'config' && defined($decoded->{mac}) && !ref($decoded->{mac})) {
		my $payload_mac = uc("$decoded->{mac}");
		$payload_mac =~ s/[^A-F0-9]//g;
		return _error('identity', "Tasmota-MAC in Topic und Payload stimmt nicht ueberein: $mac != $payload_mac",
			topic => $args{topic}) if $payload_mac ne $mac;
	}

	# Erst nach vollstaendiger Validierung wird der Format-Zustand ersetzt.
	$entry->{$kind} = $decoded;
	return _rebuild(%args, prefix => $prefix, mac => $mac, entry => $entry);
}

1;

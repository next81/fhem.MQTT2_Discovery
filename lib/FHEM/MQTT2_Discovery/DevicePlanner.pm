# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::DevicePlanner;

use strict;
use warnings;
use MQTT2_Discovery::Helper qw(stable_unique split_lines line_key);
use MQTT2_Discovery::ActionPlan ();


# Ein Topic gehoert nur dann zum Prefix, wenn die Segmentgrenze stimmt.
# Dadurch wird beispielsweise "geraet2" nicht "geraet" zugeordnet.
sub topic_has_prefix {
	my ($topic, $prefix) = @_;
	return defined($topic) && defined($prefix) && $prefix ne ''
		&& ($topic eq $prefix || index($topic, "$prefix/") == 0);
}

# Ermittelt einen sicheren gemeinsamen Topic-Stamm fuer alle Nutzdaten eines Devices.
sub device_topic {
	my ($record, $entries) = @_;

	# Availability-Topics liegen haeufig ausserhalb des eigentlichen
	# Geraetebaums und duerfen das gemeinsame Prefix nicht verfaelschen.
	my @topics = stable_unique(map { $_->{topic} }
		grep { ref($_) eq 'HASH' && ($_->{role} // '') ne 'availability'
			&& defined($_->{topic}) && !ref($_->{topic}) && $_->{topic} ne '' }
		@{ $entries || [] });
	return undef if !@topics;

	# Ein vom Parser vorgeschlagener Stamm ist genauer als eine rein
	# syntaktische Berechnung, wird aber nur nach strenger Pruefung verwendet.
	my @suggested = stable_unique(grep { defined($_) && !ref($_) && $_ ne '' }
		map { $record->{entities}{$_}{device_topic} } sort keys %{ $record->{entities} || {} });

	# Nur ein eindeutiger Vorschlag, der wirklich alle Nutzdaten-Topics umfasst,
	# ist verlaesslicher als das spaeter berechnete gemeinsame Prefix.
	if (@suggested == 1 && $suggested[0] !~ /[\s\x00-\x1f\$]/
			&& $suggested[0] !~ m{(?:^|/)[+#](?:/|$)}
			&& !grep { !topic_has_prefix($_, $suggested[0]) } @topics) {
		return $suggested[0];
	}

	# Ohne Vorschlag wird das laengste gemeinsame Topic-Prefix gesucht.
	my @parts = map { [ split m{/}, $_, -1 ] } @topics;
	my $limit = @{ $parts[0] } - 1;

	for my $parts (@parts) {
		$limit = @$parts - 1 if @$parts - 1 < $limit;
	}

	my @common;
	PART: for my $index (0 .. $limit - 1) {
		my $part = $parts[0][$index];
		last if !defined($part) || $part eq '' || $part eq '+' || $part eq '#';

		for my $parts (@parts) {
			last PART if $parts->[$index] ne $part;
		}

		push @common, $part;
	}

	# Generische Funktionssegmente sind kein stabiler Geraetestamm.
	pop @common if @common > 1 && $common[-1] =~ /^(?:cmd|command|set|state|status)$/i;
	my $candidate = join('/', @common);
	return $candidate ne '' && $candidate !~ /[\s\x00-\x1f\$]/ ? $candidate : undef;
}

# Bereitet JSON-Reading-Eintraege unter Beachtung manueller Namenskonflikte vor.
sub prepare_json_readings {
	my ($mode, $current, $previous_owned, $entries, $conflicts) = @_;
	my %previous = map { $_ => 1 } @{ $previous_owned || [] };
	my @current = split_lines($current);
	my @manual = grep { !$previous{$_} } @current;
	my %manual_by_key;
	push @{ $manual_by_key{ line_key('reading', $_) } }, $_ for @manual;
	my %remove;
	my @prepared;

	# JSON-Autocreate kann mehrere Readings aus einer Zeile erzeugen. Vor dem
	# Rendern werden deshalb Konflikte gegen manuell gepflegte Namen aufgeloest.
	for my $entry (@{ $entries || [] }) {

		# Andere Entry-Arten benoetigen keine JSON-Namensaufloesung und bleiben
		# deshalb unveraendert in ihrer urspruenglichen Reihenfolge erhalten.
		if (ref($entry) ne 'HASH'
				|| (($entry->{kind} || '') ne 'json_reading' && ($entry->{kind} || '') ne 'json_autocreate')) {
			push @prepared, $entry;
			next;
		}
		my $name = $entry->{name} // '';

		# Ein gleichnamiges manuelles Reading darf nur nach der expliziten
		# existingDevice-Strategie behandelt werden.
		if ($name ne '' && $manual_by_key{$name} && @{ $manual_by_key{$name} }) {

			# replace uebertraegt die Verantwortung fuer genau diesen Namen an
			# Discovery; konservative Modi melden stattdessen einen Konflikt.
			if ($mode eq 'replace') {
				# Im replace-Modus darf Discovery die kollidierenden manuellen Zeilen
				# gezielt entfernen; andere manuelle Zeilen bleiben erhalten.
				my $manual_lines = delete $manual_by_key{$name};
				$remove{$_} = 1 for @$manual_lines;
			} else {
				push @$conflicts, $name;
				next;
			}
		}
		push @prepared, $entry;
	}

	@current = grep { !$remove{$_} } @current if %remove;
	return (\@prepared, join("\n", @current));
}

# Baut den atomar auszufuehrenden Plan fuer devicetopic, readingList und setList auf.
sub attribute_plan {
	my (%args) = @_;
	my $plan = MQTT2_Discovery::ActionPlan->new();

	# devicetopic ist optional verwaltet, readingList und setList bilden dagegen
	# immer eine gemeinsame atomare Aenderung.
	$plan->set_attribute(
		device => $args{device}, attribute => 'devicetopic', value => ($args{device_topic} // ''),
		previous_exists => $args{previous_device_topic_exists},
		previous_value => $args{previous_device_topic},
	) if $args{manage_device_topic};
	$plan->set_attribute(
		device => $args{device}, attribute => 'readingList', value => $args{reading_list},
		previous_exists => $args{previous_reading_list_exists},
		previous_value => $args{previous_reading_list},
	);
	$plan->set_attribute(
		device => $args{device}, attribute => 'setList', value => $args{set_list},
		previous_exists => $args{previous_set_list_exists},
		previous_value => $args{previous_set_list},
	);
	return $plan;
}

1;

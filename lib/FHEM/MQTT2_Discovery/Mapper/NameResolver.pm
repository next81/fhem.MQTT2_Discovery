# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Mapper::NameResolver;

use strict;
use warnings;
use JSON::PP ();
use MQTT2_Discovery::Helper qw(safe_name stable_suffix);


# Berechnet fuer alle Mappings eindeutige Reading- und Set-Namen mit stabilen Suffixen.
sub _resolved_mapping_names {
	my ($mappings) = @_;
	my (%depth, %candidate, %resolved);
	my @keys = sort grep {
		ref($mappings->{$_}) eq 'HASH'
			&& ref($mappings->{$_}{reading_path}) eq 'ARRAY'
			&& @{ $mappings->{$_}{reading_path} }
	} keys %{ $mappings || {} };
	$depth{$_} = 1 for @keys;

	# Beginne mit dem letzten Pfadsegment. Nur kollidierende Namen werden
	# schrittweise um weitere Elternsegmente erweitert.
	while (@keys) {
		my %groups;

		for my $key (@keys) {
			my $path = $mappings->{$key}{reading_path};
			my $count = $depth{$key} > @$path ? scalar(@$path) : $depth{$key};
			my $start = @$path - $count;
			my $name = safe_name(join('_', @$path[$start .. $#$path]), $path->[-1]);
			$candidate{$key} = $name;
			push @{ $groups{$name} }, $key;
		}

		my $changed = 0;

		for my $group (values %groups) {
			next if @$group < 2;

			for my $key (@$group) {
				my $path = $mappings->{$key}{reading_path};

				# Nur Pfade mit noch ungenutzten Elternsegmenten koennen in der
				# naechsten Runde weiter praezisiert werden.
				if ($depth{$key} < @$path) {
					++$depth{$key};
					$changed = 1;
				}
			}

		}

		last if !$changed;
	}

	# Sind selbst die vollstaendigen Pfade gleich, trennt ein stabiler Hash die
	# Namen reproduzierbar, ohne von der Eingabereihenfolge abzuhaengen.
	my %groups;
	push @{ $groups{ $candidate{$_} } }, $_ for @keys;

	for my $name (keys %groups) {
		my @group = @{ $groups{$name} };

		# Ein bereits eindeutiger Kandidat bleibt lesbar und benoetigt keinen
		# technischen Hashsuffix.
		if (@group == 1) {
			$resolved{$group[0]} = $name;
			next;
		}
		$resolved{$_} = safe_name($name . '_' . stable_suffix($_, 6), $name) for @group;
	}

	return \%resolved;
}

# Passt einen abgeleiteten Namen nur an, wenn er auf den umbenannten Basisnamen zeigt.
sub _rename_derived_name {
	my ($value, $old, $new) = @_;
	return $value if !defined($value) || ref($value) || !defined($old) || $old eq '' || $old eq $new;
	return $new if $value eq $old;
	return $new . substr($value, length($old)) if index($value, $old . '_') == 0;
	return $value;
}

# Uebertraegt aufgeloeste Reading- und Set-Namen rekursiv in semantische Capabilities.
sub _rename_semantic_capabilities {
	my ($value, $old, $new) = @_;
	return if ref($value) ne 'HASH';

	for my $key (keys %$value) {

		# Direkte read/write-Referenzen werden umbenannt; verschachtelte
		# Capability-Objekte werden rekursiv nach denselben Referenzen durchsucht.
		if (($key eq 'read' || $key eq 'write') && !ref($value->{$key})) {
			$value->{$key} = _rename_derived_name($value->{$key}, $old, $new);
		} elsif (ref($value->{$key}) eq 'HASH') {
			_rename_semantic_capabilities($value->{$key}, $old, $new);
		}
	}

	return;
}

# Wendet die deviceweite Namensaufloesung auf Mappings, Eintraege und Semantik an.
sub resolve {
	my ($source) = @_;
	my %source = map { (($_->{entity_key} // '') => $_) }
		grep { ref($_) eq 'HASH' && defined($_->{entity_key}) } @{ $source || [] };
	my $resolved = _resolved_mapping_names(\%source);
	my @result;

	# Die tiefe JSON-Kopie verhindert, dass das Umbenennen die in der Registry
	# gespeicherten Original-Mappings veraendert.
	for my $key (sort keys %source) {
		my $mapping = JSON::PP->new->decode(JSON::PP->new->encode($source{$key}));
		my $old = $mapping->{reading_name};
		my $new = $resolved->{$key} // $old;

		# Nur eine tatsaechliche Namensaenderung darf die abgeleiteten Reading-,
		# Set- und Semantikreferenzen des kopierten Mappings anfassen.
		if (defined($old) && defined($new) && $old ne $new) {
			# Alle abgeleiteten Namen muessen gemeinsam umziehen, sonst zeigen Sets
			# oder semantische Capabilities auf nicht mehr vorhandene Readings.
			for my $entry (@{ $mapping->{reading_lines} || [] }) {
				next if ref($entry) ne 'HASH' || ($entry->{role} // '') eq 'availability';
				$entry->{semantic_name} = _rename_derived_name($entry->{semantic_name}, $old, $new)
					if exists $entry->{semantic_name};
				$entry->{name} = _rename_derived_name($entry->{name}, $old, $new)
					if ($entry->{kind} || '') ne 'json_autocreate';
			}

			for my $entry (@{ $mapping->{set_lines} || [] }) {
				next if ref($entry) ne 'HASH';
				$entry->{name} = _rename_derived_name($entry->{name}, $old, $new);
			}

			$mapping->{set_state_list} = [ map {
				_rename_derived_name($_, $old, $new)
			} @{ $mapping->{set_state_list} || [] } ];

			# Semantische Metadaten sind optional, muessen bei Vorhandensein aber
			# dieselben aufgeloesten Namen wie readingList und setList verwenden.
			if (ref($mapping->{semantic_entity}) eq 'HASH') {
				$mapping->{semantic_entity}{id} = _rename_derived_name(
					$mapping->{semantic_entity}{id}, $old, $new,
				);
				_rename_semantic_capabilities($mapping->{semantic_entity}{capabilities}, $old, $new);
			}
			$mapping->{reading_name} = $new;
		}
		push @result, $mapping;
	}

	return \@result;
}

1;

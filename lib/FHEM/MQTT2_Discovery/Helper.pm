# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Helper;

use strict;
use warnings;
use Exporter qw(import);
use Digest::SHA qw(sha1_hex);

our @EXPORT_OK = qw(
	trim stable_unique safe_name stable_suffix split_lines line_key
	merge_generated_lines
);

# Entfernt nur Rand-Whitespace; Inhalte innerhalb des Wertes bleiben erhalten.
sub trim {
	my ($value) = @_;
	return '' if !defined $value;
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

# Entfernt undef und Duplikate, ohne die Reihenfolge des ersten Auftretens zu veraendern.
sub stable_unique {
	my (@values) = @_;
	my %seen;
	return grep { defined($_) && !$seen{$_}++ } @values;
}

# Erzeugt einen gueltigen, reproduzierbaren FHEM-Namen aus fremden Metadaten.
sub safe_name {
	my ($value, $fallback) = @_;
	$fallback = 'device' if !defined($fallback) || $fallback eq '';
	$value = trim($value);
	$value =~ s/[^A-Za-z0-9_.]+/_/g;
	$value =~ s/_+/_/g;
	$value = $fallback if $value eq '';
	$value = "d_$value" if $value !~ /^[A-Za-z_]/;
	return substr($value, 0, 64);
}

# Erzeugt aus einem beliebigen Wert einen reproduzierbaren kurzen SHA-1-Suffix.
sub stable_suffix {
	my ($value, $length) = @_;
	$length = 8 if !defined $length;
	return substr(sha1_hex(defined($value) ? $value : ''), 0, $length);
}

# FHEM speichert readingList und setList als mehrzeilige Attributwerte.
sub split_lines {
	my ($value) = @_;
	return () if !defined($value) || $value eq '';
	my @lines = split /\r?\n/, $value;
	return grep { $_ ne '' } @lines;
}

# Extrahiert den logischen Reading- oder Set-Namen aus einer generierten Attributzeile.
sub line_key {
	my ($kind, $line) = @_;
	return '' if !defined $line;

	# readingList-Zeilen tragen ihren logischen Key an einer anderen Stelle als
	# setList-Zeilen und benoetigen deshalb eine eigene Extraktion.
	if ($kind eq 'reading') {
		# Generierte Runtime-Zeilen tragen ihren logischen Reading-Namen im
		# Funktionsaufruf; einfache Zeilen bestehen direkt aus diesem Namen.
		my (undef, $code) = split /\s+/, $line, 2;
		return '' if !defined $code;
		return $2 if $code =~ /MQTT2_DISCOVERY_runtime(?:Trigger)?Reading\(.*,\s*(['"])([A-Za-z0-9_.-]+)\1\s*\)/;
		return $1 if $code =~ /^([A-Za-z0-9_.-]+)$/;
		return '';
	}

	# Bei setList ist der Teil vor Leerzeichen bzw. Widget-Spezifikation der Key.
	my ($head) = split /\s+/, $line, 2;
	$head =~ s/:.*$// if defined $head;
	return defined($head) ? $head : '';
}

# Verschmilzt neue Discovery-Zeilen mit manuellen Inhalten nach der Konfliktstrategie.
sub merge_generated_lines {
	my (%args) = @_;
	my $kind = $args{kind} || 'set';
	my $mode = $args{mode} || 'conservative';
	my @current = split_lines($args{current});
	my %previous = map { $_ => 1 } @{ $args{previous_owned} || [] };
	my @manual = grep { !$previous{$_} } @current;
	my %manual_by_key = map { line_key($kind, $_) => $_ } @manual;
	my (@owned, @conflicts);

	# Nur zuvor von Discovery erzeugte Zeilen werden automatisch ersetzt.
	# Manuelle Zeilen gewinnen im konservativen Modus bei Namensgleichheit.
	for my $entry (@{ $args{generated} || [] }) {
		my $line = ref($entry) eq 'HASH' ? $entry->{line} : $entry;
		my $key = ref($entry) eq 'HASH' ? $entry->{name} : line_key($kind, $line);
		next if !defined($line) || $line eq '';

		# Nur eine manuelle Zeile mit demselben logischen Key erzeugt einen echten
		# Besitzkonflikt; andere manuelle Inhalte bleiben immer erhalten.
		if ($key ne '' && exists $manual_by_key{$key}) {

			# replace uebernimmt gezielt den kollidierenden Key, waehrend der
			# konservative Modus die manuelle Zeile priorisiert.
			if ($mode eq 'replace') {
				# replace entfernt nur denselben logischen Key, nicht den gesamten
				# manuell gepflegten Attributwert.
				@manual = grep { line_key($kind, $_) ne $key } @manual;
			} else {
				push @conflicts, $key;
				next;
			}
		}
		push @owned, $line;
	}

	@owned = stable_unique(sort @owned);
	return {
		value     => join("\n", @manual, @owned),
		owned     => \@owned,
		manual    => \@manual,
		conflicts => [ stable_unique(@conflicts) ],
	};
}

1;

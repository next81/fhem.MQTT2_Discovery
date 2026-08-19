# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::Mapper::Common;

use strict;
use warnings;
use Exporter qw(import);
use MQTT2_Discovery::Helper qw(safe_name stable_suffix);

our @EXPORT_OK = qw(
	capability_set_name choice_values is_device_root_entity is_numeric temperature_unit
);

sub is_device_root_entity {
	my ($entity) = @_;
	return $entity->{_canonical_root} ? 1 : 0;
}

sub capability_set_name {
	my ($entity, $reading_name, $capability) = @_;
	return safe_name($capability, 'set') if is_device_root_entity($entity);
	return "${reading_name}_$capability";
}

sub choice_values {
	my ($values) = @_;
	return ([], {}, {}) if ref($values) ne 'ARRAY';
	my (%mapping, %read_mapping, %seen_value, @tokens);

	for my $value (@$values) {
		next if !defined($value) || ref($value) || $value =~ /[\x00-\x1f]/;
		$value = "$value";
		next if $seen_value{$value}++;

		my $token = $value;
		$token =~ s/[^A-Za-z0-9_.-]+/_/g;
		$token =~ s/_+/_/g;
		$token =~ s/^[-.]+|[-.]+$//g;
		$token = 'option' if $token eq '';

		if (exists $mapping{$token}) {
			my $base = $token;
			my $suffix_length = 4;
			do {
				$token = $base . '_' . stable_suffix($value, $suffix_length);
				$suffix_length += 2;
			} while exists $mapping{$token};
		}

		$mapping{$token} = $value;
		$read_mapping{$value} = $token;
		push @tokens, $token;
	}

	return (\@tokens, \%mapping, \%read_mapping);
}

sub is_numeric {
	my ($value) = @_;
	return defined($value) && !ref($value)
		&& $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
}

sub temperature_unit {
	my ($value) = @_;
	return "\x{b0}C" if !defined($value) || ref($value) || uc($value) eq 'C';
	return "\x{b0}F" if uc($value) eq 'F';
	return "$value";
}

1;

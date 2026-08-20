# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use File::Find qw(find);
use File::Spec ();

my $controls_file = 'controls_MQTT2_DISCOVERY.txt';
my @expected = ('FHEM/10_MQTT2_DISCOVERY.pm');

sub delivery_size {
	my ($file) = @_;
	open my $input, '<:raw', $file
		or die "Kann $file nicht lesen: $!";
	local $/;
	my $content = <$input>;
	close $input or die "Kann $file nicht schliessen: $!";
	$content =~ s/\r\n/\n/g;
	return length($content);
}

find(
	{
		no_chdir => 1,
		wanted => sub {
			return if !-f $File::Find::name || $File::Find::name !~ /\.pm\z/;
			my $path = File::Spec->abs2rel($File::Find::name, '.');
			$path =~ s{\\}{/}g;
			push @expected, $path;
		},
	},
	'lib/FHEM/MQTT2_Discovery',
);

open my $controls, '<:raw', $controls_file
	or die "Kann $controls_file nicht lesen: $!";
my @lines = <$controls>;
close $controls;

my (%entries, @errors);
for my $line (@lines) {
	chomp $line;
	if ($line !~ /^UPD (\d{4}-\d{2}-\d{2}_\d{2}:\d{2}:\d{2}) (\d+) (\S+)$/) {
		push @errors, "Ungueltige Control-Zeile: $line";
		next;
	}
	my ($timestamp, $size, $path) = ($1, $2, $3);
	push @errors, "Doppelter Control-Eintrag: $path" if exists $entries{$path};
	$entries{$path} = { timestamp => $timestamp, size => 0 + $size };
}

is(\@errors, [], 'Controlfile enthaelt nur eindeutige gueltige UPD-Zeilen');
is([sort keys %entries], [sort @expected], 'Controlfile enthaelt exakt alle Produktionsmodule');
for my $path (sort keys %entries) {
	ok(-f $path, "$path existiert");
	is(
		$entries{$path}{size},
		delivery_size($path),
		"$path hat die angegebene Auslieferungs-Bytelaenge",
	);
}

done_testing;


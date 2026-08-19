#!/usr/bin/env perl

use strict;
use warnings;
use File::Find qw(find);
use File::Spec ();
use POSIX qw(strftime);

my $output = 'controls_MQTT2_DISCOVERY.txt';
my @files = ('FHEM/10_MQTT2_DISCOVERY.pm');

# controls-Dateien muessen neben dem FHEM-Modul alle ausgelieferten
# Bibliotheksmodule enthalten. Test- und Dokumentationsdateien gehoeren nicht dazu.
find(
	{
		no_chdir => 1,
		wanted => sub {
			return if !-f $File::Find::name || $File::Find::name !~ /\.pm\z/;
			push @files, File::Spec->abs2rel($File::Find::name, '.');
		},
	},
	'lib/FHEM/MQTT2_Discovery',
);

my %seen;

# Sortierung und Deduplizierung machen die Ausgabe reproduzierbar.
@files = sort grep { !$seen{$_}++ } @files;

open my $controls, '>:raw', $output
	or die "Kann $output nicht schreiben: $!\n";

for my $file (@files) {
	my @stat = stat($file);
	die "Kann $file nicht lesen: $!\n" if !@stat;
	my $path = $file;

	# FHEM-controls verwenden auch unter Windows portable Slash-Pfade.
	$path =~ s{\\}{/}g;
	my $timestamp = strftime('%Y-%m-%d_%H:%M:%S', localtime($stat[9]));
	print {$controls} "UPD $timestamp $stat[7] $path\n";
}

close $controls or die "Kann $output nicht schliessen: $!\n";
print "$output mit " . scalar(@files) . " Dateien erzeugt.\n";

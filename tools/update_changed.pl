#!/usr/bin/env perl

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Getopt::Long qw(GetOptions);
use Text::Wrap qw(wrap);
use Unicode::Normalize qw(NFKD);

my @HEADER = (
	'# MQTT2_DISCOVERY changes, newest entries first.',
	'# Generated from commit messages by tools/update_changed.pl.',
);
my $quiet = 0;

# Liest Textdateien als UTF-8 und normalisiert die Zeilenenden fuer alle Plattformen.
sub read_text {
	my ($file) = @_;
	open my $input, '<:encoding(UTF-8)', $file
		or die "Kann $file nicht lesen: $!\n";
	local $/;
	my $content = <$input>;
	close $input or die "Kann $file nicht schliessen: $!\n";
	$content = '' if !defined($content);
	$content =~ s/\r\n?/\n/g;
	return $content;
}

# Ueberfuehrt Commit-Text in die von FHEM geforderte reine ASCII-Darstellung.
sub ascii_text {
	my ($text) = @_;
	$text = '' if !defined($text);
	$text =~ s/\x{00e4}/ae/g;
	$text =~ s/\x{00f6}/oe/g;
	$text =~ s/\x{00fc}/ue/g;
	$text =~ s/\x{00c4}/Ae/g;
	$text =~ s/\x{00d6}/Oe/g;
	$text =~ s/\x{00dc}/Ue/g;
	$text =~ s/\x{00df}/ss/g;
	$text = NFKD($text);
	$text =~ s/\pM//g;
	$text =~ s/[^\x20-\x7e]/?/g;
	$text =~ s/[\t ]+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return $text;
}

# Extrahiert Betreff und fachliche Stichpunkte ohne Git-Kommentare und Trailer.
sub parse_message {
	my ($content) = @_;
	my @message;

	# Kommentar-, Leer- und Metadatenzeilen sollen nicht im Changelog erscheinen.
	for my $line (split /\n/, $content) {
		$line =~ s/^\s+|\s+$//g;
		next if $line eq '' || $line =~ /^#/;
		next if $line =~ /^(?:Signed-off-by|Co-authored-by|Reviewed-by|Acked-by|Tested-by|Change-Id):/i;
		push @message, $line;
	}

	my $subject = shift(@message) // '';
	my $relevant_message = join("\n", $subject, @message);
	my $skip = $relevant_message =~ /\[skip-changed\]/i
		|| $subject =~ /^(?:fixup|squash)!/i
		|| $subject =~ /^Merge\b/i;
	return ($subject, \@message, $skip);
}

# Leitet einen FHEM-CHANGED-Typ aus ueblichen Commit-Praefixen ab.
sub changelog_category {
	my ($subject_ref) = @_;
	my $category = 'change';

	# Bekannte Praefixe werden entfernt, damit sie nicht doppelt ausgegeben werden.
	if ($$subject_ref =~ s/^(?:feat|feature)(?:\([^)]*\))?!?:\s*//i) {
		$category = 'feature';
	} elsif ($$subject_ref =~ s/^(?:fix|bugfix)(?:\([^)]*\))?!?:\s*//i) {
		$category = 'bugfix';
	} elsif ($$subject_ref =~ s/^(?:change|refactor|perf|docs?|test|build|ci|chore)(?:\([^)]*\))?!?:\s*//i) {
		$category = 'change';
	}

	return $category;
}

# Bricht einen Changelog-Text mit stabilen Einrueckungen auf maximal 80 Zeichen um.
sub wrapped_lines {
	my ($text, $first_prefix, $continuation_prefix) = @_;
	local $Text::Wrap::columns = 80;
	local $Text::Wrap::huge = 'wrap';
	return split /\n/, wrap($first_prefix, $continuation_prefix, $text);
}

# Entfernt Generator-Kopf und letzten Nachrichten-Hash vom bisherigen Nutzinhalt.
sub existing_entries {
	my ($content) = @_;
	my @lines = split /\n/, $content;

	# Ein bereits erzeugter Kopf wird ersetzt, manuell vorhandener Inhalt bleibt erhalten.
	if (@lines >= @HEADER && join("\n", @lines[0 .. $#HEADER]) eq join("\n", @HEADER)) {
		splice @lines, 0, scalar(@HEADER);
	}
	shift @lines if @lines && $lines[0] =~ /^# Msg-SHA256: [0-9a-f]{64}$/;
	@lines = grep { $_ ne '' } @lines;
	return \@lines;
}

# Schreibt LF-kodierten ASCII-Text erst nach vollstaendiger Erzeugung der Ausgabe.
sub write_changed {
	my ($output, $content) = @_;
	open my $changed, '>:raw', $output
		or die "Kann $output nicht schreiben: $!\n";
	print {$changed} $content;
	close $changed or die "Kann $output nicht schliessen: $!\n";
}

# Aktualisiert das Changelog idempotent aus genau einer finalen Commit-Message.
sub update_changed {
	my ($message_file, $output) = @_;
	my $message = read_text($message_file);
	my ($subject, $body, $skip) = parse_message($message);
	my $existing = -f $output ? read_text($output) : '';
	my $entries = existing_entries($existing);

	# Ausgelassene technische Commits veraendern ein vorhandenes Changelog nicht.
	if ($skip || $subject eq '') {
		write_changed($output, join("\n", @HEADER, @$entries) . "\n") if !-f $output;
		print "CHANGED fuer diese Commit-Message uebersprungen.\n" if !$quiet;
		return;
	}

	$subject = ascii_text($subject);
	my @body = grep { $_ ne '' } map {
		my $line = $_;
		$line =~ s/^[-*+]\s+//;
		ascii_text($line);
	} @$body;
	my $category = changelog_category(\$subject);
	my $message_hash = sha256_hex(join("\n", $category, $subject, @body));

	# Ein erneuter Commit-Versuch mit unveraenderter Message darf nichts duplizieren.
	if ($existing =~ /^\Q$HEADER[0]\E\n\Q$HEADER[1]\E\n# Msg-SHA256: \Q$message_hash\E\n/) {
		print "CHANGED enthaelt diese Commit-Message bereits.\n" if !$quiet;
		return;
	}

	my @new_lines = wrapped_lines(
		$subject,
		"- $category: MQTT2_DISCOVERY: ",
		'  ',
	);

	# Stichpunkte ergaenzen den Haupteintrag als eingerueckte Detailzeilen.
	for my $line (@body) {
		push @new_lines, wrapped_lines($line, '  - ', '    ');
	}

	my $content = join(
		"\n",
		@HEADER,
		"# Msg-SHA256: $message_hash",
		@new_lines,
		@$entries,
	) . "\n";
	write_changed($output, $content);
	print "CHANGED aus der Commit-Message aktualisiert.\n" if !$quiet;
}

my $output = 'CHANGED';
GetOptions('output=s' => \$output, 'quiet' => \$quiet)
	or die "Verwendung: $0 [--output DATEI] [--quiet] COMMIT_MESSAGE\n";
my ($message_file) = @ARGV;
die "Verwendung: $0 [--output DATEI] [--quiet] COMMIT_MESSAGE\n"
	if !defined($message_file) || $message_file eq '' || @ARGV != 1;

update_changed($message_file, $output);

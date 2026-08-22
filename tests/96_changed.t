# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

use strict;
use warnings;
use Test2::V0;
use Encode qw(encode);
use File::Spec ();
use File::Temp qw(tempdir);

my $temp = tempdir('mqtt2-discovery-changed-XXXXXX', DIR => '.', CLEANUP => 1);
my $changed = File::Spec->catfile($temp, 'CHANGED');
my $message = File::Spec->catfile($temp, 'COMMIT_EDITMSG');
my $generator = File::Spec->catfile('tools', 'update_changed.pl');

# Schreibt eine UTF-8-Commit-Message fuer einen isolierten Generatorlauf.
sub write_message {
	my ($content) = @_;
	open my $output, '>:raw', $message or die "Kann $message nicht schreiben: $!";
	print {$output} encode('UTF-8', $content);
	close $output or die "Kann $message nicht schliessen: $!";
}

# Fuehrt nur den Generator aus; der Git-Hook mit seiner Staging-Wirkung bleibt unberuehrt.
sub run_generator {
	my @command = ($^X, $generator, '--output', $changed, '--quiet', $message);
	my $result = system(@command);
	is($result, 0, 'CHANGED-Generator ist erfolgreich');
}

# Liest das erzeugte ASCII-Changelog fuer inhaltliche Pruefungen ein.
sub read_changed {
	open my $input, '<:raw', $changed or die "Kann $changed nicht lesen: $!";
	local $/;
	my $content = <$input>;
	close $input or die "Kann $changed nicht schliessen: $!";
	return $content;
}

my $ae = chr(0x00e4);
my $ue = chr(0x00fc);
write_message(
	"Discovery-Ger${ae}te und JSON-Mapping vereinheitlicht\n\n"
	. "- kurze Namen f${ue}r Readings erzeugt\n"
	. "- sehr langer Detailpunkt mit zus${ae}tzlichem Inhalt, der zuverl${ae}ssig "
	. "auf die von FHEM erlaubten achtzig Zeichen umgebrochen werden muss\n\n"
	. "Co-authored-by: Beispiel <beispiel\@example.invalid>\n"
	. "# Diese Git-Kommentarzeile darf nicht erscheinen.\n"
);
run_generator();
my $first = read_changed();
like($first, qr/^- change: MQTT2_DISCOVERY: Discovery-Geraete und JSON-Mapping/m,
	'Betreff wird als allgemeine Aenderung und als ASCII ausgegeben');
like($first, qr/^  - kurze Namen fuer Readings erzeugt$/m,
	'Commit-Stichpunkt wird eingerueckt uebernommen');
unlike($first, qr/Co-authored|Git-Kommentar/,
	'Git-Trailer und Kommentare werden verworfen');
is([grep { length($_) > 80 } split(/\n/, $first)], [],
	'jede erzeugte Zeile bleibt innerhalb der FHEM-Grenze');
unlike($first, qr/^$/m, 'CHANGED enthaelt keine trennende Leerzeile');
unlike($first, qr/[^\x00-\x7f]/, 'CHANGED enthaelt ausschliesslich ASCII');

run_generator();
is(read_changed(), $first, 'derselbe Commit-Versuch erzeugt keinen doppelten Eintrag');

write_message("fix(parser): Ung${ue}ltige Payload abgefangen\n\n- Fehler sichtbar protokolliert\n");
run_generator();
my $second = read_changed();
like($second, qr/^# Msg-SHA256: [0-9a-f]{64}\n- bugfix: MQTT2_DISCOVERY: Ungueltige Payload abgefangen$/m,
	'Fix-Praefix erzeugt einen Bugfix-Eintrag ohne doppeltes Praefix');
like($second, qr/Discovery-Geraete und JSON-Mapping/m,
	'aeltere Eintraege bleiben unter dem neuen Eintrag erhalten');

write_message("Technischen Stand abgleichen [skip-changed]\n");
run_generator();
is(read_changed(), $second, 'Opt-out-Marker laesst CHANGED unveraendert');

done_testing;

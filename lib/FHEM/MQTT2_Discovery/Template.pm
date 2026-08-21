# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package MQTT2_Discovery::Template;

use strict;
use warnings;
use JSON::PP qw(decode_json encode_json);
use Scalar::Util qw(looks_like_number);
use MQTT2_Discovery::Helper qw(trim);


# Die Template-Engine akzeptiert absichtlich nur ein kleines Jinja-Subset.
# Sie erzeugt einen eigenen Syntaxbaum und fuehrt niemals Discovery-Text aus.
sub _fail {
	my ($message) = @_;
	return { ok => 0, error => $message };
}

# Zerlegt einen Ausdruck nur an Trennzeichen ausserhalb von Strings und Klammern.
sub _split_outside {
	my ($text, $separator) = @_;
	my @parts;
	my ($current, $quote, $depth) = ('', '', 0);

	# Separatoren innerhalb von Strings, Klammern oder Arrayzugriffen gehoeren
	# zum aktuellen Ausdruck und duerfen nicht aufgeteilt werden.
	for my $char (split //, $text) {

		# Innerhalb eines Literals haben Klammern und Separatoren keine
		# syntaktische Bedeutung; nur das passende Schlusszeichen beendet es.
		if ($quote ne '') {
			$current .= $char;
			$quote = '' if $char eq $quote;
			next;
		}

		# Ausserhalb von Literalen aktualisieren Strukturzeichen den Parserzustand
		# oder beenden am gewuenschten Separator den aktuellen Ausdrucksteil.
		if ($char eq q{'} || $char eq q{"}) {
			$quote = $char;
			$current .= $char;
		} elsif ($char eq '(' || $char eq '[') {
			++$depth;
			$current .= $char;
		} elsif ($char eq ')' || $char eq ']') {
			--$depth;
			$current .= $char;
		} elsif ($char eq $separator && $depth == 0) {
			push @parts, trim($current);
			$current = '';
		} else {
			$current .= $char;
		}
	}

	push @parts, trim($current);
	return @parts;
}

# Uebersetzt Literale, Pfade und geklammerte Teilausdruecke in AST-Knoten.
sub _parse_atom {
	my ($text) = @_;
	$text = trim($text);
	return { type => 'literal', value => $1 } if $text =~ /^'(.*)'$/s || $text =~ /^"(.*)"$/s;
	return { type => 'literal', value => 0 + $text } if $text =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/;
	return { type => 'literal', value => 1 } if $text eq 'true' || $text eq 'True';
	return { type => 'literal', value => 0 } if $text eq 'false' || $text eq 'False';
	return { type => 'literal', value => undef } if $text eq 'none' || $text eq 'None' || $text eq 'null';

	# Nach den Literalen bleibt nur ein Datenpfad mit gueltigem Wurzelbezeichner
	# als zulaessige atomare Ausdrucksform uebrig.
	if ($text =~ /^([A-Za-z_][A-Za-z0-9_]*)(.*)$/s) {
		my ($root, $rest) = ($1, $2);
		my @path;

		# Erlaubt sind nur reine Datenpfade; Methodenaufrufe ausser .get werden
		# bereits beim Parsen verworfen.
		while ($rest ne '') {

			# Die erlaubten Zugriffsschreibweisen werden alle in denselben neutralen
			# Pfad umgewandelt, den der Evaluator spaeter ohne Methodenaufruf liest.
			if ($rest =~ s/^\.get\(\s*(['"])([^'"]+)\1\s*\)//) {
				push @path, $2;
			} elsif ($rest =~ s/^\.([A-Za-z_][A-Za-z0-9_]*)//) {
				push @path, $1;
			} elsif ($rest =~ s/^\[(\d+)\]//) {
				push @path, 0 + $1;
			} elsif ($rest =~ s/^\[['"]([^'"]+)['"]\]//) {
				push @path, $1;
			} else {
				return;
			}
		}

		return { type => 'path', root => $root, path => \@path };
	}
	return;
}

# Parst Vergleiche, Bedingungen und Filterketten mit definierter Bindungsreihenfolge.
sub _parse_expression {
	my ($text) = @_;
	$text = trim($text);
	return if $text eq '';

	# Ternary und Vergleiche werden vor Filtern gebunden. Das bildet genau den
	# dokumentierten sicheren Teil der HA-Templates ab.
	if ($text =~ /^(.*?)\s+if\s+(.+?)\s+else\s+(.*?)$/s) {
		my ($yes, $condition, $no) = ($1, $2, $3);
		my ($yes_ast, $condition_ast, $no_ast) = map { _parse_expression($_) } ($yes, $condition, $no);
		return if !$yes_ast || !$condition_ast || !$no_ast;
		return { type => 'if', condition => $condition_ast, yes => $yes_ast, no => $no_ast };
	}

	for my $operator (qw(== != >= <= > <)) {

		# Der erste unterstuetzte Operator teilt den Ausdruck in zwei rekursiv zu
		# parsende Operanden; unvollstaendige Seiten machen das Template ungueltig.
		if ($text =~ /^(.*?)\s*\Q$operator\E\s*(.*?)$/s) {
			my ($left_source, $right_source) = ($1, $2);
			my ($left, $right) = (_parse_expression($left_source), _parse_expression($right_source));
			return if !$left || !$right;
			return { type => 'compare', operator => $operator, left => $left, right => $right };
		}
	}

	my @parts = _split_outside($text, '|');
	my $base = _parse_atom(shift @parts);
	return if !$base;

	for my $filter (@parts) {
		return if $filter !~ /^([A-Za-z_][A-Za-z0-9_]*)(?:\((.*)\))?$/s;
		my ($name, $argument) = ($1, $2);
		return if $name !~ /^(?:lower|upper|trim|int|float|round|default|tojson|is_defined)$/;
		return if $name eq 'is_defined' && defined($argument) && trim($argument) ne '';
		my $argument_ast;

		# Optionale Filterargumente durchlaufen denselben sicheren Parser wie der
		# Hauptausdruck und koennen daher keinen groesseren Sprachumfang oeffnen.
		if (defined($argument) && trim($argument) ne '') {
			$argument_ast = _parse_expression($argument);
			return if !$argument_ast;
		}
		$base = { type => 'filter', name => $name, argument => $argument_ast, input => $base };
	}

	return $base;
}

# Kompiliert einen Template-Text einmalig in eine Folge aus Text- und AST-Segmenten.
sub compile {
	my ($template) = @_;
	return _fail('Template fehlt') if !defined $template;
	return _fail('Nicht unterstuetzte oder unsichere Template-Konstruktion')
		if $template =~ /(?:states\s*\(|state_attr\s*\(|is_state\s*\(|__|`|;|\{%-?\s*(?:for|macro|include|import))/;
	my $ast;

	# Nur ein einzelner Ausgabeausdruck oder ein einfaches if/else ist zulaessig.
	if ($template =~ /^\s*\{\{\s*(.*?)\s*\}\}\s*$/s) {
		my $source = $1;
		$ast = _parse_expression($source);
	} elsif ($template =~ /^\s*\{%\s*if\s+(.+?)\s*%\}(.*?)\{%\s*else\s*%\}(.*?)\{%\s*endif\s*%\}\s*$/s) {
		my ($condition_source, $yes, $no) = ($1, $2, $3);
		my $condition = _parse_expression($condition_source);
		$ast = { type => 'if', condition => $condition,
			yes => { type => 'literal', value => $yes }, no => { type => 'literal', value => $no } }
			if $condition;
	}
	return _fail('Template liegt ausserhalb des unterstuetzten sicheren Subsets') if !$ast;
	return { ok => 1, ast => $ast, source => $template };
}

# Loest einen sicheren Datenpfad schrittweise in Hashes und Arrays auf.
sub _lookup {
	my ($context, $root, $path) = @_;
	return (0, undef) if !exists $context->{$root};
	my $value = $context->{$root};

	# Jeder Pfadschritt prueft Typ und Existenz, damit fehlende Daten nicht zu
	# Perl-Autovivifikation oder Warnungen fuehren.
	for my $part (@$path) {

		# Hash-Schluessel und Arrayindizes werden entsprechend dem aktuellen
		# Containertyp gelesen; jeder Typwechsel ausserhalb dieser Formen bricht ab.
		if (ref($value) eq 'HASH' && exists $value->{$part}) {
			$value = $value->{$part};
		} elsif (ref($value) eq 'ARRAY' && $part =~ /^\d+$/ && $part < @$value) {
			$value = $value->[$part];
		} else {
			return (0, undef);
		}
	}

	return (1, $value);
}

# Bildet Template-Werte nach den bewusst einfachen Wahrheitsregeln auf Boolean ab.
sub _truthy {
	my ($value, $exists) = @_;
	return 0 if !$exists || !defined($value) || !$value;
	return 1;
}

# Wertet einen validierten AST rekursiv ohne Ausfuehrung fremden Perl-Codes aus.
sub _evaluate_ast {
	my ($ast, $context) = @_;

	# Literale sind bereits beim Kompilieren validiert und koennen direkt in die
	# Auswertung uebernommen werden.
	if ($ast->{type} eq 'literal') {
		return (1, $ast->{value});
	}

	# Pfadknoten delegieren Existenz- und Typbehandlung an den sicheren Lookup.
	if ($ast->{type} eq 'path') {
		return _lookup($context, $ast->{root}, $ast->{path});
	}

	# Vergleiche werten zuerst beide Seiten aus; ein fehlender Operand ergibt
	# bewusst false statt einer impliziten Perl-Konvertierung.
	if ($ast->{type} eq 'compare') {
		my ($left_exists, $left) = _evaluate_ast($ast->{left}, $context);
		my ($right_exists, $right) = _evaluate_ast($ast->{right}, $context);
		return (1, 0) if !$left_exists || !$right_exists;

		# Zahlen werden numerisch, alle anderen skalaren Werte textuell verglichen.
		my $numeric = defined($left) && defined($right) && looks_like_number($left) && looks_like_number($right);
		my $operator = $ast->{operator};
		my $result = $operator eq '==' ? ($numeric ? $left == $right : "$left" eq "$right")
			: $operator eq '!=' ? ($numeric ? $left != $right : "$left" ne "$right")
			: $operator eq '>=' ? ($numeric ? $left >= $right : "$left" ge "$right")
			: $operator eq '<=' ? ($numeric ? $left <= $right : "$left" le "$right")
			: $operator eq '>'  ? ($numeric ? $left >  $right : "$left" gt "$right")
			:                    ($numeric ? $left <  $right : "$left" lt "$right");
		return (1, $result ? 1 : 0);
	}

	# Der Bedingungsknoten wertet nur den ausgewaehlten Zweig aus, damit ein
	# fehlender Pfad im unbenutzten Zweig das Ergebnis nicht ungueltig macht.
	if ($ast->{type} eq 'if') {
		my ($exists, $condition) = _evaluate_ast($ast->{condition}, $context);
		return _evaluate_ast(_truthy($condition, $exists) ? $ast->{yes} : $ast->{no}, $context);
	}

	# Filter bauen auf dem Ergebnis ihres Eingangsknotens auf und behandeln ein
	# optionales Argument getrennt vom eigentlichen Wert.
	if ($ast->{type} eq 'filter') {
		my ($exists, $value) = _evaluate_ast($ast->{input}, $context);
		my ($argument_exists, $argument) = $ast->{argument}
			? _evaluate_ast($ast->{argument}, $context) : (0, undef);
		my $name = $ast->{name};

		# default ist der einzige Filter, der einen fehlenden Eingang absichtlich
		# durch sein Argument ersetzen darf.
		if ($name eq 'default') {
			return ($exists && defined($value) ? (1, $value) : ($argument_exists, $argument));
		}

		# Home Assistants is_defined-Filter reicht vorhandene Werte unveraendert
		# weiter und unterdrueckt Updates, deren Quellpfad im Payload fehlt.
		if ($name eq 'is_defined') {
			return ($exists, $value);
		}
		return (0, undef) if !$exists;
		$value = '' if !defined $value;
		return (1, lc "$value") if $name eq 'lower';
		return (1, uc "$value") if $name eq 'upper';
		return (1, trim("$value")) if $name eq 'trim';
		return (0, undef) if ($name eq 'int' || $name eq 'float' || $name eq 'round') && !looks_like_number($value);
		return (1, int($value)) if $name eq 'int';
		return (1, 0 + $value) if $name eq 'float';

		# round verwendet eine explizite Dezimalstellenzahl und vermeidet damit
		# abhaengige Locale- oder Formatierungsfunktionen.
		if ($name eq 'round') {
			my $digits = $argument_exists ? int($argument) : 0;
			my $factor = 10 ** $digits;
			my $rounded = int($value * $factor + ($value < 0 ? -0.5 : 0.5)) / $factor;
			return (1, $rounded);
		}
		return (1, encode_json($value)) if $name eq 'tojson';
	}
	return (0, undef);
}

# Rendert ein kompiliertes oder rohes Template gegen den uebergebenen Wertekontext.
sub render {
	my ($template, %args) = @_;
	my $compiled = ref($template) eq 'HASH' ? $template : compile($template);
	return $compiled if !$compiled->{ok};
	my $value = defined($args{value}) ? $args{value} : '';
	my %context = (value => $value, %{ $args{vars} || {} });

	# value_json wird nur aus echtem JSON aufgebaut. Ungueltiges JSON bleibt ein
	# normaler value-String fuer einfache Templates.
	if (!exists $context{value_json}) {
		my $decoded;
		$context{value_json} = $decoded if eval { $decoded = decode_json($value); 1 };
	}
	my ($exists, $result) = _evaluate_ast($compiled->{ast}, \%context);
	return _fail('Templatewert ist nicht vorhanden oder ungueltig') if !$exists;
	$result = '' if !defined $result;
	return { ok => 1, value => ref($result) ? encode_json($result) : "$result" };
}

1;

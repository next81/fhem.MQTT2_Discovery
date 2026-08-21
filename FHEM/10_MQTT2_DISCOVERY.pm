# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

##############################################
# Native Home-Assistant-MQTT-Discovery fuer FHEM
package main;

use strict;
use warnings;
use lib './lib/FHEM';
use JSON::PP qw(decode_json);
use MQTT2_Discovery::Helper qw(stable_unique stable_suffix split_lines line_key merge_generated_lines);
use MQTT2_Discovery::FormatRegistry ();
use MQTT2_Discovery::Model ();
use MQTT2_Discovery::Mapper ();
use MQTT2_Discovery::Mapper::Semantics ();
use MQTT2_Discovery::Template ();
use MQTT2_Discovery::FHEMGateway ();
use MQTT2_Discovery::DevicePlanner ();
use vars qw(%defs %attr %modules $readingFnAttributes);

our $MQTT2_DISCOVERY_VERSION = '0.9.0';
our $MQTT2_DISCOVERY_QUEUE_DELAY = 0.01;

# --- FHEM-Zugriffe und Logging ------------------------------------------------

# Pro Modulinstanz wird genau ein Gateway erzeugt und fuer alle FHEM-Zugriffe
# wiederverwendet. Tests koennen vorab ein eigenes Gateway einsetzen.
sub MQTT2_DISCOVERY_gateway($) {
	my ($hash) = @_;
	return $hash->{helper}{gateway} ||= MQTT2_Discovery::FHEMGateway->new();
}

# Das normale FHEM-Attribut verbose steuert alle Meldungen dieses Devices.
sub MQTT2_DISCOVERY_log_enabled($$) {
	my ($hash, $level) = @_;
	return 0 if ref($hash) ne 'HASH' || !defined($hash->{NAME});
	my $gateway = MQTT2_DISCOVERY_gateway($hash);
	my $verbose = $gateway->attr_value(
		$hash->{NAME}, 'verbose', $gateway->attr_value('global', 'verbose', 3),
	);
	$verbose = 3 if !defined($verbose) || $verbose !~ /^\d+$/;
	return $verbose >= $level ? 1 : 0;
}

# Schreibt begrenzte einzeilige Diagnosemeldungen nur ab der aktiven Verbose-Stufe.
sub MQTT2_DISCOVERY_log($$$) {
	my ($hash, $level, $message) = @_;
	return if !MQTT2_DISCOVERY_log_enabled($hash, $level);
	$message = '' if !defined $message;
	$message =~ s/[\r\n]+/ /g;
	$message = substr($message, 0, 4096) . '... <truncated>' if length($message) > 4096;
	MQTT2_DISCOVERY_gateway($hash)->log(
		$hash->{NAME}, $level, "MQTT2_DISCOVERY $hash->{NAME}: $message",
	);
	return;
}

# Vorwaertsdeklaration fuer die rekursive Schwaerzung verschachtelter Logdaten.
sub MQTT2_DISCOVERY_log_redacted($);

# Schwaerzt Geheimnisse rekursiv, bevor strukturierte Payloaddaten protokolliert werden.
sub MQTT2_DISCOVERY_log_redacted($) {
	my ($value) = @_;

	# Hashes werden schluesselweise kopiert, damit vertrauliche Felder maskiert
	# werden koennen, ohne die fuer die Diagnose wichtige Struktur zu verlieren.
	if (ref($value) eq 'HASH') {
		my %safe;

		# Schluesselnamen werden bewusst breit erkannt; ein zu stark geschwaerzter
		# Diagnosewert ist sicherer als ein versehentlich protokolliertes Geheimnis.
		for my $key (keys %$value) {
			$safe{$key} = $key =~ /(?:pass(?:word)?|passwd|secret|token|auth(?:orization)?|credential|api[_-]?key|private[_-]?key|client[_-]?id|user(?:name)?|email)/i
				? '[REDACTED]' : MQTT2_DISCOVERY_log_redacted($value->{$key});
		}

		return \%safe;
	}
	return [ map { MQTT2_DISCOVERY_log_redacted($_) } @$value ] if ref($value) eq 'ARRAY';
	return $value if !ref($value);
	return '<unsupported value>';
}

# Payloads erscheinen nur auf Stufe 5, kanonisch, begrenzt und mit geschwaerzten Geheimnissen.
sub MQTT2_DISCOVERY_log_payload($) {
	my ($payload) = @_;
	$payload = '' if !defined $payload;
	return '<empty payload>' if $payload eq '';
	my ($decoded, $safe);
	my $ok = eval {
		$decoded = decode_json($payload);
		$safe = JSON::PP->new->canonical(1)->encode(MQTT2_DISCOVERY_log_redacted($decoded));
		1;
	};
	return '<invalid or unloggable JSON; length=' . length($payload) . '>' if !$ok;
	return length($safe) <= 4096 ? $safe : substr($safe, 0, 4096) . '... <truncated>';
}

# --- FHEM-Lebenszyklus und Benutzerbefehle -----------------------------------

# Registriert FHEMs Lebenszyklus-, Parser- und Attributschnittstellen fuer den Modultyp.
sub MQTT2_DISCOVERY_Initialize($) {
	my ($hash) = @_;
	$hash->{DefFn} = 'MQTT2_DISCOVERY_Define';
	$hash->{UndefFn} = 'MQTT2_DISCOVERY_Undef';
	$hash->{SetFn} = 'MQTT2_DISCOVERY_Set';
	$hash->{AttrFn} = 'MQTT2_DISCOVERY_Attr';
	$hash->{ParseFn} = 'MQTT2_DISCOVERY_Parse';
	# Kontextbezogene FHEMWEB-Hilfe fuer Set und Attr aktivieren. Die
	# zugehoerigen Commandref-Anker stehen in der eingebetteten HTML-Dokumentation.
	$hash->{FW_deviceOverview} = 1;
	# Match bleibt absichtlich prefixunabhaengig, da Prefixe je IODev konfiguriert sind.
	$hash->{Match} = '\\x00[^\\x00]+/(?:config|sensors)\\x00';
	$hash->{AttrList} = 'discoveryPrefixes deviceNamePrefix existingDevice:conservative,ignore,replace autoCreate:0,1 autoDelete:0,1 disable:0,1 ' . $readingFnAttributes;
	$modules{MQTT2_DISCOVERY}{defptr} ||= {};
}

# Validiert die Definition und bindet genau eine Discovery-Instanz an ein MQTT2-IODev.
sub MQTT2_DISCOVERY_Define($$) {
	my ($hash, $definition) = @_;
	my @parts = split /[ \t]+/, $definition;

	# Eine unvollstaendige Definition darf weder ein IODev binden noch einen
	# halb initialisierten Eintrag in der globalen Discovery-Registry hinterlassen.
	if (@parts != 3) {
		my $error = 'Usage: define <name> MQTT2_DISCOVERY <MQTT2_SERVER|MQTT2_CLIENT>';
		MQTT2_DISCOVERY_log($hash, 1, "define failed: $error");
		return $error;
	}
	my ($name, undef, $io_name) = @parts;
	my $iodev = $defs{$io_name};

	# Ohne vorhandenes IODev gibt es weder einen MQTT-Dispatch noch eine sichere
	# Stelle, an der die Discovery-Instanz registriert werden koennte.
	if (!$iodev) {
		my $error = "MQTT2_DISCOVERY: IODev $io_name existiert nicht";
		MQTT2_DISCOVERY_log($hash, 1, "define failed: $error");
		return $error;
	}

	# Nur MQTT2_SERVER und MQTT2_CLIENT stellen den Parser-Dispatch bereit, den
	# dieses Modul fuer Discovery-Nachrichten benoetigt.
	if (($iodev->{TYPE} || '') !~ /^MQTT2_(?:SERVER|CLIENT)$/) {
		my $error = "MQTT2_DISCOVERY: $io_name ist weder MQTT2_SERVER noch MQTT2_CLIENT";
		MQTT2_DISCOVERY_log($hash, 1, "define failed: $error");
		return $error;
	}
	my $registered = $modules{MQTT2_DISCOVERY}{defptr}{$io_name};

	# Pro IODev darf genau eine Instanz Nachrichten konsumieren; zwei Instanzen
	# wuerden dieselbe Config doppelt verarbeiten und konkurrierende Devices pflegen.
	if ($registered && $registered != $hash) {
		my $error = "MQTT2_DISCOVERY: Fuer $io_name ist bereits $registered->{NAME} definiert";
		MQTT2_DISCOVERY_log($hash, 1, "define failed: $error");
		return $error;
	}

	# FHEM ruft die DefFn bei modify/defmod mit gesetztem OLDDEF erneut auf.
	# Erst nach erfolgreicher Validierung des neuen IODev die bisherige
	# Registrierung und eventuell noch geplante Arbeit entfernen. Schlaegt die
	# Validierung fehl, bleibt die alte Definition dadurch voll funktionsfaehig.
	MQTT2_DISCOVERY_Undef($hash, undef) if defined $hash->{OLDDEF};

	$hash->{IODev} = $iodev;
	$hash->{IODevName} = $io_name;
	$hash->{DEF} = $io_name;
	$modules{MQTT2_DISCOVERY}{defptr}{$io_name} = $hash;
	MQTT2_DISCOVERY_registry($hash);
	MQTT2_DISCOVERY_reading($hash, 'state', MQTT2_DISCOVERY_state($hash));
	MQTT2_DISCOVERY_update_counts($hash);
	MQTT2_DISCOVERY_log($hash, 2, "defined for $iodev->{TYPE} $io_name; version=$MQTT2_DISCOVERY_VERSION");
	return undef;
}

# Loest Timer und IODev-Registrierung einer entfernten oder geaenderten Instanz.
sub MQTT2_DISCOVERY_Undef($$) {
	my ($hash, undef) = @_;
	my $io_name = $hash->{IODevName};
	MQTT2_DISCOVERY_clear_queue($hash);
	MQTT2_DISCOVERY_log($hash, 2, 'undefined' . ($io_name ? "; IODev=$io_name" : ''));
	delete $modules{MQTT2_DISCOVERY}{defptr}{$io_name}
		if $io_name && $modules{MQTT2_DISCOVERY}{defptr}{$io_name} == $hash;
	return undef;
}

# Validiert Modulattribute und setzt disable-Aenderungen unmittelbar im Laufzeitstatus um.
sub MQTT2_DISCOVERY_Attr(@) {
	my ($operation, $name, $attribute, @values) = @_;

	# disable wirkt unmittelbar auf Laufzeitstatus und Warteschlange und wird
	# deshalb getrennt von den rein deklarativen Attributen behandelt.
	if ($attribute eq 'disable') {
		my $value = join(' ', @values);
		return 'disable muss 0 oder 1 sein'
			if $operation eq 'set' && $value !~ /^(?:0|1)$/;
		my $hash = $defs{$name};

		# AttrFn kann auch waehrend des Loeschens aufgerufen werden; nur ein noch
		# vorhandenes Device darf Readings oder geplante Arbeit aktualisieren.
		if ($hash) {
			# Das Reading wird sofort aktualisiert; beim Deaktivieren darf keine
			# bereits geplante Discovery-Arbeit spaeter weiterlaufen.
			my $disabled = $operation eq 'set' && $value eq '1';
			MQTT2_DISCOVERY_clear_queue($hash) if $disabled;
			MQTT2_DISCOVERY_reading($hash, 'state', $disabled ? 'disabled' : MQTT2_DISCOVERY_state($hash, 1));
			MQTT2_DISCOVERY_log($hash, 2, $disabled ? 'disabled by attribute' : 'enabled by attribute');
		}
		return undef;
	}
	return undef if $operation ne 'set';
	my $value = join(' ', @values);

	# Jedes verwaltete Attribut beeinflusst Topic-Erkennung, Konfliktstrategie
	# oder Namensbildung und muss vor der Uebernahme seine eigene Syntax erfuellen.
	if ($attribute eq 'discoveryPrefixes') {
		my ($prefixes, $error) = MQTT2_DISCOVERY_prefixes_from_value($value);
		return $error if $error;
		return 'discoveryPrefixes darf nicht leer sein' if !@$prefixes;
	} elsif ($attribute eq 'existingDevice') {
		return 'existingDevice muss conservative, ignore oder replace sein'
			if $value !~ /^(?:conservative|ignore|replace)$/;
	} elsif ($attribute eq 'autoCreate' || $attribute eq 'autoDelete') {
		return "$attribute muss 0 oder 1 sein" if $value !~ /^(?:0|1)$/;
	} elsif ($attribute eq 'deviceNamePrefix') {
		return 'deviceNamePrefix muss mit einem Buchstaben oder Unterstrich beginnen und darf nur Buchstaben, Ziffern, Unterstriche und Punkte enthalten'
			if $value !~ /^[A-Za-z_][A-Za-z0-9_.]*$/;
	}
	return undef;
}

# Verteilt die erlaubten Set-Kommandos auf Aktivierung, Deaktivierung oder Rescan.
sub MQTT2_DISCOVERY_Set($@) {
	my ($hash, @arguments) = @_;
	shift @arguments;
	my $command = shift @arguments;
	MQTT2_DISCOVERY_log($hash, 3, 'set ' . (defined($command) ? $command : '<missing>'));
	MQTT2_DISCOVERY_log($hash, 4, 'set arguments=[' . join(', ', @arguments) . ']') if @arguments;
	return 'Unknown argument ?, choose one of activate:noArg deactivate:noArg rescan:noArg'
		if !defined $command;
	return MQTT2_DISCOVERY_activate($hash) if $command eq 'activate' && !@arguments;
	return MQTT2_DISCOVERY_deactivate($hash) if $command eq 'deactivate' && !@arguments;
	return MQTT2_DISCOVERY_rescan($hash) if $command eq 'rescan' && !@arguments;
	return "Unknown argument $command, choose one of activate:noArg deactivate:noArg rescan:noArg";
}

# Parst und validiert die kommagetrennte Liste erlaubter Discovery-Topic-Prefixe.
sub MQTT2_DISCOVERY_prefixes_from_value($) {
	my ($value) = @_;
	my @prefixes = map {
		my $prefix = $_;
		$prefix =~ s/^\s+|\s+$//g;
		$prefix;
	} split /,/, defined($value) ? $value : '';

	for my $prefix (@prefixes) {
		return (undef, 'Discovery-Prefixe duerfen nicht leer sein') if $prefix eq '';
		return (undef, "Ungueltiger Discovery-Prefix: $prefix")
			if $prefix !~ m{^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*$};
	}

	return ([ stable_unique(@prefixes) ], undef);
}

# Liest die wirksamen Discovery-Prefixe und liefert bei Altstaenden sichere Standards.
sub MQTT2_DISCOVERY_prefixes($) {
	my ($hash) = @_;
	my $value = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{NAME}, 'discoveryPrefixes', 'homeassistant,tasmota/discovery',
	);
	my ($prefixes, undef) = MQTT2_DISCOVERY_prefixes_from_value($value);
	return $prefixes || ['homeassistant', 'tasmota/discovery'];
}

# Ermittelt die aktuelle MQTT-Parserreihenfolge aus Attribut oder IODev-Standard.
sub MQTT2_DISCOVERY_client_order($) {
	my ($hash) = @_;
	my $iodev = $hash->{IODev};
	my $configured = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$iodev->{NAME}, 'clientOrder', '',
	);
	my @order = $configured ne '' ? split(/\s+/, $configured) : grep { $_ ne '' } split(/:/, $iodev->{Clients} || '');
	@order = qw(MQTT2_DEVICE MQTT_GENERIC_BRIDGE) if !@order;
	return @order;
}

# Discovery muss vor MQTT2_DEVICE laufen, damit Discovery-Nachrichten nicht als
# normale Geraetetelemetrie autocreated werden.
sub MQTT2_DISCOVERY_is_active($) {
	my ($hash) = @_;
	my @order = MQTT2_DISCOVERY_client_order($hash);
	my %position;
	$position{$order[$_]} = $_ for 0 .. $#order;
	return 0 if !exists $position{MQTT2_DISCOVERY};
	return 0 if exists($position{MQTT2_DEVICE}) && $position{MQTT2_DISCOVERY} > $position{MQTT2_DEVICE};
	return 1;
}

# Leitet den sichtbaren Modulstatus aus disable und der tatsaechlichen Parserposition ab.
sub MQTT2_DISCOVERY_state($;$) {
	my ($hash, $ignore_disable) = @_;
	return 'disabled' if !$ignore_disable
		&& MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0);
	return MQTT2_DISCOVERY_is_active($hash) ? 'active' : 'inactive';
}

# Ordnet Discovery vor den Device-Parsern ein und aktualisiert den Laufzeitstatus.
sub MQTT2_DISCOVERY_activate($) {
	my ($hash) = @_;
	my @order = grep { $_ ne 'MQTT2_DISCOVERY' } MQTT2_DISCOVERY_client_order($hash);
	my $index = 0;

	# Vor den ersten Device-Parser einsortieren, andere Client-Reihenfolge aber
	# unveraendert lassen.
	++$index while $index < @order && $order[$index] ne 'MQTT2_DEVICE' && $order[$index] ne 'MQTT_GENERIC_BRIDGE';
	splice @order, $index, 0, 'MQTT2_DISCOVERY';
	my $error = MQTT2_DISCOVERY_gateway($hash)->set_attribute(
		$hash->{IODevName}, 'clientOrder', join(' ', @order),
	);

	# Bei einem FHEM-Fehler ist die neue Parserposition nicht verlaesslich aktiv;
	# Status und Erfolgsmeldung duerfen dann nicht vorgetaeuscht werden.
	if ($error) {
		MQTT2_DISCOVERY_log($hash, 1, "activation failed: $error");
		return $error;
	}
	MQTT2_DISCOVERY_reading($hash, 'state', MQTT2_DISCOVERY_state($hash));
	MQTT2_DISCOVERY_check_ignore_regexp($hash);
	MQTT2_DISCOVERY_log($hash, 2, 'activated; clientOrder=' . join(' ', @order));
	return undef;
}

# Entfernt Discovery aus clientOrder und verwirft danach noch geplante Verarbeitung.
sub MQTT2_DISCOVERY_deactivate($) {
	my ($hash) = @_;
	my @order = grep { $_ ne 'MQTT2_DISCOVERY' } MQTT2_DISCOVERY_client_order($hash);
	my $error = MQTT2_DISCOVERY_gateway($hash)->set_attribute(
		$hash->{IODevName}, 'clientOrder', @order ? join(' ', @order) : '',
	);

	# Schlaegt das Entfernen aus clientOrder fehl, kann der Parser weiterhin aktiv
	# sein; seine Warteschlange bleibt deshalb bis zu einer erfolgreichen Aenderung erhalten.
	if ($error) {
		MQTT2_DISCOVERY_log($hash, 1, "deactivation failed: $error");
		return $error;
	}
	MQTT2_DISCOVERY_clear_queue($hash);
	MQTT2_DISCOVERY_reading($hash, 'state', MQTT2_DISCOVERY_state($hash));
	MQTT2_DISCOVERY_log($hash, 2, 'deactivated; clientOrder=' . join(' ', @order));
	return undef;
}

# Warnt, wenn das IODev-ignoreRegexp typische Discovery-Topics ausfiltern wuerde.
sub MQTT2_DISCOVERY_check_ignore_regexp($) {
	my ($hash) = @_;
	my $regexp = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{IODevName}, 'ignoreRegexp', '',
	);
	return if $regexp eq '';

	# Beispieltopics pruefen die haeufigen Discovery-Layouts, ohne reale
	# Nachrichten oder Devices zu erzeugen.
	for my $prefix (@{ MQTT2_DISCOVERY_prefixes($hash) }) {
		my $matches = eval {
			"$prefix/sensor/example/config:{}" =~ /$regexp/
				|| "$prefix/001122AABBCC/sensors:{}" =~ /$regexp/
		};

		# Ein Treffer auf typische Discovery-Topics erklaert ausbleibende Geraete
		# fruehzeitig, bevor der Filter echte Broker-Nachrichten unbemerkt verwirft.
		if ($matches) {
			my $warning = 'ignoreRegexp blockiert moeglicherweise Discovery-Nachrichten';
			MQTT2_DISCOVERY_reading($hash, 'lastWarning', $warning);
			MQTT2_DISCOVERY_log($hash, 2, "warning: $warning; prefix=$prefix");
			return;
		}
	}

}

# Spielt den lokalen MQTT2_SERVER-Retain-Cache als gemeinsamen Discovery-Batch erneut ein.
sub MQTT2_DISCOVERY_rescan($) {
	my ($hash) = @_;

	# Ein manueller Rescan darf die ausdrueckliche Deaktivierung nicht umgehen
	# und dadurch trotz disable=1 wieder Devices oder Attribute veraendern.
	if (MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		my $message = 'MQTT2_DISCOVERY ist durch disable=1 deaktiviert';
		MQTT2_DISCOVERY_reading($hash, 'lastRescan', $message);
		MQTT2_DISCOVERY_log($hash, 2, "rescan skipped: $message");
		return $message;
	}
	my $iodev = $hash->{IODev};
	MQTT2_DISCOVERY_log($hash, 3, "rescan started; IODev=$hash->{IODevName}");

	# MQTT2_CLIENT verwaltet keinen lokalen Retain-Cache; dort kann nur der Broker
	# die Configs nach Reconnect oder erneuter Subscription wieder ausliefern.
	if (($iodev->{TYPE} || '') eq 'MQTT2_CLIENT') {
		my $message = 'MQTT2_CLIENT besitzt keinen lokalen Retain-Cache; Broker-Replay oder Reconnect erforderlich';
		MQTT2_DISCOVERY_reading($hash, 'lastRescan', $message);
		MQTT2_DISCOVERY_log($hash, 2, "rescan unavailable: $message");
		return $message;
	}
	my $retain = $iodev->{retain};

	# Ohne den erwarteten Hash ist keine vertrauenswuerdige Liste retained Topics
	# vorhanden, aus der ein lokaler Wiederholungslauf aufgebaut werden koennte.
	if (ref($retain) ne 'HASH') {
		my $message = 'Kein Retain-Cache vorhanden; respectRetain und retained Discovery pruefen';
		MQTT2_DISCOVERY_reading($hash, 'lastRescan', $message);
		MQTT2_DISCOVERY_log($hash, 2, "rescan unavailable: $message");
		return $message;
	}
	my $cid = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$iodev->{NAME}, 'clientId', $iodev->{NAME},
	);
	my ($processed, $failed) = (0, 0);

	# Alle retained Topics teilen eine Registry-Kopie und werden erst nach dem
	# vollstaendigen Scan pro Device angewendet.
	my $batch = { pending_identities => {}, created_identities => {} };

	for my $topic (sort keys %$retain) {
		my $entry = $retain->{$topic};
		my $payload = ref($entry) eq 'HASH' ? $entry->{val} : $entry;
		my $status = MQTT2_DISCOVERY_process($hash, $cid, $topic, $payload, $batch);
		++$processed if $status eq 'consumed';
		++$failed if $status eq 'error';
	}

	my $apply_error = MQTT2_DISCOVERY_finish_batch($hash, $batch);

	# Ein Fehler beim abschliessenden Device-Apply gehoert zur Rescan-Bilanz, auch
	# wenn alle einzelnen retained Nachrichten zuvor erfolgreich geparst wurden.
	if ($apply_error) {
		++$failed;
		MQTT2_DISCOVERY_reading($hash, 'lastError', $apply_error);
		MQTT2_DISCOVERY_log($hash, 1, "rescan apply failed: $apply_error");
	}
	my $message = "processed=$processed failed=$failed";
	MQTT2_DISCOVERY_reading($hash, 'lastRescan', $message);
	MQTT2_DISCOVERY_log($hash, $failed ? 2 : 3, "rescan finished; $message");
	return undef;
}

# Konsumiert passende MQTT-Dispatchnachrichten und plant oder startet deren Verarbeitung.
sub MQTT2_DISCOVERY_Parse($$) {
	my ($iodev, $message) = @_;
	my $config = $modules{MQTT2_DISCOVERY}{defptr}{ $iodev->{NAME} };
	return '[NEXT]' if !$config;

	# Auch deaktivierte Discovery-Nachrichten werden konsumiert, damit
	# MQTT2_DEVICE daraus keine unerwuenschten Fremd-Devices autocreated.
	if (MQTT2_DISCOVERY_gateway($config)->attr_value($config->{NAME}, 'disable', 0)) {
		MQTT2_DISCOVERY_log($config, 4, 'disabled; consuming discovery message without processing');
		return '';
	}
	$message =~ s/^autocreate=[^\0]+\0//s;
	my ($cid, $topic, $payload) = split /\0/, $message, 3;
	return '[NEXT]' if !defined($topic) || !defined($payload);
	return '[NEXT]' if !grep { MQTT2_Discovery::DevicePlanner::topic_has_prefix($topic, $_) }
		@{ MQTT2_DISCOVERY_prefixes($config) };

	# MQTT2_SERVER kann beim Start viele retained Configs in einem einzigen
	# Dispatch-Schub liefern. Die teure Parser-/Mapping-/Attributarbeit darf
	# dabei FHEMs Event-Loop nicht fuer den gesamten Schub blockieren.
	if (MQTT2_DISCOVERY_gateway($config)->can_schedule()) {
		MQTT2_DISCOVERY_enqueue($config, $cid, $topic, $payload);
		return '';
	}

	# Isolierte Testumgebungen ohne FHEM-Timer bleiben synchron nutzbar.
	my $status = MQTT2_DISCOVERY_process($config, $cid, $topic, $payload);
	return '[NEXT]' if $status eq 'next';
	# Ein definierter Leerstring stoppt im aktuellen Dispatch die Parserkette ohne Device-Event.
	return '';
}

# --- Asynchrone Verarbeitung -------------------------------------------------

# Koalesziert Config-Nachrichten pro Topic und plant genau einen kurzen Queue-Timer.
sub MQTT2_DISCOVERY_enqueue($$$$) {
	my ($hash, $cid, $topic, $payload) = @_;
	my $queue = $hash->{helper}{queue} ||= { order => [], messages => {}, scheduled => 0 };

	# Fuer ein Config-Topic ist nur der zuletzt empfangene Stand relevant. Das
	# begrenzt zugleich die Arbeit bei schnellen Wiederholungen/Reconnects.
	push @{ $queue->{order} }, $topic if !exists $queue->{messages}{$topic};
	$queue->{messages}{$topic} = [$cid, $topic, $payload];
	return if $queue->{scheduled};

	$queue->{scheduled} = 1;
	MQTT2_DISCOVERY_gateway($hash)->schedule(
		$MQTT2_DISCOVERY_QUEUE_DELAY, $hash, 'MQTT2_DISCOVERY_process_queue',
	);
	return;
}

# Verarbeitet pro Timerlauf eine Nachricht oder ein vorbereitetes Zieldevice atomar.
sub MQTT2_DISCOVERY_process_queue($) {
	my ($hash) = @_;
	my $queue = $hash->{helper}{queue};
	return if ref($queue) ne 'HASH';

	# Nach Loeschen, Ersetzen oder Deaktivieren des Devices darf ein alter Timer
	# keine bereits ueberholten Discovery-Nachrichten mehr anwenden.
	if (!$defs{ $hash->{NAME} } || $defs{ $hash->{NAME} } != $hash
			|| MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'disable', 0)) {
		MQTT2_DISCOVERY_clear_queue($hash);
		return;
	}

	my $batch = $queue->{batch} ||= {
		pending_identities => {}, created_identities => {}, delete_had_manual => {},
	};
	my $message;

	# Pro Timerlauf wird hoechstens eine MQTT-Nachricht verarbeitet. Wenn keine
	# mehr wartet, folgt hoechstens ein bereits zusammengefuehrtes Zieldevice.
	while (@{ $queue->{order} || [] }) {
		my $topic = shift @{ $queue->{order} };
		$message = delete $queue->{messages}{$topic};
		last if $message;
	}

	MQTT2_DISCOVERY_process($hash, @$message, $batch) if $message;

	my $error;

	# Sind keine MQTT-Nachrichten mehr offen, wird pro Timerlauf genau ein bereits
	# zusammengefuehrtes Zieldevice angewendet, damit FHEMs Event-Loop responsiv bleibt.
	if (!$message && keys %{ $batch->{pending_identities} || {} }) {
		my ($identity) = sort keys %{ $batch->{pending_identities} };
		$error = MQTT2_DISCOVERY_apply_batch_identity($hash, $batch, $identity);
		delete $batch->{pending_identities}{$identity} if !$error;
	}

	# Ein fehlgeschlagener Apply beendet den gesamten Queue-Batch; nur in diesem
	# Lauf erzeugte Devices werden dabei als Teil der Transaktion zurueckgerollt.
	if ($error) {
		# Neu angelegte Devices gehoeren zur fehlgeschlagenen Transaktion und
		# werden entfernt; bestehende Devices bleiben durch den ActionPlan intakt.
		MQTT2_DISCOVERY_cleanup_created_devices($hash, $batch->{registry}, $batch->{created_identities});
		$hash->{helper}{registry} = $batch->{registry};
		MQTT2_DISCOVERY_persist_registry($hash);
		MQTT2_DISCOVERY_update_counts($hash);
		MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
		MQTT2_DISCOVERY_log($hash, 1, "queue apply failed: $error");
		MQTT2_DISCOVERY_clear_queue($hash);
	} elsif (@{ $queue->{order} || [] } || keys %{ $batch->{pending_identities} || {} }) {
		MQTT2_DISCOVERY_gateway($hash)->schedule(
			$MQTT2_DISCOVERY_QUEUE_DELAY, $hash, 'MQTT2_DISCOVERY_process_queue',
		);
	} else {
		$hash->{helper}{registry} = $batch->{registry} if ref($batch->{registry}) eq 'HASH';
		MQTT2_DISCOVERY_persist_registry($hash);
		MQTT2_DISCOVERY_update_counts($hash);
		$queue->{scheduled} = 0;
		delete $queue->{batch};
	}
	return;
}

# Bricht geplante Queue-Arbeit ab und entfernt den vollstaendigen Batchzustand.
sub MQTT2_DISCOVERY_clear_queue($) {
	my ($hash) = @_;
	MQTT2_DISCOVERY_gateway($hash)->cancel_timer($hash, 'MQTT2_DISCOVERY_process_queue');
	delete $hash->{helper}{queue} if ref($hash->{helper}) eq 'HASH';
	return;
}

# Vorwaertsdeklaration der inneren Verarbeitung fuer den davor definierten Fehlerwrapper.
sub MQTT2_DISCOVERY_process_inner($$$$;$);

# Issues werden pro Topic gespeichert. Ein spaeter erfolgreich verarbeitetes
# Topic kann dadurch genau seinen vorherigen Fehler oder seine Warnung loeschen.
# Synchronisiert Fehler- und Warnungszaehler mit den Topic-bezogenen Issue-Tabellen.
sub MQTT2_DISCOVERY_update_issue_readings($) {
	my ($hash) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	MQTT2_DISCOVERY_reading($hash, 'errorCount', scalar keys %{ $issues->{error} || {} });
	MQTT2_DISCOVERY_reading($hash, 'warningCount', scalar keys %{ $issues->{warning} || {} });
	return;
}

# Speichert einen Fehler oder eine Warnung samt Topic und Adapter in Readings und Speicher.
sub MQTT2_DISCOVERY_record_issue($$$$$) {
	my ($hash, $level, $topic, $adapter, $reason) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	$issues->{$level}{$topic} = {
		adapter => $adapter || 'unknown', reason => $reason || 'Unbekannter Fehler',
	};
	my $prefix = $level eq 'error' ? 'lastError' : 'lastWarning';
	MQTT2_DISCOVERY_reading($hash, $prefix, $reason || 'Unbekannter Fehler');
	MQTT2_DISCOVERY_reading($hash, $prefix . 'Adapter', $adapter || 'unknown');
	MQTT2_DISCOVERY_reading($hash, $prefix . 'Topic', $topic);
	MQTT2_DISCOVERY_update_issue_readings($hash);
	return;
}

# Entfernt ein geloestes Topic-Issue und aktualisiert die zugehoerigen Zaehler.
sub MQTT2_DISCOVERY_clear_issue($$$) {
	my ($hash, $level, $topic) = @_;
	my $issues = $hash->{helper}{issues} ||= { error => {}, warning => {} };
	delete $issues->{$level}{$topic};
	MQTT2_DISCOVERY_reading($hash, 'lastWarning', 'none')
		if $level eq 'warning' && !keys %{ $issues->{warning} || {} };
	MQTT2_DISCOVERY_update_issue_readings($hash);
	return;
}

# Kapselt die gesamte Topic-Verarbeitung in einer Exception-Grenze und pflegt Issues.
sub MQTT2_DISCOVERY_process($$$$;$) {
	my ($hash, $cid, $topic, $payload, $batch) = @_;
	delete $hash->{helper}{process_adapter};
	delete $hash->{helper}{process_warning};
	my $status;

	# Diese Exception-Grenze verhindert, dass fehlerhafte Fremddaten FHEMs
	# gesamten MQTT-Dispatch abbrechen.
	my $ok = eval {
		$status = MQTT2_DISCOVERY_process_inner($hash, $cid, $topic, $payload, $batch);
		1;
	};

	# Nur ein expliziter Status aus einer fehlerfrei verlassenen Prozessgrenze ist
	# geeignet, die Topic-bezogenen Fehler- und Warnungsreadings fortzuschreiben.
	if ($ok && defined $status) {

		# Parser- oder Apply-Fehler bleiben ihrem Topic und Adapter zugeordnet, damit
		# eine spaetere erfolgreiche Wiederholung genau diesen Eintrag loeschen kann.
		if ($status eq 'error') {
			MQTT2_DISCOVERY_record_issue(
				$hash, 'error', $topic,
				$hash->{helper}{process_adapter}
					|| MQTT2_DISCOVERY_gateway($hash)->reading_value($hash->{NAME}, 'lastErrorAdapter', 'unknown'),
				MQTT2_DISCOVERY_gateway($hash)->reading_value($hash->{NAME}, 'lastError', 'Unbekannter Fehler'),
			);
		} elsif ($status eq 'consumed') {
			MQTT2_DISCOVERY_clear_issue($hash, 'error', $topic);
			my $warning = delete $hash->{helper}{process_warning};

			# Ein erfolgreich konsumiertes Topic kann dennoch degradierte oder nicht
			# unterstuetzte Bestandteile enthalten, die als Warnung sichtbar bleiben sollen.
			if (defined($warning) && $warning ne '') {
				MQTT2_DISCOVERY_record_issue(
					$hash, 'warning', $topic,
					MQTT2_DISCOVERY_gateway($hash)->reading_value($hash->{NAME}, 'lastAdapter', 'unknown'), $warning,
				);
			} else {
				MQTT2_DISCOVERY_clear_issue($hash, 'warning', $topic);
			}
			MQTT2_DISCOVERY_reading($hash, 'lastError', 'none')
				if !keys %{ $hash->{helper}{issues}{error} || {} };
		}
		return $status;
	}

	my $detail = $ok ? 'Verarbeitung lieferte keinen Status' : ($@ || 'unbekannter Fehler');
	$detail =~ s/[\r\n]+/ /g;
	$detail = substr($detail, 0, 1000) . '... <truncated>' if length($detail) > 1000;
	my $error = "Unerwarteter Fehler in der MQTT-Verarbeitung: $detail";
	eval { MQTT2_DISCOVERY_reading($hash, 'lastError', $error) };
	eval { MQTT2_DISCOVERY_record_issue(
		$hash, 'error', $topic, $hash->{helper}{process_adapter} || 'unknown', $error,
	) };
	eval { MQTT2_DISCOVERY_log($hash, 1, $error) };
	return 'error';
}

# Fuehrt Formatwahl, Modellierung, Mapping und transaktionales Device-Apply fuer ein Topic aus.
sub MQTT2_DISCOVERY_process_inner($$$$;$) {
	my ($hash, $cid, $topic, $payload, $batch) = @_;
	MQTT2_DISCOVERY_log($hash, 3, "processing topic=$topic");
	MQTT2_DISCOVERY_log($hash, 4, 'message cid=' . (defined($cid) ? $cid : '') . '; payloadLength=' . length(defined($payload) ? $payload : ''));
	MQTT2_DISCOVERY_log($hash, 5, 'discovery payload=' . MQTT2_DISCOVERY_log_payload($payload))
		if MQTT2_DISCOVERY_log_enabled($hash, 5);
	my $prefixes = MQTT2_DISCOVERY_prefixes($hash);
	my $parsed = MQTT2_Discovery::FormatRegistry::consume(
		topic => $topic, payload => $payload, prefixes => $prefixes,
		states => ($hash->{helper}{formats} ||= {}),
		(ref($hash->{helper}{format_adapters}) eq 'ARRAY'
			? (adapters => $hash->{helper}{format_adapters}) : ()),
	);
	$hash->{helper}{process_adapter} = $parsed->{adapter} if $parsed->{adapter};

	# Kein Adapter beansprucht das Topic; es muss fuer nachfolgende MQTT-Parser
	# freigegeben werden und darf keine Discovery-Readings veraendern.
	if ($parsed->{status} eq 'next') {
		MQTT2_DISCOVERY_log($hash, 4, "topic does not match configured prefixes; passing to next parser: $topic");
		return 'next';
	}
	MQTT2_DISCOVERY_reading($hash, 'lastTopic', $topic);

	# Parserfehler liefern kein belastbares kanonisches Modell und duerfen daher
	# weder Registry noch Zieldevices teilweise veraendern.
	if ($parsed->{status} ne 'ok') {
		my $error = $parsed->{error} || 'Unbekannter Parserfehler';
		MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
		MQTT2_DISCOVERY_reading($hash, 'lastErrorAdapter', $parsed->{adapter} || 'unknown');
		MQTT2_DISCOVERY_reading($hash, 'lastErrorTopic', $topic);
		MQTT2_DISCOVERY_reading($hash, 'unsupportedCount', scalar @{ $parsed->{warnings} || [] }) if $parsed->{warnings};
		MQTT2_DISCOVERY_log($hash, 1, "parser error for topic=$topic: $error");
		return 'error';
	}

	# Die Registry wird als Transaktionsentwurf kopiert. Erst nach erfolgreichem
	# Mapping und Attribut-Apply ersetzt sie den bisher sichtbaren Stand.
	my $registry;
	my $clone_ok = eval {

		# Ein Batch teilt genau einen Registry-Entwurf ueber alle Nachrichten;
		# Einzelverarbeitung erhaelt dagegen eine nur fuer dieses Topic gueltige Kopie.
		if ($batch) {
			$batch->{registry} ||= MQTT2_DISCOVERY_clone_registry(MQTT2_DISCOVERY_registry($hash));
			$registry = $batch->{registry};
		} else {
			$registry = MQTT2_DISCOVERY_clone_registry(MQTT2_DISCOVERY_registry($hash));
		}
		1;
	};

	# Ohne vollstaendige Registry-Kopie fehlt die Rollback-Grenze; die Verarbeitung
	# muss abbrechen, bevor irgendein Device den neuen Stand sieht.
	if (!$clone_ok) {
		my $detail = $@ || 'unbekannter JSON-Fehler';
		$detail =~ s/[\r\n]+/ /g;
		my $error = "Registry konnte nicht kopiert werden: $detail";
		MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
		MQTT2_DISCOVERY_log($hash, 1, $error);
		return 'error';
	}
	my @warnings = @{ $parsed->{warnings} || [] };
	my %pending_identities;
	my %created_identities;

	# Parser koennen aus einer Nachricht mehrere Upserts und Deletes liefern.
	# Zunaechst werden alle davon nur in der Registry-Kopie gesammelt.
	for my $event (@{ $parsed->{events} || [] }) {
		my $operation = $event->{operation} || 'upsert';
		MQTT2_DISCOVERY_log($hash, 4, 'entity operation=' . $operation
			. '; component=' . ($event->{entity}{kind} || '') . '; key=' . ($event->{source}{key} || ''));

		# Loeschereignisse entfernen bestehende Registry-Eintraege und durchlaufen
		# deshalb nicht das fuer Upserts bestimmte Mapping und Rendering.
		if ($operation eq 'delete' || $operation eq 'delete_device') {
			my ($entity, $model_error) = MQTT2_Discovery::Model::to_entity($event);

			# Eine nicht kanonisierbare Loeschung koennte die falsche Entity treffen;
			# in diesem Fall bleibt der bisherige Registry-Stand unveraendert.
			if ($model_error) {
				MQTT2_DISCOVERY_reading($hash, 'lastError', $model_error);
				MQTT2_DISCOVERY_log($hash, 1, "canonical delete failed for topic=$topic: $model_error");
				return 'error';
			}
			my $error = MQTT2_DISCOVERY_delete_entity($hash, $registry, $entity, $batch);

			# Fehler beim Neurendern oder automatischen Loeschen machen die gesamte
			# Delete-Operation unvollstaendig und werden als Topic-Fehler zurueckgegeben.
			if ($error) {
				MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
				MQTT2_DISCOVERY_log($hash, 1, "delete failed for topic=$topic: $error");
				return 'error';
			}
			next;
		}
		my $mapping = MQTT2_Discovery::Mapper::map_model(
			model => $event, io_name => $hash->{IODevName},
			name_prefix => MQTT2_DISCOVERY_gateway($hash)->attr_value(
				$hash->{NAME}, 'deviceNamePrefix', '',
			),
		);

		# Nicht abbildbare Komponenten werden isoliert uebersprungen, damit andere
		# Entities derselben Discovery-Nachricht weiterhin nutzbar bleiben.
		if (!$mapping->{ok}) {
			push @warnings, $mapping->{error};
			MQTT2_DISCOVERY_log($hash, 2, 'mapping warning: ' . ($mapping->{error} || 'unknown mapping error'));
			next;
		}
		MQTT2_DISCOVERY_log($hash, 4, 'mapped component=' . ($mapping->{metadata}{component} || '')
			. '; target=' . ($mapping->{proposed_name} || '') . '; readings=' . scalar(@{ $mapping->{reading_lines} || [] })
			. '; sets=' . scalar(@{ $mapping->{set_lines} || [] }));
		push @warnings, @{ $mapping->{warnings} || [] };
		my $identity_existed = exists $registry->{devices}{ $mapping->{identity} };
		my $error = MQTT2_DISCOVERY_stage_mapping($hash, $registry, $mapping, $cid);

		# Ein Staging-Fehler kann bereits ein neues Device angelegt haben; solche
		# Seiteneffekte dieses Laufs werden entfernt, bevor der Fehler weitergereicht wird.
		if ($error) {
			MQTT2_DISCOVERY_cleanup_created_devices($hash, $registry, \%created_identities);
			MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
			MQTT2_DISCOVERY_log($hash, 1, "apply failed for topic=$topic: $error");
			return 'error';
		}
		$pending_identities{ $mapping->{identity} } = 1;
		$created_identities{ $mapping->{identity} } = 1
			if !$identity_existed && $registry->{devices}{ $mapping->{identity} }{created};
	}

	# Im Batch werden nur betroffene Identitaeten vorgemerkt; ohne Batch koennen
	# die vollstaendig gesammelten Mappings sofort pro Zieldevice angewendet werden.
	if ($batch) {
		$batch->{pending_identities}{$_} = 1 for keys %pending_identities;
		$batch->{created_identities}{$_} = 1 for keys %created_identities;
	} else {
		# Erst die vollstaendige Nachricht sammeln, damit jedes Zieldevice nur einmal
		# neue Attribute erhaelt und Device-Discovery atomar sichtbar wird.
		for my $identity (sort keys %pending_identities) {
			my $record = $registry->{devices}{$identity};
			my $error = MQTT2_DISCOVERY_apply_device_lines($hash, $record);

			# Scheitert ein Zieldevice, gehoeren alle in dieser Nachricht neu erzeugten
			# Devices zum fehlgeschlagenen Apply und werden gemeinsam bereinigt.
			if ($error) {
				MQTT2_DISCOVERY_cleanup_created_devices($hash, $registry, \%created_identities);
				MQTT2_DISCOVERY_reading($hash, 'lastError', $error);
				MQTT2_DISCOVERY_log($hash, 1, "apply failed for topic=$topic: $error");
				return 'error';
			}
		}

	}

	# Bei Einzelverarbeitung ist der neue Entwurf jetzt vollstaendig angewendet und
	# darf den sichtbaren Registry-Stand ersetzen; ein Batch tut das erst am Ende.
	if (!$batch) {
		$hash->{helper}{registry} = $registry;
		MQTT2_DISCOVERY_persist_registry($hash);
		MQTT2_DISCOVERY_update_counts($hash);
	}

	# Parser- und Mapping-Warnungen degradieren das Ergebnis, verhindern aber nicht
	# die erfolgreichen Entities und werden deshalb getrennt von Fehlern gespeichert.
	if (@warnings) {
		my $warning = join('; ', @warnings);
		$hash->{helper}{process_warning} = $warning;
		MQTT2_DISCOVERY_reading($hash, 'lastWarning', $warning);
		MQTT2_DISCOVERY_log($hash, 2, "warning: $warning");
	}
	MQTT2_DISCOVERY_reading($hash, 'lastAdapter', $parsed->{adapter} || 'unknown');
	MQTT2_DISCOVERY_log($hash, 3, 'processing finished; topic=' . $topic
		. '; entities=' . scalar(@{ $parsed->{events} || [] }));
	return 'consumed';
}

# Prueft, ob eine geladene Registry die fuer sichere Weiterverarbeitung erwartete Struktur hat.
sub MQTT2_DISCOVERY_registry_valid($) {
	my ($registry) = @_;
	return 0 if ref($registry) ne 'HASH' || ref($registry->{devices}) ne 'HASH';

	for my $record (values %{ $registry->{devices} }) {
		return 0 if ref($record) ne 'HASH' || ref($record->{entities}) ne 'HASH';
		return 0 if exists($record->{owned_reading}) && ref($record->{owned_reading}) ne 'ARRAY';
		return 0 if exists($record->{owned_set}) && ref($record->{owned_set}) ne 'ARRAY';
		return 0 if grep { ref($_) ne 'HASH' } values %{ $record->{entities} };
	}

	return 1;
}

# Die versteckte .registry-Reading ueberlebt einen FHEM-Neustart, ohne eine
# Konfigurationsdatei zu veraendern. Ungueltige Altstaende werden verworfen.
sub MQTT2_DISCOVERY_registry($) {
	my ($hash) = @_;
	return $hash->{helper}{registry} if ref($hash->{helper}{registry}) eq 'HASH';
	my $stored = MQTT2_DISCOVERY_gateway($hash)->reading_value($hash->{NAME}, '.registry', '');
	my $registry;
	eval {
		$registry = utf8::is_utf8($stored)
			? JSON::PP->new->decode($stored)
			: decode_json($stored);
	} if $stored ne '';

	# Ein fehlender oder strukturell veralteter Persistenzstand wird durch eine
	# leere Registry ersetzt, statt spaetere Mapping-Schritte mit Fremddaten zu speisen.
	if (!MQTT2_DISCOVERY_registry_valid($registry)) {
		MQTT2_DISCOVERY_log($hash, 2, 'stored registry is empty or invalid; starting with an empty registry') if $stored ne '';
		$registry = { version => 1, devices => {} };
	}
	$hash->{helper}{registry} = $registry;
	return $registry;
}

# Erstellt ueber kanonisches JSON eine tiefe Kopie des reinen Registry-Datenmodells.
sub MQTT2_DISCOVERY_clone_registry($) {
	my ($registry) = @_;
	my $json = JSON::PP->new->canonical(1);
	return $json->decode($json->encode($registry));
}

# Persistiert den kanonischen Registry-Stand in einer internen, nicht ausloesenden Reading.
sub MQTT2_DISCOVERY_persist_registry($) {
	my ($hash) = @_;
	my $json = JSON::PP->new->canonical(1)->encode(MQTT2_DISCOVERY_registry($hash));
	MQTT2_DISCOVERY_gateway($hash)->update_reading($hash, '.registry', $json, 0);
}

# Waehlt bei Namenskonflikten einen stabilen, reproduzierbaren Zieldevicenamen.
sub MQTT2_DISCOVERY_target_name($$$) {
	my ($mapping, $registry, $allow_existing) = @_;
	my $base = $mapping->{proposed_name};
	return $base if !$defs{$base} || $allow_existing;

	# Der Hash bleibt ueber Neustarts stabil; ein Zaehler ist nur der seltene
	# Fallback, wenn sogar dieser Name bereits belegt ist.
	my $suffix = stable_suffix($mapping->{identity});
	my $candidate = "${base}_$suffix";
	my $counter = 2;
	$candidate = "${base}_${suffix}_" . $counter++ while $defs{$candidate};
	return $candidate;
}

# Erzeugt fuer Transporte ohne Publisher-CID einen stabilen lokalen Routing-Schluessel.
sub MQTT2_DISCOVERY_virtual_cid($) {
	my ($mapping) = @_;
	return undef if !defined($mapping->{identity}) || $mapping->{identity} eq '';
	return 'mqtt2_discovery_' . stable_suffix($mapping->{identity}, 16);
}

# Leitet aus Bridge-Regeln oder fehlender Publisher-Identitaet die Ziel-CID ab.
sub MQTT2_DISCOVERY_autocreate_cid($$$) {
	my ($mapping, $cid, $io_type) = @_;
	my $transport_cid = defined($cid) ? $cid : '';
	my $bridge = $modules{MQTT2_DEVICE}{defptr}{bridge};

	my @topics = stable_unique(map { $_->{topic} }
		grep { ref($_) eq 'HASH' && defined($_->{topic}) && $_->{topic} ne '' }
			@{ $mapping->{reading_lines} || [] });
	my %resolved;

	# MQTT_GENERIC_BRIDGE kann aus Topic und Transport-CID eine logischere CID
	# ableiten. Der fremde Ausdruck stammt aus lokaler FHEM-Konfiguration, nicht
	# aus dem Discovery-Payload, und wird in einer Fehlergrenze ausgewertet.
	for my $topic (@topics) {

		for my $regexp (sort keys %{ ref($bridge) eq 'HASH' ? $bridge : {} }) {
			my $rule = $bridge->{$regexp};
			next if ref($rule) ne 'HASH' || !defined($rule->{name});
			my ($matched, $new_cid);
			my $ok = eval {

				# Nur eine zur Topic- oder CID/Topic-Form passende Bridge-Regel darf die
				# Transport-CID durch ihre logisch abgeleitete Client-ID ersetzen.
				if ("$topic:" =~ m/^$regexp$/s || "$transport_cid:$topic:" =~ m/^$regexp$/s) {
					$matched = 1;
					$new_cid = eval $rule->{name};
					die $@ if $@;
				}
				1;
			};
			return (undef, "bridgeRegexp fuer $topic konnte nicht ausgewertet werden: " . ($@ || 'unbekannter Fehler'))
				if !$ok;
			next if !$matched;
			return (undef, "bridgeRegexp fuer $topic liefert keine Client-ID")
				if !defined($new_cid) || ref($new_cid) || $new_cid eq '';
			$resolved{$new_cid} = 1;
		}

	}

	return (undef, 'Discovery-Topics ergeben mehrere bridgeRegexp-Client-IDs: ' . join(', ', sort keys %resolved))
		if keys(%resolved) > 1;
	my ($resolved_cid) = keys %resolved;
	return ($resolved_cid, undef) if defined($resolved_cid);

	# MQTT2_CLIENT kennt nur die Client-ID seiner eigenen Brokerverbindung und
	# nicht die des urspruenglichen Publishers. Eine fehlende Transport-CID hat
	# dieselbe Grenze und erhaelt deshalb ebenfalls eine logische Discovery-CID.
	if (($io_type || '') eq 'MQTT2_CLIENT' || $transport_cid eq '') {
		my $virtual_cid = MQTT2_DISCOVERY_virtual_cid($mapping);
		return (undef, 'Discovery-Geraeteidentitaet kann keine virtuelle Client-ID bilden')
			if !defined($virtual_cid);
		return ($virtual_cid, undef);
	}
	return ($transport_cid, undef);
}

# Findet unter Beruecksichtigung fremder Registry-Besitzer ein eindeutiges CID-Zieldevice.
sub MQTT2_DISCOVERY_existing_cid_target($$$$$) {
	my ($hash, $registry, $identity, $mapping, $cid) = @_;
	my $devices = MQTT2_DISCOVERY_gateway($hash)->mqtt2_devices_for_cid($cid);
	return (undef, undef) if ref($devices) ne 'ARRAY' || !@$devices;

	# Eine Transport-CID kann bei Bridges fuer mehrere logische Discovery-Geraete
	# stehen. Bereits einer anderen Discovery-Identitaet zugeordnete Targets sind
	# deshalb keine Kandidaten fuer die aktuelle Identitaet.
	my %owned_elsewhere = map {
		my $record = $registry->{devices}{$_};
		defined($record->{name}) ? ($record->{name} => 1) : ()
	} grep { $_ ne $identity && ref($registry->{devices}{$_}) eq 'HASH' }
		keys %{ $registry->{devices} || {} };
	my @available = grep { !$owned_elsewhere{ $_->{NAME} || '' } } @$devices;
	return (undef, undef) if !@available;
	return ($available[0], undef) if @available == 1;

	my @named = grep { ($_->{NAME} || '') eq $mapping->{proposed_name} } @available;
	return ($named[0], undef) if @named == 1;
	return (undef, "Mehrere MQTT2_DEVICE-Devices verwenden Client-ID $cid: "
		. join(', ', sort map { $_->{NAME} || '<ohne Name>' } @available));
}

# Ordnet ein Mapping einem bestehenden oder neu angelegten Registry-Zieldevice zu.
sub MQTT2_DISCOVERY_stage_mapping($$$$) {
	my ($hash, $registry, $mapping, $cid) = @_;
	my $identity = $mapping->{identity};
	my $record = $registry->{devices}{$identity};
	my $created_now = 0;
	my ($target_cid, $cid_error);

	# Die Registry haelt die dauerhafte Zielzuordnung. Nur eine erstmals
	# auftretende Discovery-Identitaet benoetigt eine neue CID-Aufloesung.
	if ($record) {
		$target_cid = $record->{cid};
	} else {
		my $io_type = $defs{ $hash->{IODevName} }{TYPE} || '';
		($target_cid, $cid_error) = MQTT2_DISCOVERY_autocreate_cid($mapping, $cid, $io_type);
	}
	return $cid_error if $cid_error;
	my ($cid_target, $target_error) = MQTT2_DISCOVERY_existing_cid_target(
		$hash, $registry, $identity, $mapping, $target_cid,
	);
	return $target_error if $target_error;

	# Ein Registry-Eintrag besitzt Vorrang vor neuer Namensfindung, weil er die
	# stabile Zuordnung zwischen Discovery-Identitaet und Zieldevice festhaelt.
	if ($record) {
		my $registered = $defs{ $record->{name} };

		# Wurde das Ziel ausserhalb der Discovery umbenannt, kann seine eindeutige
		# Client-ID die Registry-Zuordnung wiederherstellen, ohne ein Duplikat anzulegen.
		if (!$registered || ($registered->{TYPE} || '') ne 'MQTT2_DEVICE') {
			return "Verwaltetes Device $record->{name} existiert nicht und Client-ID $target_cid ist nicht eindeutig auffindbar"
				if !$cid_target;
			MQTT2_DISCOVERY_log($hash, 2,
				"recovered renamed target device $record->{name} as $cid_target->{NAME} by cid=$target_cid");
			$record->{name} = $cid_target->{NAME};
		}
		$record->{cid} = $target_cid;
	}

	# Nur bisher unbekannte Identitaeten durchlaufen Uebernahme, Namenskonflikt
	# und gegebenenfalls die automatische Anlage eines MQTT2_DEVICE.
	if (!$record) {
		my $mode = MQTT2_DISCOVERY_gateway($hash)->attr_value(
			$hash->{NAME}, 'existingDevice', 'conservative',
		);

		# ignore lehnt vorhandene Targets ab, replace darf ein gleichnamiges
		# MQTT2_DEVICE uebernehmen, conservative weicht auf einen stabilen Namen aus.
		if ($cid_target && $mode eq 'ignore') {
			return "Bestehendes Device $cid_target->{NAME} wird im ignore-Modus nicht veraendert";
		}
		my $base_exists = $defs{ $mapping->{proposed_name} } ? 1 : 0;

		# ignore schuetzt auch gleichnamige Devices ohne eindeutige CID-Zuordnung;
		# die Discovery darf sie weder uebernehmen noch unter diesem Namen veraendern.
		if (!$cid_target && $base_exists && $mode eq 'ignore') {
			return "Bestehendes Device $mapping->{proposed_name} wird im ignore-Modus nicht veraendert";
		}
		my $adopt_by_name = !$cid_target && $base_exists && $mode eq 'replace'
			&& ($defs{ $mapping->{proposed_name} }{TYPE} || '') eq 'MQTT2_DEVICE';
		my $name = $cid_target ? $cid_target->{NAME}
			: MQTT2_DISCOVERY_target_name($mapping, $registry, $adopt_by_name);

		# Erst wenn weder CID-Aufloesung noch Bestandsdevice ein Ziel liefern, ist
		# eine Neuanlage erforderlich und dabei die autoCreate-Vorgabe massgeblich.
		if (!$defs{$name}) {
			return "autoCreate ist deaktiviert; $name wurde nicht angelegt"
				if !MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'autoCreate', 1);
			my $error = MQTT2_DISCOVERY_gateway($hash)->define_mqtt2_device(
				$name, $target_cid, $hash->{IODevName},
			);
			return $error if $error;
			$created_now = 1;
		}
		return "$name ist kein MQTT2_DEVICE" if ($defs{$name}{TYPE} || '') ne 'MQTT2_DEVICE';
		$record = {
			name => $name, created => $created_now ? 1 : 0, io => $hash->{IODevName},
			cid => $target_cid,
			entities => {}, owned_reading => [], owned_set => [], owned_devicetopic => undef,
		};
		$registry->{devices}{$identity} = $record;
		MQTT2_DISCOVERY_log($hash, 2, ($created_now ? 'created and registered' : 'adopted') . " target device $name");
	}
	$record->{entities}{ $mapping->{entity_key} } = $mapping;
	MQTT2_DISCOVERY_log($hash, 4, "staged target=$record->{name}; entity=$mapping->{entity_key}");
	return undef;
}

# Entfernt nach Fehlern ausschliesslich Devices, die in der aktuellen Transaktion entstanden.
sub MQTT2_DISCOVERY_cleanup_created_devices($$$) {
	my ($hash, $registry, $created_identities) = @_;

	# Ausschliesslich in diesem Lauf neu angelegte Devices duerfen bei einem
	# Fehler wieder entfernt werden; uebernommene Devices sind tabu.
	for my $identity (sort keys %{ $created_identities || {} }) {
		my $record = $registry->{devices}{$identity};
		MQTT2_DISCOVERY_gateway($hash)->delete_device($record->{name})
			if $record && $defs{ $record->{name} };
		delete $registry->{devices}{$identity};
	}

	return;
}

# Loescht einen leeren, vollstaendig automatisch verwalteten Registry-Datensatz optional mit Device.
sub MQTT2_Discovery_autoDeleteRecord {
	my ($hash, $registry, $identity, $record, $hadManual) = @_;
	return undef if keys %{ $record->{entities} };
	return undef if !MQTT2_DISCOVERY_gateway($hash)->attr_value($hash->{NAME}, 'autoDelete', 0);
	return undef if !$record->{created} || $hadManual;
	return undef if MQTT2_DISCOVERY_record_has_manual_lines($hash, $record);

	# autoDelete gilt nur fuer vollstaendig von Discovery erzeugte Devices ohne
	# verbliebene manuelle Attribute oder Zeilen.
	my $error = MQTT2_DISCOVERY_gateway($hash)->delete_device($record->{name});
	return $error if $error;
	MQTT2_DISCOVERY_log($hash, 2, "deleted automatically managed MQTT2_DEVICE $record->{name}");
	delete $registry->{devices}{$identity};
	return undef;
}

# Wendet alle vorgemerkten Batch-Identitaeten an und veroeffentlicht den Registry-Stand.
sub MQTT2_DISCOVERY_finish_batch($$) {
	my ($hash, $batch) = @_;
	return undef if ref($batch) ne 'HASH';
	my $registry = ref($batch->{registry}) eq 'HASH'
		? $batch->{registry} : MQTT2_DISCOVERY_registry($hash);

	for my $identity (sort keys %{ $batch->{pending_identities} || {} }) {
		my $error = MQTT2_DISCOVERY_apply_batch_identity($hash, $batch, $identity);

		# Ein einziges fehlgeschlagenes Zieldevice macht den gemeinsamen Registry-
		# Entwurf unvollstaendig; neu erzeugte Devices werden vor dem Abbruch bereinigt.
		if ($error) {
			MQTT2_DISCOVERY_cleanup_created_devices($hash, $registry, $batch->{created_identities});
			$hash->{helper}{registry} = $registry;
			MQTT2_DISCOVERY_persist_registry($hash);
			MQTT2_DISCOVERY_update_counts($hash);
			return $error;
		}
	}

	$hash->{helper}{registry} = $registry;
	MQTT2_DISCOVERY_persist_registry($hash);
	MQTT2_DISCOVERY_update_counts($hash);
	return undef;
}

# Rendert ein einzelnes Batch-Ziel und fuehrt danach die geschuetzte autoDelete-Entscheidung aus.
sub MQTT2_DISCOVERY_apply_batch_identity($$$) {
	my ($hash, $batch, $identity) = @_;
	my $registry = $batch->{registry};
	return undef if ref($registry) ne 'HASH';
	my $record = $registry->{devices}{$identity};
	return undef if !$record;
	my $error = MQTT2_DISCOVERY_apply_device_lines($hash, $record);
	return $error if $error;

	my $hadManual = delete $batch->{delete_had_manual}{$identity};
	return MQTT2_Discovery_autoDeleteRecord($hash, $registry, $identity, $record, $hadManual);
}

# Rendert und setzt alle verwalteten Attribute eines Zieldevices als atomaren Plan.
sub MQTT2_DISCOVERY_apply_device_lines($$) {
	my ($hash, $record) = @_;
	my $name = $record->{name};
	return "Verwaltetes Device $name existiert nicht" if !$defs{$name};

	# Namen werden ueber alle Entities des Devices gemeinsam aufgeloest, bevor
	# eine einzige readingList- oder setList-Zeile gerendert wird.
	my $resolved_mappings = MQTT2_Discovery::Mapper::resolve_mapping_names([
		map { $record->{entities}{$_} } sort keys %{ $record->{entities} }
	]);
	my %resolved_by_key = map { (($_->{entity_key} // '') => $_) } @$resolved_mappings;
	my (@reading_entries, @set_entries);

	for my $mapping (@$resolved_mappings) {
		push @reading_entries, @{ $mapping->{reading_lines} || [] };
		push @set_entries, @{ $mapping->{set_lines} || [] };
	}

	my @all_entries = (@reading_entries, @set_entries);
	my $generated_device_topic = MQTT2_Discovery::DevicePlanner::device_topic($record, \@all_entries);
	my $old_device_topic_exists = exists($attr{$name}) && exists($attr{$name}{devicetopic});
	my $old_device_topic = $old_device_topic_exists ? $attr{$name}{devicetopic} : undef;
	my $previous_owned_device_topic = $record->{owned_devicetopic};
	my $render_device_topic;
	my $manage_device_topic = 0;

	# Ein manuell geaendertes devicetopic bleibt erhalten, sofern alle erzeugten
	# Topics weiterhin darunter liegen. Nur eigene Werte werden automatisch ersetzt.
	if ($record->{created}) {

		# Fehlende oder weiterhin von Discovery besessene Werte duerfen dem neu
		# berechneten gemeinsamen Topic-Prefix folgen; manuelle Werte bleiben erhalten.
		if (!$old_device_topic_exists
				|| (defined($previous_owned_device_topic) && $old_device_topic eq $previous_owned_device_topic)) {
			$render_device_topic = $generated_device_topic;
			$manage_device_topic = 1;
		} elsif (defined($old_device_topic)
				&& !grep { !MQTT2_Discovery::DevicePlanner::topic_has_prefix($_->{topic}, $old_device_topic) }
					grep { ref($_) eq 'HASH' && defined($_->{topic}) } @all_entries) {
			$render_device_topic = $old_device_topic;
		}
	} elsif ($old_device_topic_exists
			&& !grep { !MQTT2_Discovery::DevicePlanner::topic_has_prefix($_->{topic}, $old_device_topic) }
				grep { ref($_) eq 'HASH' && defined($_->{topic}) } @all_entries) {
		$render_device_topic = $old_device_topic;
	}
	my $mode = MQTT2_DISCOVERY_gateway($hash)->attr_value(
		$hash->{NAME}, 'existingDevice', 'conservative',
	);
	my $old_reading = MQTT2_DISCOVERY_gateway($hash)->attr_value($name, 'readingList', '');
	my $old_set = MQTT2_DISCOVERY_gateway($hash)->attr_value($name, 'setList', '');
	my @json_conflicts;

	# Konflikte werden vor dem Gruppieren der JSON-Readings bestimmt; danach
	# verschmelzen manuelle und generierte Zeilen nach dem gewaehlten Modus.
	my ($prepared_readings, $prepared_old_reading) = MQTT2_Discovery::DevicePlanner::prepare_json_readings(
		$mode, $old_reading, $record->{owned_reading}, \@reading_entries, \@json_conflicts,
	);
	@reading_entries = @{ MQTT2_Discovery::Mapper::render_entries($prepared_readings, $render_device_topic) };
	@set_entries = @{ MQTT2_Discovery::Mapper::render_entries(\@set_entries, $render_device_topic) };
	my $reading = merge_generated_lines(
		kind => 'reading', mode => $mode, current => $prepared_old_reading,
		previous_owned => $record->{owned_reading}, generated => \@reading_entries,
	);
	my $set = merge_generated_lines(
		kind => 'set', mode => $mode, current => $old_set,
		previous_owned => $record->{owned_set}, generated => \@set_entries,
	);
	my $plan = MQTT2_Discovery::DevicePlanner::attribute_plan(
		device => $name,
		manage_device_topic => $manage_device_topic,
		device_topic => $generated_device_topic,
		previous_device_topic_exists => $old_device_topic_exists,
		previous_device_topic => $old_device_topic,
		reading_list => $reading->{value},
		previous_reading_list_exists => (exists($attr{$name}) && exists($attr{$name}{readingList})),
		previous_reading_list => $old_reading,
		set_list => $set->{value},
		previous_set_list_exists => (exists($attr{$name}) && exists($attr{$name}{setList})),
		previous_set_list => $old_set,
	);

	# Alle Attribute werden mit Rollback als eine logische Einheit angewendet.
	my $error = $plan->execute(MQTT2_DISCOVERY_gateway($hash));
	return $error if $error;
	$record->{owned_reading} = $reading->{owned};
	$record->{owned_set} = $set->{owned};
	$record->{owned_devicetopic} = $manage_device_topic ? $generated_device_topic : undef;
	MQTT2_DISCOVERY_apply_device_semantics($hash, $record, \%resolved_by_key);
	my @conflicts = (@json_conflicts, @{ $reading->{conflicts} }, @{ $set->{conflicts} });

	# Manuell gewonnene Konflikte sind kein Apply-Fehler, muessen aber sichtbar
	# machen, welche generierten readingList- oder setList-Anteile nicht uebernommen wurden.
	if (@conflicts) {
		my $conflicts = join(',', stable_unique(@conflicts));
		MQTT2_DISCOVERY_reading($hash, 'conflicts', $conflicts);
		MQTT2_DISCOVERY_log($hash, 2, "manual configuration wins for target=$name; conflicts=$conflicts");
	}
	MQTT2_DISCOVERY_log($hash, 4, "attributes updated for target=$name; readingLines="
		. scalar(@{ $reading->{owned} }) . '; setLines=' . scalar(@{ $set->{owned} }));
	return undef;
}

# Komponiert und hinterlegt semantische Metadaten fuer automatisch erzeugte Devices.
sub MQTT2_DISCOVERY_apply_device_semantics($$;$) {
	my ($hash, $record, $resolved) = @_;

	# Uebernommene Bestandsdevices erhalten keine automatisch erzeugten
	# semantischen Metadaten; ihre bestehende Beschreibung bleibt unangetastet.
	return if !$record->{created};
	my $name = $record->{name};
	return if !$defs{$name};
	my @items;
	my %id_count;

	for my $entity_key (sort keys %{ $record->{entities} || {} }) {
		my $mapping = ref($resolved) eq 'HASH' && $resolved->{$entity_key}
			? $resolved->{$entity_key} : $record->{entities}{$entity_key};
		my $source = $mapping->{semantic_entity};
		next if ref($source) ne 'HASH';
		my $entry = JSON::PP->new->decode(JSON::PP->new->canonical(1)->encode($source));
		push @items, {
			entity_key => $entity_key,
			entry => $entry,
			mapping => $mapping,
		};
	}

	my $composed = MQTT2_Discovery::Mapper::Semantics::compose_device_entities(\@items);
	my @entries = map { [$_->{entity_key}, $_->{entry}] } @$composed;
	++$id_count{ $_->[1]{id} // 'entity' } for @entries;

	# Erst nach Device-Komposition werden verbleibende Entity-ID-Kollisionen
	# stabil aufgeloest.
	for my $item (@entries) {
		my ($entity_key, $entry) = @$item;
		my $id = $entry->{id} // 'entity';
		$entry->{id} = $id . '_' . stable_suffix($entity_key, 6) if $id_count{$id} > 1;
	}

	# Vorhandene semantische Entities werden als gemeinsamer Device-Vertrag gesetzt;
	# ohne Entities muss ein frueherer Vertrag explizit entfernt werden.
	if (@entries) {
		MQTT2_DISCOVERY_gateway($hash)->set_semantic_metadata($name, {
			confidence => 0.95,
			entities => [ map { $_->[1] } @entries ],
		});
	} else {
		MQTT2_DISCOVERY_gateway($hash)->set_semantic_metadata($name, undef);
	}
	my $integration_ended = eval {
		MQTT2_DISCOVERY_gateway($hash)->semantic_integration_end($name);
	} || 0;
	MQTT2_DISCOVERY_log($hash, 2, "semantic integration end failed for target=$name") if $@;
	MQTT2_DISCOVERY_publish_semantic_update($hash, $name) if !$integration_ended;
	MQTT2_DISCOVERY_log($hash, 4, "semantic metadata updated for target=$name; entities=" . scalar(@entries));
	return;
}

# Erzeugt aus der aktuellen Beschreibung ein semantisches Upsert- oder Remove-Ereignis.
sub MQTT2_DISCOVERY_publish_semantic_update($$) {
	my ($hash, $name) = @_;
	my $gateway = MQTT2_DISCOVERY_gateway($hash);
	return if !$gateway->can_publish_semantics();
	my $definition = eval { $gateway->semantic_description($name) };

	# Ohne gueltige Beschreibung kann kein wohldefiniertes Upsert- oder Remove-
	# Ereignis erzeugt werden; ein Broadcast wuerde nur unvollstaendige Daten verteilen.
	if ($@ || ref($definition) ne 'HASH') {
		MQTT2_DISCOVERY_log($hash, 2, "semantic update failed for target=$name");
		return;
	}
	my $event = $definition->{visible}
		? { type => 'device_upsert', device => $definition }
		: { type => 'device_remove', device => $name };
	eval { $gateway->semantic_broadcast($event) };
	MQTT2_DISCOVERY_log($hash, 2, "semantic broadcast failed for target=$name") if $@;
	return;
}

# Entfernt passende Entities aus der Registry und rendert betroffene Devices neu.
sub MQTT2_DISCOVERY_delete_entity($$$;$) {
	my ($hash, $registry, $entity, $batch) = @_;

	for my $identity (sort keys %{ $registry->{devices} }) {
		my $record = $registry->{devices}{$identity};
		my @delete = grep {
			my $mapping = $record->{entities}{$_};
			$mapping->{discovery_topic} eq $entity->{discovery_topic}
				&& ($entity->{operation} eq 'delete_device' || $_ eq $entity->{entity_key});
		} keys %{ $record->{entities} };
		next if !@delete;

		# Der manuelle Zustand wird vor dem Entfernen/Neurendern erfasst, damit
		# autoDelete ein ehemals angepasstes Device nicht versehentlich loescht.
		my $hadManual = MQTT2_DISCOVERY_record_has_manual_lines($hash, $record);
		delete $record->{entities}{$_} for @delete;
		MQTT2_DISCOVERY_log($hash, 2, 'removed ' . scalar(@delete) . " discovery entity/entities from $record->{name}");

		# Innerhalb eines Batchs wird das betroffene Device erst nach allen Deletes
		# neu gerendert; der vorherige manuelle Zustand bleibt fuer autoDelete erhalten.
		if ($batch) {
			$batch->{pending_identities}{$identity} = 1;
			$batch->{delete_had_manual}{$identity} = $hadManual
				if !exists $batch->{delete_had_manual}{$identity};
			next;
		}
		my $error = MQTT2_DISCOVERY_apply_device_lines($hash, $record);
		return $error if $error;
		$error = MQTT2_Discovery_autoDeleteRecord($hash, $registry, $identity, $record, $hadManual);
		return $error if $error;
	}

	return undef;
}

# Erkennt konservativ, ob ein verwaltetes Device noch benutzereigene Konfiguration enthaelt.
sub MQTT2_DISCOVERY_record_has_manual_lines($$) {
	my ($hash, $record) = @_;
	my $name = $record->{name};
	return 1 if !$defs{$name};

	# Ein abweichendes oder nicht als eigenerzeugt vermerktes devicetopic ist eine
	# manuelle Anpassung und sperrt das automatische Entfernen des ganzen Devices.
	if (exists($attr{$name}) && exists($attr{$name}{devicetopic})) {
		return 1 if !defined($record->{owned_devicetopic})
			|| $attr{$name}{devicetopic} ne $record->{owned_devicetopic};
	}

	for my $attribute (['readingList', 'owned_reading'], ['setList', 'owned_set']) {

		# Alles, was nicht exakt in der Registry als eigenerzeugt vermerkt ist,
		# gilt konservativ als manuelle Benutzerkonfiguration.
		my %owned = map { $_ => 1 } @{ $record->{ $attribute->[1] } || [] };
		my @current = grep { $_ ne '' } split /\r?\n/,
			MQTT2_DISCOVERY_gateway($hash)->attr_value($name, $attribute->[0], '');
		return 1 if grep { !$owned{$_} } @current;
	}

	return 0;
}

# Berechnet und schreibt die Anzahl aktiver Registry-Devices und Entities.
sub MQTT2_DISCOVERY_update_counts($) {
	my ($hash) = @_;
	my $registry = MQTT2_DISCOVERY_registry($hash);
	my ($devices, $entities) = (0, 0);

	for my $record (values %{ $registry->{devices} }) {
		my $count = scalar keys %{ $record->{entities} || {} };
		++$devices if $count;
		$entities += $count;
	}

	MQTT2_DISCOVERY_reading($hash, 'discoveredDevices', $devices);
	MQTT2_DISCOVERY_reading($hash, 'discoveredEntities', $entities);
	MQTT2_DISCOVERY_log($hash, 4, "counts updated; devices=$devices; entities=$entities");
}

# Schreibt ein Modulreading ueber das Gateway mit normalisiertem undef-Wert.
sub MQTT2_DISCOVERY_reading($$$) {
	my ($hash, $name, $value) = @_;
	MQTT2_DISCOVERY_gateway($hash)->update_reading(
		$hash, $name, defined($value) ? $value : '', 1,
	);
}

# Entfernt den Set-Kommandonamen und liefert nur den vom Benutzer uebergebenen Wert.
sub MQTT2_Discovery_commandValue {
	my ($event) = @_;
	$event = '' if !defined $event;
	$event =~ s/^\S+\s*//;
	return $event;
}

# Baut den sicheren Home-Assistant-Kontext fuer MQTT-Device-Trigger auf.
sub MQTT2_DISCOVERY_triggerVars($) {
	my ($event) = @_;
	$event = '' if !defined $event;
	my ($decoded, $has_json);
	$has_json = eval { $decoded = JSON::PP::decode_json($event); 1 } ? 1 : 0;
	my %trigger = (
		payload => $event,
		value   => $has_json ? $decoded : $event,
	);

	# JSON-Trigger erhalten dieselben strukturierten Aliase, die HA-Templates
	# fuer value_json und payload_json bereitstellen.
	if ($has_json) {
		$trigger{value_json} = $decoded;
		$trigger{payload_json} = $decoded;
	}

	return { trigger => \%trigger };
}

# Die Wrapper rufen nur die sichere Template-Engine auf; Discovery-Text wird nie als Perl-Code evaluiert.
sub MQTT2_Discovery_runtime {
	my ($operation, @arguments) = @_;
	my $answer;

	# Jede Runtime-Operation liefert lediglich den von MQTT2_DEVICE erwarteten
	# Reading-Hash oder "topic payload"-String. Fehler bleiben lokal und ergeben undef.
	my $ok = eval {

		# Die Operation bestimmt den erlaubten, fest implementierten Rendering-Pfad;
		# unbekannte Namen erreichen weder Template-Auswertung noch MQTT-Payloadbau.
		if ($operation eq 'reading') {
			my ($template, $event, $reading) = @arguments;
			my $compiled = MQTT2_Discovery::Template::compile($template);
			my $result = MQTT2_Discovery::Template::render($compiled, value => $event);
			$answer = { $reading => $result->{value} }
				if ref($result) eq 'HASH' && $result->{ok};
		} elsif ($operation eq 'triggerReading') {
			my ($template, $event, $reading) = @arguments;
			my $compiled = MQTT2_Discovery::Template::compile($template);
			my $result = MQTT2_Discovery::Template::render(
				$compiled, value => $event, vars => MQTT2_DISCOVERY_triggerVars($event),
			);
			$answer = { $reading => $result->{value} }
				if ref($result) eq 'HASH' && $result->{ok};
		} elsif ($operation eq 'templatePublish') {
			my ($topic, $template, $event) = @arguments;
			my $value = MQTT2_Discovery_commandValue($event);
			my $result = MQTT2_Discovery::Template::render($template, value => $value);
			$answer = $topic . ' ' . $result->{value}
				if ref($result) eq 'HASH' && $result->{ok};
		} elsif ($operation eq 'choice') {
			my ($topic, $mapping, $event) = @arguments;
			my $choice = MQTT2_Discovery_commandValue($event);
			$answer = $topic . ' ' . $mapping->{$choice}
				if ref($mapping) eq 'HASH' && exists $mapping->{$choice};
		} elsif ($operation eq 'templateChoice') {
			my ($topic, $template, $mapping, $event) = @arguments;
			my $choice = MQTT2_Discovery_commandValue($event);

			# Nur konfigurierte Auswahlwerte werden in das Template eingesetzt; freie
			# Benutzereingaben duerfen die vorgegebene Choice-Abbildung nicht umgehen.
			if (ref($mapping) eq 'HASH' && exists $mapping->{$choice}) {
				my $result = MQTT2_Discovery::Template::render($template, value => $mapping->{$choice});
				$answer = $topic . ' ' . $result->{value}
					if ref($result) eq 'HASH' && $result->{ok};
			}
		} elsif ($operation eq 'publish') {
			my ($topic, $payload) = @arguments;
			$answer = $topic . ' ' . $payload;
		} elsif ($operation eq 'jsonPublish') {
			my ($topic, $key, $event) = @arguments;
			my $value = MQTT2_Discovery_commandValue($event);

			# JSON-Zahlen werden als numerische Werte codiert; andere Eingaben duerfen
			# nicht stillschweigend als String einen numerischen Aktor ansteuern.
			if ($value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/) {
				my $payload = JSON::PP->new->canonical(1)->encode({ $key => 0 + $value });
				$answer = $topic . ' ' . $payload;
			}
		} else {
			die "Unbekannte Runtime-Operation: $operation";
		}
		1;
	};
	return $ok ? $answer : undef;
}

# Rendert ein Runtime-Reading und liefert bei Fehlern einen leeren Reading-Hash.
sub MQTT2_DISCOVERY_runtimeReading($$$) {
	my $answer = MQTT2_Discovery_runtime('reading', @_);
	return ref($answer) eq 'HASH' ? $answer : {};
}

# Rendert ein Device-Automation-Reading mit dem sicheren HA-Triggerkontext.
sub MQTT2_DISCOVERY_runtimeTriggerReading($$$) {
	my $answer = MQTT2_Discovery_runtime('triggerReading', @_);
	return ref($answer) eq 'HASH' ? $answer : {};
}

# Rendert einen freien Set-Wert mit sicherem Template zu einem MQTT-Publish-String.
sub MQTT2_DISCOVERY_runtimeTemplatePublish($$$) {
	return MQTT2_Discovery_runtime('templatePublish', @_);
}

# Uebersetzt einen erlaubten Auswahlwert direkt in Topic und Payload.
sub MQTT2_DISCOVERY_runtimeChoice($$$) {
	return MQTT2_Discovery_runtime('choice', @_);
}

# Uebersetzt einen erlaubten Auswahlwert und rendert ihn anschliessend per Template.
sub MQTT2_DISCOVERY_runtimeTemplateChoice($$$$) {
	return MQTT2_Discovery_runtime('templateChoice', @_);
}

# Baut fuer konstante Kommandos den von MQTT2_DEVICE erwarteten Publish-String.
sub MQTT2_DISCOVERY_runtimePublish($$) {
	return MQTT2_Discovery_runtime('publish', @_);
}

# Codiert einen numerischen Set-Wert als kanonisches JSON fuer das Zieltopic.
sub MQTT2_DISCOVERY_runtimeJSONPublish($$$) {
	return MQTT2_Discovery_runtime('jsonPublish', @_);
}

1;

=pod

=head1 NAME

MQTT2_DISCOVERY - native Home-Assistant-MQTT-Discovery fuer FHEM

=head1 SYNOPSIS

	define mqttDiscovery MQTT2_DISCOVERY mqttServer
	set mqttDiscovery activate

=head1 SECURITY

Das Modul fuehrt kein C<save> aus und wertet Discovery-Payloads nicht als Perl-Code aus.

=item device
=item summary Native Home Assistant MQTT and Tasmota discovery for MQTT2_DEVICE
=item summary_DE Native Home-Assistant-MQTT- und Tasmota-Discovery fuer MQTT2_DEVICE

=begin html

<a id="MQTT2_DISCOVERY"></a>
<h3>MQTT2_DISCOVERY</h3>
<p>Processes Home Assistant MQTT Discovery and native Tasmota Discovery messages
and creates conservatively managed <code>MQTT2_DEVICE</code> devices.</p>

<a id="MQTT2_DISCOVERY-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; MQTT2_DISCOVERY &lt;MQTT2_SERVER|MQTT2_CLIENT&gt;</code></p>

<a id="MQTT2_DISCOVERY-set"></a>
<h4>Set</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-set-activate"></a><b>activate</b><br>
Adds <code>MQTT2_DISCOVERY</code> to the IO device's current <code>clientOrder</code>
before the regular MQTT2 consumers without removing other clients.<br>
Syntax: <code>set &lt;name&gt; activate</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-deactivate"></a><b>deactivate</b><br>
Removes only <code>MQTT2_DISCOVERY</code> from the IO device's current
<code>clientOrder</code> and discards pending discovery work.<br>
Syntax: <code>set &lt;name&gt; deactivate</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-rescan"></a><b>rescan</b><br>
Processes matching retained discovery messages from an <code>MQTT2_SERVER</code>
again. An <code>MQTT2_CLIENT</code> has no local retained-message cache.<br>
Syntax: <code>set &lt;name&gt; rescan</code>
</li>
</ul>

<a id="MQTT2_DISCOVERY-attr"></a>
<h4>Attributes</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-attr-discoveryPrefixes"></a><b>discoveryPrefixes</b><br>
Comma-separated discovery topic prefixes. Default: <code>homeassistant,tasmota/discovery</code>.<br>
Example: <code>attr &lt;name&gt; discoveryPrefixes homeassistant,tasmota/discovery</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-deviceNamePrefix"></a><b>deviceNamePrefix</b><br>
Optional prefix for newly created device names. By default no prefix is added.<br>
Example: <code>attr &lt;name&gt; deviceNamePrefix HA_</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-existingDevice"></a><b>existingDevice</b><br>
Controls handling of existing devices: <code>conservative</code> keeps manual
configuration, <code>ignore</code> skips the device and <code>replace</code> replaces
conflicting generated lines while preserving unrelated manual lines. Existing
<code>MQTT2_DEVICE</code> devices are resolved through FHEM's CID registry, independent
of their current name. Configured <code>bridgeRegexp</code> rules are applied to the
announced state topics before this lookup. Since an <code>MQTT2_CLIENT</code> cannot
observe the original publisher CID, a stable virtual CID derived from the discovery
device identity is used when no bridge rule matches. <code>MQTT2_SERVER</code> keeps
the publisher CID.<br>
Syntax: <code>attr &lt;name&gt; existingDevice &lt;conservative|ignore|replace&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-autoCreate"></a><b>autoCreate</b><br>
Allows (<code>1</code>, default) or prevents (<code>0</code>) creation of new
<code>MQTT2_DEVICE</code> devices.<br>
Syntax: <code>attr &lt;name&gt; autoCreate &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-autoDelete"></a><b>autoDelete</b><br>
If set to <code>1</code>, devices created and still fully managed by this module
may be deleted after their last discovery entity is removed. Default: <code>0</code>.<br>
Syntax: <code>attr &lt;name&gt; autoDelete &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-disable"></a><b>disable</b><br>
Disables (<code>1</code>) or enables (<code>0</code>) discovery processing. Disabling
also discards pending discovery work.<br>
Syntax: <code>attr &lt;name&gt; disable &lt;0|1&gt;</code>
</li><br>
<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
</ul>

=end html

=begin html_DE

<a id="MQTT2_DISCOVERY"></a>
<h3>MQTT2_DISCOVERY</h3>
<p>Verarbeitet Home-Assistant-MQTT-Discovery und das native Tasmota-Discovery-Protokoll
und erzeugt daraus konservativ verwaltete <code>MQTT2_DEVICE</code>-Devices.</p>

<a id="MQTT2_DISCOVERY-define"></a>
<h4>Define</h4>
<p><code>define &lt;name&gt; MQTT2_DISCOVERY &lt;MQTT2_SERVER|MQTT2_CLIENT&gt;</code></p>

<a id="MQTT2_DISCOVERY-set"></a>
<h4>Set</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-set-activate"></a><b>activate</b><br>
Fuegt <code>MQTT2_DISCOVERY</code> vor den normalen MQTT2-Consumern in die aktuelle
<code>clientOrder</code> des IODev ein, ohne fremde Clients zu entfernen.<br>
Syntax: <code>set &lt;name&gt; activate</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-deactivate"></a><b>deactivate</b><br>
Entfernt nur <code>MQTT2_DISCOVERY</code> aus der aktuellen <code>clientOrder</code>
des IODev und verwirft noch nicht verarbeitete Discovery-Arbeit.<br>
Syntax: <code>set &lt;name&gt; deactivate</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-set-rescan"></a><b>rescan</b><br>
Verarbeitet passende retained Discovery-Nachrichten aus dem lokalen Cache eines
<code>MQTT2_SERVER</code> erneut. Ein <code>MQTT2_CLIENT</code> besitzt keinen solchen Cache.<br>
Syntax: <code>set &lt;name&gt; rescan</code>
</li>
</ul>

<a id="MQTT2_DISCOVERY-attr"></a>
<h4>Attribute</h4>
<ul>
<li><a id="MQTT2_DISCOVERY-attr-discoveryPrefixes"></a><b>discoveryPrefixes</b><br>
Kommaseparierte Discovery-Topic-Prefixe. Default: <code>homeassistant,tasmota/discovery</code>.<br>
Beispiel: <code>attr &lt;name&gt; discoveryPrefixes homeassistant,tasmota/discovery</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-deviceNamePrefix"></a><b>deviceNamePrefix</b><br>
Optionaler Prefix fuer neu angelegte Device-Namen. Standardmaessig wird kein Prefix vorangestellt.<br>
Beispiel: <code>attr &lt;name&gt; deviceNamePrefix HA_</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-existingDevice"></a><b>existingDevice</b><br>
Behandlung vorhandener Devices: <code>conservative</code> bewahrt manuelle
Konfiguration, <code>ignore</code> ueberspringt das Device und <code>replace</code>
ersetzt kollidierende erzeugte Zeilen, behaelt aber unabhaengige manuelle Zeilen.
Vorhandene <code>MQTT2_DEVICE</code>-Devices werden unabhaengig von ihrem aktuellen
Namen ueber FHEMs CID-Register aufgeloest. Konfigurierte <code>bridgeRegexp</code>-
Regeln werden davor auf die angekuendigten State-Topics angewandt. Da ein
<code>MQTT2_CLIENT</code> die urspruengliche Publisher-CID nicht kennt, wird ohne
passende Bridge-Regel eine stabile virtuelle CID aus der Discovery-Geraeteidentitaet
gebildet. Beim <code>MQTT2_SERVER</code> bleibt die Publisher-CID erhalten.<br>
Syntax: <code>attr &lt;name&gt; existingDevice &lt;conservative|ignore|replace&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-autoCreate"></a><b>autoCreate</b><br>
Erlaubt (<code>1</code>, Default) oder verhindert (<code>0</code>) das Anlegen neuer
<code>MQTT2_DEVICE</code>-Devices.<br>
Syntax: <code>attr &lt;name&gt; autoCreate &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-autoDelete"></a><b>autoDelete</b><br>
Bei <code>1</code> duerfen vom Modul angelegte und weiterhin vollstaendig verwaltete
Devices nach dem Entfernen ihrer letzten Discovery-Entity geloescht werden. Default: <code>0</code>.<br>
Syntax: <code>attr &lt;name&gt; autoDelete &lt;0|1&gt;</code>
</li><br>
<li><a id="MQTT2_DISCOVERY-attr-disable"></a><b>disable</b><br>
Deaktiviert (<code>1</code>) oder aktiviert (<code>0</code>) die Discovery-Verarbeitung.
Beim Deaktivieren wird auch noch nicht verarbeitete Discovery-Arbeit verworfen.<br>
Syntax: <code>attr &lt;name&gt; disable &lt;0|1&gt;</code>
</li><br>
<li><a href="#readingFnAttributes">readingFnAttributes</a></li>
</ul>

=end html_DE

=cut

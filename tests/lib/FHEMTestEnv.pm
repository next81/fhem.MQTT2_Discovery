# Copyright (c) 2026 Andreas Planer
# Repository: https://github.com/next81/fhem.MQTT2_Discovery
# FHEM profile: https://forum.fhem.de/index.php?action=profile;u=45773
# Licensed under the GNU General Public License v2.0 only
# https://www.gnu.org/licenses/old-licenses/gpl-2.0.html

package FHEMTestEnv;

use strict;
use warnings;
use Exporter qw(import);
use JSON::PP qw(encode_json);

our @EXPORT_OK = qw(reset_env add_iodev define_discovery dispatch_message attr_value reading_value command_log log_entries);
our @COMMAND_LOG;
our @LOG_ENTRIES;

# Setzt alle simulierten FHEM-Globals, Protokolle und Modulregistrierungen zurueck.
sub reset_env {
	%main::defs = ();
	%main::attr = (global => { modpath => '.' });
	%main::modules = (
		MQTT2_DISCOVERY => {},
		MQTT2_DEVICE => { Match => '.*', defptr => { re => {}, cid => {}, bridge => {} } },
		MQTT_GENERIC_BRIDGE => { Match => '.*' },
	);
	@COMMAND_LOG = ();
	@LOG_ENTRIES = ();
	$main::readingFnAttributes = '';
	$main::init_done = 1;
	main::MQTT2_DISCOVERY_Initialize($main::modules{MQTT2_DISCOVERY});
}

# Legt ein minimales MQTT2-IODev fuer Modul- und Integrationstests an.
sub add_iodev {
	my ($name, $type) = @_;
	$type ||= 'MQTT2_SERVER';
	my $hash = {
		NAME => $name, TYPE => $type, ClientsKeepOrder => 1,
		Clients => ':MQTT2_DEVICE:MQTT_GENERIC_BRIDGE:', retain => {},
	};
	$main::defs{$name} = $hash;
	return $hash;
}

# Definiert eine Discovery-Instanz in der simulierten FHEM-Laufzeit.
sub define_discovery {
	my ($name, $io_name) = @_;
	my $hash = { NAME => $name, TYPE => 'MQTT2_DISCOVERY', READINGS => {} };
	$main::defs{$name} = $hash;
	my $error = main::MQTT2_DISCOVERY_Define($hash, "$name MQTT2_DISCOVERY $io_name");
	return ($hash, $error);
}

# Simuliert FHEMs geordneten MQTT-Parserdispatch fuer eine einzelne Nachricht.
sub dispatch_message {
	my ($io_name, $cid, $topic, $payload) = @_;
	my $io = $main::defs{$io_name};
	my @order = grep { $_ ne '' } split /:/, $io->{Clients};
	my @seen;
	for my $module (@order) {
		next if !$main::modules{$module};
		my $message = "autocreate=simple\0$cid\0$topic\0$payload";
		next if $message !~ /$main::modules{$module}{Match}/s;
		push @seen, $module;
		if ($module eq 'MQTT2_DISCOVERY') {
			my @result = main::MQTT2_DISCOVERY_Parse($io, $message);
			next if @result && $result[0] eq '[NEXT]';
			last if @result && defined $result[0];
		}
	}
	return \@seen;
}

# Liefert einen Attributwert direkt aus der simulierten FHEM-Datenstruktur.
sub attr_value { return $main::attr{$_[0]}{$_[1]}; }
# Liefert einen Readingwert direkt aus der simulierten FHEM-Datenstruktur.
sub reading_value { return $main::defs{$_[0]}{READINGS}{$_[1]}{VAL}; }
# Stellt das vollstaendige Protokoll simulierter FHEM-Kommandos bereit.
sub command_log { return \@COMMAND_LOG; }
# Stellt alle waehrend eines Tests erfassten Logmeldungen bereit.
sub log_entries { return \@LOG_ENTRIES; }

package main;

our (%defs, %attr, %modules, $readingFnAttributes, $init_done);

# Bildet FHEMs AttrVal inklusive Standardwertverhalten fuer Tests nach.
sub AttrVal($$$) {
	my ($device, $attribute, $default) = @_;
	return exists($attr{$device}) && exists($attr{$device}{$attribute}) ? $attr{$device}{$attribute} : $default;
}

# Bildet FHEMs ReadingsVal inklusive Standardwertverhalten fuer Tests nach.
sub ReadingsVal($$$) {
	my ($device, $reading, $default) = @_;
	return exists($defs{$device}{READINGS}{$reading}) ? $defs{$device}{READINGS}{$reading}{VAL} : $default;
}

# Aktualisiert ein simuliertes Reading mit einem festen reproduzierbaren Zeitstempel.
sub readingsSingleUpdate($$$$) {
	my ($hash, $reading, $value, undef) = @_;
	$hash->{READINGS}{$reading} = { VAL => $value, TIME => '2026-08-18 12:00:00' };
	return undef;
}

# Simuliert die Anlage eines MQTT2_DEVICE und pflegt zugleich dessen CID-Index.
sub CommandDefine($$) {
	my (undef, $definition) = @_;
	push @FHEMTestEnv::COMMAND_LOG, "define $definition";
	my ($name, $type, $cid, $io_name) = split /\s+/, $definition, 4;
	return "$name already defined" if $defs{$name};
	return 'only MQTT2_DEVICE is supported in test env' if $type ne 'MQTT2_DEVICE';
	$defs{$name} = {
		NAME => $name, TYPE => $type, CID => $cid, DEF => $cid, IODev => $defs{$io_name}, READINGS => {},
	};
	push @{ $modules{MQTT2_DEVICE}{defptr}{cid}{$cid} ||= [] }, $defs{$name}
		if defined($cid) && $cid ne '';
	return undef;
}

# Simuliert attr und synchronisiert bei clientOrder auch die Parserreihenfolge.
sub CommandAttr($$) {
	my (undef, $definition) = @_;
	my ($device, $attribute, $value) = split /\s+/, $definition, 3;
	return "Unknown device $device" if !$defs{$device};
	$value = '' if !defined $value;
	push @FHEMTestEnv::COMMAND_LOG, "attr $device $attribute $value";
	$attr{$device}{$attribute} = $value;
	if ($attribute eq 'clientOrder') {
		my @order = split /\s+/, $value;
		$defs{$device}{Clients} = ':' . join(':', @order) . ':';
		$defs{$device}{MatchList} = { map { ($_ + 1) . ':' . $order[$_] => '^.' } 0 .. $#order };
	}
	return undef;
}

# Simuliert deleteattr und protokolliert die ausgefuehrte Aenderung.
sub CommandDeleteAttr($$) {
	my (undef, $definition) = @_;
	my ($device, $attribute) = split /\s+/, $definition, 2;
	push @FHEMTestEnv::COMMAND_LOG, "deleteattr $device $attribute";
	delete $attr{$device}{$attribute};
	return undef;
}

# Simuliert das Device-Loeschen samt Bereinigung des MQTT2_DEVICE-CID-Indexes.
sub CommandDelete($$) {
	my (undef, $device) = @_;
	push @FHEMTestEnv::COMMAND_LOG, "delete $device";
	my $hash = $defs{$device};
	if ($hash && defined($hash->{CID}) && $hash->{CID} ne '') {
		my $registered = $modules{MQTT2_DEVICE}{defptr}{cid}{ $hash->{CID} } || [];
		my @remaining = grep { $_ != $hash } @$registered;
		if (@remaining) {
			$modules{MQTT2_DEVICE}{defptr}{cid}{ $hash->{CID} } = \@remaining;
		} else {
			delete $modules{MQTT2_DEVICE}{defptr}{cid}{ $hash->{CID} };
		}
	}
	delete $defs{$device};
	delete $attr{$device};
	return undef;
}

# Sammelt FHEM-Logaufrufe strukturiert fuer nachfolgende Testassertionen.
sub Log3 {
	push @FHEMTestEnv::LOG_ENTRIES, [ @_ ];
	return undef;
}

package FHEMTestEnv;

1;

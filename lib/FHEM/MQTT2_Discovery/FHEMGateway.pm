# Copyright (c) 2026 Andreas Planer
# Licensed under the GNU General Public License v2.0 only

package MQTT2_Discovery::FHEMGateway;

use strict;
use warnings;


# Das Gateway kapselt alle Zugriffe auf globale FHEM-Funktionen. Tests koennen
# fuer jeden Zugriff einen Callback injizieren, ohne FHEM selbst zu starten.
sub new {
	my ($class, %callbacks) = @_;
	return bless { callbacks => \%callbacks }, $class;
}

# Waehlt einen injizierten Test-Callback oder die produktive FHEM-Implementierung aus.
sub _callback {
	my ($self, $name, $fallback) = @_;
	return $self->{callbacks}{$name} if ref($self->{callbacks}{$name}) eq 'CODE';
	return $fallback;
}

# Liest einen FHEM-Attributwert ueber die austauschbare Gateway-Grenze.
sub attr_value {
	my ($self, @args) = @_;
	my $callback = $self->_callback(attr_value => sub { return &main::AttrVal(@_) });
	return $callback->(@args);
}

# Liest ein FHEM-Reading mit dem von FHEM vorgegebenen Fallbackverhalten.
sub reading_value {
	my ($self, @args) = @_;
	my $callback = $self->_callback(reading_value => sub { return &main::ReadingsVal(@_) });
	return $callback->(@args);
}

# Liefert getrennt, ob ein Attribut existiert und welchen Wert es aktuell besitzt.
sub attribute_state {
	my ($self, $device, $attribute) = @_;
	my $callback = $self->_callback(attribute_state => sub {
		return (0, undef) if !exists($main::attr{$device})
			|| !exists($main::attr{$device}{$attribute});
		return (1, $main::attr{$device}{$attribute});
	});
	return $callback->($device, $attribute);
}

# Loest einen FHEM-Devicenamen auf den aktuellen internen Device-Hash auf.
sub device {
	my ($self, $name) = @_;
	my $callback = $self->_callback(device => sub { return $main::defs{$_[0]}; });
	return $callback->($name);
}

# Sucht alle lebenden MQTT2_DEVICE-Instanzen, die einer Client-ID zugeordnet sind.
sub mqtt2_devices_for_cid {
	my ($self, $cid) = @_;
	my $callback = $self->{callbacks}{mqtt2_devices_for_cid};
	return $callback->($cid) if ref($callback) eq 'CODE';
	return [] if !defined($cid) || ref($cid) || $cid eq '';

	my @devices;

	# Der offizielle defptr-Index ist schnell und bildet FHEMs eigene
	# Zuordnung einer Client-ID ab.
	# FHEM stellt diesen Index als Package-Global bereit. In diesem Gateway ist
	# der einzelne Zugriff beabsichtigt und kein Tippfehler.
	no warnings 'once';
	my $registered = $main::modules{MQTT2_DEVICE}{defptr}{cid}{$cid};
	push @devices, grep {
		ref($_) eq 'HASH' && defined($_->{NAME})
			&& $main::defs{ $_->{NAME} } && $main::defs{ $_->{NAME} } == $_
			&& ($_->{TYPE} || '') eq 'MQTT2_DEVICE'
	} @$registered if ref($registered) eq 'ARRAY';

	# Der FHEM-CID-Index ist die primaere Quelle. Der Scan macht die Aufloesung
	# auch waehrend der Initialisierung und in schlanken Testumgebungen robust.
	if (!@devices) {
		push @devices, grep {
			my $device = $main::defs{$_};
			($device->{TYPE} || '') eq 'MQTT2_DEVICE'
				&& (($device->{CID} // $device->{DEF} // '') eq $cid)
		} sort keys %main::defs;
		@devices = map { $main::defs{$_} } @devices;
	}

	my %seen;
	return [ grep { !$seen{ $_->{NAME} }++ } @devices ];
}

# Setzt oder entfernt ein Attribut idempotent und gibt einen FHEM-Fehler zurueck.
sub set_attribute {
	my ($self, $device, $attribute, $value) = @_;
	my ($exists, $current) = $self->attribute_state($device, $attribute);

	# Identische Werte und das Loeschen nicht vorhandener Attribute sind No-ops.
	return undef if defined($value) && $value ne '' && $exists && $current eq $value;
	return undef if (!defined($value) || $value eq '') && !$exists;

	# Nichtleere Werte werden mit attr gesetzt; ein leerer Zielwert bedeutet in
	# dieser Abstraktion bewusst das Entfernen des vorhandenen Attributes.
	if (defined($value) && $value ne '') {
		my $callback = $self->_callback(command_attr => sub {
			return main::CommandAttr(undef, $_[0]);
		});
		return $callback->("$device $attribute $value");
	}
	my $callback = $self->_callback(command_delete_attr => sub {
		return main::CommandDeleteAttr(undef, $_[0]);
	});
	return $callback->("$device $attribute");
}

# Legt ein MQTT2_DEVICE mit Client-ID und IODev ueber FHEMs Define-Schnittstelle an.
sub define_mqtt2_device {
	my ($self, $name, $cid, $io_name) = @_;
	my $callback = $self->_callback(command_define => sub {
		return main::CommandDefine(undef, $_[0]);
	});
	return $callback->("$name MQTT2_DEVICE $cid $io_name");
}

# Entfernt ein Device ausschliesslich ueber FHEMs regulaere Delete-Schnittstelle.
sub delete_device {
	my ($self, $name) = @_;
	my $callback = $self->_callback(command_delete => sub {
		return main::CommandDelete(undef, $_[0]);
	});
	return $callback->($name);
}

# Aktualisiert ein Reading und normalisiert undef sowie den Event-Trigger.
sub update_reading {
	my ($self, $hash, $name, $value, $trigger) = @_;
	my $callback = $self->_callback(update_reading => sub {
		return &main::readingsSingleUpdate(@_);
	});
	return $callback->($hash, $name, defined($value) ? $value : '', $trigger ? 1 : 0);
}

# Schreibt eine bereits aufbereitete Meldung mit Name und Stufe in FHEMs Log.
sub log {
	my ($self, $name, $level, $message) = @_;
	my $callback = $self->_callback(log => sub {
		return main::Log3($_[0], $_[1], $_[2]);
	});
	return $callback->($name, $level, $message);
}

# Meldet, ob ein injizierter oder nativer FHEM-Timer zur Verfuegung steht.
sub can_schedule {
	my ($self) = @_;
	return 1 if ref($self->{callbacks}{schedule}) eq 'CODE';
	return defined(&main::InternalTimer) && defined(&main::gettimeofday);
}

# FHEM-Timer erhalten Hash und Funktionsnamen in einer anderen Reihenfolge als
# der testfreundliche Gateway-Callback; der Adapter vereinheitlicht beides.
sub schedule {
	my ($self, $delay, $hash, $function) = @_;
	my $callback = $self->_callback(schedule => sub {
		return main::InternalTimer(main::gettimeofday() + $_[0], $_[2], $_[1], 0);
	});
	return $callback->($delay, $hash, $function);
}

# Entfernt einen passenden geplanten Timer, sofern die Laufzeit dies unterstuetzt.
sub cancel_timer {
	my ($self, $hash, $function) = @_;
	my $callback = $self->{callbacks}{cancel_timer};
	return $callback->($hash, $function) if ref($callback) eq 'CODE';
	return undef if !defined(&main::RemoveInternalTimer);
	return main::RemoveInternalTimer($hash, $function);
}

# Ruft die aktuelle semantische Device-Beschreibung optional ueber Semantic ab.
sub semantic_description {
	my ($self, $name) = @_;
	my $callback = $self->{callbacks}{semantic_description};
	return $callback->($name) if ref($callback) eq 'CODE';
	return undef if !defined(&main::Semantic_DescribeDevice);
	return main::Semantic_DescribeDevice($name);
}

# Beendet eine semantische Integrationsphase und meldet, ob Semantic selbst publiziert hat.
sub semantic_integration_end {
	my ($self, $name) = @_;
	my $callback = $self->{callbacks}{semantic_integration_end};
	return $callback->($name) if ref($callback) eq 'CODE';
	return 0 if !defined(&main::Semantic_EndIntegration);
	return main::Semantic_EndIntegration($name) ? 1 : 0;
}

# Prueft, ob Beschreibung und Broadcast fuer semantische Updates gemeinsam verfuegbar sind.
sub can_publish_semantics {
	my ($self) = @_;
	return 1 if ref($self->{callbacks}{semantic_description}) eq 'CODE'
		&& ref($self->{callbacks}{semantic_broadcast}) eq 'CODE';
	return defined(&main::Semantic_DescribeDevice) && defined(&main::SemanticWEB_Broadcast);
}

# Hinterlegt oder entfernt die von Discovery erzeugten semantischen Metadaten am Device.
sub set_semantic_metadata {
	my ($self, $name, $metadata) = @_;
	my $callback = $self->{callbacks}{set_semantic_metadata};
	return $callback->($name, $metadata) if ref($callback) eq 'CODE';
	return undef if !exists $main::defs{$name};

	# undef bedeutet bewusst "Metadaten entfernen", nicht "leere Metadaten".
	if (defined $metadata) {
		$main::defs{$name}{SEMANTIC_METADATA} = $metadata;
	} else {
		delete $main::defs{$name}{SEMANTIC_METADATA};
	}
	return undef;
}

# Verteilt ein semantisches Upsert- oder Remove-Ereignis an verbundene Oberflaechen.
sub semantic_broadcast {
	my ($self, $event) = @_;
	my $callback = $self->{callbacks}{semantic_broadcast};
	return $callback->($event) if ref($callback) eq 'CODE';
	return undef if !defined(&main::SemanticWEB_Broadcast);
	return main::SemanticWEB_Broadcast($event);
}

1;

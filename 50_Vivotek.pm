#
#	50_Vivotek.pm 
#
#	(c) 2023 Andreas Planer (https://forum.fhem.de/index.php?action=profile;u=45773)
#a


package main;
use strict;
use warnings;
use JSON();
use HttpUtils;
use Crypt::OpenSSL::RSA;
use Crypt::OpenSSL::Bignum;
use POSIX;
use URI::Escape;

###################################################################################################
# Main
###################################################################################################

sub Vivotek_Initialize($) {
    my $hash = shift // return;

	$hash->{DefFn}		= 'Vivotek_Define';
	$hash->{UndefFn}	= 'Vivotek_Undefine';
	$hash->{AttrFn}		= 'Vivotek_Attr';
	$hash->{WriteFn}	= 'Vivotek_Write';
	$hash->{GetFn}		= 'Vivotek_Get';
	$hash->{SetFn}		= 'Vivotek_Set';
	$hash->{AttrList}	= 'interval username '.$readingFnAttributes;
	$hash->{Clients}	= 'VivotekDevice';

	return Vivotek_LoadVivotekDevice();
}

sub Vivotek_Define($$) {
    my $hash		= shift // return;
    my $def			= shift // return;
	my $name		= $hash->{NAME};
	my $caller		= (caller(1))[3];

	# define <name> Vivotek <hostname>

	my @a = split("[ \t][ \t]*", $def);

	return "Wrong syntax: use 'define <name> Vivotek <hostname>'" if (@a != 3);


	Log3 $name, 4, "Vivotek ($name): Vivotek_Define() called by $caller";

	$hash->{hostname} = $a[2];
	$hash->{interval} = 60; # Default Interval

	readingsSingleUpdate($hash, 'state', 'defined. set username, password', $init_done);

	$modules{Vivotek}{defptr}{$name} = \$hash;

	# Verbindungsaufbau mit dem NVR starten
	Vivotek_Connect($hash);

	return undef;
}

sub Vivotek_Undefine($$) {
	my ($hash, $name) = @_;
	my $caller	= (caller(1))[3];

	Log3 $hash->{NAME}, 4, "Vivotek ($hash->{NAME}): Vivotek_Undefine() called by $caller";
	Log3 $hash->{NAME}, 4, "Vivotek ($hash->{NAME}) deleting device";

	RemoveInternalTimer($hash);   
	
	return undef;
}

sub Vivotek_Get($$@) {
	my ($hash, $name, $cmd, @args) = @_;
	my $caller	= (caller(1))[3];

	return "\"get $name\" needs at least one argument" unless(defined($cmd));
	return "unknown argument $cmd choose one of smartInfo" if ($cmd eq '?');

	Log3 $hash->{NAME}, 4, "Vivotek ($hash->{NAME}): Vivotek_Get() called by $caller";

	if ($cmd eq 'smartInfo') 
	{
		Vivotek_RequestAPI($hash, 'getSmartInfo', 0);
	}

}

sub Vivotek_Set($@) {
	my ($hash, @param) = @_;
	my $setKeys = ["password"];

	return '"set $name" needs at least one argument' 
		if (int(@param) < 2);

	my $name	= shift @param;
	my $cmd		= shift @param;
	my $value	= join("", @param);
	my $caller	= (caller(1))[3];

	Log3 $hash->{NAME}, 4, "Vivotek (".$hash->{NAME}.") Vivotek_Set() called by $caller";
	
	if ($cmd ~~ $setKeys) {

		if ($cmd eq "password" && $value ne "") {
			Log3 $hash->{NAME}, 4, "Vivotek (".$hash->{NAME}."): Vivotek_Set saving password";

			Vivotek_storePassword($hash, $value);
			
			if (AttrVal($name, "username", "") ne "" && $hash->{hostname} ne "") {
				Vivotek_Connect($hash);
			}
			
			return undef;
		} 
	}
	else {
		return "Unknown argument $cmd, choose one of password";
	}
}

sub Vivotek_Write($$) {
	my ( $hash, $deviceName, $cmd, $value) = @_;
	my $name		= $hash->{NAME};
	my $deviceHash	= $defs{$deviceName};
	my $caller		= (caller(1))[3];
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_Write() called by $caller";
	Log3 $name, 5, "Vivotek ($name): Vivotek_Write(): (deviceName: $deviceName cmd:$cmd, value:".(defined($value) ? $value : "");


	if ($cmd eq 'on' || $cmd eq 'off') {
		
		Vivotek_RecordMode($hash, $deviceName, 'manual');
		Vivotek_RequestAPI($hash, $cmd, $value, $deviceName);

		# Wenn ein Write erfolgt, soll state auf updating gesetzt werden, welcher erst vom Callback wieder auf on/off gesetzt wird.
		$deviceHash->{'.newState'} = lc $cmd;
	}
#	elsif ($cmd eq 'recordMode') {
	elsif ($cmd eq 'auto') {
		Vivotek_RecordMode($hash, $deviceName, 'auto');
		Vivotek_RequestAPI($hash, 'off', $value, $deviceName);

		$deviceHash->{'.newState'} = lc $cmd;

	}
	elsif ($cmd eq 'recordMode') {
		Vivotek_RecordMode($hash, $deviceName, $value);
	}
	
	$deviceHash->{'.lastState'} = ReadingsVal($deviceName, "state", undef) if (ReadingsVal($deviceName, "state", undef) ne "updating");
	readingsSingleUpdate($deviceHash, "state", "updating", 1);
	
	return undef;
}

sub Vivotek_RecordMode($$$) {
	my ($hash, $deviceName, $mode) = @_;
	my $deviceHash	= $defs{$deviceName};
	my $rValue		= $mode eq 'auto' ? 1 : 2;
	my ($data);


	# Json Array muss zuerst zusammen gebaut werden. Beim NVR kann je 30 Minuten angegeben werden, ob aufgezeichnet werden soll.
	$data->{$deviceHash->{channel}} = {	'version' => 2,
											'schedule_type' => 'system',
											'schedule_index' => 0,
											'customized' => \1,
											'id' => $deviceHash->{channel}};
	my ($weekDay);

	# je Wochentag
	foreach (1 .. 7) {
		$weekDay = ();
		# je halbe Stunde eines Tages
		for (1 .. 48) {
			push @$weekDay, $rValue;
		}
		push @{$data->{$deviceHash->{channel}}{value}},$weekDay;
	}

	Vivotek_RequestAPI($hash, 'recordMode', JSON->new->encode($data), $deviceName);
}

sub Vivotek_Attr($$$$) {
	my ( $cmd, $name, $aName, $aValue ) = @_;
	my $caller	= (caller(1))[3];
    my $hash	= $defs{$name};
	
  	# $cmd  - Vorgangsart - kann die Werte "del" (löschen) oder "set" (setzen) annehmen
	# $name - Gerätename
	# $aName/$aValue sind Attribut-Name und Attribut-Wert

	Log3 $name, 4, "Vivotek ($name): Vivotek_Attr() called by $caller";
    
	if ($cmd eq "set") {
		if ($aName eq "username") {
			if ($aValue ne "" && Vivotek_readPassword($hash) ne "") {
				InternalTimer(gettimeofday() + 1, 'Vivotek_Connect', $hash);
			}

		}
	}
	return undef;
}

sub Vivotek_Connect($) {
	my $hash	= shift // return;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	
	Log3 $name, 3, "Vivotek ($name): Vivotek_Connect() called by $caller";

	# Vor dem Connect Session ID löschen
	delete $hash->{'.SID'};
	
	Vivotek_RequestAPI($hash, 'getSystemKey');
}

# Alle im Account konfiguierten Geräte auslesen
sub Vivotek_GetDevices($) {
	my ($hash)	= @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];

	Log3 $name, 4, "Vivotek ($name): Vivotek_GetDevices() called by $caller";

	Vivotek_RequestAPI($hash, 'getDevices');
	Vivotek_RequestAPI($hash, 'getRecordStatus');
	
	# Timestamp des letzten Durchlauf speichern
	$hash->{lastUpdateCycle} = TimeNow();

	# neuen Timer starten in einem konfigurierten Interval
	Log3 $name, 4, "Vivotek ($name): Vivotek_GetDevices new interval with ".AttrVal($name, 'interval', $hash->{interval}).'s';
	InternalTimer(gettimeofday() + AttrVal($name, 'interval', $hash->{interval}), 'Vivotek_GetDevices', $hash);
}

# Auslesen aller angeschlossenen Kameras
sub Vivotek_KeepAlive($) {
	my ($hash) = @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_KeepAlive() called by $caller";

	Vivotek_RequestAPI($hash, 'keepAlive');
	InternalTimer(gettimeofday() + $hash->{interval}, 'Vivotek_KeepAlive', $hash);
}

# Kommunuikation mit der Vivotek NVR API
sub Vivotek_RequestAPI($$;$$) {
	my $hash		= shift // return;
	my $cmd			= shift // return;
	my $data		= shift; # Optional
	my $deviceName	= shift; # Optional
	my $name		= $hash->{NAME};
	my $caller		= (caller(1))[3];
	my ($param, $paramCmd);
	my $username	= AttrVal($name, "username", "");
	my $hostname	= $hash->{hostname};

	if ($hostname ne "") {
		my $header = {	'Accept' 		=> 'application/json, text/plain, */*',
						'Content-Type'	=> 'application/x-www-form-urlencoded', 
						'charset'		=> 'UTF-8'};

		my $deviceHash	= $defs{$deviceName} if (defined($deviceName));

		# Header um Session Cookie erweitern, wenn vorhanden
		if (defined($hash->{'.SID'})) {
			$header = { %$header,
						'Cookie'		=> 'username='.$username.'; language=1; _SID_='.$hash->{'.SID'}};
		}
										
		Log3 $name, 4, "Vivotek ($name): Vivotek_RequestAPI (cmd: $cmd) called by $caller";

		if ($cmd eq 'getSystemKey') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/system.key',
							method		=> 'GET'
						};
		} elsif ($cmd eq 'login') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/system.login',
							method		=> 'POST',
							data		=> $data
						};
		} elsif ($cmd eq 'getDevices') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/operator/gconf.query',
							method		=> 'POST',
							data		=> 'path=/system/software/meteor/encoder'
						};
		} elsif ($cmd eq 'getDeviceInfo' && Vivotek_IsNumeric($deviceHash->{channel})) {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/operator/gconf.query',
							method		=> 'POST',
							data		=> 'path=/system/software/meteor/encoder/'.$deviceHash->{channel},
							deviceName	=> $deviceName
						};
		} elsif ($cmd eq 'getSystemInfo') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/operator/gconf.query',
							method		=> 'POST',
							data		=> 'path=/system/software/raphael/system'
						};
		} elsif ($cmd eq 'getVolumeInfo') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/admin/volume.info',
							method		=> 'POST'
						};
		} elsif ($cmd eq 'keepAlive') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/system.session-keep-alive?alive=true',
							method		=> 'POST',
							data		=> 'alive=true'
						};
		} elsif ($cmd eq 'on' && Vivotek_IsNumeric($deviceHash->{channel})) {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/operator/recording.start',
							method		=> 'POST',
							data		=> 'channel='.$deviceHash->{channel}.'&username='.$username,
							deviceName	=> $deviceName
						};
		} elsif ($cmd eq 'off' && Vivotek_IsNumeric($deviceHash->{channel})) {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/operator/recording.stop',
							method		=> 'POST',
							data		=> 'channel='.$deviceHash->{channel}.'&username='.$username,
							deviceName	=> $deviceName
						};
		} elsif ($cmd eq 'recordMode') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/operator/gconf.update',
							method		=> 'POST',
							data		=> 'path=/system/software/mars-rec/schedule&data='.$data,
							deviceName	=> $deviceName
						};
		} elsif ($cmd eq 'getRecordStatus') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/operator/gconf.query',
							method		=> 'POST',
							data		=> "path=/system/software/mars-rec/status"
						};
		} elsif ($cmd eq 'getDeviceRecordStatus' && Vivotek_IsNumeric($deviceHash->{channel})) {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/operator/gconf.query',
							method		=> 'POST',
							data		=> 'path=/system/software/mars-rec/status/'.$deviceHash->{channel},
							deviceName	=> $deviceName
						};
		} elsif ($cmd eq 'getSmartInfo' && Vivotek_IsNumeric($data)) {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/admin/smart.info',
							method		=> 'POST',
							data		=> 'disk='.$data
						};
	#todo
		} elsif ($cmd eq 'getDiskInfo') {
			$paramCmd = {	url 		=> 'http://'.$hostname.'/fcgi-bin/admin/disk.info',
							method		=> 'GET'
						};
		}

		if (!defined($paramCmd)) {
			Log3 $name, 1, "Vivotek_RequestAPI ($name): Fatal error. No parameter defined!";
			use Data::Dumper;
			print Dumper $cmd;
			print Dumper $data;
			print Dumper Vivotek_IsNumeric($data);
		}
		
		# Standardwerte für alle Requests ergänzen
		$param = {	%$paramCmd,
					cmd			=> $cmd, 
					timeout		=> 30,
					hash		=> $hash,
					header		=> $header,
					callback	=> \&Vivotek_Callback
					};

		HttpUtils_NonblockingGet($param);
	} else {
		Log3 $name, 1, "Vivotek ($name): no hostname set";
		readingsSingleUpdate($hash, 'state', 'no hostname set', 1);

	}
}


###################################################################################################
# Callbacks
###################################################################################################

# Wrapper Callback für Errorhandling etc
sub Vivotek_Callback($) {
	my ($param, $err, $content) = @_;
	my $hash	= $param->{hash};
	my $name	= $hash->{NAME};
	my $cmd		= $param->{cmd};
	my $caller	= (caller(1))[3];
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_Callback() called by $caller (cmd: $cmd)";
	Log3 $name, 5, "Vivotek ($name): Vivotek_Callback() received content: $content";

	# Errorhandling
	if ($err ne '') {
		Log3 $name, 2, "Vivotek ($name): error while requesting $param->{url} - $err";
		return;
    }
	elsif ($param->{code} != 200) {
		Log3 $name, 3, "Vivotek ($name): Vivotek_Callback() API returned error code: $param->{code}";
		readingsSingleUpdate($hash, 'state', 'login error. wrong user/password?', 1) if ($param->{code} == 401);
	}
	elsif ($content ne '') {
	

		if ($cmd eq 'on' || $cmd eq 'off' || $cmd eq 'recordMode') {
			#{ "status": 500, "message": "Invalid camera authentication." }			
			Vivotek_StateCallback($hash, $param, $content);
		}
		elsif ($cmd eq 'getSystemKey') {
			Vivotek_GetSystemKeyCallback($hash, $content);
		}
		elsif ($cmd eq 'login') {
			Vivotek_LoginCallback($hash, $content);
		}
		elsif ($cmd eq 'getVolumeInfo') {
			Vivotek_GetVolumeInfoCallback($hash, $content);
		}
		elsif ($cmd eq 'getSystemInfo') {
			Vivotek_GetSystemInfoCallback($hash, $content);
		}
		elsif ($cmd eq 'getDevices') {
			Vivotek_GetDevicesCallback($hash, $content);
		}	
		elsif ($cmd eq 'getDeviceInfo') {
			Vivotek_GetDeviceInfoCallback($hash, $param, $content);
		}	
		elsif ($cmd eq 'getRecordStatus') {
			Vivotek_GetRecordStatusCallback($hash, $content);
		}
		elsif ($cmd eq 'getDeviceRecordStatus') {
			Vivotek_GetDeviceRecordStatusCallback($hash, $param, $content);
		}
		elsif ($cmd eq 'getSmartInfo') {
			Vivotek_GetSmartInfoCallback($hash, $content);
		}


	}
}

sub Vivotek_GetDeviceRecordStatusCallback($$$) {
	my ($hash, $param, $content) = @_;
	my $name			= $hash->{NAME};
	my $deviceHash		= $defs{$param->{deviceName}};
	my $deviceNumber	= $deviceHash->{channel};
	my ($decodedJson, $deviceData);

	Log3 $name, 4, "Vivotek ($name): Vivotek_GetRecordStatusCallback() called";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {
		$decodedJson->{channel} = $deviceNumber;
		Log3 $name, 4, "Vivotek ($name): Vivotek_GetDeviceRecordStatusCallback() dispatching $deviceNumber";
		Dispatch($hash, $decodedJson);
	}
}

sub Vivotek_GetRecordStatusCallback($$) {
	my ($hash, $content) = @_;
	my $name = $hash->{NAME};
	my ($decodedJson, $deviceData);

	Log3 $name, 4, "Vivotek ($name): Vivotek_GetRecordStatusCallback() called";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {
		foreach my $deviceNumber (sort {$a <=> $b} keys %$decodedJson) {
			$deviceData = \$decodedJson->{$deviceNumber};

			$$deviceData->{channel} = $deviceNumber;
			Log3 $name, 4, "Vivotek ($name): Vivotek_GetRecordStatusCallback() dispatching $deviceNumber";
			Dispatch($hash, $$deviceData);
		}
	}
}

sub Vivotek_StateCallback($$$) {
	my ($hash, $param, $content) = @_;
	my $name		= $hash->{NAME};
	my $deviceHash	= $defs{$param->{deviceName}};
	my ($decodedJson);

	Log3 $name, 4, "Vivotek ($name): Vivotek_StateCallback() called";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {
		if ($decodedJson eq 'True') {
			# besser wäre es den Status über getDeviceRecordStatus auszulesen. Allerdings erfolgt die Aktualisierung scheinbar asynchron. Daher schreiben wir den Status selbst
	
			if (defined($deviceHash->{'.newState'})) {
				$deviceHash->{'.lastState'} = $deviceHash->{'.newState'};
				delete $deviceHash->{'.newState'};
			}

			readingsSingleUpdate($deviceHash, 'state', $deviceHash->{'.lastState'}, 1);
		}
	}
}


# PublicKey wird regelmäßig vom NVR neu erzeugt. Wird für den Login zwingend benötigt
sub Vivotek_GetSystemKeyCallback($$) {
	my ($hash, $content) = @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	my ($publicKey, $ciphertext);
	my $username = AttrVal($name, "username", "");
	my $password = Vivotek_readPassword($hash);
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_SystemKeyCallback() called by $caller";

	# Fehlermeldung, wenn PublicKey nicht vorhanden
	if (!defined($publicKey = Vivotek_DecodeJson($hash, $content) )) {
		Log3 $name, 1, "Vivotek ($name): RSA publicKey not received";
		return;
	}
	
	# Logindaten aufbereiten und verschlüsseln für Post Data encode=""
	$ciphertext = Vivotek_EncryptLoginData($hash, $publicKey, $username, $password);

	# Login durchführen
	Vivotek_RequestAPI($hash, 'login', 'encode='.Vivotek_String2Hex($ciphertext) );
}

sub Vivotek_LoginCallback($$) {
	my ($hash, $content) = @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	my ($decodedJson);
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_ConnectCallback() called by $caller";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {

		readingsSingleUpdate($hash, 'state', 'connected', 1);

		$hash->{'.SID'} = $decodedJson->{'_SID_'};

		# nach Login zunächst Systeminfo und alle verfügbaren Kameras auslesen
		Vivotek_RequestAPI($hash, 'getSystemInfo');
		Vivotek_RequestAPI($hash, 'getVolumeInfo');
		Vivotek_GetDevices($hash);

		# KeepAlive initialisieren
		Vivotek_KeepAlive($hash);
	}
}

# Auslesen der S.M.A.R.T. Daten
sub Vivotek_GetSmartInfoCallback($$) {
	my ($hash, $content) = @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	my ($decodedJson);
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_GetSmartInfoCallback() called by $caller";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {
		#use Data::Dumper;
		#print Dumper $decodedJson;
	}
}

# Auslesen der Volumes
sub Vivotek_GetVolumeInfoCallback($$) {
	my ($hash, $content) = @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	my ($decodedJson);
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_GetVolumeInfoCallback() called by $caller";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {
		# Zur Zeit wird nur ein Volume(0) unterstützt.
		my $data = @$decodedJson[0];

		# DiskStatus ist nur dann healthy, wenn alle HDD in Ordnung sind
		my $diskStatus = 'healthy';
		foreach my $disk (@{$data->{'MemberDisksStatus'}}) {
			$diskStatus = 'error' if ($disk ne 'active');
		}
		
		readingsBeginUpdate($hash);
		readingsBulkUpdateIfChanged($hash, 'volumeStatus', $data->{'Status'});
		readingsBulkUpdateIfChanged($hash, 'volumeCapacity', $data->{'Capacity'});
		readingsBulkUpdateIfChanged($hash, 'volumeCapacityFree', $data->{'UnusedSpace'});
		readingsBulkUpdateIfChanged($hash, 'volumeRaidType', $data->{'RaidType'});
		readingsBulkUpdateIfChanged($hash, 'volumeDiskStatus', $diskStatus);
		readingsEndUpdate($hash, 1);
	}
}

# Auslesen aller angeschlossenen Kameras
sub Vivotek_GetSystemInfoCallback($$) {
	my ($hash, $content) = @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	my ($decodedJson);
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_GetSystemInfoCallback() called by $caller";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {
		readingsBeginUpdate($hash);
		readingsBulkUpdateIfChanged($hash, 'hostname', $decodedJson->{hostname});
		readingsBulkUpdateIfChanged($hash, 'device_pack_version', $decodedJson->{device_pack_version});
		readingsBulkUpdateIfChanged($hash, 'brand', $decodedJson->{brand});
		readingsBulkUpdateIfChanged($hash, 'model_name', $decodedJson->{model_name});
		readingsBulkUpdateIfChanged($hash, 'ntp_server', $decodedJson->{ntp_server});
		readingsBulkUpdateIfChanged($hash, 'serial_number', $decodedJson->{serial_number});
		readingsBulkUpdateIfChanged($hash, 'version', $decodedJson->{version});
		readingsEndUpdate($hash, 1);
	}
}

# Auslesen aller angeschlossenen Kameras
sub Vivotek_GetDeviceInfoCallback($$$) {
	my ($hash, $param, $content) = @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	my ($decodedJson, $deviceData);
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_GetDevicesCallback() called by $caller";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {
		# foreach my $deviceNumber (sort {$a <=> $b} keys %$decodedJson) {
			# $deviceData = \$decodedJson->{$deviceNumber};

			# if ($$deviceData->{status} ne 'CAM_EMPTY') {

				# $$deviceData->{channel} = $deviceNumber;
				
				# Log3 $name, 4, "Vivotek ($name): Vivotek_GetDevicesCallback() dispatching $deviceNumber";
				# Dispatch($hash, $$deviceData);
			# }
		# }
		
		#use Data::Dumper;
		#print Dumper $decodedJson;
	}
}

# Auslesen aller angeschlossenen Kameras
sub Vivotek_GetDevicesCallback($$) {
	my ($hash, $content) = @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	my ($decodedJson, $deviceData);
	
	Log3 $name, 4, "Vivotek ($name): Vivotek_GetDevicesCallback() called by $caller";

	if ($decodedJson = Vivotek_DecodeJson($hash, $content)) {
		foreach my $deviceNumber (sort {$a <=> $b} keys %$decodedJson) {
			$deviceData = \$decodedJson->{$deviceNumber};

			if ($$deviceData->{status} ne 'CAM_EMPTY') {

				$$deviceData->{channel} = $deviceNumber;
				
				Log3 $name, 4, "Vivotek ($name): Vivotek_GetDevicesCallback() dispatching $deviceNumber";
				Dispatch($hash, $$deviceData);
			}
		}
	}
}


###################################################################################################
# Helper
###################################################################################################

# API Result decodieren
sub Vivotek_DecodeJson($$) {
    my $hash		= shift // return;
	my $content		= shift // return;
    my $caller		= (caller(1))[3];
    my $name		= $hash->{NAME};
    my $decodedJson;
   
    Log3 $name, 4, "Vivotek_DecodeJson() called by $caller";
   
    # Fehler prüfen, wenn $content kein valides JSON enthielt
    if ( !eval { $decodedJson  = JSON->new->decode($content) ; 1 } ) {
        Log3($name, 2, "Vivotek (${name}): $caller returned error: $@ content: $content");

		# prüfen ob "401 Authorization Required" als html
        return 'error';
    }

    return $decodedJson;
 
}

sub Vivotek_String2Hex {
	my $str = shift // return;
	return unpack('H*', $str);
}

sub Vivotek_EncryptLoginData($$$$) {
	my $hash		= shift // return;
	my $publicKey	= shift // return;
	my $username	= shift // return;
	my $password	= shift // return;
	my $caller		= (caller(1))[3];
	my $name		= $hash->{NAME};
	my $message 	= ":$username:$password"; # wird abhängig von der Keystärke aus Sicherheitsgründen mit Zufallszahlen aufgefüllt, so dass $message immer $encode_l lang ist
	my @hex			= ('0' .. '9', 'a' .. 'f');

	my ($ciphertext, $rsa, $seg_l, $encode_l, $pad_l, $padding);
   
    Log3 $name, 4, "Vivotek ($name): Vivotek_EncryptLoginData() called by $caller";

	# Errorhandling
	if (!defined($publicKey->{n})) {
		Log3 $name, 3, "Vivotek ($name): RSA->n not set!";
		return;
	}
	if (!defined($publicKey->{e})) {
		Log3 $name, 3, "Vivotek ($name): RSA->e not set! Using default value 10001";
		$publicKey->{e} = '10001';
	}

 	# 1024 bit Key
	if (length($publicKey->{n}) == 256) {
    # case 256: // 1024 bits
        # Länge ist (1024 / 8 - 11) * 2 = 234
		$seg_l = 117;		# Keysize erlaubt maximal 128 Zeichen, abzgl. 11 (PKCS1 Padding) = 117 
		$encode_l = 234;	# 2 segments. 
	}
	# 512 bit Key
	elsif (length($publicKey->{n}) == 128) {
		# Länge ist (512 / 8 - 11) * 3 = 159
		$seg_l = 53;		# Keysize erlaubt maximal 64 Zeichen, abzgl. 11 (PKCS1 Padding) = 53 
		$encode_l = 159;	# 3 segments. 
	}

    $pad_l = $encode_l - length($message);

	# Hex Zahl mit Länge von $pad_l erzeugen zum Auffüllen von $message
	$message = (join '' => map $hex[rand @hex], 1 .. $pad_l).$message;

	# RSA PublicKey erzeugen 
	$rsa = Crypt::OpenSSL::RSA->new_key_from_parameters(Crypt::OpenSSL::Bignum->new_from_hex($publicKey->{n}),
														Crypt::OpenSSL::Bignum->new_from_hex($publicKey->{e}),
														);
	$rsa->use_pkcs1_padding();

	Log3 $name, 4, 'Vivotek_EncryptLoginData: Keysize: '.length($publicKey->{n}).' - msgsize: '.length($message);
	Log3 $name, 5, 'Vivotek_EncryptLoginData: public key (in PKCS1 format) is: '.sprintf('\n%s\n', $rsa->get_public_key_string());

	# Loginphrase mit Public Key verschlüsseln
	for (my $l = 0; $l < $encode_l; $l += $seg_l) {
		$ciphertext.= $rsa->encrypt(substr($message, $l, $seg_l));
	}

	return $ciphertext;
}

# Gernerierung eines kompatiblen deviceNames
sub Vivotek_MakeDeviceName($) {
	my ($name) = @_;

	return makeDeviceName($name);
}

# Laden der PanasonicACDevice Funktionen		
sub Vivotek_LoadVivotekDevice() {
	if( !$modules{VivotekDevice}{LOADED}) {
		my $ret = CommandReload(undef, '51_VivotekDevice');
		Log3 undef, 4, "LoadVivotekDevice: $ret" if( $ret );
	}
}

sub Vivotek_IsNumeric($) {
	my $number = shift // return;
	return 1 if ($number =~ /^\d+$/);
}


# Passwort verschlüsselt im key<>value Store speichern 
sub Vivotek_storePassword($$) {
	my ($hash, $password) = @_;
	my $name	= $hash->{NAME};
	my $index	= $hash->{TYPE}."_".$hash->{NAME}."_passwd";
	my $key		= getUniqueId().$index;
	my $enc_pwd	= "";

	if(eval "use Digest::MD5;1") {
		$key = Digest::MD5::md5_hex(unpack "H*", $key);
		$key.= Digest::MD5::md5_hex($key);
	}

	for my $char (split //, $password) {
		my $encode = chop($key);
		$enc_pwd.= sprintf("%.2x",ord($char)^ord($encode));
		$key = $encode.$key;
	}

	my $err = setKeyValue($index, $enc_pwd);
	return "Vivotek ($name): error while saving the password - $err" if(defined($err));

	return "Vivotek ($name): password successfully saved";
} 

# Passwort aus key<>value Store lesen und entschlüsseln 
sub Vivotek_readPassword($) {
	my ($hash)	= @_;
	my $name	= $hash->{NAME};
	my $index	= $hash->{TYPE}."_".$hash->{NAME}."_passwd";
	my $key		= getUniqueId().$index;
	my ($password, $err);

	Log3 $name, 5, "Read Vivotek password from file";

	($err, $password) = getKeyValue($index);

	if ( defined($err) ) {
		Log3 $name, 5, "unable to read Vivotek password from file: $err";
		return undef;
	}

	if ( defined($password) ) {
		if ( eval "use Digest::MD5;1" ) {
			$key = Digest::MD5::md5_hex(unpack "H*", $key);
			$key.= Digest::MD5::md5_hex($key);
		}

		my $dec_pwd = '';

		for my $char (map { pack('C', hex($_)) } ($password =~ /(..)/g)) {
			my $decode = chop($key);
			$dec_pwd.= chr(ord($char)^ord($decode));
			$key = $decode.$key;
		}
		return $dec_pwd;
	} else {
		Log3 $name, 5, "No password in file";
		return undef;
	}
}

1;
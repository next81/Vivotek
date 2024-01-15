#
#	51_VivotekDevice.pm 
#
#	(c) 2023 Andreas Planer (https://forum.fhem.de/index.php?action=profile;u=45773)
#


package main;
use strict;
use warnings;
use experimental 'smartmatch';

###################################################################################################
# Main
###################################################################################################

sub VivotekDevice_Initialize($) {
	my ($hash) = @_;

	$hash->{DefFn}			= 'VivotekDevice_Define';
	$hash->{UndefFn}		= 'VivotekDevice_Undefine';
	$hash->{SetFn}			= 'VivotekDevice_Set';
	$hash->{AttrFn}			= 'VivotekDevice_Attr';
    $hash->{ParseFn}		= 'VivotekDevice_Parse';
#	$hash->{FW_summaryFn}	= 'VivotekDevice_HTML';
    $hash->{Match}			= '.+';

	$hash->{noAutocreatedFilelog} = 1;
	$hash->{AutoCreate} = 	{"Vivotek\..*"	=> {ATTR => 'event-on-change-reading:.* event-min-interval:.*:300 room:Vivotek icon:it_camera devStateIcon:{VivotekDevice_devStateIcon($name)} webCmd:on:off:auto',
												autocreateThreshold	=> '1:60'
												}
							};
	$hash->{AttrList} = 'intervalDetails '.$readingFnAttributes;
}

sub VivotekDevice_HTML($$$) {
	my ($FW_wname, $deviceName, $FW_room) = @_;
	my $deviceHash	= $defs{$deviceName};

	my $html = '';

	return $html;
}

sub VivotekDevice_Define($$) {
	my ($hash, $def) = @_;
	my @param = split('[ \t]+', $def);

	if (int(@param) < 3) {
		return 'too few parameters: define <name> VivotekDevice <channel>';
	}

	$hash->{channel}	= $param[2];

	# Referenz auf $hash unter der channel anlegen
	$modules{VivotekDevice}{defptr}{$hash->{channel}} = \$hash;

	AssignIoPort($hash);

	return undef;
}

sub VivotekDevice_Undefine($$)
{
	my ($hash, $name) = @_;
 
	return undef;
}

sub VivotekDevice_Set($$$;$) {
	my ($hash, $name, $cmd, $value) = @_;
	my $setKeys = ['on', 'off', 'auto'];#'recordMode'
	my $caller = (caller(1))[3];


	if ($cmd ne '?') {
		Log3 $name, 4, "VivotekDevice ($name): VivotekDevice_Set() called by $caller";
		Log3 $name, 5, "VivotekDevice ($name): VivotekDevice_Set() (cmd: $cmd - value: ".(defined($value) ? $value : "").") start";

		return "\"set $name\" needs at least one argument"  unless(defined($cmd));

	}

	if ($cmd ~~ $setKeys) {
		Log3 $name, 4, "VivotekDevice ($name): VivotekDevice_Set() IOWrite calling";

		my $result = IOWrite($hash, $name, $cmd, $value);
	}
	else {
		return "Unknown argument $cmd, choose one of on:noArg off:noArg auto:noArg";
	}
}

sub VivotekDevice_Attr($$$$) {
	my ( $cmd, $name, $aName, $aValue ) = @_;
    
	return undef;
}


sub VivotekDevice_Parse ($$) {
	my ($IOhash, $data) = @_;    # IOhash = Vivotek, nicht VivotekDevice
    my $name			= $IOhash->{NAME};
	my $channel			= $data->{channel};
	my $caller 			= (caller(1))[3];
	my ($deviceName);

	my $validParameters = ['pir_count','f_speed','device_channel','t_speed_lv','p_speed','netloc','large_stream_url','z_speed','port','counting','camctrl','channel_count','joystick','medium_stream','vca','mac_binding','vca_auth_websocket','rtsp_uri','ptz_buildinpt','auto_tracking','remote_focus','e_z_speed','di_count','small_stream','e_t_speed','motion_count','isptz','https_port','ext_model','enable_recording','enable','model','vca_wss_port','eptz','large_stream','videomode','mac','object_info','t_speed','p_speed_lv','device_pack_supported','address','z_speed_lv','sip','username','fisheye_mounttype','link_local_address','https_only','medium_stream_url','dms_vca_event','sub_stream','onvif','do_count','status','http_anonymousviewing','vca_ws_port','name','enable_fisheye','small_stream_url','e_p_speed','motion_cell','enable_manual_recording','vca_event','brand','http_authmode','stream_count','http_alt_port','enable_audio_recording','rtsp_authmode','main_stream','ptz_zoommodule','rtsp_port','channel','vca_version','generic','schedule','manual','state'];

	Log3 $name, 4, "VivotekDevice: VivotekDevice_parse() called by $caller";

	if (defined($channel)) {
		# $hashRef ist eine Referenz auf $hash des jeweiligen Devices
		my $hashRef = $modules{VivotekDevice}{defptr}{$channel};

		# $hash existiert nur, wenn das Device schon angelegt wurde
		if ($hashRef)
		{
			$deviceName = $$hashRef->{NAME};

			Log3 $deviceName, 4, "VivotekDevice ($deviceName): existing device Id ".$channel;


			# Wenn manual OFF ist und state = ON, dann soll als state 'auto' statt on gesetzt werden.
			$data->{'state'} = 'auto' if (defined($data->{'state'}) && lc $data->{state} eq 'on' && lc $data->{manual} eq 'off');

			readingsBeginUpdate($$hashRef);

			foreach my $key (keys %{$data}) {
				if ($key ~~ $validParameters) {

					readingsBulkUpdateIfChanged($$hashRef, $key, lc($data->{$key}) );
				}
			}

			readingsEndUpdate($$hashRef, 1);

			# DeviceName als Array für dispatch() zurückgeben 
			return ($deviceName);
		}
		elsif (defined($data->{mac}))
		{
			use Encode qw(decode);

			$deviceName = Vivotek_MakeDeviceName("Vivotek_$data->{model}_$data->{name}_$data->{mac}");
			
			# Wenn deviceName nicht gesetzt werden konnte oder Device mit dem Namen bereits existiert wird $channel zur Namensbildung genutzt
#			if ($deviceName eq "" || $defs{$deviceName}) { 
#				$deviceName = Vivotek_MakeDeviceName("Vivotek_$data->{model}_$data->{name}_$data->{channel}");
			#}
			
			Log3 $name, 4, "UNDEFINED $deviceName VivotekDevice $channel";

			# Keine Gerätedefinition verfügbar, Rückmeldung für AutoCreate
			return "UNDEFINED $deviceName VivotekDevice $channel";
		}
	} else {
		Log3 $name, 3, "Vivotek ($name): no channel found!";
	}

}


###################################################################################################
# GUI
###################################################################################################

sub VivotekDevice_devStateIcon {
	my ($name)	= @_;
	my $manual	= ReadingsVal($name, 'manual', undef);
	my $state	= ReadingsVal($name, 'state', undef);

	return 'off:rc_STOP on:rc_RED auto:rc_BLUE updating:refresh@blue';
}


1;
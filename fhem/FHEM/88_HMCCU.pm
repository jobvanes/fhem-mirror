##############################################################################
#
#  88_HMCCU.pm
#
#  $Id$
#
#  Version 4.0
#
#  Module for communication between FHEM and Homematic CCU2.
#
#  Supports BidCos-RF, BidCos-Wired, HmIP-RF, virtual CCU channels,
#  CCU group devices, HomeGear, CUxD, Osram Lightify.
#
#  (c) 2017 zap (zap01 <at> t-online <dot> de)
#
##############################################################################
#
#  define <name> HMCCU <hostname_or_ip_of_ccu> [ccunumber]
#
#  set <name> cleardefaults
#  set <name> defaults
#  set <name> execute <ccu_program>
#  set <name> importdefaults <filename>
#  set <name> hmscript <hm_script_file>
#  set <name> rpcserver {on|off|restart}
#  set <name> var <value> [...]
#
#  get <name> aggregation {<rule>|all}
#  get <name> configdesc {<device>|<channel>}
#  get <name> defaults
#  get <name> deviceinfo <device>
#  get <name> devicelist [dump]
#  get <name> devicelist create <devexp> [t={chn|dev|all}] [s=<suffix>]
#                                        [p=<prefix>] [f=<format>]
#                                        [defattr] [<attr>=<val> [...]]}]
#  get <name> dump {devtypes|datapoints} [<filter>]
#  get <name> exportdefaults {filename}
#  get <name> parfile [<parfile>]
#  get <name> rpcevents
#  get <name> rpcstate
#  get <name> update [<fhemdevexp> [{ State | Value }]]
#  get <name> updateccu [<devexp> [{ State | Value }]]
#  get <name> vars <regexp>
#
#  attr <name> ccuackstate { 0 | 1 }
#  attr <name> ccuaggregate <rules>
#  attr <name> ccudef-hmstatevals <subst_rules>
#  attr <name> ccudef-readingfilter <filter_rule>
#  attr <name> ccudef-readingname <rules>
#  attr <name> ccudef-substitute <subst_rule>
#  attr <name> ccudefaults <filename>
#  attr <name> ccuflags { intrpc,extrpc,dptnocheck,noagg }
#  attr <name> ccuget { State | Value }
#  attr <name> ccureadings { 0 | 1 }
#  attr <name> parfile <parfile>
#  attr <name> rpcevtimeout <seconds>
#  attr <name> rpcinterfaces { BidCos-Wired, BidCos-RF, HmIP-RF, VirtualDevices, Homegear }
#  attr <name> rpcinterval <seconds>
#  attr <name> rpcport <ccu_rpc_port>
#  attr <name> rpcqueue <file>
#  attr <name> rpcserver { on | off }
#  attr <name> rpcserveraddr <ip-or-name>
#  attr <name> rpcserverport <base_port>
#  attr <name> rpctimeout <read>[,<write>]
#  attr <name> stripchar <character>
#  attr <name> stripnumber { -<digits> | 0 | 1 | 2 }
#  attr <name> substitute <subst_rule>
#
#  filter_rule := [channel-regexp!]datapoint-regexp[,...]
#  subst_rule := [[channel.]datapoint[,...]!]<regexp>:<subtext>[,...][;...]
##############################################################################
#  Verbose levels:
#
#  0 = Log start/stop and initialization messages
#  1 = Log errors
#  2 = Log counters and warnings
#  3 = Log events and runtime information
##############################################################################

package main;

no if $] >= 5.017011, warnings => 'experimental::smartmatch';

use strict;
use warnings;
# use Data::Dumper;
# use Time::HiRes qw(usleep);
use IO::File;
use Fcntl 'SEEK_END', 'SEEK_SET', 'O_CREAT', 'O_RDWR';
use RPC::XML::Client;
use RPC::XML::Server;
use SetExtensions;
use SubProcess;
use HMCCUConf;

# Import configuration data
my $HMCCU_CHN_DEFAULTS = \%HMCCUConf::HMCCU_CHN_DEFAULTS;
my $HMCCU_DEV_DEFAULTS = \%HMCCUConf::HMCCU_DEV_DEFAULTS;
my $HMCCU_SCRIPTS = \%HMCCUConf::HMCCU_SCRIPTS;

# Custom configuration data
my %HMCCU_CUST_CHN_DEFAULTS;
my %HMCCU_CUST_DEV_DEFAULTS;

# HMCCU version
my $HMCCU_VERSION = '4.0';

# RPC Ports and URL extensions
my $HMCCU_RPC_PORT_DEFAULT = 2001;

my %HMCCU_RPC_NUMPORT = (
	2000 => 'BidCos-Wired', 2001 => 'BidCos-RF', 2010 => 'HmIP-RF', 9292 => 'VirtualDevices',
	2003 => 'Homegear', 8701 => 'CUxD'
);
my %HMCCU_RPC_PORT = (
   'BidCos-Wired', 2000, 'BidCos-RF', 2001, 'HmIP-RF', 2010, 'VirtualDevices', 9292,
   'Homegear', 2003, 'CUxD', 8701
);
my %HMCCU_RPC_URL = (
	9292, 'groups'
);
my %HMCCU_RPC_PROT = (
   2000 => 'A', 2001 => 'A', 2010 => 'A', 9292 => 'A', 2003 => 'A', 8701 => 'B'
);

# Initial intervals for registration of RPC callbacks and reading RPC queue
#
# X                      = Start RPC server
# X+HMCCU_INIT_INTERVAL1 = Register RPC callback
# X+HMCCU_INIT_INTERVAL2 = Read RPC Queue
#
my $HMCCU_INIT_INTERVAL0 = 12;
my $HMCCU_INIT_INTERVAL1 = 7;
my $HMCCU_INIT_INTERVAL2 = 5;

# Number of arguments in RPC events
my %rpceventargs = (
	"EV", 3,
	"ND", 6,
	"DD", 1,
	"RD", 2,
	"RA", 1,
	"UD", 2,
	"IN", 3,
	"EX", 3,
	"SL", 2,
	"ST", 10
);

# Datapoint operations
my $HMCCU_OPER_READ  = 1;
my $HMCCU_OPER_WRITE = 2;
my $HMCCU_OPER_EVENT = 4;

# Datapoint types
my $HMCCU_TYPE_BINARY  = 2;
my $HMCCU_TYPE_FLOAT   = 4;
my $HMCCU_TYPE_INTEGER = 16;
my $HMCCU_TYPE_STRING  = 20;

# Flags for CCU object specification
my $HMCCU_FLAG_NAME      = 1;
my $HMCCU_FLAG_CHANNEL   = 2;
my $HMCCU_FLAG_DATAPOINT = 4;
my $HMCCU_FLAG_ADDRESS   = 8;
my $HMCCU_FLAG_INTERFACE = 16;
my $HMCCU_FLAG_FULLADDR  = 32;

# Valid flag combinations
my $HMCCU_FLAGS_IACD = $HMCCU_FLAG_INTERFACE | $HMCCU_FLAG_ADDRESS |
	$HMCCU_FLAG_CHANNEL | $HMCCU_FLAG_DATAPOINT;
my $HMCCU_FLAGS_IAC = $HMCCU_FLAG_INTERFACE | $HMCCU_FLAG_ADDRESS |
	$HMCCU_FLAG_CHANNEL;
my $HMCCU_FLAGS_ACD = $HMCCU_FLAG_ADDRESS | $HMCCU_FLAG_CHANNEL |
	$HMCCU_FLAG_DATAPOINT;
my $HMCCU_FLAGS_AC = $HMCCU_FLAG_ADDRESS | $HMCCU_FLAG_CHANNEL;
my $HMCCU_FLAGS_ND = $HMCCU_FLAG_NAME | $HMCCU_FLAG_DATAPOINT;
my $HMCCU_FLAGS_NC = $HMCCU_FLAG_NAME | $HMCCU_FLAG_CHANNEL;
my $HMCCU_FLAGS_NCD = $HMCCU_FLAG_NAME | $HMCCU_FLAG_CHANNEL |
	$HMCCU_FLAG_DATAPOINT;

# Declare functions
sub HMCCU_Initialize ($);
sub HMCCU_Define ($$);
sub HMCCU_Undef ($$);
sub HMCCU_Shutdown ($);
sub HMCCU_Set ($@);
sub HMCCU_Get ($@);
sub HMCCU_Attr ($@);
sub HMCCU_AggregationRules ($$);
sub HMCCU_ExportDefaults ($);
sub HMCCU_ImportDefaults ($);
sub HMCCU_FindDefaults ($$);
sub HMCCU_SetDefaults ($);
sub HMCCU_GetDefaults ($$);
sub HMCCU_Notify ($$);
sub HMCCU_AggregateReadings ($$);
sub HMCCU_ParseObject ($$$);
sub HMCCU_FilterReading ($$$);
sub HMCCU_GetReadingName ($$$$$$$);
sub HMCCU_FormatReadingValue ($$);
sub HMCCU_SetError ($$);
sub HMCCU_SetState ($$);
sub HMCCU_Substitute ($$$$$);
sub HMCCU_SubstRule ($$$);
sub HMCCU_SubstVariables ($$);
sub HMCCU_UpdateClients ($$$$);
sub HMCCU_UpdateDeviceTable ($$);
sub HMCCU_UpdateSingleDatapoint ($$$$);
sub HMCCU_UpdateSingleDevice ($$$);
sub HMCCU_UpdateMultipleDevices ($$);
sub HMCCU_GetRPCPortList ($);
sub HMCCU_RPCRegisterCallback ($);
sub HMCCU_RPCDeRegisterCallback ($);
sub HMCCU_ResetCounters ($);
sub HMCCU_StartExtRPCServer ($);
sub HMCCU_StopExtRPCServer ($);
sub HMCCU_StartIntRPCServer ($);
sub HMCCU_StopRPCServer ($);
sub HMCCU_IsRPCStateBlocking ($);
sub HMCCU_IsRPCServerRunning ($$$);
sub HMCCU_GetDeviceInfo ($$$);
sub HMCCU_FormatDeviceInfo ($);
sub HMCCU_GetDeviceList ($);
sub HMCCU_GetDatapointList ($);
sub HMCCU_FindDatapoint ($$$$$);
sub HMCCU_GetAddress ($$$$);
sub HMCCU_IsDevAddr ($$);
sub HMCCU_IsChnAddr ($$);
sub HMCCU_SplitChnAddr ($);
sub HMCCU_GetCCUObjectAttribute ($$$);
sub HMCCU_FindClientDevices ($$$$);
sub HMCCU_GetRPCDevice ($$);
sub HMCCU_FindIODevice ($);
sub HMCCU_GetHash ($@);
sub HMCCU_GetAttribute ($$$$);
sub HMCCU_GetDatapointCount ($$$);
sub HMCCU_GetSpecialDatapoints ($$$$$);
sub HMCCU_GetAttrReadingFormat ($$);
sub HMCCU_GetAttrSubstitute ($$);
sub HMCCU_IsValidDeviceOrChannel ($$);
sub HMCCU_IsValidDevice ($$);
sub HMCCU_IsValidChannel ($$);
sub HMCCU_GetCCUDeviceParam ($$);
sub HMCCU_GetValidDatapoints ($$$$$);
sub HMCCU_GetSwitchDatapoint ($$$);
sub HMCCU_IsValidDatapoint ($$$$$);
sub HMCCU_GetMatchingDevices ($$$$);
sub HMCCU_GetDeviceName ($$$);
sub HMCCU_GetChannelName ($$$);
sub HMCCU_GetDeviceType ($$$);
sub HMCCU_GetDeviceChannels ($$$);
sub HMCCU_GetDeviceInterface ($$$);
sub HMCCU_ResetRPCQueue ($$);
sub HMCCU_ReadRPCQueue ($);
sub HMCCU_ProcessEvent ($$);
sub HMCCU_HMScript ($$);
sub HMCCU_BulkUpdate ($$$$);
sub HMCCU_GetDatapoint ($@);
sub HMCCU_SetDatapoint ($$$);
sub HMCCU_ScaleValue ($$$$);
sub HMCCU_GetVariables ($$);
sub HMCCU_SetVariable ($$$);
sub HMCCU_GetUpdate ($$$);
sub HMCCU_GetChannel ($$);
sub HMCCU_RPCGetConfig ($$$$);
sub HMCCU_RPCSetConfig ($$$);

# File queue functions
sub HMCCU_QueueOpen ($$);
sub HMCCU_QueueClose ($);
sub HMCCU_QueueReset ($);
sub HMCCU_QueueEnq ($$);
sub HMCCU_QueueDeq ($);

# Helper functions
sub HMCCU_GetHMState ($$$);
sub HMCCU_GetTimeSpec ($);
sub HMCCU_CalculateReading ($$$);
sub HMCCU_EncodeEPDisplay ($);

# Subprocess functions
sub HMCCU_CCURPC_Write ($$);
sub HMCCU_CCURPC_OnRun ($);
sub HMCCU_CCURPC_OnExit ();
sub HMCCU_CCURPC_NewDevicesCB ($$$);
sub HMCCU_CCURPC_DeleteDevicesCB ($$$);
sub HMCCU_CCURPC_UpdateDeviceCB ($$$$);
sub HMCCU_CCURPC_ReplaceDeviceCB ($$$$);
sub HMCCU_CCURPC_ReaddDevicesCB ($$$);
sub HMCCU_CCURPC_EventCB ($$$$$);
sub HMCCU_CCURPC_ListDevicesCB ($$);


##################################################
# Initialize module
##################################################

sub HMCCU_Initialize ($)
{
	my ($hash) = @_;

	$hash->{DefFn} = "HMCCU_Define";
	$hash->{UndefFn} = "HMCCU_Undef";
	$hash->{SetFn} = "HMCCU_Set";
	$hash->{GetFn} = "HMCCU_Get";
	$hash->{ReadFn} = "HMCCU_Read";
	$hash->{AttrFn} = "HMCCU_Attr";
	$hash->{NotifyFn} = "HMCCU_Notify";
	$hash->{ShutdownFn} = "HMCCU_Shutdown";
	$hash->{parseParams} = 1;

	$hash->{AttrList} = "stripchar stripnumber ccuackstate:0,1 ccuaggregate:textField-long".
		" ccudefaults rpcinterfaces:multiple-strict,".join(',',sort keys %HMCCU_RPC_PORT).
		" ccudef-hmstatevals:textField-long ccudef-substitute:textField-long".
		" ccudef-readingname:textField-long ccudef-readingfilter:textField-long".
		" ccudef-readingformat:name,namelc,address,addresslc,datapoint,datapointlc".
		" ccuflags:multiple-strict,extrpc,intrpc,dptnocheck,noagg,nohmstate ccureadings:0,1".
		" rpcdevice rpcinterval:2,3,5,7,10 rpcqueue".
		" rpcport:multiple-strict,".join(',',sort keys %HMCCU_RPC_NUMPORT).
		" rpcserver:on,off rpcserveraddr rpcserverport rpctimeout rpcevtimeout parfile substitute".
		" ccuget:Value,State ".
		$readingFnAttributes;
}

######################################################################
# Define device
######################################################################

sub HMCCU_Define ($$)
{
	my ($hash, $a, $h) = @_;
	my $name = $hash->{NAME};

	return "Specify CCU hostname or IP address as a parameter" if(scalar (@$a) < 3);
	
	$hash->{host} = $$a[2];
	$hash->{Clients} = ':HMCCUDEV:HMCCUCHN:HMCCURPC:';

	if (scalar (@$a) >= 4) {
		return "CCU number must be in range 1-9" if ($$a[3] < 1 || $$a[3] > 9);
		$hash->{CCUNum} = $$a[3];
	}
	else {
		# Count CCU devices
		my $ccucount = 0;
		foreach my $d (keys %defs) {
			my $ch = $defs{$d};
			next if (!exists ($ch->{TYPE}));
			$ccucount++ if ($ch->{TYPE} eq 'HMCCU' && $ch != $hash);
			$ccucount++ if ($ch->{TYPE} eq 'HMCCURPC' && $ch->{noiodev} == 1);
		}
		$hash->{CCUNum} = $ccucount+1;
	}

	$hash->{version} = $HMCCU_VERSION;
	$hash->{ccutype} = 'CCU2';
	$hash->{RPCState} = "stopped";

	Log3 $name, 1, "HMCCU: Device $name. Initialized version $HMCCU_VERSION";
	my ($devcnt, $chncnt) = HMCCU_GetDeviceList ($hash);
	Log3 $name, 1, "HMCCU: Read $devcnt devices with $chncnt channels read from CCU".$hash->{host};
	
	$hash->{hmccu}{evtime} = 0;
	$hash->{hmccu}{evtimeout} = 0;
	$hash->{hmccu}{updatetime} = 0;
	$hash->{hmccu}{rpccount} = 0;
	$hash->{hmccu}{rpcports} = $HMCCU_RPC_PORT_DEFAULT;

	readingsBeginUpdate ($hash);
	readingsBulkUpdate ($hash, "state", "Initialized");
	readingsBulkUpdate ($hash, "rpcstate", "stopped");
	readingsEndUpdate ($hash, 1);

	$attr{$name}{stateFormat} = "rpcstate/state";
	
	return undef;
}

######################################################################
# Set or delete attribute
######################################################################

sub HMCCU_Attr ($@)
{
	my ($cmd, $name, $attrname, $attrval) = @_;
	my $hash = $defs{$name};
	my $rc = 0;

	if ($cmd eq 'set') {
		if ($attrname eq 'ccudefaults') {
			$rc = HMCCU_ImportDefaults ($attrval);
			return HMCCU_SetError ($hash, -16) if ($rc == 0);
			if ($rc < 0) {
				$rc = -$rc;
				return HMCCU_SetError ($hash,
					"Syntax error in default attribute file $attrval line $rc");
			}
		}
		elsif ($attrname eq 'ccuaggregate') {
			$rc = HMCCU_AggregationRules ($hash, $attrval);
			return HMCCU_SetError ($hash, "Syntax error in attribute ccuaggregate") if ($rc == 0);
		}
		elsif ($attrname eq 'ccuflags') {
			my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
			if ($attrval =~ /extrpc/ && $attrval =~ /intrpc/) {
				return "Flags extrpc and inttpc cannot be combined";
			}
			if ($attrval =~ /(extrpc|intrpc)/) {
				my $rpcmode = $1;
				if ($ccuflags !~ /$rpcmode/) { 
					my @hm_pids = ();
					my @ex_pids = ();
					if (HMCCU_IsRPCServerRunning ($hash, \@hm_pids, \@ex_pids)) {
						return "Stop RPC server before switching between extrpc and intrpc";
					}
				}
			}
		}
		elsif ($attrname eq 'rpcdevice') {
			return "HMCCU: Can't find HMCCURPC device $attrval"
				if (!exists ($defs{$attrval}) || $defs{$attrval}->{TYPE} ne 'HMCCURPC');
			if (exists ($defs{$attrval}->{IODev})) {
				return "HMCCU: Device $attrval is not assigned to $name"
					if ($defs{$attrval}->{IODev} != $hash);
			}
			else {
				$defs{$attrval}->{IODev} = $hash;
			}
			$hash->{RPCDEV} = $attrval;
		}
		elsif ($attrname eq 'rpcinterfaces') {
			my @ports = split (',', $attrval);
			my @plist = ();
			foreach my $p (@ports) {
				return "Illegal RPC interface $p" if (!exists ($HMCCU_RPC_PORT{$p}));
				push (@plist, $HMCCU_RPC_PORT{$p});
			}
			return "No RPC interface specified" if (scalar (@plist) == 0);
			$hash->{hmccu}{rpcports} = join (',', @plist);
			$attr{$name}{"rpcport"} = $hash->{hmccu}{rpcports};
		}
		elsif ($attrname eq 'rpcport') {
			my @ports = split (',', $attrval);
			my @ilist = ();
			foreach my $p (@ports) {
				return "Illegal RPC port $p" if (!exists ($HMCCU_RPC_NUMPORT{$p}));
				push (@ilist, $HMCCU_RPC_NUMPORT{$p});
			}
			return "No RPC port specified" if (scalar (@ilist) == 0);
			$hash->{hmccu}{rpcports} = $attrval;
			$attr{$name}{"rpcinterfaces"} = join (',', @ilist);
		}
	}
	elsif ($cmd eq 'del') {
		if ($attrname eq 'ccuaggregate') {
			HMCCU_AggregationRules ($hash, '');			
		}
		elsif ($attrname eq 'rpcdevice') {
			delete $hash->{RPCDEV} if (exists ($hash->{RPCDEV}));
		}
		elsif ($attrname eq 'rpcport' || $attrname eq 'rpcinterfaces') {
			$hash->{hmccu}{rpcports} = $HMCCU_RPC_PORT_DEFAULT;
		}
	}
	
	return undef;
}

######################################################################
# Parse aggregation rules for readings.
# Syntax of aggregation rule is:
# FilterSpec[;...]
# FilterSpec := {Name|Filt|Read|Cond|Else|Pref|Coll}[,...]
# Name := name:Name
# Filt := filter:{name|type|group|room|alias}=Regexp[!Regexp]
# Read := read:Regexp
# Cond := if:{any|all|min|max|sum|avg|gt|lt|ge|le}=Value
# Else := else:Value
# Pref := prefix:{RULE|Prefix}
# Coll := coll:{NAME|Attribute}
######################################################################

sub HMCCU_AggregationRules ($$)
{
	my ($hash, $rulestr) = @_;
	my $name = $hash->{NAME};

	# Delete existing aggregation rules
	if (exists ($hash->{hmccu}{agg})) {
		delete $hash->{hmccu}{agg};
	}
	return if ($rulestr eq '');
	
	my @opts = ('name', 'filter', 'if', 'else');

	# Extract aggregation rules
	my $cnt = 0;
	my @rules = split (/[;\n]+/, $rulestr);
	foreach my $r (@rules) {
		$cnt++;
		
		# Set default rule parameters
		my %opt = (
			'read' => 'state',
			prefix => 'RULE',
			coll   => 'NAME'
		);

		# Parse aggregation rule
		my @specs = split (',', $r);		
		foreach my $spec (@specs) {
			if ($spec =~ /^(name|filter|read|if|else|prefix|coll):(.+)$/) {
				$opt{$1} = $2;
			}
		}
		
		# Check if rule syntax is correct
		foreach my $o (@opts) {
			if (!exists ($opt{$o})) {
				Log3 $name, 1, "HMCCU: Parameter $o is missing in aggregation rule $cnt.";
				return 0;
			}
		}
		
		my $fname = $opt{name};
		my ($fincl, $fexcl) = split ('!', $opt{filter});
		my ($ftype, $fexpr) = split ('=', $fincl);
		return 0 if (!defined ($fexpr));
		my ($fcond, $fval) = split ('=', $opt{if});
		return 0 if (!defined ($fval));
		my ($fcoll, $fdflt) = split ('!', $opt{coll});
		$fdflt = 'no match' if (!defined ($fdflt));

		$hash->{hmccu}{agg}{$fname}{ftype} = $ftype;
		$hash->{hmccu}{agg}{$fname}{fexpr} = $fexpr;
		$hash->{hmccu}{agg}{$fname}{fexcl} = (defined ($fexcl) ? $fexcl : '');
		$hash->{hmccu}{agg}{$fname}{fread} = $opt{'read'};
		$hash->{hmccu}{agg}{$fname}{fcond} = $fcond;
		$hash->{hmccu}{agg}{$fname}{ftrue} = $fval;
		$hash->{hmccu}{agg}{$fname}{felse} = $opt{'else'};
		$hash->{hmccu}{agg}{$fname}{fpref} = $opt{prefix} eq 'RULE' ? $fname : $opt{prefix};
		$hash->{hmccu}{agg}{$fname}{fcoll} = $fcoll;
		$hash->{hmccu}{agg}{$fname}{fdflt} = $fdflt;
	}
	
	return 1;
}

######################################################################
# Export default attributes.
######################################################################

sub HMCCU_ExportDefaults ($)
{
	my ($filename) = @_;

	return 0 if (!open (DEFFILE, ">$filename"));

	print DEFFILE "# HMCCU default attributes for channels\n";
	foreach my $t (keys %{$HMCCU_CHN_DEFAULTS}) {
		print DEFFILE "\nchannel:$t\n";
		foreach my $a (sort keys %{$HMCCU_CHN_DEFAULTS->{$t}}) {
			print DEFFILE "$a=".$HMCCU_CHN_DEFAULTS->{$t}{$a}."\n";
		}
	}

	print DEFFILE "\n# HMCCU default attributes for devices\n";
	foreach my $t (keys %{$HMCCU_DEV_DEFAULTS}) {
		print DEFFILE "\ndevice:$t\n";
		foreach my $a (sort keys %{$HMCCU_DEV_DEFAULTS->{$t}}) {
			print DEFFILE "$a=".$HMCCU_DEV_DEFAULTS->{$t}{$a}."\n";
		}
	}

	close (DEFFILE);

	return 1;
}

######################################################################
# Import customer default attributes
# Returns 1 on success. Returns negative line number on syntax errors.
# Returns 0 on file open error.
######################################################################
 
sub HMCCU_ImportDefaults ($)
{
	my ($filename) = @_;
	my $modtype = '';
	my $ccutype = '';
	my $line = 0;

	return 0 if (!open (DEFFILE, "<$filename"));
	my @defaults = <DEFFILE>;
	close (DEFFILE);
	chomp (@defaults);

	%HMCCU_CUST_CHN_DEFAULTS = ();
	%HMCCU_CUST_DEV_DEFAULTS = ();
	
	foreach my $d (@defaults) {
		$line++;
		next if ($d eq '' || $d =~ /^#/);

		if ($d =~ /^(channel|device):/) {
			my @t = split (':', $d, 2);
			if (scalar (@t) != 2) {
				close (DEFFILE);
				return -$line;
			}
			$modtype = $t[0];
			$ccutype = $t[1];
			next;
		}

		if ($ccutype eq '' || $modtype eq '') {
			close (DEFFILE);
			return -$line;
		}

		my @av = split ('=', $d, 2);
		if (scalar (@av) != 2) {
			close (DEFFILE);
			return -$line;
		}

		if ($modtype eq 'channel') {
			$HMCCU_CUST_CHN_DEFAULTS{$ccutype}{$av[0]} = $av[1];
		}
		else {
			$HMCCU_CUST_DEV_DEFAULTS{$ccutype}{$av[0]} = $av[1];
		}
	}

	return 1;
}

######################################################################
# Find default attributes
# Return template reference.
######################################################################

sub HMCCU_FindDefaults ($$)
{
	my ($hash, $common) = @_;
	my $type = $hash->{TYPE};
	my $ccutype = $hash->{ccutype};

	if ($type eq 'HMCCUCHN') {
		my ($adr, $chn) = split (':', $hash->{ccuaddr});

		if ($common) {
			return \%{$HMCCU_CUST_CHN_DEFAULTS{COMMON}} if (exists ($HMCCU_CUST_CHN_DEFAULTS{COMMON}));
			return \%{$HMCCU_CHN_DEFAULTS->{COMMON}} if (exists ($HMCCU_CHN_DEFAULTS->{COMMON}));
		}
		
		foreach my $deftype (keys %HMCCU_CUST_CHN_DEFAULTS) {
			my @chnlst = split (',', $HMCCU_CUST_CHN_DEFAULTS{$deftype}{_channels});
			return \%{$HMCCU_CUST_CHN_DEFAULTS{$deftype}}
				if ($ccutype =~ /^($deftype)$/i && grep { $_ eq $chn} @chnlst);
		}
		
		foreach my $deftype (keys %{$HMCCU_CHN_DEFAULTS}) {
			my @chnlst = split (',', $HMCCU_CHN_DEFAULTS->{$deftype}{_channels});
			return \%{$HMCCU_CHN_DEFAULTS->{$deftype}}
				if ($ccutype =~ /^($deftype)$/i && grep { $_ eq $chn} @chnlst);
		}
	}
	elsif ($type eq 'HMCCUDEV' || $type eq 'HMCCU') {
		if ($common) {
			return \%{$HMCCU_CUST_DEV_DEFAULTS{COMMON}} if (exists ($HMCCU_CUST_DEV_DEFAULTS{COMMON}));
			return \%{$HMCCU_DEV_DEFAULTS->{COMMON}} if (exists ($HMCCU_DEV_DEFAULTS->{COMMON}));
		}

		foreach my $deftype (keys %HMCCU_CUST_DEV_DEFAULTS) {
			return \%{$HMCCU_CUST_DEV_DEFAULTS{$deftype}} if ($ccutype =~ /^($deftype)$/i);
		}

		foreach my $deftype (keys %{$HMCCU_DEV_DEFAULTS}) {
			return \%{$HMCCU_DEV_DEFAULTS->{$deftype}} if ($ccutype =~ /^($deftype)$/i);
		}
	}

	return undef;	
}

############################################################
# Set default attributes from template
############################################################

sub HMCCU_SetDefaultsTemplate ($$)
{
	my ($hash, $template) = @_;
	my $name = $hash->{NAME};
	
	foreach my $a (keys %{$template}) {
		next if ($a =~ /^_/);
		my $v = $template->{$a};
		CommandAttr (undef, "$name $a $v");
	}
}

############################################################
# Set default attributes
############################################################

sub HMCCU_SetDefaults ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	# Set common attributes
	my $template = HMCCU_FindDefaults ($hash, 1);
	HMCCU_SetDefaultsTemplate ($hash, $template) if (defined ($template));

	# Set type specific attributes	
	$template = HMCCU_FindDefaults ($hash, 0);
	return 0 if (!defined ($template));
	
	HMCCU_SetDefaultsTemplate ($hash, $template);
	return 1;
}

############################################################
# List default attributes for device type (mode = 0) or all
# device types (mode = 1) with default attributes available.
############################################################

sub HMCCU_GetDefaults ($$)
{
	my ($hash, $mode) = @_;
	my $name = $hash->{NAME};
	my $type = $hash->{TYPE};
	my $ccutype = $hash->{ccutype};
	my $result = '';
	my $deffile = '';
	
# 	my $template = HMCCU_FindDefaults ($hash, 1);
# 	if (defined ($template)) {
# 		foreach my $a (keys %{$template}) {
# 			next if ($a =~ /^_/);
# 			my $v = $template->{$a};
# 			$result .= $a." = ".$v."\n";
# 		}
# 	}
	
	if ($mode == 0) {
		my $template = HMCCU_FindDefaults ($hash, 0);
		return ($result eq '' ? "No default attributes defined" : $result) if (!defined ($template));
	
		foreach my $a (keys %{$template}) {
			next if ($a =~ /^_/);
			my $v = $template->{$a};
			$result .= $a." = ".$v."\n";
		}
	}
	else {
		$result = "HMCCU Channels:\n------------------------------\n";
		foreach my $deftype (sort keys %{$HMCCU_CHN_DEFAULTS}) {
			my $tlist = $deftype;
			$tlist =~ s/\|/,/g;
			$result .= $HMCCU_CHN_DEFAULTS->{$deftype}{_description}." ($tlist), channels ".
				$HMCCU_CHN_DEFAULTS->{$deftype}{_channels}."\n";
		}
		$result .= "\nHMCCU Devices:\n------------------------------\n";
		foreach my $deftype (sort keys %{$HMCCU_DEV_DEFAULTS}) {
			my $tlist = $deftype;
			$tlist =~ s/\|/,/g;
			$result .= $HMCCU_DEV_DEFAULTS->{$deftype}{_description}." ($tlist)\n";
		}
		$result .= "\nCustom Channels:\n-----------------------------\n";
		foreach my $deftype (sort keys %HMCCU_CUST_CHN_DEFAULTS) {
			my $tlist = $deftype;
			$tlist =~ s/\|/,/g;
			$result .= $HMCCU_CUST_CHN_DEFAULTS{$deftype}{_description}." ($tlist), channels ".
				$HMCCU_CUST_CHN_DEFAULTS{$deftype}{_channels}."\n";
		}
		$result .= "\nCustom Devices:\n-----------------------------\n";
		foreach my $deftype (sort keys %HMCCU_CUST_DEV_DEFAULTS) {
			my $tlist = $deftype;
			$tlist =~ s/\|/,/g;
			$result .= $HMCCU_CUST_DEV_DEFAULTS{$deftype}{_description}." ($tlist)\n";
		}
	}
	
	return $result;	
}

######################################################################
# Handle FHEM events
######################################################################

sub HMCCU_Notify ($$)
{
	my ($hash, $devhash) = @_;
	my $name = $hash->{NAME};
	my $devname = $devhash->{NAME};
	my $devtype = $devhash->{TYPE};

	my $disable = AttrVal ($name, 'disable', 0);
	my $rpcserver = AttrVal ($name, 'rpcserver', 'off');
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');

	return if ($disable);
		
	my $events = deviceEvents ($devhash, 1);
	return if (! $events);

	# Process events
	foreach my $event (@{$events}) {	
		if ($devname eq 'global') {
			if ($event eq 'INITIALIZED') {
				return if ($rpcserver eq 'off');
				my $delay = $HMCCU_INIT_INTERVAL0;
				Log3 $name, 0, "HMCCU: Start of RPC server after FHEM initialization in $delay seconds";
				if ($ccuflags =~ /extrpc/) {
					InternalTimer (gettimeofday()+$delay, "HMCCU_StartExtRPCServer", $hash, 0);
				}
				else {
					InternalTimer (gettimeofday()+$delay, "HMCCU_StartIntRPCServer", $hash, 0);
				}
			}
		}
		else {
			return if ($devtype ne 'HMCCUDEV' && $devtype ne 'HMCCUCHN');
			my ($r, $v) = split (": ", $event);
			return if (!defined ($v));
			my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
			return if ($ccuflags =~ /noagg/);

			foreach my $rule (keys %{$hash->{hmccu}{agg}}) {
				my $ftype = $hash->{hmccu}{agg}{$rule}{ftype};
				my $fexpr = $hash->{hmccu}{agg}{$rule}{fexpr};
				my $fread = $hash->{hmccu}{agg}{$rule}{fread};
				next if ($r !~ $fread);
				next if ($ftype eq 'name' && $devname !~ /$fexpr/);
				next if ($ftype eq 'type' && $devhash->{ccutype} !~ /$fexpr/);
				next if ($ftype eq 'group' && AttrVal ($devname, 'group', 'null') !~ /$fexpr/);
				next if ($ftype eq 'room' && AttrVal ($devname, 'room', 'null') !~ /$fexpr/);
				next if ($ftype eq 'alias' && AttrVal ($devname, 'alias', 'null') !~ /$fexpr/);
			
				HMCCU_AggregateReadings ($hash, $rule);
			}
		}
	}

	return;
}

######################################################################
# Calculate reading aggregation.
# Called by Notify or via command get aggregation.
######################################################################

sub HMCCU_AggregateReadings ($$)
{
	my ($hash, $rule) = @_;
	
	my $dc = 0;
	my $mc = 0;
	my $result = '';
	my $rl = '';

	# Get rule parameters
	my $ftype = $hash->{hmccu}{agg}{$rule}{ftype};
	my $fexpr = $hash->{hmccu}{agg}{$rule}{fexpr};
	my $fexcl = $hash->{hmccu}{agg}{$rule}{fexcl};
	my $fread = $hash->{hmccu}{agg}{$rule}{fread};
#	my $fcoll = $hash->{hmccu}{agg}{$rule}{fcoll};
	my $fcond = $hash->{hmccu}{agg}{$rule}{fcond};
	my $ftrue = $hash->{hmccu}{agg}{$rule}{ftrue};
	my $felse = $hash->{hmccu}{agg}{$rule}{felse};
	my $fpref = $hash->{hmccu}{agg}{$rule}{fpref};

	my $resval;
	$resval = $ftrue if ($fcond =~ /^(max|min|sum|avg)$/);
	
	my @devlist = HMCCU_FindClientDevices ($hash, "(HMCCUDEV|HMCCUCHN)", undef, undef);
	foreach my $d (@devlist) {
		my $ch = $defs{$d};
		my $cn = $ch->{NAME};
		my $ct = $ch->{TYPE};
		
		my $fmatch = '';
		$fmatch = $cn if ($ftype eq 'name');
		$fmatch = $ch->{ccutype} if ($ftype eq 'type');
		$fmatch = AttrVal ($cn, 'group', '') if ($ftype eq 'group');
		$fmatch = AttrVal ($cn, 'room', '') if ($ftype eq 'room');
		$fmatch = AttrVal ($cn, 'alias', '') if ($ftype eq 'alias');		
		next if ($fmatch eq '' || $fmatch !~ /$fexpr/ || ($fexcl ne '' && $fmatch =~ /$fexcl/));
		
		my $fcoll = $hash->{hmccu}{agg}{$rule}{fcoll} eq 'NAME' ?
			$cn : AttrVal ($cn, $hash->{hmccu}{agg}{$rule}{fcoll}, $cn);
		
		# Compare readings
		my $f = 0;
		foreach my $r (keys %{$ch->{READINGS}}) {
			next if ($r !~ /$fread/);
			my $rv = $ch->{READINGS}{$r}{VAL};
			if (($fcond eq 'any' || $fcond eq 'all') && $rv =~ /$ftrue/) {
				$mc++;
				$rl .= ($mc > 1 ? ",$fcoll" : $fcoll);
				last;
			}
			if ($fcond eq 'max' && $rv > $resval) {
				$resval = $rv;
				$mc = 1;
				$rl = $fcoll;
				last;
			}
			if ($fcond eq 'min' && $rv < $resval) {
				$resval = $rv;
				$mc = 1;
				$rl = $fcoll;
				last;
			}
			if ($fcond eq 'sum' || $fcond eq 'avg') {
				$resval += $rv;
				$mc++;
				$f = 1;
				last;
			}
			if (($fcond eq 'gt' && $rv > $ftrue) ||
			    ($fcond eq 'lt' && $rv < $ftrue) ||
			    ($fcond eq 'ge' && $rv >= $ftrue) ||
			    ($fcond eq 'le' && $rv <= $ftrue)) {
				$mc++;
				$rl .= ($mc > 1 ? ",$fcoll" : $fcoll);
				last;
			}
		}
		$dc++;
	}
	
	$rl =  $hash->{hmccu}{agg}{$rule}{fdflt} if ($rl eq '');
	if ($fcond eq 'any') {
		$result = $mc > 0 ? $ftrue : $felse;
	}
	elsif ($fcond eq 'all') {
		$result = $mc == $dc ? $ftrue : $felse;
	}
	elsif ($fcond eq 'min' || $fcond eq 'max' || $fcond eq 'sum') {
		$result = $mc > 0 ? $resval : $felse;
	}
	elsif ($fcond eq 'avg') {
		$result = $mc > 0 ? $resval/$mc : $felse;
	}
	elsif ($fcond =~ /^(gt|lt|ge|le)$/) {
		$result = $mc;
	}
	
	# Set readings
	readingsBeginUpdate ($hash);
	readingsBulkUpdate ($hash, $fpref.'state', $result);
	readingsBulkUpdate ($hash, $fpref.'match', $mc);
	readingsBulkUpdate ($hash, $fpref.'count', $dc);
	readingsBulkUpdate ($hash, $fpref.'list', $rl);
	readingsEndUpdate ($hash, 1);
	
	return $result;
}

######################################################################
# Delete device
######################################################################

sub HMCCU_Undef ($$)
{
	my ($hash, $arg) = @_;

	# Shutdown RPC server
	HMCCU_Shutdown ($hash);

	# Delete reference to IO module in client devices
	my @keylist = keys %defs;
	foreach my $d (@keylist) {
		if (exists ($defs{$d}) && exists($defs{$d}{IODev}) &&
		    $defs{$d}{IODev} == $hash) {
        		delete $defs{$d}{IODev};
		}
	}

	return undef;
}

######################################################################
# Shutdown FHEM
######################################################################

sub HMCCU_Shutdown ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	
	# Shutdown RPC server
	if ($ccuflags =~ /extrpc/) {
		HMCCU_StopExtRPCServer ($hash);
	}
	else {
		HMCCU_StopRPCServer ($hash);
	}
	
	# Remove existing timer functions
	RemoveInternalTimer ($hash);

	return undef;
}

######################################################################
# Set commands
######################################################################

sub HMCCU_Set ($@)
{
	my ($hash, $a, $h) = @_;
	my $name = shift @$a;
	my $opt = shift @$a;
	my $options = "var execute hmscript cleardefaults:noArg defaults:noArg ".
		"importdefaults rpcserver:on,off";
	my $host = $hash->{host};

	if ($opt ne 'rpcserver' && HMCCU_IsRPCStateBlocking ($hash)) {
		HMCCU_SetState ($hash, "busy");
		return "HMCCU: CCU busy, choose one of rpcserver:off";
	}

	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	$options .= ",restart" if ($ccuflags =~ /intrpc/);
	my $stripchar = AttrVal ($name, "stripchar", '');
	my $ccureadings = AttrVal ($name, "ccureadings", 1);
	my $readingformat = HMCCU_GetAttrReadingFormat ($hash, $hash);
	my $substitute = HMCCU_GetAttrSubstitute ($hash, $hash);

	if ($opt eq 'var') {
		my $objname = shift @$a;
		my $objvalue = shift @$a;
		my $result;

		return HMCCU_SetError ($hash, "Usage: set $name $opt {ccuobject} {value}")
			if (!defined ($objname) || !defined ($objvalue));

		$objname =~ s/$stripchar$// if ($stripchar ne '');
		$objvalue =~ s/\\_/%20/g;

		$result = HMCCU_SetVariable ($hash, $objname, $objvalue);

		return HMCCU_SetError ($hash, $result) if ($result < 0);
		return HMCCU_SetState ($hash, "OK");
	}
	elsif ($opt eq "execute") {
		my $program = shift @$a;
		my $response;

		return HMCCU_SetError ($hash, "Usage: set $name execute {program-name}")
			if (!defined ($program));

		my $url = qq(http://$host:8181/do.exe?r1=dom.GetObject("$program").ProgramExecute());
		$response = GetFileFromURL ($url);
		$response =~ m/<r1>(.*)<\/r1>/;
		my $value = $1;
		if (defined ($value) && $value ne '' && $value ne 'null') {
			return HMCCU_SetState ($hash, "OK");
		}
		else {
			return HMCCU_SetError ($hash, "Program execution error");
		}
	}
	elsif ($opt eq 'hmscript') {
		my $scrfile = shift @$a;
		my $dump = shift @$a;
		my $script;
		my $response;
		my %objects = ();
		my $objcount = 0;

		return HMCCU_SetError ($hash, "Usage: set $name hmscript {scriptfile} [dump] [parname=value [...]]")
			if (!defined ($scrfile) || (defined ($dump) && $dump ne 'dump'));
			
		if (open (SCRFILE, "<$scrfile")) {
			my @lines = <SCRFILE>;
			$script = join ("\n", @lines);
			close (SCRFILE);
		}
		else {
			return HMCCU_SetError ($hash, -16);
		}

		# Replace variables
		foreach my $svar (keys %{$h}) {
			next if ($script !~ /\$$svar/);
			$script =~ s/\$$svar/$h->{$svar}/g;
		}
		
		$response = HMCCU_HMScript ($hash, $script);
		return HMCCU_SetError ($hash, -2) if ($response eq '');

		HMCCU_SetState ($hash, "OK");
		return $response if (! $ccureadings);

		foreach my $line (split /\n/, $response) {
			my @tokens = split /=/, $line;
			next if (@tokens != 2);
			my $reading;
			my ($int, $add, $chn, $dpt, $nam, $flags) = HMCCU_ParseObject ($hash, $tokens[0],
				$HMCCU_FLAG_INTERFACE);
			($add, $chn) = HMCCU_GetAddress ($hash, $nam, '', '') if ($flags == $HMCCU_FLAGS_NCD);
			
			if ($flags == $HMCCU_FLAGS_IACD || $flags == $HMCCU_FLAGS_NCD) {
				$objects{$add}{$chn}{$dpt} = $tokens[1];
				$objcount++;
			}
			else {
				# If output is not related to a channel store reading in I/O device
				my $Value = HMCCU_Substitute ($tokens[1], $substitute, 0, undef, $tokens[0]);
				readingsSingleUpdate ($hash, $tokens[0], $Value, 1);
			}
		}
		
		HMCCU_UpdateMultipleDevices ($hash, \%objects) if ($objcount > 0);

		return defined ($dump) ? $response : undef;
	}
	elsif ($opt eq 'rpcserver') {
		my $action = shift @$a;

		return HMCCU_SetError ($hash, "Usage: set $name rpcserver {on|off|restart}")
		   if (!defined ($action) || $action !~ /^(on|off|restart)$/);
		   
		if ($action eq 'on') {
			if ($ccuflags =~ /extrpc/) {
				return HMCCU_SetError ($hash, "Start of RPC server failed")
				   if (!HMCCU_StartExtRPCServer ($hash));
			}
			else {
				return HMCCU_SetError ($hash, "Start of RPC server failed")
				   if (!HMCCU_StartIntRPCServer ($hash));
			}
		}
		elsif ($action eq 'off') {
			if ($ccuflags =~ /extrpc/) {
				return HMCCU_SetError ($hash, "Stop of RPC server failed")
					if (!HMCCU_StopExtRPCServer ($hash));
			}
			else {
				return HMCCU_SetError ($hash, "Stop of RPC server failed")
					if (!HMCCU_StopRPCServer ($hash));
			}
		}
		elsif ($action eq 'restart') {
			my @hm_pids;
			my @ex_pids;
			return "HMCCU: RPC server not running"
			   if (!HMCCU_IsRPCServerRunning ($hash, \@hm_pids, \@ex_pids));
			
			if ($ccuflags =~ /intrpc/) {
				return "HMCCU: Can't stop RPC server" if (!HMCCURPC_StopRPCServer ($hash));
				$hash->{RPCState} = "restarting";
				readingsSingleUpdate ($hash, "rpcstate", "restarting", 1);
				DoTrigger ($name, "RPC server restarting");
			}
			else {
				return HMCCU_SetError ($hash, "HMCCU: restart not supported by external RPC server");
			}
		}
		
		return HMCCU_SetState ($hash, "OK");
	}
	elsif ($opt eq 'defaults') {
		my $rc = HMCCU_SetDefaults ($hash);
		return HMCCU_SetError ($hash, "HMCCU: No default attributes found") if ($rc == 0);
		return HMCCU_SetState ($hash, "OK");
	}
	elsif ($opt eq 'cleardefaults') {
		%HMCCU_CUST_CHN_DEFAULTS = ();
		%HMCCU_CUST_DEV_DEFAULTS = ();
		
		return "Default attributes deleted";
	}
	elsif ($opt eq 'importdefaults') {
		my $filename = shift @$a;

		return HMCCU_SetError ($hash, "Usage: set $name importdefaults {filename}")
			if (!defined ($filename));
			
		my $rc = HMCCU_ImportDefaults ($filename);
		return HMCCU_SetError ($hash, -16) if ($rc == 0);
		if ($rc < 0) {
			$rc = -$rc;
			return HMCCU_SetError ($hash, "Syntax error in default attribute file $filename line $rc");
		}
		
		HMCCU_SetState ($hash, "OK");
		return "Default attributes read from file $filename";
	}
	else {
		return "HMCCU: Unknown argument $opt, choose one of ".$options;
	}
}

######################################################################
# Get commands
######################################################################

sub HMCCU_Get ($@)
{
	my ($hash, $a, $h) = @_;
	my $name = shift @$a;
	my $opt = shift @$a;
	my $options = "defaults:noArg exportdefaults devicelist dump vars update updateccu parfile".
		" configdesc rpcevents:noArg rpcstate:noArg deviceinfo";
	my $host = $hash->{host};

	if ($opt ne 'rpcstate' && HMCCU_IsRPCStateBlocking ($hash)) {
		HMCCU_SetState ($hash, "busy");
		return "HMCCU: CCU busy, choose one of rpcstate:noArg";
	}

	my $ccuflags = AttrVal ($name, "ccuflags", "null");
	my $ccureadings = AttrVal ($name, "ccureadings", 1);
	my $parfile = AttrVal ($name, "parfile", '');

	my $readname;
	my $readaddr;
	my $result = '';
	my $rc;

	if ($opt eq 'dump') {
		my $content = shift @$a;
		my $filter = shift @$a;
		$filter = '.*' if (!defined ($filter));
		
		my %foper = (1, "R", 2, "W", 4, "E", 3, "RW", 5, "RE", 6, "WE", 7, "RWE");
		my %ftype = (2, "B", 4, "F", 16, "I", 20, "S");
		
		return HMCCU_SetError ($hash, "Usage: get $name dump {datapoints|devtypes} [filter]")
		   if (!defined ($content));
		
		if ($content eq 'devtypes') {
			foreach my $devtype (sort keys %{$hash->{hmccu}{dp}}) {
				$result .= $devtype."\n" if ($devtype =~ /$filter/);
			}
		}
		elsif ($content eq 'datapoints') {
			foreach my $devtype (sort keys %{$hash->{hmccu}{dp}}) {
				next if ($devtype !~ /$filter/);
				foreach my $chn (sort keys %{$hash->{hmccu}{dp}{$devtype}{ch}}) {
					foreach my $dpt (sort keys %{$hash->{hmccu}{dp}{$devtype}{ch}{$chn}}) {
						my $t = $hash->{hmccu}{dp}{$devtype}{ch}{$chn}{$dpt}{type};
						my $o = $hash->{hmccu}{dp}{$devtype}{ch}{$chn}{$dpt}{oper};
						$result .= $devtype.".".$chn.".".$dpt." [".
						   (exists($ftype{$t}) ? $ftype{$t} : $t)."] [".
						   (exists($foper{$o}) ? $foper{$o} : $o)."]\n";
					}
				}
			}
		}
		else {
			return HMCCU_SetError ($hash, "Usage: get $name dump {datapoints|devtypes} [{filter}]");
		}
		
		return "No data found" if ($result eq '');
		return $result;
	}
	elsif ($opt eq 'vars') {
		my $varname = shift @$a;

		return HMCCU_SetError ($hash, "Usage: get $name vars {regexp}[,...]")
		   if (!defined ($varname));

		($rc, $result) = HMCCU_GetVariables ($hash, $varname);
		return HMCCU_SetError ($hash, $rc) if ($rc < 0);

		HMCCU_SetState ($hash, "OK");
		return $ccureadings ? undef : $result;
	}
	elsif ($opt eq 'update' || $opt eq 'updateccu') {
		my $devexp = shift @$a;
		$devexp = '.*' if (!defined ($devexp));
		my $ccuget = shift @$a;
		$ccuget = 'Attr' if (!defined ($ccuget));
		return HMCCU_SetError ($hash, "Usage: get $name $opt [device-expr [{'State'|'Value'}]]")
			if ($ccuget !~ /^(Attr|State|Value)$/);

		my ($c_ok, $c_err) = HMCCU_UpdateClients ($hash, $devexp, $ccuget,
			($opt eq 'updateccu') ? 1 : 0);

		HMCCU_SetState ($hash, "OK");
		return "$c_ok client devices successfully updated. Update for $c_err client devices failed";
	}
	elsif ($opt eq 'parfile') {
		my $par_parfile = shift @$a;
		my @parameters;
		my $parcount;

		if (defined ($par_parfile)) {
			$parfile = $par_parfile;
		}
		else {
			return HMCCU_SetError ($hash, "No parameter file specified") if ($parfile eq '');
		}

		# Read parameter file
		if (open (PARFILE, "<$parfile")) {
			@parameters = <PARFILE>;
			$parcount = scalar @parameters;
			close (PARFILE);
		}
		else {
			return HMCCU_SetError ($hash, -16);
		}

		return HMCCU_SetError ($hash, "Empty parameter file") if ($parcount < 1);

		($rc, $result) = HMCCU_GetChannel ($hash, \@parameters);
		return HMCCU_SetError ($hash, $rc) if ($rc < 0);

		HMCCU_SetState ($hash, "OK");
		return $ccureadings ? undef : $result;
	}
	elsif ($opt eq 'deviceinfo') {
		my $device = shift @$a;

		return HMCCU_SetError ($hash, "Usage: get $name deviceinfo {device} [{'State'|'Value'}]")
		   if (!defined ($device));

		my $ccuget = shift @$a;
		$ccuget = 'Attr' if (!defined ($ccuget));
		return HMCCU_SetError ($hash, "Usage: get $name deviceinfo {device} [{'State'|'Value'}]")
		   if ($ccuget !~ /^(Attr|State|Value)$/);

		return HMCCU_SetError ($hash, -1) if (!HMCCU_IsValidDeviceOrChannel ($hash, $device));
		$result = HMCCU_GetDeviceInfo ($hash, $device, $ccuget);
		return HMCCU_SetError ($hash, -2) if ($result eq '');
		return HMCCU_FormatDeviceInfo ($result);
	}
	elsif ($opt eq 'rpcevents') {
		if ($ccuflags =~ /intrpc/) {
			return HMCCU_SetError ($hash, "No event statistics available")
				if (!exists ($hash->{hmccu}{evs}) || !exists ($hash->{hmccu}{evr}));
			foreach my $stkey (sort keys %{$hash->{hmccu}{evr}}) {
				$result .= "S: ".$stkey." = ".$hash->{hmccu}{evs}{$stkey}."\n";
				$result .= "R: ".$stkey." = ".$hash->{hmccu}{evr}{$stkey}."\n";
			}
			return $result;
		}
		return HMCCU_SetError ($hash, "HMCCU: command not supported for external RPC server");
	}
	elsif ($opt eq 'rpcstate') {
		my @hm_pids = ();
		my @ex_pids = ();
		if (HMCCU_IsRPCServerRunning ($hash, \@hm_pids, \@ex_pids)) {
			return "RPC process(es) running with pid(s) ".
				join (',', @hm_pids) if (scalar (@hm_pids) > 0);
			return "RPC thread(s) running with tid(s) ".
				join (',', @ex_pids) if (scalar (@ex_pids) > 0);
		}
		return "No RPC processes or threads are running";
	}
	elsif ($opt eq 'devicelist') {
		my ($devcount, $chncount) = HMCCU_GetDeviceList ($hash);
		return HMCCU_SetError ($hash, -2) if ($devcount < 0);
		return HMCCU_SetError ($hash, "No devices received from CCU") if ($devcount == 0);
		$result = "Read $devcount devices with $chncount channels from CCU";

		my $optcmd = shift @$a;
		if (defined ($optcmd)) {
			if ($optcmd eq 'dump') {
				$result .= "\n-----------------------------------------\n";
				my $n = 0;
				foreach my $add (sort keys %{$hash->{hmccu}{dev}}) {
					if ($hash->{hmccu}{dev}{$add}{addtype} eq 'dev') {
						$result .= "Device ".'"'.$hash->{hmccu}{dev}{$add}{name}.'"'." [".$add."] ".
							"Type=".$hash->{hmccu}{dev}{$add}{type}."\n";
						$n = 0;
					}
					else {
						$result .= "  Channel $n ".'"'.$hash->{hmccu}{dev}{$add}{name}.'"'.
							" [".$add."]\n";
						$n++;
					}
				}
				return $result;
			}
			elsif ($optcmd eq 'create') {
				my $devprefix = exists ($h->{p}) ? $h->{p} : '';
				my $devsuffix = exists ($h->{'s'}) ? $h->{'s'} : '';
				my $devtype = exists ($h->{t}) ? $h->{t} : 'dev';
				my $devformat = exists ($h->{f}) ? $h->{f} : '%n';
				my $devdefaults = 0;
				my $newcount = 0;
				my @devattr;
				
				my $devspec = shift @$a;
				return "Please specify expression for CCU device or channel names"
					if (!defined ($devspec));

				foreach my $defopt (@$a) {
					if ($defopt eq 'defattr') {
						$devdefaults = 1;
					}
					else {
						push (@devattr, $defopt);
					}
				}
				
				foreach my $add (sort keys %{$hash->{hmccu}{dev}}) {
					my $defmod = $hash->{hmccu}{dev}{$add}{addtype} eq 'dev' ? 'HMCCUDEV' : 'HMCCUCHN';
					my $ccuname = $hash->{hmccu}{dev}{$add}{name};	
					my $ccudevname = HMCCU_GetDeviceName ($hash, $add, $ccuname);
					next if ($devtype ne 'all' && $devtype ne $hash->{hmccu}{dev}{$add}{addtype});
					next if ($ccuname !~ /$devspec/);
					my $devname = $devformat;
					$devname = $devprefix.$devname.$devsuffix;
					$devname =~ s/%n/$ccuname/g;
					$devname =~ s/%d/$ccudevname/g;
					$devname =~ s/%a/$add/g;
					$devname =~ s/[^A-Za-z\d_\.]+/_/g;
					my $ret = CommandDefine (undef, $devname." $defmod ".$add);
					if ($ret) {
						Log3 $name, 2, "HMCCU: Define command failed $devname $defmod $ccuname";
						Log3 $name, 2, "$defmod: $ret";
						next;
					}
					HMCCU_SetDefaults ($defs{$devname}) if ($devdefaults);
					foreach my $da (@devattr) {
						my ($at, $vl) = split ('=', $da);
						CommandAttr (undef, "$devname $at $vl") if (defined ($vl));
					}
					Log3 $name, 2, "$defmod: Created device $devname";
					$newcount++;
				}

				CommandSave (undef, undef) if ($newcount > 0);				
				$result .= ", created $newcount client devices";
			}
		}

		HMCCU_SetState ($hash, "OK");
		return $result;
	}
	elsif ($opt eq 'defaults') {
		$result = HMCCU_GetDefaults ($hash, 1);
		return $result;
	}
	elsif ($opt eq 'exportdefaults') {
		my $filename = shift @$a;
		
		return HMCCU_SetError ($hash, "Usage: get $name exportdefaults {filename}")
			if (!defined ($filename));
		
		my $rc = HMCCU_ExportDefaults ($filename);
		return HMCCU_SetError ($hash, -16) if ($rc == 0);
		
		HMCCU_SetState ($hash, "OK");
		return "Default attributes written to $filename";
	}
	elsif ($opt eq 'aggregation') {
		my $rule = shift @$a;
		
		return HMCCU_SetError ($hash, "Usage: get $name aggregagtion {all|rule}")
			if (!defined ($rule));
			
		if ($rule eq 'all') {
			foreach my $r (keys %{$hash->{hmccu}{agg}}) {
				my $rc = HMCCU_AggregateReadings ($hash, $r);
				$result .= "$r = $rc\n";
			}
		}
		else {
			return HMCCU_SetError ($hash, "HMCCU: Aggregation rule does not exist")
				if (!exists ($hash->{hmccu}{agg}{$rule}));
			$result = HMCCU_AggregateReadings ($hash, $rule);
			$result = "$rule = $result";			
		}

		HMCCU_SetState ($hash, "OK");
		return $ccureadings ? undef : $result;
	}
	elsif ($opt eq 'configdesc') {
		my $ccuobj = shift @$a;

		return HMCCU_SetError ($hash, "Usage: get $name configdesc {device|channel}")
		   if (!defined ($ccuobj));

		my ($rc, $res) = HMCCU_RPCGetConfig ($hash, $ccuobj, "getParamsetDescription", undef);
		return HMCCU_SetError ($hash, $rc) if ($rc < 0);

		HMCCU_SetState ($hash, "OK");
		return $res;
	}
	else {
		if (exists ($hash->{hmccu}{agg})) {
			my @rules = keys %{$hash->{hmccu}{agg}};
			$options .= " aggregation:all,".join (',', @rules) if (scalar (@rules) > 0);
		}
		return "HMCCU: Unknown argument $opt, choose one of ".$options;
	}
}

######################################################################
# Parse CCU object specification.
# Supports classic Homematic and Homematic-IP addresses.
# Supports team addresses with leading * for BidCos-RF.
# Supports CCU virtual remote addresses (BidCoS:ChnNo)
#
# Possible syntax for datapoints:
#   Interface.Address:Channel.Datapoint
#   Address:Channel.Datapoint
#   Channelname.Datapoint
#
# Possible syntax for channels:
#   Interface.Address:Channel
#   Address:Channel
#   Channelname
#
# If object name doesn't match the rules above it's treated as name.
# With parameter flags one can specify if result is filled up with
# default values for interface or datapoint.
#
# Return list of detected attributes (empty string if attribute is
# not detected):
#   (Interface, Address, Channel, Datapoint, Name, Flags)
#   Flags is a bitmask of detected attributes.
######################################################################

sub HMCCU_ParseObject ($$$)
{
	my ($hash, $object, $flags) = @_;
	my ($i, $a, $c, $d, $n, $f) = ('', '', '', '', '', '', 0);

	if ($object =~ /^(.+?)\.([\*]*[A-Z]{3}[0-9]{7}):([0-9]{1,2})\.(.+)$/ ||
		$object =~ /^(.+?)\.([0-9A-F]{12,14}):([0-9]{1,2})\.(.+)$/ ||
		$object =~ /^(.+?)\.(OL-.+):([0-9]{1,2})\.(.+)$/ ||
		$object =~ /^(.+?)\.(BidCoS-RF):([0-9]{1,2})\.(.+)$/) {
		#
		# Interface.Address:Channel.Datapoint [30=11110]
		#
		$f = $HMCCU_FLAGS_IACD;
		($i, $a, $c, $d) = ($1, $2, $3, $4);
	}
	elsif ($object =~ /^(.+)\.([\*]*[A-Z]{3}[0-9]{7}):([0-9]{1,2})$/ ||
		$object =~ /^(.+)\.([0-9A-F]{12,14}):([0-9]{1,2})$/ ||
		$object =~ /^(.+)\.(OL-.+):([0-9]{1,2})$/ ||
		$object =~ /^(.+)\.(BidCoS-RF):([0-9]{1,2})$/) {
		#
		# Interface.Address:Channel [26=11010]
		#
		$f = $HMCCU_FLAGS_IAC | ($flags & $HMCCU_FLAG_DATAPOINT);
		($i, $a, $c, $d) = ($1, $2, $3, $flags & $HMCCU_FLAG_DATAPOINT ? '.*' : '');
	}
	elsif ($object =~ /^([\*]*[A-Z]{3}[0-9]{7}):([0-9]){1,2}\.(.+)$/ ||
		$object =~ /^([0-9A-F]{12,14}):([0-9]{1,2})\.(.+)$/ ||
		$object =~ /^(OL-.+):([0-9]{1,2})\.(.+)$/ ||
		$object =~ /^(BidCoS-RF):([0-9]{1,2})\.(.+)$/) {
		#
		# Address:Channel.Datapoint [14=01110]
		#
		$f = $HMCCU_FLAGS_ACD;
		($a, $c, $d) = ($1, $2, $3);
	}
	elsif ($object =~ /^([\*]*[A-Z]{3}[0-9]{7}):([0-9]{1,2})$/ ||
		$object =~ /^([0-9A-Z]{12,14}):([0-9]{1,2})$/ ||
		$object =~ /^(OL-.+):([0-9]{1,2})$/ ||
		$object =~ /^(BidCoS-RF):([0-9]{1,2})$/) {
		#
		# Address:Channel [10=01010]
		#
		$f = $HMCCU_FLAGS_AC | ($flags & $HMCCU_FLAG_DATAPOINT);
		($a, $c, $d) = ($1, $2, $flags & $HMCCU_FLAG_DATAPOINT ? '.*' : '');
	}
	elsif ($object =~ /^([\*]*[A-Z]{3}[0-9]{7})$/ ||
		$object =~ /^([0-9A-Z]{12,14})$/ ||
		$object =~ /^(OL-.+)$/ ||
		$object eq 'BidCoS') {
		#
		# Address
		#
		$f = $HMCCU_FLAG_ADDRESS;
		$a = $1;
	}
	elsif ($object =~ /^(.+?)\.([A-Z_]+)$/) {
		#
		# Name.Datapoint
		#
		$f = $HMCCU_FLAGS_ND;
		($n, $d) = ($1, $2);
	}
	elsif ($object =~ /^.+$/) {
		#
		# Name [1=00001]
		#
		$f = $HMCCU_FLAG_NAME | ($flags & $HMCCU_FLAG_DATAPOINT);
		($n, $d) = ($object, $flags & $HMCCU_FLAG_DATAPOINT ? '.*' : '');
	}
	else {
		$f = 0;
	}

	# Check if name is a valid channel name
	if ($f & $HMCCU_FLAG_NAME) {
		my ($add, $chn) = HMCCU_GetAddress ($hash, $n, '', '');
		if ($chn ne '') {
			$f = $f | $HMCCU_FLAG_CHANNEL;
		}
		if ($flags & $HMCCU_FLAG_FULLADDR) {
			($i, $a, $c) = (HMCCU_GetDeviceInterface ($hash, $add, 'BidCos-RF'), $add, $chn);
			$f |= $HMCCU_FLAG_INTERFACE;
			$f |= $HMCCU_FLAG_ADDRESS if ($add ne '');
			$f |= $HMCCU_FLAG_CHANNEL if ($chn ne '');
		}
	}
	elsif ($f & $HMCCU_FLAG_ADDRESS && $i eq '' &&
	   ($flags & $HMCCU_FLAG_FULLADDR || $flags & $HMCCU_FLAG_INTERFACE)) {
		$i = HMCCU_GetDeviceInterface ($hash, $a, 'BidCos-RF');
		$f |= $HMCCU_FLAG_INTERFACE;
	}

	return ($i, $a, $c, $d, $n, $f);
}

######################################################################
# Filter reading by datapoint and optionally by channel name or
# channel address.
# Parameters: hash, channel, datapoint
######################################################################

sub HMCCU_FilterReading ($$$)
{
	my ($hash, $chn, $dpt) = @_;
	my $name = $hash->{NAME};
	my $fnc = "FilterReading";

	my $hmccu_hash = HMCCU_GetHash ($hash);
	return 1 if (!defined ($hmccu_hash));
	
	my $cf = AttrVal ($name, 'ccuflags', 'null');
	my $grf = AttrVal ($hmccu_hash->{NAME}, 'ccudef-readingfilter', '');
	$grf = '.*' if ($grf eq '');
	my $rf = AttrVal ($name, 'ccureadingfilter', $grf);
	$rf = $grf.";".$rf if ($rf ne $grf && $grf ne '.*' && $grf ne '');

	my $chnnam = HMCCU_IsChnAddr ($chn, 0) ? HMCCU_GetChannelName ($hmccu_hash, $chn, '') : $chn;

	Log3 $name, 2, "HMCCU: $fnc: chn=$chn, dpt=$dpt, rules = $rf" if ($cf =~ /trace/);
	
	my $rm = 1;
	my @rules = split (';', $rf);
	foreach my $r (@rules) {
		$rm = 1;
		if ($r =~ /^N:/) {
			$rm = 0;
			$r =~ s/^N://;
		}
		my ($c, $f) = split ("!", $r);
		Log3 $name, 2, "HMCCU:    rm=$rm, r=$r, dpt=$dpt chnflt=$c chnnam=$chnnam"
			if ($cf =~ /trace/);
		if (defined ($f) && $chnnam ne '') {
			if ($chnnam =~ /$c/) {
				Log3 $name, 2, "HMCCU:    $chnnam = $c" if ($cf =~/trace/);
				return $rm if (($rm && $dpt =~ /$f/) || (!$rm && $dpt =~ /$f/));
				return $rm ? 0 : 1;
			}
		}
		else {
			Log3 $name, 2, "HMCCU:    check $rm = 1 AND $dpt = $r OR $rm = 0 AND $dpt = $r"
				if ($cf =~ /trace/);
			return $rm if (($rm && $dpt =~ /$r/) || (!$rm && $dpt =~ /$r/));
			Log3 $name, 2, "HMCCU:    check negative" if ($cf =~ /trace/);
		}
	}

	Log3 $name, 2, "HMCCU: $fnc: return rm = $rm ? 0 : 1" if ($cf =~ /trace/);
	return $rm ? 0 : 1;
}

######################################################################
# Build reading name
#
# Parameters:
#
#   Interface,Address,ChannelNo,Datapoint,ChannelNam,ReadingFormat
#
#   ReadingFormat := { name[lc] | datapoint[lc] | address[lc] }
#
# Valid combinations:
#
#   ChannelName,Datapoint
#   Address,Datapoint
#   Address,ChannelNo,Datapoint
#
# Reading names can be modified by setting attribut ccureadingname.
# Returns list of readings names.
######################################################################

sub HMCCU_GetReadingName ($$$$$$$)
{
	my ($hash, $i, $a, $c, $d, $n, $rf) = @_;
	my $name = $hash->{NAME};

	my $hmccu_hash = HMCCU_GetHash ($hash);
	return '' if (!defined ($hmccu_hash));
	
	my $rn = '';
	my @rnlist;

	Log3 $name, 1, "HMCCU: ChannelNo undefined: Addr=".$a if (!defined ($c));

	$rf = HMCCU_GetAttrReadingFormat ($hash, $hmccu_hash) if (!defined ($rf));
	my $gsr = AttrVal ($hmccu_hash->{NAME}, 'ccudef-readingname', '');
	my $sr = AttrVal ($name, 'ccureadingname', $gsr);
	$sr .= ";".$gsr if ($sr ne $gsr && $gsr ne '');
	
	# Datapoint is mandatory
	return '' if ($d eq '');

	if ($rf eq 'datapoint' || $rf eq 'datapointlc') {
		$rn = (defined ($c) && $c ne '') ? $c.'.'.$d : $d;
	}
	elsif ($rf eq 'name' || $rf eq 'namelc') {
		if ($n eq '') {
			if ($a ne '' && $c ne '') {
				$n = HMCCU_GetChannelName ($hmccu_hash, $a.':'.$c, '');
			}
			elsif ($a ne '' && $c eq '') {
				$n = HMCCU_GetDeviceName ($hmccu_hash, $a, '');
			}
			else {
				return '';
			}
		}

		$n =~ s/\:/\./g;
		$n =~ s/[^A-Za-z\d_\.-]+/_/g;

		return '' if ($n eq '');
		$rn = $n.'.'.$d;
	}
	elsif ($rf eq 'address' || $rf eq 'addresslc') {
		if ($a eq '' && $n ne '') {
			($a, $c) = HMCCU_GetAddress ($hmccu_hash, $n, '', '');
		}

		if ($a ne '') {
			my $t = $a;
			$i = HMCCU_GetDeviceInterface ($hmccu_hash, $a, '') if ($i  eq '');
			$t = $i.'.'.$t if ($i ne '');
			$t = $t.'.'.$c if ($c ne '');

			$rn = $t.'.'.$d;
		}
	}
	
	push (@rnlist, $rn);
	
	# Rename and/or add reading names
	if ($sr ne '') {
		my @rules = split (';', $sr);
		foreach my $rr (@rules) {
			my ($rold, $rnew) = split (':', $rr);
			next if (!defined ($rnew));
			if ($rnlist[0] =~ /$rold/) {
				if ($rnew =~ /^\+(.+)$/) {
					my $radd = $1;
					$radd =~ s/$rold/$radd/;
					push (@rnlist, $radd);
				}
				else {
					$rnlist[0] =~ s/$rold/$rnew/;
				}
			}
		}
	}
	
	# Convert to lowercase
	$rnlist[0] = lc($rnlist[0]) if ($rf =~ /lc$/);

	return @rnlist;
}

######################################################################
# Format reading value depending on attribute stripnumber. Integer
# values are ignored.
# 0 = Preserve all digits
# 1 = Preserve 1 digit
# 2 = Remove trailing zeroes
# -n = Round value to specified number of digits (-0 is valid)
######################################################################

sub HMCCU_FormatReadingValue ($$)
{
	my ($hash, $value) = @_;

	my $stripnumber = AttrVal ($hash->{NAME}, 'stripnumber', '0');
	return $value if ($stripnumber eq '0' || $value !~ /\.[0-9]+$/);

	if ($stripnumber eq '1') {
		return sprintf ("%.1f", $value);
	}
	elsif ($stripnumber eq '2') {
		return sprintf ("%g", $value);
	}
	elsif ($stripnumber =~ /^-([0-9])$/) {
		my $fmt = '%.'.$1.'f';
		return sprintf ($fmt, $value);
	}

	return $value;
}

######################################################################
# Set error state and write log file message
######################################################################

sub HMCCU_SetError ($$)
{
	my ($hash, $text) = @_;
	my $name = $hash->{NAME};
	my $type = $hash->{TYPE};
	my $msg;
	my %errlist = (
	   -1 => 'Invalid name or address',
	   -2 => 'Execution of CCU script or command failed',
	   -3 => 'Cannot detect IO device',
	   -4 => 'Device deleted in CCU',
	   -5 => 'No response from CCU',
	   -6 => 'Update of readings disabled. Set attribute ccureadings first',
	   -7 => 'Invalid channel number',
	   -8 => 'Invalid datapoint',
	   -9 => 'Interface does not support RPC calls',
	   -10 => 'No readable datapoints found',
	   -11 => 'No state channel defined',
	   -12 => 'No control channel defined',
	   -13 => 'No state datapoint defined',
	   -14 => 'No control datapoint defined',
	   -15 => 'No state values defined',
	   -16 => 'Cannot open file'
	);

	$msg = exists ($errlist{$text}) ? $errlist{$text} : $text;
	$msg = $type.": ".$name." ". $msg;

	HMCCU_SetState ($hash, "Error");
	Log3 $name, 1, $msg;
	return $msg;
}

##################################################################
# Set state of device if attribute ccuackstate = 1
##################################################################

sub HMCCU_SetState ($$)
{
	my ($hash, $text) = @_;
	my $name = $hash->{NAME};

	my $defackstate = $hash->{TYPE} eq 'HMCCU' ? 1 : 0;
	my $ackstate = AttrVal ($name, 'ccuackstate', $defackstate);
	return undef if ($ackstate == 0);
	
	if (defined ($hash) && defined ($text)) {
		readingsSingleUpdate ($hash, "state", $text, 1);
	}

	return ($text eq "busy") ? "HMCCU: CCU busy" : undef;
}

##################################################################
# Substitute first occurrence of regular expressions or fixed
# string. Floating point values are ignored without datapoint
# specification. Integer values are compared with complete value.
# mode: 0=Substitute regular expression, 1=Substitute text
##################################################################

sub HMCCU_Substitute ($$$$$)
{
	my ($value, $substrule, $mode, $chn, $dpt, $std) = @_;
	my $rc = 0;
	my $newvalue;

	return $value if (!defined ($substrule) || $substrule eq '');

	# Remove channel number from datapoint if specified
	if ($dpt =~ /^([0-9]{1,2})\.(.+)$/) {
		($chn, $dpt) = ($1, $2);
	}

	my @rulelist = split (';', $substrule);
	foreach my $rule (@rulelist) {
		my @ruletoks = split ('!', $rule);
		if (@ruletoks == 2 && $dpt ne '' && $mode == 0) {
			my @dptlist = split (',', $ruletoks[0]);
			foreach my $d (@dptlist) {
				my $c = -1;
				if ($d =~ /^([0-9]{1,2})\.(.+)$/) {
					($c, $d) = ($1, $2);
				}
				if ($d eq $dpt && ($c == -1 || !defined($chn) || $c == $chn)) {
					($rc, $newvalue) = HMCCU_SubstRule ($value, $ruletoks[1], $mode);
					return $newvalue;
				}
			}
		}
		elsif (@ruletoks == 1) {
			return $value if ($value !~ /^[+-]?\d+$/ && $value =~ /^[+-]?\d*\.?\d+(?:(?:e|E)\d+)?$/);
			($rc, $newvalue) = HMCCU_SubstRule ($value, $ruletoks[0], $mode);
			return $newvalue if ($rc == 1);
		}
	}

	return $value;
}

##################################################################
# Execute substitution list.
# Syntax for single substitution: {#n-n|regexp|text}:newtext
#   mode=0: Substitute regular expression
#   mode=1: Substitute text (for setting statevals)
# newtext can contain ':'. Parameter ${value} in newtext is
# substituted by original value.
# Return (status, value)
#   status=1: value = substituted value
#   status=0: value = original value
##################################################################

sub HMCCU_SubstRule ($$$)
{
	my ($value, $substitutes, $mode ) = @_;
	my $rc = 0;

	$substitutes =~ s/\$\{value\}/$value/g;
	
	my @sub_list = split /,/,$substitutes;
	foreach my $s (@sub_list) {
		my ($regexp, $text) = split /:/,$s,2;
		next if (!defined ($regexp) || !defined($text));
		if ($regexp =~ /^#([+-]?\d*\.?\d+?)\-([+-]?\d*\.?\d+?)$/) {
			my ($mi, $ma) = ($1, $2);
			if ($value =~ /^\d*\.?\d+?$/ && $value >= $mi && $value <= $ma) {
				$value = $text;
				$rc = 1;
			}
		}
		if ($mode == 0 && $value =~ /$regexp/ && $value !~ /^[+-]?\d+$/) {
			my $x = eval { $value =~ s/$regexp/$text/ };
			$rc = 1 if (defined ($x));
			last;
		}
		elsif (($mode == 1 || $value =~/^[+-]?\d+$/) && $value =~ /^$regexp$/) {
			my $x = eval { $value =~ s/^$regexp$/$text/ };
			$rc = 1 if (defined ($x));
			last;
		}
	}

	return ($rc, $value);
}

##################################################################
# Substitute datapoint variables in string by datapoint value.
##################################################################

sub HMCCU_SubstVariables ($$)
{
	my ($clhash, $text) = @_;
	
	# Substitute datapoint variables by value
	foreach my $dp (keys %{$clhash->{hmccu}{dp}}) {
		my ($chn,$dpt) = split (/\./, $dp);
		if (defined ($clhash->{hmccu}{dp}{$dp}{VAL})) {
			my $value = HMCCU_FormatReadingValue ($clhash, $clhash->{hmccu}{dp}{$dp}{VAL});
			$text =~ s/\$\{$dp\}/$value/g;
			$text =~ s/\$\{$dpt\}/$value/g;
		}
	}
	
	return $text;
}

######################################################################
# Update all datapoint/readings of all client devices matching
# specified regular expression. Update will fail if device is deleted
# or disabled or if attribute ccureadings of a device is set to 0.
# If fromccu is 1 regular expression is compared to CCU device name.
# Otherwise it's compared to FHEM device name.
######################################################################

sub HMCCU_UpdateClients ($$$$)
{
	my ($hash, $devexp, $ccuget, $fromccu) = @_;
	my $fhname = $hash->{NAME};
	my $c_ok = 0;
	my $c_err = 0;

	if ($fromccu) {
		foreach my $name (sort keys %{$hash->{hmccu}{adr}}) {
			next if ($name !~ /$devexp/ || !($hash->{hmccu}{adr}{$name}{valid}));

			my @devlist = HMCCU_FindClientDevices ($hash, "(HMCCUDEV|HMCCUCHN)", undef,
				"ccudevstate=active");
			
			foreach my $d (@devlist) {
				my $ch = $defs{$d};
				next if (!defined ($ch->{IODev}) || !defined ($ch->{ccuaddr}));
				next if ($ch->{ccuaddr} ne $hash->{hmccu}{adr}{$name}{address});

				my $rc = HMCCU_GetUpdate ($ch, $hash->{hmccu}{adr}{$name}{address}, $ccuget);
				if ($rc <= 0) {
					if ($rc == -10) {
						Log3 $fhname, 3, "HMCCU: Device $name has no readable datapoints";
					}
					else {
						Log3 $fhname, 2, "HMCCU: Update of device $name failed" if ($rc != -10);
					}
					$c_err++;
				}
				else {
					$c_ok++;
				}
			}
		}
	}
	else {
		my @devlist = HMCCU_FindClientDevices ($hash, "(HMCCUDEV|HMCCUCHN)", $devexp, 
			"ccudevstate=active");
		Log3 $fhname, 2, "HMCCU: No client devices matching $devexp" if (scalar (@devlist) == 0);
		
		foreach my $d (@devlist) {
			my $ch = $defs{$d};
			next if (!defined ($ch->{IODev}) || !defined ($ch->{ccuaddr}));

			my $rc = HMCCU_GetUpdate ($ch, $ch->{ccuaddr}, $ccuget);
			if ($rc <= 0) {
				if ($rc == -10) {
					Log3 $fhname, 3, "HMCCU: Device ".$ch->{ccuaddr}." has no readable datapoints";
				}
				else {
					Log3 $fhname, 2, "HMCCU: Update of device ".$ch->{ccuaddr}." failed"
						if ($ch->{ccuif} ne 'VirtualDevices');
				}
				$c_err++;
			}
			else {
				$c_ok++;
			}
		}
	}

	return ($c_ok, $c_err);
}

##########################################################################
# Update parameters in internal device tables and client devices.
# Parameter devices is a hash reference with following keys:
#  {address}
#  {address}{flag}      := [N, D, R]
#  {address}{addtype}   := [chn, dev]
#  {address}{channels}  := Number of channels
#  {address}{name}      := Device or channel name
#  {address}{type}      := Homematic device type
#  {address}{usetype}   := Usage type
#  {address}{interface} := Device interface ID
#  {address}{firmware}  := Firmware version of device
#  {address}{version}   := Version of RPC device description
#  {address}{rxmode}    := Transmit mode
# If flag is 'D' the hash must contain an entry for the device address
# and for each channel address.
##########################################################################

sub HMCCU_UpdateDeviceTable ($$)
{
	my ($hash, $devices) = @_;
	my $devcount = 0;
	my $chncount = 0;

	# Update internal device table
	foreach my $da (keys %{$devices}) {
		my $nm = $hash->{hmccu}{dev}{$da}{name} if (defined ($hash->{hmccu}{dev}{$da}{name}));
		$nm = $devices->{$da}{name} if (defined ($devices->{$da}{name}));

		if ($devices->{$da}{flag} eq 'N' && defined ($nm)) {
			# Updated or new device/channel
			$hash->{hmccu}{dev}{$da}{addtype}   = HMCCU_IsChnAddr ($da, 0) ? 'chn' : 'dev';
			$hash->{hmccu}{dev}{$da}{name}      = $nm if (defined ($nm));
			$hash->{hmccu}{dev}{$da}{valid}     = 1;
			$hash->{hmccu}{dev}{$da}{channels}  = $devices->{$da}{channels}
				if (defined ($devices->{$da}{channels}));
			$hash->{hmccu}{dev}{$da}{type}      = $devices->{$da}{type}
				if (defined ($devices->{$da}{type}));
			$hash->{hmccu}{dev}{$da}{usetype}   = $devices->{$da}{usetype}
				if (defined ($devices->{$da}{usetype}));
			$hash->{hmccu}{dev}{$da}{interface} = $devices->{$da}{interface}
				if (defined ($devices->{$da}{interface}));
			$hash->{hmccu}{dev}{$da}{version}   = $devices->{$da}{version}
				if (defined ($devices->{$da}{version}));
			$hash->{hmccu}{dev}{$da}{firmware}  = $devices->{$da}{firmware}
				if (defined ($devices->{$da}{firmware}));
			$hash->{hmccu}{dev}{$da}{rxmode}    = $devices->{$da}{rxmode}
				if (defined ($devices->{$da}{rxmode}));
			$hash->{hmccu}{adr}{$nm}{address}   = $da;
			$hash->{hmccu}{adr}{$nm}{addtype}   = $hash->{hmccu}{dev}{$da}{addtype};
			$hash->{hmccu}{adr}{$nm}{valid}     = 1 if (defined ($nm));
		}
		elsif ($devices->{$da}{flag} eq 'D' && exists ($hash->{hmccu}{dev}{$da})) {
			# Device deleted, mark as invalid
			$hash->{hmccu}{dev}{$da}{valid} = 0;
			$hash->{hmccu}{adr}{$nm}{valid} = 0 if (defined ($nm));
		}
		elsif ($devices->{$da}{flag} eq 'R' && exists ($hash->{hmccu}{dev}{$da})) {
			# Device replaced, change address
			my $na = $devices->{hmccu}{newaddr};
			# Copy device entries and delete old device entries
			foreach my $k (keys %{$hash->{hmccu}{dev}{$da}}) {
				$hash->{hmccu}{dev}{$na}{$k} = $hash->{hmccu}{dev}{$da}{$k};
			}
			$hash->{hmccu}{adr}{$nm}{address} = $na;
			delete $hash->{hmccu}{dev}{$da};
		}
	}
	
	# Update client devices
	my @devlist = HMCCU_FindClientDevices ($hash, "(HMCCUDEV|HMCCUCHN)", undef, undef);

	foreach my $d (@devlist) {
		my $ch = $defs{$d};
		my $ct = $ch->{TYPE};
		my $ca = $ch->{ccuaddr};
		next if (!exists ($devices->{$ca}));
		if ($devices->{$ca}{flag} eq 'N') {
			# New device or new device information
			$ch->{ccudevstate} = 'active';
			if ($ct eq 'HMCCUDEV') {
				$ch->{ccutype} = $hash->{hmccu}{dev}{$ca}{type} 
					if (defined ($hash->{hmccu}{dev}{$ca}{type}));
				$ch->{firmware} = $devices->{$ca}{firmware}
					if (defined ($devices->{$ca}{firmware}));
			}
			else {
				$ch->{chntype} = $devices->{$ca}{usetype}
					if (defined ($devices->{$ca}{usetype}));
				my ($add, $chn) = HMCCU_SplitChnAddr ($ca);
				$ch->{ccutype} = $devices->{$add}{type}
					if (defined ($devices->{$add}{type}));
				$ch->{firmware} = $devices->{$add}{firmware}
					if (defined ($devices->{$add}{firmware}));
			}
			$ch->{ccuname} = $hash->{hmccu}{dev}{$ca}{name}
				if (defined ($hash->{hmccu}{dev}{$ca}{name}));
			$ch->{ccuif} = $hash->{hmccu}{dev}{$ca}{interface}
				if (defined ($devices->{$ca}{interface}));
			$ch->{channels} = $hash->{hmccu}{dev}{$ca}{channels}
				if (defined ($hash->{hmccu}{dev}{$ca}{channels}));
		}
		elsif ($devices->{$ca}{flag} eq 'D') {
			# Deleted device
			$ch->{ccudevstate} = 'deleted';
		}
		elsif ($devices->{$ca}{flag} eq 'R') {
			# Replaced device
			$ch->{ccuaddr} = $devices->{$ca}{newaddr};
		}
	}
	
	# Update internals of I/O device
	foreach my $adr (keys %{$hash->{hmccu}{dev}}) {
		if (exists ($hash->{hmccu}{dev}{$adr}{addtype})) {
			$devcount++ if ($hash->{hmccu}{dev}{$adr}{addtype} eq 'dev');
			$chncount++ if ($hash->{hmccu}{dev}{$adr}{addtype} eq 'chn');
		}
	}
	$hash->{ccudevices} = $devcount;
	$hash->{ccuchannels} = $chncount;
	
	return ($devcount, $chncount);
}

######################################################################
# Update a single client device datapoint considering
# scaling, reading format and value substitution.
# Return stored value.
######################################################################

sub HMCCU_UpdateSingleDatapoint ($$$$)
{
	my ($hash, $chn, $dpt, $value) = @_;

	my $hmccu_hash = HMCCU_GetHash ($hash);
	return $value if (!defined ($hmccu_hash));
	
	my %objects;
	
	my $ccuaddr = $hash->{ccuaddr};
	my ($devaddr, $chnnum) = HMCCU_SplitChnAddr ($ccuaddr);
	$objects{$devaddr}{$chn}{$dpt} = $value;
	
	my $rc = HMCCU_UpdateSingleDevice ($hmccu_hash, $hash, \%objects);
	return (ref ($rc)) ? $rc->{$devaddr}{$chn}{$dpt} : $value;
}

######################################################################
# Update readings of client device.
# Parameter objects is a hash reference which contains updated data
# for any device:
#   {devaddr}
#   {devaddr}{channelno}
#   {devaddr}{channelno}{datapoint}
#   {devaddr}{channelno}{datapoint} = value
# If client device is virtual device group: check if group members are
# affected by updates and update readings in virtual group device.
# Return a hash reference with datapoints and new values:
#   {devaddr}
#   {devaddr}{datapoint} = value
######################################################################

sub HMCCU_UpdateSingleDevice ($$$)
{
	my ($ccuhash, $clthash, $objects) = @_;
	my $ccuname = $ccuhash->{NAME};
	my $cltname = $clthash->{NAME};
	my $clttype = $clthash->{TYPE};
	my $fnc = "UpdateSingleDevice";

	return 0 if (!defined ($clthash->{IODev}) || !defined ($clthash->{ccuaddr}));
	return 0 if ($clthash->{IODev} != $ccuhash);

	# Check for updated data
 	my ($devaddr, $cnum) = HMCCU_SplitChnAddr ($clthash->{ccuaddr});
 	return 0 if (!exists ($objects->{$devaddr}));
 	return 0 if ($clttype eq 'HMCUCCHN' && !exists ($objects->{$devaddr}{$cnum}) &&
 		!exists ($objects->{$devaddr}{0}));

	# Get attributes of IO device
	my $ccuflags = AttrVal ($ccuname, 'ccuflags', 'null');
	
	# Get attributes of client device
 	my $cltflags = AttrVal ($cltname, 'ccuflags', 'null');

	# Build device list including virtual devices
	my @grplist = ($cltname);
	my @virlist = HMCCU_FindClientDevices ($ccuhash, "HMCCUDEV", undef, "ccuif=VirtualDevices");
	foreach my $vd (@virlist) {
		my $vh = $defs{$vd};
		next if (!defined ($vh->{ccugroup}));
		foreach my $gadd (split (",", $vh->{ccugroup})) {
			if ("$gadd" eq "$devaddr") {
				push @grplist, $vd;
				last;
			} 
		}
	}
	
	if ($cltflags =~ /trace/) {
		Log3 $ccuname, 2, "HMCCU: $fnc: $cltname Virlist = ".join(',', @virlist);
		Log3 $ccuname, 2, "HMCCU: $fnc: $cltname Grplist = ".join(',', @grplist);
		Log3 $ccuname, 2, "HMCCU: $fnc: $cltname Objects = ".join(',', keys %{$objects});
	}
	
	# Store the resulting readings
	my %results;
	
	# Update device considering foreign device data assigned to group device
	foreach my $cn (@grplist) {
		my $ch = $defs{$cn};
		my $ct = $ch->{TYPE};
		my $cf = AttrVal ($cn, 'ccuflags', 'null');
		my $disable = AttrVal ($cn, 'disable', 0);
		my $update = AttrVal ($cn, 'ccureadings', 1);
		next if ($update == 0 || $disable == 1);

		Log3 $ccuname, 2, "HMCCU: $fnc: Processing device $cn" if ($cf =~ /trace/);
		
		my $crf = HMCCU_GetAttrReadingFormat ($ch, $ccuhash);
		my $substitute = HMCCU_GetAttrSubstitute ($ch, $ccuhash);
		my ($sc, $st, $cc, $cd) = HMCCU_GetSpecialDatapoints ($ch, '', 'STATE', '', '');

		my @devlist = ($ch->{ccuaddr});
		push @devlist, split (",", $ch->{ccugroup})
			if ($ch->{ccuif} eq 'VirtualDevices' && exists ($ch->{ccugroup}));
				
		readingsBeginUpdate ($ch);
		
		foreach my $dev (@devlist) {
			my ($da, $cnum) = HMCCU_SplitChnAddr ($dev);
			next if (!exists ($objects->{$da}));
			next if ($clttype eq 'HMCUCCHN' && !exists ($objects->{$da}{$cnum}) &&
				!exists ($objects->{$da}{0}));

			# Update channels of device
			foreach my $chnnum (keys (%{$objects->{$da}})) {
				next if ($ct eq 'HMCCUCHN' && "$chnnum" ne "$cnum" && "$chnnum" ne "0");
				next if ("$chnnum" eq "0" && $cf =~ /nochn0/);
				my $chnadd = "$da:$chnnum";
			
				# Update datapoints of channel
				foreach my $dpt (keys (%{$objects->{$da}{$chnnum}})) {
					my $value = $objects->{$da}{$chnnum}{$dpt};
					next if (!defined ($value));
					$clthash->{hmccu}{dp}{"$chnnum.$dpt"}{VAL} = $value;

					Log3 $ccuname, 2, "HMCCU: $fnc dev=$cn, chnadd=$chnadd, dpt=$dpt, value=$value"
						if ($cf =~ /trace/);

					if (HMCCU_FilterReading ($ch, $chnadd, $dpt)) {
						my @readings = HMCCU_GetReadingName ($ch, '', $da, $chnnum, $dpt, '', $crf);
						my $svalue = HMCCU_ScaleValue ($ch, $dpt, $value, 0);	
						my $fvalue = HMCCU_FormatReadingValue ($ch, $svalue);
						my $cvalue = HMCCU_Substitute ($fvalue, $substitute, 0, $chnnum, $dpt);
						my %calcs = HMCCU_CalculateReading ($ch, $chnnum, $dpt);
					
						# Store the resulting value after scaling, formatting and substitution
						$results{$da}{$chnnum}{$dpt} = $cvalue;
					
						Log3 $ccuname, 2, "HMCCU: $fnc device=$cltname, readings=".join(',', @readings).
							", orgvalue=$value value=$cvalue" if ($cf =~ /trace/);

						foreach my $rn (@readings) {
							HMCCU_BulkUpdate ($ch, $rn, $fvalue, $cvalue) if ($rn ne '');
						}
						foreach my $clcr (keys %calcs) {
							HMCCU_BulkUpdate ($ch, $clcr, $calcs{$clcr}, $calcs{$clcr});
						}
						HMCCU_BulkUpdate ($ch, 'control', $fvalue, $cvalue)
							if ($cd ne '' && $dpt eq $cd && $chnnum eq $cc);
						HMCCU_BulkUpdate ($ch, 'state', $fvalue, $cvalue)
							if ($dpt eq $st && ($sc eq '' || $sc eq $chnnum));
					}	
				}
			}
		}
		
		# Calculate and update HomeMatic state
		if ($ccuflags !~ /nohmstate/) {
			my ($hms_read, $hms_chn, $hms_dpt, $hms_val) = HMCCU_GetHMState ($cn, $ccuname, undef);
			HMCCU_BulkUpdate ($ch, $hms_read, $hms_val, $hms_val) if (defined ($hms_val));
		}
	
		readingsEndUpdate ($ch, 1);
	}
	
	return \%results;
}

######################################################################
# Update readings of multiple client devices.
# Parameter objects is a hash reference:
#   {devaddr}
#   {devaddr}{channelno}
#   {devaddr}{channelno}{datapoint} = value
# Return number of updated devices.
######################################################################

sub HMCCU_UpdateMultipleDevices ($$)
{
	my ($hash, $objects) = @_;
	my $name = $hash->{NAME};
	my $fnc = "UpdateMultipleDevices";
	my $c = 0;
	
	# Check syntax
	return 0 if (!defined ($hash) || !defined ($objects));

	# Update reading in matching client devices
	my @devlist = HMCCU_FindClientDevices ($hash, "(HMCCUDEV|HMCCUCHN)", undef,
		"ccudevstate=active");
	foreach my $d (@devlist) {
		my $ch = $defs{$d};
		my $rc = HMCCU_UpdateSingleDevice ($hash, $ch, $objects);
		$c++ if (ref ($rc));
	}

	return $c;
}

######################################################################
# Get list of valid RPC ports.
# Considers binary RPC ports and interfaces used by CCU devices.
# Default is 2001.
######################################################################

sub HMCCU_GetRPCPortList ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my @ports = ($HMCCU_RPC_PORT_DEFAULT);
	
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	
	if (defined ($hash->{hmccu}{rpcports})) {
		foreach my $p (split (',', $hash->{hmccu}{rpcports})) {
			my $ifname = $HMCCU_RPC_NUMPORT{$p};
			next if ($p == $HMCCU_RPC_PORT_DEFAULT ||
				($HMCCU_RPC_PROT{$p} eq 'B' && $ccuflags !~ /extrpc/) ||
				!exists ($hash->{hmccu}{iface}{$ifname}));
			push (@ports, $p);
		}
	}	
	
	return @ports;
}

######################################################################
# Register RPC callbacks at CCU if RPC-Server already in server loop
######################################################################

sub HMCCU_RPCRegisterCallback ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $serveraddr = $hash->{host};
	my $localaddr = $hash->{hmccu}{localaddr};

	my $rpcinterval = AttrVal ($name, 'rpcinterval', $HMCCU_INIT_INTERVAL2);
	my $rpcserveraddr = AttrVal ($name, 'rpcserveraddr', $localaddr);
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	my @rpcports = HMCCU_GetRPCPortList ($hash);
	
	foreach my $port (@rpcports) {
		my $clkey = 'CB'.$port;
		my $cburl = "http://".$localaddr.":".$hash->{hmccu}{rpc}{$clkey}{cbport}."/fh".$port;
		my $url = "http://$serveraddr:$port/";
		$url .= $HMCCU_RPC_URL{$port} if (exists ($HMCCU_RPC_URL{$port}));
		if ($hash->{hmccu}{rpc}{$clkey}{loop} == 1 ||
			$hash->{hmccu}{rpc}{$clkey}{state} eq "register") {		
			$hash->{hmccu}{rpc}{$clkey}{port} = $port;
			$hash->{hmccu}{rpc}{$clkey}{clurl} = $url;
			$hash->{hmccu}{rpc}{$clkey}{cburl} = $cburl;
			$hash->{hmccu}{rpc}{$clkey}{loop} = 2;
			$hash->{hmccu}{rpc}{$clkey}{state} = "registered";

			Log3 $name, 1, "HMCCU: Registering callback $cburl with ID $clkey at $url";
			my $rpcclient = RPC::XML::Client->new ($url);
			$rpcclient->send_request ("init", $cburl, $clkey);
			Log3 $name, 1, "HMCCU: RPC callback with URL $cburl initialized";
		}
	}
	
	# Schedule reading of RPC queue
	InternalTimer (gettimeofday()+$rpcinterval, 'HMCCU_ReadRPCQueue', $hash, 0);
}

######################################################################
# Deregister RPC callbacks at CCU
######################################################################

sub HMCCU_RPCDeRegisterCallback ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	foreach my $clkey (keys %{$hash->{hmccu}{rpc}}) {
		my $rpchash = \%{$hash->{hmccu}{rpc}{$clkey}};
		if (exists ($rpchash->{cburl}) && $rpchash->{cburl} ne '') {
			my $port = $rpchash->{port};
			my $rpcclient = RPC::XML::Client->new ($rpchash->{clurl});
			Log3 $name, 1, "HMCCU: Deregistering RPC server ".$rpchash->{cburl}.
			   " at ".$rpchash->{clurl};
			$rpcclient->send_request("init", $rpchash->{cburl});
			$rpchash->{cburl} = '';
			$rpchash->{clurl} = '';
			$rpchash->{cbport} = 0;
		}
	}
}

######################################################################
# Initialize statistic counters
######################################################################

sub HMCCU_ResetCounters ($)
{
	my ($hash) = @_;
	my @counters = ('total', 'EV', 'ND', 'IN', 'DD', 'RA', 'RD', 'UD', 'EX', 'SL', 'ST');
	
	foreach my $cnt (@counters) {
		$hash->{hmccu}{ev}{$cnt} = 0;
	}
	delete $hash->{hmccu}{evs};
	delete $hash->{hmccu}{evr};

	$hash->{hmccu}{evtimeout} = 0;
	$hash->{hmccu}{evtime} = 0;
}

######################################################################
# Start external RPC server via HMCCURPC device.
# Return number of RPC server threads or 0 on error.
######################################################################

sub HMCCU_StartExtRPCServer ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	
	# Search RPC device. Create one if none exists
	my $rpcdev = HMCCU_GetRPCDevice ($hash, 1);
	if ($rpcdev eq '') {
		Log3 $name, 0, "HMCCU: Can't find or create HMCCURPC device";
		return 0;
	}
	
	my ($rc, $msg) = HMCCURPC_StartRPCServer ($defs{$rpcdev});
	Log3 $name, 0, "HMCCURPC: $msg" if (!$rc && defined ($msg));
		
	return $rc;
}

######################################################################
# Stop external RPC server via HMCCURPC device.
######################################################################

sub HMCCU_StopExtRPCServer ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (!exists ($modules{'HMCCURPC'})) {
		Log3 $name, 0, "HMCCU: Module HMCCURPC not loaded";
		return 0;
	}
	
	# Search RPC device. Create one if none exists
	my $rpcdev = HMCCU_GetRPCDevice ($hash, 1);
	if ($rpcdev eq '') {
		Log3 $name, 0, "HMCCU: Can't find or create RPC device";
		return 0;
	}

	return HMCCURPC_StopRPCServer ($defs{$rpcdev});	
}

######################################################################
# Start internal file queue based RPC server.
# Return number of RPC server processes or 0 on error.
######################################################################

sub HMCCU_StartIntRPCServer ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	# Timeouts
	my $timeout = AttrVal ($name, 'rpctimeout', '0.01,0.25');
	my ($to_read, $to_write) = split (",", $timeout);
	$to_write = $to_read if (!defined ($to_write));
	
	# Address and ports
	my $rpcqueue = AttrVal ($name, 'rpcqueue', '/tmp/ccuqueue');
	my $rpcserverport = AttrVal ($name, 'rpcserverport', 5400);
	my $rpcinterval = AttrVal ($name, 'rpcinterval', $HMCCU_INIT_INTERVAL1);
	my @rpcportlist = HMCCU_GetRPCPortList ($hash);
	my $serveraddr = $hash->{host};
	my $fork_cnt = 0;

	# Check for running RPC server processes	
	my @hm_pids;
	my @ex_pids;
	HMCCU_IsRPCServerRunning ($hash, \@hm_pids, \@ex_pids);
	if (@hm_pids > 0) {
		Log3 $name, 0, "HMCCU: RPC server(s) already running with PIDs ".join (',', @hm_pids);
		return scalar (@hm_pids);
	}
	elsif (@ex_pids > 0) {
		Log3 $name, 1, "HMCCU: Externally launched RPC server(s) detected. Kill process(es) manually with command kill -SIGINT pid for pid=".join (',', @ex_pids);
		return 0;
	}

	# Detect local IP address
	my $socket = IO::Socket::INET->new (PeerAddr => $serveraddr, PeerPort => $rpcportlist[0]);
	if (!$socket) {
		Log3 $name, 1, "HMCCU: Can't connect to CCU port".$rpcportlist[0];
		return 0;
	}
	my $localaddr = $socket->sockhost ();
	close ($socket);

	my $ccunum = $hash->{CCUNum};
	
	# Fork child processes
	foreach my $port (@rpcportlist) {
		my $clkey = 'CB'.$port;
		my $rpcqueueport = $rpcqueue."_".$port."_".$ccunum;
		my $callbackport = $rpcserverport+$port+($ccunum*10);

		# Clear event queue
		HMCCU_ResetRPCQueue ($hash, $port);
		
		# Create child process
		Log3 $name, 2, "HMCCU: Create child process with timeouts $to_read and $to_write";
		my $child = SubProcess->new ({ onRun => \&HMCCU_CCURPC_OnRun,
			onExit => \&HMCCU_CCURPC_OnExit, timeoutread => $to_read, timeoutwrite => $to_write });
		$child->{serveraddr}   = $serveraddr;
		$child->{serverport}   = $port;
		$child->{callbackport} = $callbackport;
		$child->{devname}      = $name;
		$child->{queue}        = $rpcqueueport;
		
		# Start child process
		my $pid = $child->run ();
		if (!defined ($pid)) {
			Log3 $name, 1, "HMCCU: No RPC process for server $clkey started";
			next;
		}
		
		Log3 $name, 0, "HMCCU: Child process for server $clkey started with PID $pid";
		$fork_cnt++;

		# Store child process parameters
		$hash->{hmccu}{rpc}{$clkey}{child}  = $child;
		$hash->{hmccu}{rpc}{$clkey}{cbport} = $callbackport;
		$hash->{hmccu}{rpc}{$clkey}{loop}   = 0;
		$hash->{hmccu}{rpc}{$clkey}{pid}    = $pid;
		$hash->{hmccu}{rpc}{$clkey}{queue}  = $rpcqueueport;
		$hash->{hmccu}{rpc}{$clkey}{state}  = "starting";
		push (@hm_pids, $pid);
	}

	$hash->{hmccu}{rpccount}  = $fork_cnt;
	$hash->{hmccu}{localaddr} = $localaddr;

	if ($fork_cnt > 0) {	
		# Set internals
		$hash->{RPCPID} = join (',', @hm_pids);
		$hash->{RPCPRC} = "internal";
		$hash->{RPCState} = "starting";

		# Initialize statistic counters
		HMCCU_ResetCounters ($hash);
	
		readingsSingleUpdate ($hash, "rpcstate", "starting", 1);	
		Log3 $name, 0, "RPC server(s) starting";
		DoTrigger ($name, "RPC server starting");

		InternalTimer (gettimeofday()+$rpcinterval, 'HMCCU_ReadRPCQueue', $hash, 0);
	}
		
	return $fork_cnt;
}

######################################################################
# Stop RPC server(s) by sending SIGINT to process(es)
######################################################################

sub HMCCU_StopRPCServer ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $pid = 0;

	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	my $serveraddr = $hash->{host};

	# Deregister callback URLs in CCU
	HMCCU_RPCDeRegisterCallback ($hash);
		
	# Send signal SIGINT to RPC server processes
	foreach my $clkey (keys %{$hash->{hmccu}{rpc}}) {
		my $rpchash = \%{$hash->{hmccu}{rpc}{$clkey}};
		if (exists ($rpchash->{pid}) && $rpchash->{pid} != 0) {
			Log3 $name, 0, "HMCCU: Stopping RPC server $clkey with PID ".$rpchash->{pid};
			kill ('INT', $rpchash->{pid});
			$rpchash->{state} = "stopping";
		}
		else {
			$rpchash->{state} = "stopped";
		}
	}
	
	# Update status
	if ($hash->{hmccu}{rpccount} > 0) {
		readingsSingleUpdate ($hash, "rpcstate", "stopping", 1);
		$hash->{RPCState} = "stopping";
	}
	
	# Wait
	sleep (1);
	
	# Check if processes were terminated
	my @hm_pids;
	my @ex_pids;
	HMCCU_IsRPCServerRunning ($hash, \@hm_pids, \@ex_pids);
	if (@hm_pids > 0) {
		foreach my $pid (@hm_pids) {
			Log3 $name, 0, "HMCCU: Stopping RPC server with PID $pid";
			kill ('INT', $pid);
		}
	}
	if (@ex_pids > 0) {
		Log3 $name, 0, "HMCCU: Externally launched RPC server detected.";
		foreach my $pid (@ex_pids) {
			kill ('INT', $pid);
		}
	}
	
	# Wait
	sleep (1);
	
	# Kill the rest
	@hm_pids = ();
	@ex_pids = ();
	if (HMCCU_IsRPCServerRunning ($hash, \@hm_pids, \@ex_pids)) {
		push (@hm_pids, @ex_pids);
		foreach my $pid (@hm_pids) {
			kill ('KILL', $pid);
		}
	}

	@hm_pids = ();
	@ex_pids = ();
	HMCCU_IsRPCServerRunning ($hash, \@hm_pids, \@ex_pids);
	push (@hm_pids, @ex_pids);
	$hash->{hmccu}{rpccount} = scalar(@hm_pids);

	return $hash->{hmccu}{rpccount} > 0 ? 0 : 1;
}

######################################################################
# Check status of RPC server depending on internal RPCState.
# Return 1 if RPC server is stopping, starting or restarting. During
# this phases CCU reacts very slowly so any get or set command from
# HMCCU devices are disabled.
######################################################################

sub HMCCU_IsRPCStateBlocking ($)
{
	my ($hash) = @_;

	if ($hash->{RPCState} eq "starting" ||
	    $hash->{RPCState} eq "restarting" ||
	    $hash->{RPCState} eq "stopping") {
		return 1;
	}
	else {
		return 0;
	}
}

######################################################################
# Check if RPC server is running. Return list of PIDs or TIDs in
# arrays referenced by parameters hm_pids and ex_pids.
# 1 = One or more RPC servers running.
# 0 = No RPC server running.
######################################################################

sub HMCCU_IsRPCServerRunning ($$$)
{
	my ($hash, $hm_pids, $ex_pids) = @_;
	my $name = $hash->{NAME};
	
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');

	if ($ccuflags =~ /extrpc/) {
		my $rpcdev = HMCCU_GetRPCDevice ($hash, 0);
		if ($rpcdev ne '') {
			my $rpc_hash = $defs{$rpcdev};
			my @tids = ();
			@tids = split (',', $rpc_hash->{RPCTID})
				if (exists ($rpc_hash->{RPCTID}) && $rpc_hash->{RPCTID} ne "0");
			push (@$ex_pids, @tids) if (scalar (@tids) > 0);
		}
	}
	else {
		foreach my $clkey (keys %{$hash->{hmccu}{rpc}}) {
			if (exists ($hash->{hmccu}{rpc}{$clkey}{pid}) &&
			   defined ($hash->{hmccu}{rpc}{$clkey}{pid}) &&
			   $hash->{hmccu}{rpc}{$clkey}{pid} != 0) {
			   my $pid = $hash->{hmccu}{rpc}{$clkey}{pid};
				push (@$hm_pids, $pid) if (kill (0, $pid));
			}
		}
	}
	
	return (@$hm_pids > 0 || @$ex_pids > 0) ? 1 : 0;
}

######################################################################
# Get channels and datapoints of CCU device
######################################################################

sub HMCCU_GetDeviceInfo ($$$)
{
	my ($hash, $device, $ccuget) = @_;
	my $name = $hash->{NAME};
	my $devname = '';

	my $hmccu_hash = HMCCU_GetHash ($hash);
	return '' if (!defined ($hmccu_hash));

	$ccuget = HMCCU_GetAttribute ($hmccu_hash, $hash, 'ccuget', 'Value') if ($ccuget eq 'Attr');
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');

	my ($int, $add, $chn, $dpt, $nam, $flags) = HMCCU_ParseObject ($hmccu_hash, $device, 0);
	if ($flags == $HMCCU_FLAG_ADDRESS) {
		$devname = HMCCU_GetDeviceName ($hmccu_hash, $add, '');
		return '' if ($devname eq '');
	}
	else {
		$devname = $nam;
	}

	my $script = qq(
string chnid;
string sDPId;
object odev = dom.GetObject ("$devname");
if (odev) {
  foreach (chnid, odev.Channels()) {
    object ochn = dom.GetObject(chnid);
    if (ochn) {
      foreach(sDPId, ochn.DPs()) {
        object oDP = dom.GetObject(sDPId);
        if (oDP) {
          integer op = oDP.Operations();
          string flags = "";
          if (OPERATION_READ & op) { flags = flags # "R"; }
          if (OPERATION_WRITE & op) { flags = flags # "W"; }
          if (OPERATION_EVENT & op) { flags = flags # "E"; }
          WriteLine ("C;" # ochn.Address() # ";" # ochn.Name() # ";" # oDP.Name() # ";" # oDP.ValueType() # ";" # oDP.$ccuget() # ";" # flags);
        }
      }
    }
  }
}
	);

	my $response = HMCCU_HMScript ($hmccu_hash, $script);
	if ($ccuflags =~ /trace/) {
		Log3 $name, 2, "HMCCU: Device=$device Devname=$devname";
		Log3 $name, 2, "HMCCU: Script response = \n".$response;
		Log3 $name, 2, "HMCCU: Script = ".$script;
	}
	return $response;
}

######################################################################
# Make device info readable
######################################################################

sub HMCCU_FormatDeviceInfo ($)
{
	my ($devinfo) = @_;
	
	my %vtypes = (2, "b", 4, "f", 8, "n", 11, "s", 16, "i", 20, "s", 29, "e");
	my $result = '';
	my $c_oaddr = '';
	
	foreach my $dpspec (split ("\n", $devinfo)) {
		my ($c, $c_addr, $c_name, $d_name, $d_type, $d_value, $d_flags) = split (";", $dpspec);
		if ($c_addr ne $c_oaddr) {
			$result .= "CHN $c_addr $c_name\n";
			$c_oaddr = $c_addr;
		}
		my $t = exists ($vtypes{$d_type}) ? $vtypes{$d_type} : $d_type;
		$result .= "  DPT {$t} $d_name = $d_value [$d_flags]\n";
	}
	
	return $result;
}

######################################################################
# Read list of CCU devices and channels via Homematic Script.
# Update data of client devices if not current.
# Return (device count, channel count) or (-1, -1) on error.
######################################################################

sub HMCCU_GetDeviceList ($)
{
	my ($hash) = @_;
	my $devcount = 0;
	my $chncount = 0;
	my %objects = ();
	
	my $script = qq(
string devid;
string chnid;
foreach(devid, root.Devices().EnumUsedIDs()) {
   object odev=dom.GetObject(devid);
   string intid=odev.Interface();
   string intna=dom.GetObject(intid).Name();
   integer cc=0;
   foreach (chnid, odev.Channels()) {
      object ochn=dom.GetObject(chnid);
      WriteLine("C;" # ochn.Address() # ";" # ochn.Name());
      cc=cc+1;
   }
   WriteLine("D;" # intna # ";" # odev.Address() # ";" # odev.Name() # ";" # odev.HssType() # ";" # cc);
}
	);

	my $response = HMCCU_HMScript ($hash, $script);
	return (-1, -1) if ($response eq '');

	%{$hash->{hmccu}{dev}} = ();
	%{$hash->{hmccu}{adr}} = ();
	$hash->{hmccu}{updatetime} = time ();

#  Hash elements:
#
#  {address}{flag}      := [N, D, R]
#  {address}{addtype}   := [chn, dev]
#  {address}{channels}  := Number of channels
#  {address}{name}      := Device or channel name
#  {address}{type}      := Homematic device type
#  {address}{usetype}   := Usage type
#  {address}{interface} := Device interface ID
#  {address}{firmware}  := Firmware version of device
#  {address}{version}   := Version of RPC device description
#  {address}{rxmode}    := Transmit mode

	my @scrlines = split /\n/,$response;
	foreach my $hmdef (@scrlines) {
		my @hmdata = split /;/,$hmdef;

		if ($hmdata[0] eq 'D') {
			# 1=Interface 2=Device-Address 3=Device-Name 4=Device-Type 5=Channel-Count
			$objects{$hmdata[2]}{addtype}   = 'dev';
			$objects{$hmdata[2]}{channels}  = $hmdata[5];
			$objects{$hmdata[2]}{flag}      = 'N';
			$objects{$hmdata[2]}{interface} = $hmdata[1];
			$objects{$hmdata[2]}{name}      = $hmdata[3];
			$objects{$hmdata[2]}{type}      = ($hmdata[2] =~ /^CUX/) ? "CUX-".$hmdata[4] : $hmdata[4];
			# Count used interfaces
			$hash->{hmccu}{iface}{$hmdata[1]}++;
			# CCU information
			if ($hmdata[2] eq 'BidCoS-RF') {
				$hash->{ccuname} = $hmdata[3];
				$hash->{ccuaddr} = $hmdata[2];
				$hash->{ccuif}   = $hmdata[1];
			}
		}
		elsif ($hmdata[0] eq 'C') {
			# 1=Channel-Address 2=Channel-Name
			$objects{$hmdata[1]}{addtype}   = 'chn';
			$objects{$hmdata[1]}{channels}  = 1;
			$objects{$hmdata[1]}{flag}      = 'N';
			$objects{$hmdata[1]}{name}      = $hmdata[2];
			$objects{$hmdata[1]}{valid}     = 1;
		}
	}

	# Update some CCU I/O device information
	$hash->{ccuinterfaces} = join (',', keys %{$hash->{hmccu}{iface}});
	
	($devcount, $chncount) = HMCCU_UpdateDeviceTable ($hash, \%objects) if (scalar (@scrlines) > 0);
	HMCCU_GetDatapointList ($hash);

	return ($devcount, $chncount);
}

######################################################################
# Read list of datapoints for CCU device types.
# Function must not be called before GetDeviceList.
# Return number of datapoints.
######################################################################

sub HMCCU_GetDatapointList ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};

	if (exists ($hash->{hmccu}{dp})) {
		delete $hash->{hmccu}{dp};
	}
	
	# Get unique device types
	my %alltypes;
	my @devunique;
	foreach my $add (sort keys %{$hash->{hmccu}{dev}}) {
		next if ($hash->{hmccu}{dev}{$add}{addtype} ne 'dev');
#		next if ($hash->{hmccu}{dev}{$add}{addtype} ne 'dev' ||
#		   $hash->{hmccu}{dev}{$add}{interface} eq 'CUxD');
		my $dt = $hash->{hmccu}{dev}{$add}{type};
		if ($dt ne '' && !exists ($alltypes{$dt})) {
			$alltypes{$dt} = 1;
			push @devunique, $hash->{hmccu}{dev}{$add}{name};
		}
	}
	my $devlist = join (',', @devunique);

	my $script = qq(
string chnid;
string sDPId;
string sDevice;
string sDevList = "$devlist";
foreach (sDevice, sDevList.Split(",")) {
  object odev = dom.GetObject (sDevice);
  if (odev) {
    string sType = odev.HssType();
    foreach (chnid, odev.Channels()) {
      object ochn = dom.GetObject(chnid);
      if (ochn) {
        string sAddr = ochn.Address();
        string sChnNo = sAddr.StrValueByIndex(":",1);
        foreach(sDPId, ochn.DPs()) {
          object oDP = dom.GetObject(sDPId);
          if (oDP) {
            string sDPName = oDP.Name().StrValueByIndex(".",2);
            WriteLine (sAddr # ";" # sType # ";" # sChnNo # ";" # sDPName # ";" # oDP.ValueType() # ";" # oDP.Operations());
          }
        }
      }
    }
  }
}
	);

	my $response = HMCCU_HMScript ($hash, $script);
	return 0 if ($response eq '');

	my $c = 0;	
	foreach my $dpspec (split /\n/,$response) {
		my ($chna, $devt, $devc, $dptn, $dptt, $dpto) = split (";", $dpspec);
		$devt = "CUX-".$devt if ($chna =~ /^CUX/);
		$hash->{hmccu}{dp}{$devt}{spc}{ontime} = $devc.".".$dptn if ($dptn eq "ON_TIME");
		$hash->{hmccu}{dp}{$devt}{spc}{ramptime} = $devc.".".$dptn if ($dptn eq "RAMP_TIME");
		$hash->{hmccu}{dp}{$devt}{spc}{submit} = $devc.".".$dptn if ($dptn eq "SUBMIT");
		$hash->{hmccu}{dp}{$devt}{spc}{level} = $devc.".".$dptn if ($dptn eq "LEVEL");		
		$hash->{hmccu}{dp}{$devt}{ch}{$devc}{$dptn}{type} = $dptt;
		$hash->{hmccu}{dp}{$devt}{ch}{$devc}{$dptn}{oper} = $dpto;
		if (exists ($hash->{hmccu}{dp}{$devt}{cnt}{$dptn})) {
			$hash->{hmccu}{dp}{$devt}{cnt}{$dptn}++;
		}
		else {
			$hash->{hmccu}{dp}{$devt}{cnt}{$dptn} = 1;
		}
		$c++;
	}
	
	return $c;
}

######################################################################
# Check if device/channel name or address is valid and refers to an
# existing device or channel.
######################################################################

sub HMCCU_IsValidDeviceOrChannel ($$)
{
	my ($hash, $param) = @_;

	if (HMCCU_IsDevAddr ($param, 1) || HMCCU_IsChnAddr ($param, 1)) {
		my ($i, $a) = split (/\./, $param);
		return 0 if (! exists ($hash->{hmccu}{dev}{$a}));
		return $hash->{hmccu}{dev}{$a}{valid};		
	}
	
	if (HMCCU_IsDevAddr ($param, 0) || HMCCU_IsChnAddr ($param, 0)) {
		return 0 if (! exists ($hash->{hmccu}{dev}{$param}));
		return $hash->{hmccu}{dev}{$param}{valid};
	}
	else {
		return 0 if (! exists ($hash->{hmccu}{adr}{$param}));
		return $hash->{hmccu}{adr}{$param}{valid};
	}
}

######################################################################
# Check if device name or address is valid and refers to an existing
# device.
######################################################################

sub HMCCU_IsValidDevice ($$)
{
	my ($hash, $param) = @_;

	if (HMCCU_IsDevAddr ($param, 1)) {
		my ($i, $a) = split (/\./, $param);
		return 0 if (! exists ($hash->{hmccu}{dev}{$a}));
		return $hash->{hmccu}{dev}{$a}{valid};		
	}
	
	if (HMCCU_IsDevAddr ($param, 0)) {
		return 0 if (! exists ($hash->{hmccu}{dev}{$param}));
		return $hash->{hmccu}{dev}{$param}{valid};
	}
	else {
		return 0 if (! exists ($hash->{hmccu}{adr}{$param}));
		return $hash->{hmccu}{adr}{$param}{valid} && $hash->{hmccu}{adr}{$param}{addtype} eq 'dev';
	}
}

######################################################################
# Check if channel name or address is valid and refers to an existing
# channel.
######################################################################

sub HMCCU_IsValidChannel ($$)
{
	my ($hash, $param) = @_;

	if (HMCCU_IsChnAddr ($param, 1)) {
		my ($i, $a) = split (/\./, $param);
		return 0 if (! exists ($hash->{hmccu}{dev}{$a}));
		return $hash->{hmccu}{dev}{$a}{valid};		
	}
	
	if (HMCCU_IsChnAddr ($param, 0)) {
		return 0 if (! exists ($hash->{hmccu}{dev}{$param}));
		return $hash->{hmccu}{dev}{$param}{valid};
	}
	else {
		return 0 if (! exists ($hash->{hmccu}{adr}{$param}));
		return $hash->{hmccu}{adr}{$param}{valid} && $hash->{hmccu}{adr}{$param}{addtype} eq 'chn';
	}
}

######################################################################
# Get CCU parameters of device or channel.
# Returns list containing interface, deviceaddress, name, type and
# channels.
######################################################################

sub HMCCU_GetCCUDeviceParam ($$)
{
	my ($hash, $param) = @_;
	my $name = $hash->{NAME};
	my $devadd;
	my $add = undef;
	my $chn = undef;

	if (HMCCU_IsDevAddr ($param, 1) || HMCCU_IsChnAddr ($param, 1)) {
		my $i;
		($i, $add) = split (/\./, $param);
	}
	else {
		if (HMCCU_IsDevAddr ($param, 0) || HMCCU_IsChnAddr ($param, 0)) {
			$add = $param;
		}
		else {
			if (exists ($hash->{hmccu}{adr}{$param})) {
				$add = $hash->{hmccu}{adr}{$param}{address};
			}
		}
	}
	
	return (undef, undef, undef, undef) if (!defined ($add));
	($devadd, $chn) = HMCCU_SplitChnAddr ($add);
	return (undef, undef, undef, undef) if (!defined ($devadd) ||
		!exists ($hash->{hmccu}{dev}{$devadd}) || $hash->{hmccu}{dev}{$devadd}{valid} == 0);
	
	return ($hash->{hmccu}{dev}{$devadd}{interface}, $add, $hash->{hmccu}{dev}{$add}{name},
		$hash->{hmccu}{dev}{$devadd}{type}, $hash->{hmccu}{dev}{$add}{channels});
}

######################################################################
# Get list of valid datapoints for device type.
# hash = hash of client or IO device
# devtype = Homematic device type
# chn = Channel number, -1=all channels
# oper = Valid operation: 1=Read, 2=Write, 4=Event
# dplistref = Reference for array with datapoints.
# Return number of datapoints.
######################################################################

sub HMCCU_GetValidDatapoints ($$$$$)
{
	my ($hash, $devtype, $chn, $oper, $dplistref) = @_;
	
	my $hmccu_hash = HMCCU_GetHash ($hash);
	
	my $ccuflags = AttrVal ($hmccu_hash->{NAME}, 'ccuflags', 'null');
	return 0 if ($ccuflags =~ /dptnocheck/);

	return 0 if (!exists ($hmccu_hash->{hmccu}{dp}));
	
	if (!defined ($chn)) {
		Log3 $hash->{NAME}, 2, $hash->{NAME}.": chn undefined";
		return 0;
	}
	
	if ($chn >= 0) {
		if (exists ($hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$chn})) {
			foreach my $dp (sort keys %{$hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$chn}}) {
				if ($hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$chn}{$dp}{oper} & $oper) {
					push @$dplistref, $dp;
				}
			}
		}
	}
	else {
		if (exists ($hmccu_hash->{hmccu}{dp}{$devtype})) {
			foreach my $ch (sort keys %{$hmccu_hash->{hmccu}{dp}{$devtype}{ch}}) {
				foreach my $dp (sort keys %{$hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$ch}}) {
					if ($hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$ch}{$dp}{oper} & $oper) {
						push @$dplistref, $ch.".".$dp;
					}
				}
			}
		}
	}
	
	return scalar (@$dplistref);
}

######################################################################
# Find a datapoint for device type.
# hash = hash of client or IO device
# devtype = Homematic device type
# chn = Channel number, -1=all channels
# oper = Valid operation: 1=Read, 2=Write, 4=Event
# Return channel of first match or -1.
######################################################################

sub HMCCU_FindDatapoint ($$$$$)
{
	my ($hash, $devtype, $chn, $dpt, $oper) = @_;
	
	my $hmccu_hash = HMCCU_GetHash ($hash);

	return -1 if (!exists ($hmccu_hash->{hmccu}{dp}));
	
	if ($chn >= 0) {
		if (exists ($hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$chn})) {
			foreach my $dp (sort keys %{$hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$chn}}) {
				return $chn if ($dp eq $dpt &&
					$hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$chn}{$dp}{oper} & $oper);
			}
		}
	}
	else {
		if (exists ($hmccu_hash->{hmccu}{dp}{$devtype})) {
			foreach my $ch (sort keys %{$hmccu_hash->{hmccu}{dp}{$devtype}{ch}}) {
				foreach my $dp (sort keys %{$hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$ch}}) {
					return $ch if ($dp eq $dpt &&
						$hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$ch}{$dp}{oper} & $oper);
				}
			}
		}
	}
	
	return -1;
}

######################################################################
# Get channel number and datapoint name for special datapoint.
# Valid modes are ontime, ramptime, submit, level
######################################################################

sub HMCCU_GetSwitchDatapoint ($$$)
{
	my ($hash, $devtype, $mode) = @_;

	my $hmccu_hash = HMCCU_GetHash ($hash);
		
	if (exists ($hmccu_hash->{hmccu}{dp}{$devtype}{spc}{$mode})) {
		return $hmccu_hash->{hmccu}{dp}{$devtype}{spc}{$mode};
	}
	else {
		return '';
	}
}

######################################################################
# Check if datapoint is valid.
# Parameter chn can be a channel address or a channel number.
# Parameter dpt can contain a channel number.
# Parameter oper specifies access flag:
#   1 = datapoint readable
#   2 = datapoint writeable
# Return 1 if ccuflags is set to dptnocheck or datapoint is valid.
# Otherwise 0.
######################################################################

sub HMCCU_IsValidDatapoint ($$$$$)
{
	my ($hash, $devtype, $chn, $dpt, $oper) = @_;
	
	my $hmccu_hash = HMCCU_GetHash ($hash);
	return 0 if (!defined ($hmccu_hash));
	
	if ($hash->{TYPE} eq 'HMCCU' && !defined ($devtype)) {
		$devtype = HMCCU_GetDeviceType ($hmccu_hash, $chn, 'null');
	}
	
	my $ccuflags = AttrVal ($hmccu_hash->{NAME}, 'ccuflags', 'null');
	return 1 if ($ccuflags =~ /dptnocheck/);

	return 1 if (!exists ($hmccu_hash->{hmccu}{dp}));

	my $chnno = $chn;
	if (HMCCU_IsChnAddr ($chn, 0)) {
		my ($a, $c) = split(":",$chn);
		$chnno = $c;
	}
	
	# If datapoint name has format channel-number.datapoint ignore parameter chn
	if ($dpt =~ /^([0-9]{1,2})\.(.+)$/) {
		$chnno = $1;
		$dpt = $2;
	}
	
	return (exists ($hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$chnno}{$dpt}) &&
	   ($hmccu_hash->{hmccu}{dp}{$devtype}{ch}{$chnno}{$dpt}{oper} & $oper)) ? 1 : 0;
}

######################################################################
# Get list of device or channel addresses for which device or channel
# name matches regular expression.
# Parameter mode can be 'dev' or 'chn'.
# Return number of matching entries.
######################################################################

sub HMCCU_GetMatchingDevices ($$$$)
{
	my ($hash, $regexp, $mode, $listref) = @_;
	my $c = 0;

	foreach my $name (sort keys %{$hash->{hmccu}{adr}}) {
		next if ($name !~/$regexp/ || $hash->{hmccu}{adr}{$name}{addtype} ne $mode ||
		   $hash->{hmccu}{adr}{$name}{valid} == 0);
		push (@$listref, $hash->{hmccu}{adr}{$name}{address});
		$c++;
	}

	return $c;
}

######################################################################
# Get name of a CCU device by address.
# Channel number will be removed if specified.
######################################################################

sub HMCCU_GetDeviceName ($$$)
{
	my ($hash, $addr, $default) = @_;

	if (HMCCU_IsDevAddr ($addr, 0) || HMCCU_IsChnAddr ($addr, 0)) {
		$addr =~ s/:[0-9]+$//;
		if (exists ($hash->{hmccu}{dev}{$addr})) {
			return $hash->{hmccu}{dev}{$addr}{name};
		}
	}

	return $default;
}

######################################################################
# Get name of a CCU device channel by address.
######################################################################

sub HMCCU_GetChannelName ($$$)
{
	my ($hash, $addr, $default) = @_;

	if (HMCCU_IsChnAddr ($addr, 0)) {
		if (exists ($hash->{hmccu}{dev}{$addr})) {
			return $hash->{hmccu}{dev}{$addr}{name};
		}
	}

	return $default;
}

######################################################################
# Get type of a CCU device by address.
# Channel number will be removed if specified.
######################################################################

sub HMCCU_GetDeviceType ($$$)
{
	my ($hash, $addr, $default) = @_;

	if (HMCCU_IsDevAddr ($addr, 0) || HMCCU_IsChnAddr ($addr, 0)) {
		$addr =~ s/:[0-9]+$//;
		if (exists ($hash->{hmccu}{dev}{$addr})) {
			return $hash->{hmccu}{dev}{$addr}{type};
		}
	}

	return $default;
}


######################################################################
# Get number of channels of a CCU device.
# Channel number will be removed if specified.
######################################################################

sub HMCCU_GetDeviceChannels ($$$)
{
	my ($hash, $addr, $default) = @_;

	if (HMCCU_IsDevAddr ($addr, 0) || HMCCU_IsChnAddr ($addr, 0)) {
		$addr =~ s/:[0-9]+$//;
		if (exists ($hash->{hmccu}{dev}{$addr})) {
			return $hash->{hmccu}{dev}{$addr}{channels};
		}
	}

	return 0;
}

######################################################################
# Get interface of a CCU device by address.
# Channel number will be removed if specified.
######################################################################

sub HMCCU_GetDeviceInterface ($$$)
{
	my ($hash, $addr, $default) = @_;

	if (HMCCU_IsDevAddr ($addr, 0) || HMCCU_IsChnAddr ($addr, 0)) {
		$addr =~ s/:[0-9]+$//;
		if (exists ($hash->{hmccu}{dev}{$addr})) {
			return $hash->{hmccu}{dev}{$addr}{interface};
		}
	}

	return $default;
}

######################################################################
# Get address of a CCU device or channel by name.
# Return array with device address and channel no.
######################################################################

sub HMCCU_GetAddress ($$$$)
{
	my ($hash, $name, $defadd, $defchn) = @_;
	my $add = $defadd;
	my $chn = $defchn;

	if (exists ($hash->{hmccu}{adr}{$name})) {
		# Address known by HMCCU
		my $addr = $hash->{hmccu}{adr}{$name}{address};
		if (HMCCU_IsChnAddr ($addr, 0)) {
			($add, $chn) = split (":", $addr);
		}
		elsif (HMCCU_IsDevAddr ($addr, 0)) {
			$add = $addr;
		}
	}
	else {
		# Address not known. Query CCU
		my $response = HMCCU_GetCCUObjectAttribute ($hash, $name, "Address()");
		if (defined ($response)) {
			if (HMCCU_IsChnAddr ($response, 0)) {
				($add, $chn) = split (":", $response);
				$hash->{hmccu}{adr}{$name}{address} = $response;
				$hash->{hmccu}{adr}{$name}{addtype} = 'chn';
			}
			elsif (HMCCU_IsDevAddr ($response, 0)) {
				$add = $response;
				$hash->{hmccu}{adr}{$name}{address} = $response;
				$hash->{hmccu}{adr}{$name}{addtype} = 'dev';
			}
		}
	}

	return ($add, $chn);
}

######################################################################
# Check if parameter is a channel address (syntax)
# f=1: Interface required.
######################################################################

sub HMCCU_IsChnAddr ($$)
{
	my ($id, $f) = @_;

	if ($f) {
		return ($id =~ /^.+\.[\*]*[A-Z]{3}[0-9]{7}:[0-9]{1,2}$/ ||
		   $id =~ /^.+\.[0-9A-F]{12,14}:[0-9]{1,2}$/ ||
		   $id =~ /^.+\.OL-.+:[0-9]{1,2}$/ ||
		   $id =~ /^.+\.BidCoS-RF:[0-9]{1,2}$/) ? 1 : 0;
	}
	else {
		return ($id =~ /^[\*]*[A-Z]{3}[0-9]{7}:[0-9]{1,2}$/ ||
		   $id =~ /^[0-9A-F]{12,14}:[0-9]{1,2}$/ ||
		   $id =~ /^OL-.+:[0-9]{1,2}$/ ||
		   $id =~ /^BidCoS-RF:[0-9]{1,2}$/) ? 1 : 0;
	}
}

######################################################################
# Check if parameter is a device address (syntax)
# f=1: Interface required.
######################################################################

sub HMCCU_IsDevAddr ($$)
{
	my ($id, $f) = @_;

	if ($f) {
		return ($id =~ /^.+\.[\*]*[A-Z]{3}[0-9]{7}$/ ||
		   $id =~ /^.+\.[0-9A-F]{12,14}$/ ||
		   $id =~ /^.+\.OL-.+$/ ||
		   $id =~ /^.+\.BidCoS-RF$/) ? 1 : 0;
	}
	else {
		return ($id =~ /^[\*]*[A-Z]{3}[0-9]{7}$/ ||
		   $id =~ /^[0-9A-F]{12,14}$/ ||
		   $id =~ /^OL-.+$/ ||
		   $id eq 'BidCoS-RF') ? 1 : 0;
	}
}

######################################################################
# Split channel address into device address and channel number.
# Returns device address only if parameter is already a device address.
######################################################################

sub HMCCU_SplitChnAddr ($)
{
	my ($addr) = @_;

	if (HMCCU_IsChnAddr ($addr, 0)) {
		return split (":", $addr);
	}
	elsif (HMCCU_IsDevAddr ($addr, 0)) {
		return ($addr, '');
	}

	return ('', '');
}

######################################################################
# Query object attribute from CCU. Attribute must be a valid method
# for specified object, i.e. Address()
######################################################################

sub HMCCU_GetCCUObjectAttribute ($$$)
{
	my ($hash, $object, $attr) = @_;

	my $url = 'http://'.$hash->{host}.':8181/do.exe?r1=dom.GetObject("'.$object.'").'.$attr;
	my $response = GetFileFromURL ($url);
	if (defined ($response) && $response !~ /<r1>null</) {
		if ($response =~ /<r1>(.+)<\/r1>/) {
			return $1;
		}
	}

	return undef;
}

######################################################################
# Get list of client devices matching the specified criteria.
# If no criteria is specified all device names will be returned.
# Parameters modexp and namexp are regular expressions for module
# name and device name. Parameter internal contains an expression
# like internal=valueexp.
# All parameters can be undefined.
######################################################################
 
sub HMCCU_FindClientDevices ($$$$)
{
	my ($hash, $modexp, $namexp, $internal) = @_;
	my @devlist = ();

	foreach my $d (keys %defs) {
		my $ch = $defs{$d};
		next if (!defined ($ch->{TYPE}) || !defined ($ch->{NAME}));
		next if (defined ($modexp) && $ch->{TYPE} !~ /$modexp/);
		next if (defined ($namexp) && $ch->{NAME} !~ /$namexp/);
		next if (defined ($hash) && exists ($ch->{IODev}) && $ch->{IODev} != $hash);
		if (defined ($internal)) {
			my ($i, $v) = split ('=', $internal);
			next if (defined ($v) && exists ($ch->{$i}) && $ch->{$i} !~ /$v/);
		}
		push @devlist, $ch->{NAME};
	}

	return @devlist;
}

######################################################################
# Get name of assigned client device of type HMCCURPC.
# Create a HMCCURPC device if no one is found and parameter create
# is set to 1.
# Return empty string if HMCCURPC device cannot be identified
######################################################################

sub HMCCU_GetRPCDevice ($$)
{
	my ($hash, $create) = @_;
	my $name = $hash->{NAME};
	my $rpcdevname = '';

	# RPC device already defined
	if (defined ($hash->{RPCDEV})) {
		if (exists ($defs{$hash->{RPCDEV}})) {
			if ($defs{$hash->{RPCDEV}}->{IODev} == $hash) {
				$rpcdevname = $hash->{RPCDEV};
			}
			else {
				Log3 $name, 1, "HMCCU: RPC device $rpcdevname is not assigned to $name";
			}
		}
		else {
			Log3 $name, 1, "HMCCU: RPC device $rpcdevname not found";
		}
	}
	else {
		# Search for HMCCURPC devices associated with I/O device
		my @devlist = HMCCU_FindClientDevices ($hash, 'HMCCURPC', undef, undef);
		my $devcnt = scalar (@devlist);
		if ($devcnt == 0 && $create) {
			# Define HMCCURPC device with same room and group as HMCCU device
			$rpcdevname = $name."_rpc";
			Log3 $name, 1, "HMCCU: Creating new RPC device $rpcdevname";
			my $ret = CommandDefine (undef, $rpcdevname." HMCCURPC ".$hash->{host});
			if (!defined ($ret)) {
				# HMCCURPC device created. Copy some attributes from HMCCU device
				my $room = AttrVal ($name, 'room', '');
				CommandAttr (undef, "$rpcdevname room $room") if ($room ne '');
				my $group = AttrVal ($name, 'group', '');
				CommandAttr (undef, "$rpcdevname group $group") if ($group ne '');
				my $icon = AttrVal ($name, 'icon', '');
				CommandAttr (undef, "$rpcdevname icon $icon") if ($icon ne '');
				$hash->{RPCDEV} = $rpcdevname;
				CommandSave (undef, undef);
			}
			else {
				Log3 $name, 1, "HMCCU: Definition of RPC device failed. $ret";
				$rpcdevname = '';
			}
		}
		elsif ($devcnt == 1) {
			$rpcdevname = $devlist[0];
			$hash->{RPCDEV} = $devlist[0];
		}
		elsif ($devcnt > 1) {
			# Found more than 1 HMCCURPC device
			Log3 $name, 2, "HMCCU: Found more than one HMCCURPC device. Specify device with attribute rpcdevice";
		}
	}

	return $rpcdevname;
}

######################################################################
# Get hash of HMCCU IO device which is responsible for device or
# channel specified by parameter
######################################################################

sub HMCCU_FindIODevice ($)
{
	my ($param) = @_;
	
	foreach my $dn (sort keys %defs) {
		my $ch = $defs{$dn};
		next if (!exists ($ch->{TYPE}));
		next if ($ch->{TYPE} ne 'HMCCU');
		
		return $ch if (HMCCU_IsValidDeviceOrChannel ($ch, $param));
	}
	
	return undef;
}

######################################################################
# Get hash of HMCCU IO device. Useful for client devices. Accepts hash
# of HMCCU, HMCCUDEV or HMCCUCHN device as parameter.
######################################################################

sub HMCCU_GetHash ($@)
{
	my ($hash) = @_;

	if (defined ($hash) && $hash != 0) {
		if ($hash->{TYPE} eq 'HMCCUDEV' || $hash->{TYPE} eq 'HMCCUCHN') {
			return $hash->{IODev} if (exists ($hash->{IODev}));
			return HMCCU_FindIODevice ($hash->{ccuaddr}) if (exists ($hash->{ccuaddr}));
		}
		elsif ($hash->{TYPE} eq 'HMCCU') {
			return $hash;
		}
	}

	# Search for first HMCCU device
	foreach my $dn (sort keys %defs) {
		my $ch = $defs{$dn};
		next if (!exists ($ch->{TYPE}));
		return $ch if ($ch->{TYPE} eq 'HMCCU');
	}

	return undef;
}

######################################################################
# Get attribute of client device. Fallback to attribute of IO device.
######################################################################

sub HMCCU_GetAttribute ($$$$)
{
	my ($hmccu_hash, $cl_hash, $attr_name, $attr_def) = @_;

	my $value = AttrVal ($cl_hash->{NAME}, $attr_name, '');
	$value = AttrVal ($hmccu_hash->{NAME}, $attr_name, $attr_def) if ($value eq '');

	return $value;
}

######################################################################
# Get number of occurrences of datapoint.
# Return 0 if datapoint does not exist.
######################################################################

sub HMCCU_GetDatapointCount ($$$)
{
	my ($hash, $devtype, $dpt) = @_;
	
	if (exists ($hash->{hmccu}{dp}{$devtype}{cnt}{$dpt})) {
		return $hash->{hmccu}{dp}{$devtype}{cnt}{$dpt};
	}
	else {
		return 0;
	}
}

######################################################################
# Get channels and datapoints from attributes statechannel,
# statedatapoint and controldatapoint.
# Return attribute values. Attribute controldatapoint is splitted into
# controlchannel and datapoint name. If attribute statedatapoint
# contains channel number it is splitted into statechannel and
# datapoint name.
######################################################################

sub HMCCU_GetSpecialDatapoints ($$$$$)
{
#	my ($hash, $defsc, $defsd, $defcc, $defcd) = @_;
	my ($hash, $sc, $sd, $cc, $cd) = @_;
	my $name = $hash->{NAME};
	my $type = $hash->{TYPE};

	my $statedatapoint = AttrVal ($name, 'statedatapoint', '');
	my $statechannel = AttrVal ($name, 'statechannel', '');
	my $controldatapoint = AttrVal ($name, 'controldatapoint', '');
	
	if ($statedatapoint ne '') {
		if ($statedatapoint =~ /^([0-9]+)\.(.+)$/) {
			($sc, $sd) = ($1, $2);
		}
		else {
			$sd = $statedatapoint;
		}
	}
	$sc = $statechannel if ($statechannel ne '' && $sc eq '');

	if ($controldatapoint ne '') {
		if ($controldatapoint =~ /^([0-9]+)\.(.+)$/) {
			($cc, $cd) = ($1, $2);
		}
		else {
			$cd = $controldatapoint;
		}
	}
	
	# For devices of type HMCCUCHN extract channel numbers from CCU device address
	if ($type eq 'HMCCUCHN') {
		$sc = $hash->{ccuaddr};
		$sc =~ s/^[\*]*[0-9A-Z]+://;
		$cc = $sc;
	}
	
	# Try to find state channel and state datapoint
	my $c = -1;
	if ($sc eq '' && $sd ne '') {
		$c = HMCCU_FindDatapoint ($hash, $hash->{ccutype}, -1, $sd, 3);
		$sc = $c if ($c >= 0);
	}
	
	# Try to find control channel
	if ($cc eq '' && $cd ne '') {
		$c = HMCCU_FindDatapoint  ($hash, $hash->{ccutype}, -1, $cd, 3);
		$cc = $c if ($c >= 0);
	}

	return ($sc, $sd, $cc, $cd);
}

######################################################################
# Get reading format considering default attribute
# ccudef-readingformat defined in I/O device.
# Default reading format for virtual groups is always 'name'.
######################################################################

sub HMCCU_GetAttrReadingFormat ($$)
{
	my ($clhash, $iohash) = @_;
	
	my $clname = $clhash->{NAME};
	my $ioname = $iohash->{NAME};
	my $rfdef = '';
	
	if (exists ($clhash->{ccutype}) && $clhash->{ccutype} =~ /^HM-CC-VG/) {
		$rfdef = 'name';
	}
	else {
		$rfdef = AttrVal ($ioname, 'ccudef-readingformat', 'datapoint');
	}
	
	return  AttrVal ($clname, 'ccureadingformat', $rfdef);
}

######################################################################
# Get attributes substitute and substexcl considering default
# attribute ccudef-substitute defined in I/O device.
# Substitute ${xxx} by datapoint value.
######################################################################

sub HMCCU_GetAttrSubstitute ($$)
{
	my ($clhash, $iohash) = @_;
	my $fnc = "GetAttrSubstitute";
	
	my $clname = $clhash->{NAME};
	my $ioname = $iohash->{NAME};

	my $ccuflags = AttrVal ($clname, 'ccuflags', 'null');
	my $substdef = AttrVal ($ioname, 'ccudef-substitute', '');
	my $subst = AttrVal ($clname, 'substitute', $substdef);
	$subst .= ";$substdef" if ($subst ne $substdef && $substdef ne '');
	Log3 $clname, 2, "HMCCU: $fnc: subst = $subst" if ($ccuflags =~ /trace/);
	
	return $subst if ($subst !~ /\$\{.+\}/);

	$subst = HMCCU_SubstVariables ($clhash, $subst);

	Log3 $clname, 2, "HMCCU: fnc: subst_vars = $subst" if ($ccuflags =~ /trace/);
	
	return $subst;
}

######################################################################
# Clear RPC queue
######################################################################

sub HMCCU_ResetRPCQueue ($$)
{
	my ($hash, $port) = @_;
	my $name = $hash->{NAME};

	my $rpcqueue = AttrVal ($name, 'rpcqueue', '/tmp/ccuqueue');
	my $clkey = 'CB'.$port;

	if (HMCCU_QueueOpen ($hash, $rpcqueue."_".$port."_".$hash->{CCUNum})) {
		HMCCU_QueueReset ($hash);
		while (defined (HMCCU_QueueDeq ($hash))) { }
		HMCCU_QueueClose ($hash);
	}
	$hash->{hmccu}{rpc}{$clkey}{queue} = '' if (exists ($hash->{hmccu}{rpc}{$clkey}{queue}));
}

######################################################################
# Process RPC server event
######################################################################

sub HMCCU_ProcessEvent ($$)
{
	my ($hash, $event) = @_;
	my $name = $hash->{NAME};
	my $rh = \%{$hash->{hmccu}{rpc}};
	
	return undef if (!defined ($event) || $event eq '');

	my @t = split (/\|/, $event);
	my $tc = scalar (@t);

	# Update statistic counters
	if (exists ($hash->{hmccu}{ev}{$t[0]})) {
		$hash->{hmccu}{evtime} = time ();
		$hash->{hmccu}{ev}{total}++;
		$hash->{hmccu}{ev}{$t[0]}++;
		$hash->{hmccu}{evtimeout} = 0 if ($hash->{hmccu}{evtimeout} == 1);
	}
	else {
		my $errtok = $t[0];
		$errtok =~ s/([\x00-\xFF])/sprintf("0x%X ",ord($1))/eg;
		Log3 $name, 2, "HMCCU: Received unknown event from CCU: ".$errtok;
		return undef;
	}
	
	# Check event syntax
	if (exists ($rpceventargs{$t[0]}) && ($tc-1) != $rpceventargs{$t[0]}) {
		Log3 $name, 2, "HMCCU: Wrong number of parameters in event $event";
		return undef;
	}
		
	if ($t[0] eq 'EV') {
		#
		# Update of datapoint
		# Input:  EV|Adress|Datapoint|Value
		# Output: EV, DevAdd, ChnNo, Reading='', Value
		#
		return undef if ($tc != 4 || !HMCCU_IsChnAddr ($t[1], 0));
		my ($add, $chn) = split (/:/, $t[1]);
		return ($t[0], $add, $chn, $t[2], $t[3]);
	}
	elsif ($t[0] eq 'SL') {
		#
		# RPC server enters server loop
		# Input:  SL|Pid|Servername
		# Output: SL, Servername, Pid
		#
		my $clkey = $t[2];
		if (!exists ($rh->{$clkey})) {
			Log3 $name, 0, "HMCCU: Received SL event for unknown RPC server $clkey";
			return undef;
		}
		Log3 $name, 0, "HMCCU: Received SL event. RPC server $clkey enters server loop";
		$rh->{$clkey}{loop} = 1 if ($rh->{$clkey}{pid} == $t[1]);
		return ($t[0], $clkey, $t[1]);
	}
	elsif ($t[0] eq 'IN') {
		#
		# RPC server initialized
		# Input:  IN|INIT|State|Servername
		# Output: IN, Servername, Running, NotRunning, ClientsUpdated, UpdateErrors
		#
		my $clkey = $t[3];
		my $norun = 0;
		my $run = 0;
		my $c_ok = 0;
		my $c_err = 0;
		if (!exists ($rh->{$clkey})) {
			Log3 $name, 0, "HMCCU: Received IN event for unknown RPC server $clkey";
			return undef;
		}
		Log3 $name, 0, "HMCCU: Received IN event. RPC server $clkey initialized.";
		$rh->{$clkey}{state} = $rh->{$clkey}{pid} != 0 ? "running" : "initialized";
		
		# Check if all RPC servers were initialized. Set overall status
		foreach my $ser (keys %{$rh}) {
			$norun++ if ($rh->{$ser}{state} ne "running" && $rh->{$ser}{pid} != 0);
			$norun++ if ($rh->{$ser}{state} ne "initialized" && $rh->{$ser}{pid} == 0);
			$run++ if ($rh->{$ser}{state} eq "running");
		}
		if ($norun == 0) {
			$hash->{RPCState} = "running";
			readingsSingleUpdate ($hash, "rpcstate", "running", 1);
			HMCCU_SetState ($hash, "OK");
			($c_ok, $c_err) = HMCCU_UpdateClients ($hash, '.*', 'Attr', 0);
			Log3 $name, 2, "HMCCU: Updated devices. Success=$c_ok Failed=$c_err";
			Log3 $name, 1, "HMCCU: All RPC servers running";
			DoTrigger ($name, "RPC server running");
		}
		$hash->{hmccu}{rpcinit} = $run;
		return ($t[0], $clkey, $run, $norun, $c_ok, $c_err);
	}
	elsif ($t[0] eq 'EX') {
		#
		# RPC server shutdown
		# Input:  EX|SHUTDOWN|Pid|Servername
		# Output: EX, Servername, Pid, Flag, Run
		#
		my $clkey = $t[3];
		my $run = 0;
		if (!exists ($rh->{$clkey})) {
			Log3 $name, 0, "HMCCU: Received EX event for unknown RPC server $clkey";
			return undef;
		}
		
		Log3 $name, 0, "HMCCU: Received EX event. RPC server $clkey terminated.";
		my $f = $hash->{RPCState} eq "restarting" ? 2 : 1;
		delete $rh->{$clkey};
	
		# Check if all RPC servers were terminated. Set overall status
		foreach my $ser (keys %{$rh}) {
			$run++ if ($rh->{$ser}{state} ne "stopped");
		}
		if ($run == 0) {
			if ($f == 1) {
				$hash->{RPCState} = "stopped";
				readingsSingleUpdate ($hash, "rpcstate", "stopped", 1);
			}
			$hash->{RPCPID} = '0';
		}
		$hash->{hmccu}{rpccount} = $run;
		$hash->{hmccu}{rpcinit} = $run;
		return ($t[0], $clkey, $t[2], $f, $run);
	}
	elsif ($t[0] eq 'ND') {
		#
		# CCU device added
		# Input:  ND|C/D|Address|Type|Version|Firmware|RxMode
		# Output: ND, DevAdd, C/D, Type, Version, Firmware, RxMode
		#
		return ($t[0], $t[2], $t[1], $t[3], $t[4], $t[5], $t[6]);
	}
	elsif ($t[0] eq 'DD' || $t[0] eq 'RA') {
		#
		# CCU device added, deleted or readded
		# Input:  {DD,RA}|Address
		# Output: {DD,RA}, DevAdd
		#
		return ($t[0], $t[1]);
	}
	elsif ($t[0] eq 'UD') {
		#
		# CCU device updated
		# Input:  UD|Address|Hint
		# Output: UD, DevAdd, Hint
		#
		return ($t[0], $t[1], $t[2]);
	}
	elsif ($t[0] eq 'RD') {
		#
		# CCU device replaced
		# Input:  RD|Address1|Address2
		# Output: RD, Address1, Address2
		#
		return ($t[0], $t[1], $t[2]);
	}
	elsif ($t[0] eq 'ST') {
		#
		# Statistic data. Store snapshots of sent and received events.
		# Input:  ST|nTotal|nEV|nND|nDD|nRD|nRA|nUD|nIN|nSL|nEX
		# Output: ST, ...
		#
		my @stkeys = ('total', 'EV', 'ND', 'DD', 'RD', 'RA', 'UD', 'IN', 'SL', 'EX');
		for (my $i=0; $i<10; $i++) {
			$hash->{hmccu}{evs}{$stkeys[$i]} = $t[$i+1];
			$hash->{hmccu}{evr}{$stkeys[$i]} = $hash->{hmccu}{ev}{$stkeys[$i]};
		}
		return @t;
	}
	else {
		my $errtok = $t[0];
		$errtok =~ s/([\x00-\xFF])/sprintf("0x%X ",ord($1))/eg;
		Log3 $name, 2, "HMCCU: Received unknown event from CCU: ".$errtok;
	}
	
	return undef;
}

######################################################################
# Timer function for reading RPC queue
######################################################################

sub HMCCU_ReadRPCQueue ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $eventno = 0;
	my $f = 0;
 	my @newdevices;
 	my @deldevices;
	my @termpids;
	my $newcount = 0;
	my $devcount = 0;
	my %events = ();
	my %devices = ();
	
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	my $rpcinterval = AttrVal ($name, 'rpcinterval', 5);
	my $rpcqueue = AttrVal ($name, 'rpcqueue', '/tmp/ccuqueue');
	my $rpctimeout = AttrVal ($name, 'rpcevtimeout', 300);
	my $maxevents = $rpcinterval*10;
	$maxevents = 50 if ($maxevents > 50);
	$maxevents = 10 if ($maxevents < 10);

	my @portlist = HMCCU_GetRPCPortList ($hash);
	foreach my $port (@portlist) {
		my $clkey = 'CB'.$port;
		next if (!exists ($hash->{hmccu}{rpc}{$clkey}{queue}));
		my $queuename = $hash->{hmccu}{rpc}{$clkey}{queue};
		next if ($queuename eq '');
		if (!HMCCU_QueueOpen ($hash, $queuename)) {
			Log3 $name, 1, "HMCCU: Can't open file queue $queuename";
			next;
		}

		my $element = HMCCU_QueueDeq ($hash);
		while (defined ($element)) {
			my ($et, @par) = HMCCU_ProcessEvent ($hash, $element);
			if (defined ($et)) {
				if ($et eq 'EV') {
					$events{$par[0]}{$par[1]}{$par[2]} = $par[3];
					$eventno++;
					last if ($eventno == $maxevents);
				}
				elsif ($et eq 'ND') {
#					push (@newdevices, $par[1]);
					$newcount++ if (!exists ($hash->{hmccu}{dev}{$par[0]}));
#					$hash->{hmccu}{dev}{$par[1]}{chntype} = $par[3];
					$devices{$par[0]}{flag} = 'N';
					$devices{$par[0]}{version} = $par[3];
					if ($par[1] eq 'D') {
						$devices{$par[0]}{type} = $par[2];
						$devices{$par[0]}{firmware} = $par[4];
						$devices{$par[0]}{rxmode} = $par[5];
					}
					else {
						$devices{$par[0]}{usetype} = $par[2];
					}
					$devcount++;
				}
				elsif ($et eq 'DD') {
#					push (@deldevices, $par[0]);
					$devices{$par[0]}{flag} = 'D';
					$devcount++;
#					$delcount++;
				}
				elsif ($et eq 'RD') {
					$devices{$par[0]}{flag} = 'R';
					$devices{$par[0]}{newaddr} = $par[1];			
					$devcount++;
				}
				elsif ($et eq 'SL') {
					InternalTimer (gettimeofday()+$HMCCU_INIT_INTERVAL1,
					   'HMCCU_RPCRegisterCallback', $hash, 0);
					$f = -1;
					last;
				}
				elsif ($et eq 'EX') {
					push (@termpids, $par[1]);
					$f = $par[2];
					last;
				}
			}

			last if ($f == -1);
			
			# Read next element from queue
			$element = HMCCU_QueueDeq ($hash);
		}

		HMCCU_QueueClose ($hash);
	}

	# Update readings
	HMCCU_UpdateMultipleDevices ($hash, \%events) if ($eventno > 0);

	# Update device table and client device parameter
	HMCCU_UpdateDeviceTable ($hash, \%devices) if ($devcount > 0);
	
	return if ($f == -1);
	
	# Check if events from CCU timed out
	if ($hash->{hmccu}{evtime} > 0 && time()-$hash->{hmccu}{evtime} > $rpctimeout &&
	   $hash->{hmccu}{evtimeout} == 0) {
	   $hash->{hmccu}{evtimeout} = 1;
		Log3 $name, 2, "HMCCU: Received no events from CCU since $rpctimeout seconds";
		DoTrigger ($name, "No events from CCU since $rpctimeout seconds");
	}

	my @hm_pids;
	my @ex_pids;
	HMCCU_IsRPCServerRunning ($hash, \@hm_pids, \@ex_pids);
	my $nhm_pids = scalar (@hm_pids);
	my $nex_pids = scalar (@ex_pids);
	Log3 $name, 1, "HMCCU: Externally launched RPC server(s) detected. f=$f" if ($nex_pids > 0);

	if ($f > 0) {
		# At least one RPC server has been stopped. Update PID list
		$hash->{RPCPID} = $nhm_pids > 0 ? join(',',@hm_pids) : '0';
		Log3 $name, 0, "HMCCU: RPC server(s) with PID(s) ".join(',',@termpids)." shut down. f=$f";
			
		# Output statistic counters
		foreach my $cnt (sort keys %{$hash->{hmccu}{ev}}) {
			Log3 $name, 2, "HMCCU: Eventcount $cnt = ".$hash->{hmccu}{ev}{$cnt};
		}
	}

	if ($f == 2 && $nhm_pids == 0) {
		# All RPC servers terminated and restart flag set
		if ($ccuflags =~ /intrpc/) {
			return if (HMCCU_StartIntRPCServer ($hash));
		}
		Log3 $name, 0, "HMCCU: Restart of RPC server failed";
	}

	if ($nhm_pids > 0) {
		# Reschedule reading of RPC queues if at least one RPC server is running
		InternalTimer (gettimeofday()+$rpcinterval, 'HMCCU_ReadRPCQueue', $hash, 0);
	}
	else {
		# No more RPC servers active
		Log3 $name, 0, "HMCCU: Periodical check found no RPC Servers";
		# Deregister existing callbacks
		HMCCU_RPCDeRegisterCallback ($hash);
		
		# Cleanup hash variables
		my @clkeylist = keys %{$hash->{hmccu}{rpc}};
		foreach my $clkey (@clkeylist) {
			delete $hash->{hmccu}{rpc}{$clkey};
		}
		$hash->{hmccu}{rpccount} = 0;
		$hash->{hmccu}{rpcinit} = 0;

		$hash->{RPCPID} = '0';
		$hash->{RPCPRC} = 'none';
		$hash->{RPCState} = "stopped";

		Log3 $name, 0, "HMCCU: All RPC servers stopped";
		readingsSingleUpdate ($hash, "rpcstate", "stopped", 1);
		DoTrigger ($name, "All RPC servers stopped");
	}
}

######################################################################
# Execute Homematic script on CCU.
# Parameters: hostname, script-code
######################################################################

sub HMCCU_HMScript ($$)
{
	my ($hash, $hmscript) = @_;
	my $name = $hash->{NAME};
	my $host = $hash->{host};

	my $url = "http://".$host.":8181/tclrega.exe";
	my $ua = new LWP::UserAgent ();
	my $response = $ua->post($url, Content => $hmscript);

	if (! $response->is_success ()) {
		Log3 $name, 1, "HMCCU: HMScript failed. ".$response->status_line();
		return '';
	}
	else {
		my $output = $response->content;
		$output =~ s/<xml>.*<\/xml>//;
		$output =~ s/\r//g;
		return $output;
	}
}

######################################################################
# Bulk update of reading considering attribute substexcl.
######################################################################

sub HMCCU_BulkUpdate ($$$$)
{
	my ($hash, $reading, $orgval, $subval) = @_;

	my $excl = AttrVal ($hash->{NAME}, 'substexcl', '');
	
	readingsBulkUpdate ($hash, $reading, ($excl ne '' && $reading =~ /$excl/ ? $orgval : $subval));
}

######################################################################
# Get datapoint value from CCU and update reading.
######################################################################

sub HMCCU_GetDatapoint ($@)
{
	my ($hash, $param) = @_;
	my $name = $hash->{NAME};
	my $type = $hash->{TYPE};
	my $fnc = "GetDatapoint";
	my $hmccu_hash;
	my $value = '';

	$hmccu_hash = HMCCU_GetHash ($hash);
	return (-3, $value) if (!defined ($hmccu_hash));
	return (-4, $value) if ($type ne 'HMCCU' && $hash->{ccudevstate} eq 'deleted');

	my $ccureadings = AttrVal ($name, 'ccureadings', 1);
	my $readingformat = HMCCU_GetAttrReadingFormat ($hash, $hmccu_hash);
	my ($statechn, $statedpt, $controlchn, $controldpt) = HMCCU_GetSpecialDatapoints (
	   $hash, '', 'STATE', '', '');
	my $ccuget = HMCCU_GetAttribute ($hmccu_hash, $hash, 'ccuget', 'Value');
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	my $tf = ($ccuflags =~ /trace/) ? 1 : 0;

	my $url = 'http://'.$hmccu_hash->{host}.':8181/do.exe?r1=dom.GetObject("';
	my ($int, $add, $chn, $dpt, $nam, $flags) = HMCCU_ParseObject ($hmccu_hash, $param,
		$HMCCU_FLAG_INTERFACE);
	if ($flags == $HMCCU_FLAGS_IACD) {
		$url .= $int.'.'.$add.':'.$chn.'.'.$dpt.'").'.$ccuget.'()';
	}
	elsif ($flags == $HMCCU_FLAGS_NCD) {
		$url .= $nam.'").DPByHssDP("'.$dpt.'").'.$ccuget.'()';
		($add, $chn) = HMCCU_GetAddress ($hmccu_hash, $nam, '', '');
	}
	else {
		return (-1, $value);
	}

	if ($tf) {
		Log3 $name, 2, "$type: $fnc";
		Log3 $name, 2, "$type:   URL=$url";
		Log3 $name, 2, "$type:   param=$param";
		Log3 $name, 2, "$type:   ccuget=$ccuget";
	}

	my $rawresponse = GetFileFromURL ($url);
	my $response = $rawresponse;
	$response =~ m/<r1>(.*)<\/r1>/;
	$value = $1;

	Log3 ($name, 2, "$type: $fnc: Response = ".$rawresponse) if ($tf);

	if (defined ($value) && $value ne '' && $value ne 'null') {
		$value = HMCCU_UpdateSingleDatapoint ($hash, $chn, $dpt, $value);
		Log3 $name, 2, "$type: $fnc: Value of $chn.$dpt = $value" if ($tf); 
		return (1, $value);
	}
	else {
		Log3 $name, 1, "$type: Error URL = ".$url;
		return (-2, '');
	}
}

######################################################################
# Set datapoint on CCU
######################################################################

sub HMCCU_SetDatapoint ($$$)
{
	my ($hash, $param, $value) = @_;
	my $type = $hash->{TYPE};

	my $hmccu_hash = HMCCU_GetHash ($hash);
	return -3 if (!defined ($hmccu_hash));
	return -4 if ($hash->{ccudevstate} eq 'deleted');
	my $name = $hmccu_hash->{NAME};
	my $cdname = $hash->{NAME};
	
	my $readingformat = HMCCU_GetAttrReadingFormat ($hash, $hmccu_hash);
	my $ccuflags = AttrVal ($cdname, 'ccuflags', 'null');
	my $ccuverify = AttrVal ($cdname, 'ccuverify', 0); 

	my $url = 'http://'.$hmccu_hash->{host}.':8181/do.exe?r1=dom.GetObject("';
	my ($int, $add, $chn, $dpt, $nam, $flags) = HMCCU_ParseObject ($hmccu_hash, $param,
		$HMCCU_FLAG_INTERFACE);
	return -1 if ($flags != $HMCCU_FLAGS_IACD && $flags != $HMCCU_FLAGS_NCD);
	
	if ($hash->{ccutype} eq 'HM-Dis-EP-WM55' && $dpt eq 'SUBMIT') {
		$value = HMCCU_EncodeEPDisplay ($value);
	}
	else {
		$value = HMCCU_ScaleValue ($hash, $dpt, $value, 1);
	}
	
	if ($flags == $HMCCU_FLAGS_IACD) {
		$url .= $int.'.'.$add.':'.$chn.'.'.$dpt.'").State('.$value.')';
		$nam = HMCCU_GetChannelName ($hmccu_hash, $add.":".$chn, '');
	}
	elsif ($flags == $HMCCU_FLAGS_NCD) {
		$url .= $nam.'").DPByHssDP("'.$dpt.'").State('.$value.')';
		($add, $chn) = HMCCU_GetAddress ($hmccu_hash, $nam, '', '');
	}

	my $addr = $add.":".$chn;
	
	my $response = GetFileFromURL ($url);
	if ($ccuflags =~ /trace/) {
		Log3 $name, 2, "$type: Addr=$addr Name=$nam";
		Log3 $name, 2, "$type: Script response = \n".(defined ($response) ? $response: 'undef');
		Log3 $name, 2, "$type: Script = \n".$url;
	}
	
	return -2 if (!defined ($response) || $response =~ /<r1>null</);

	# Verify setting of datapoint value or update reading with new datapoint value
	if (HMCCU_IsValidDatapoint ($hash, $hash->{ccutype}, $addr, $dpt, 1)) {
		if ($ccuverify == 1) {
#			usleep (100000);
			my ($rc, $result) = HMCCU_GetDatapoint ($hash, $param);
			return $rc;
		}
		elsif ($ccuverify == 2) {
			HMCCU_UpdateSingleDatapoint ($hash, $chn, $dpt, $value);
		}
	}
	
	return 0;
}

######################################################################
# Scale, spread and/or shift datapoint value.
# Mode: 0 = Get/Divide, 1 = Set/Multiply
# Supports reversing of value if value range is specified. Syntax for
# Rule is:
#   Datapoint:Factor
#   [!]Datapoint:Min:Max:Range1:Range2
# If Datapoint name starts with a ! the value is reversed. In case of
# an error original value is returned.
######################################################################

sub HMCCU_ScaleValue ($$$$)
{
	my ($hash, $dpt, $value, $mode) = @_;
	my $name = $hash->{NAME};
	
	my $ccuscaleval = AttrVal ($name, 'ccuscaleval', '');	
	return $value if ($ccuscaleval eq '');

	my @sl = split (',', $ccuscaleval);
	foreach my $sr (@sl) {
		my $f = 1.0;
		my @a = split (':', $sr);
		my $n = scalar (@a);
		next if ($n != 2 && $n != 5);

		my $rev = 0;
		my $dn = $a[0];
		if ($dn =~ /^\!(.+)$/) {
			$dn = $1;
			$rev = 1;
		}		
		next if ($dpt ne $dn);
			
		if ($n == 2) {
			$f = ($a[1] == 0.0) ? 1.0 : $a[1];
			return ($mode == 0) ? $value/$f : $value*$f;
		}
		else {
			# Do not scale if value out of range or interval wrong
			return $value if ($a[1] > $a[2] || $a[3] > $a[4]);
			return $value if ($mode == 0 && ($value < $a[1] || $value > $a[2]));
			return $value if ($mode == 1 && ($value >= $a[1] && $value <= $a[2]));
				
			# Reverse value 
			if ($rev) {
				my $dr = ($mode == 0) ? $a[1]+$a[2] : $a[3]+$a[4];
				$value = $dr-$value;
			}
				
			my $d1 = $a[2]-$a[1];
			my $d2 = $a[4]-$a[3];
			return $value if ($d1 == 0.0 || $d2 == 0.0);
			$f = $d1/$d2;
			return ($mode == 0) ? $value/$f+$a[3] : ($value-$a[3])*$f;
		}
	}
	
	return $value;
}

######################################################################
# Get CCU system variables and update readings.
# System variable readings are stored in I/O device.
######################################################################

sub HMCCU_GetVariables ($$)
{
	my ($hash, $pattern) = @_;
	my $count = 0;
	my $result = '';

	my $ccureadings = AttrVal ($hash->{NAME}, 'ccureadings', 1);

	my $script = qq(
object osysvar;
string ssysvarid;
foreach (ssysvarid, dom.GetObject(ID_SYSTEM_VARIABLES).EnumUsedIDs())
{
   osysvar = dom.GetObject(ssysvarid);
   WriteLine (osysvar.Name() # "=" # osysvar.Variable() # "=" # osysvar.Value());
}
	);

	my $response = HMCCU_HMScript ($hash, $script);
	return (-2, $result) if ($response eq '');
  
	readingsBeginUpdate ($hash) if ($ccureadings);

	foreach my $vardef (split /\n/, $response) {
		my @vardata = split /=/, $vardef;
		next if (@vardata != 3);
		next if ($vardata[0] !~ /$pattern/);
		my $value = HMCCU_FormatReadingValue ($hash, $vardata[2]);
		readingsBulkUpdate ($hash, $vardata[0], $value) if ($ccureadings); 
		$result .= $vardata[0].'='.$vardata[2]."\n";
		$count++;
	}

	readingsEndUpdate ($hash, 1) if ($hash->{TYPE} ne 'HMCCU' && $ccureadings);

	return ($count, $result);
}

######################################################################
# Set CCU system variable. Variable must exist in CCU.
######################################################################

sub HMCCU_SetVariable ($$$)
{
	my ($hash, $param, $value) = @_;
	my $name = $hash->{NAME};
	my $url = 'http://'.$hash->{host}.':8181/do.exe?r1=dom.GetObject("'.$param.
		'").State("'.$value.'")';

	my $response = GetFileFromURL ($url);
	if (!defined ($response) || $response =~ /<r1>null</) {
		Log3 $name, 1, "HMCCU: URL=$url";
		return -2;
	}

	return 0;
}

######################################################################
# Update all datapoints / readings of device or channel considering
# attribute ccureadingfilter.
# Parameter $ccuget can be 'State', 'Value' or 'Attr'.
######################################################################

sub HMCCU_GetUpdate ($$$)
{
	my ($cl_hash, $addr, $ccuget) = @_;
	my $name = $cl_hash->{NAME};
	my $type = $cl_hash->{TYPE};

	my $disable = AttrVal ($name, 'disable', 0);
	return 1 if ($disable == 1);

	my $hmccu_hash = HMCCU_GetHash ($cl_hash);
	return -3 if (!defined ($hmccu_hash));
	return -4 if ($type ne 'HMCCU' && $cl_hash->{ccudevstate} eq 'deleted');

	my $nam = '';
	my $script;

	$ccuget = HMCCU_GetAttribute ($hmccu_hash, $cl_hash, 'ccuget', 'Value') if ($ccuget eq 'Attr');
	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');

	if (HMCCU_IsChnAddr ($addr, 0)) {
		$nam = HMCCU_GetChannelName ($hmccu_hash, $addr, '');
		return -1 if ($nam eq '');
		my ($stadd, $stchn) = HMCCU_SplitChnAddr ($addr);
		my $stnam = HMCCU_GetChannelName ($hmccu_hash, "$stadd:0", '');
		my $chnlist = $stnam eq '' ? $nam : $stnam . "," . $nam;

		$script = qq(
string sDPId;
string sChnName;
string sChnList = "$chnlist";
integer c = 0;
foreach (sChnName, sChnList.Split(",")) {
  object oChannel = dom.GetObject (sChnName);
  if (oChannel) {
    foreach(sDPId, oChannel.DPs()) {
      object oDP = dom.GetObject(sDPId);
      if (oDP) {
        if (OPERATION_READ & oDP.Operations()) {
          WriteLine (sChnName # "=" # oDP.Name() # "=" # oDP.$ccuget());
          c = c+1;
        }
      }
    }
  }
}
WriteLine (c);
		);
	}
	elsif (HMCCU_IsDevAddr ($addr, 0)) {
		$nam = HMCCU_GetDeviceName ($hmccu_hash, $addr, '');
		return -1 if ($nam eq '');
		my $devlist = $nam;

		# Consider members of group device
		if ($type eq 'HMCCUDEV' && $cl_hash->{ccuif} eq 'VirtualDevices' &&
			exists ($cl_hash->{ccugroup})) {
			foreach my $gd (split (",", $cl_hash->{ccugroup})) {
				$nam = HMCCU_GetDeviceName ($hmccu_hash, $gd, '');
				$devlist .= ','.$nam if ($nam ne '');
			}
		}

		$script = qq(
string chnid;
string sDPId;
string sDevName;
string sDevList = "$devlist";
integer c = 0;
foreach (sDevName, sDevList.Split(",")) {
  object odev = dom.GetObject (sDevName);
  if (odev) {
    foreach (chnid, odev.Channels()) {
	   object ochn = dom.GetObject(chnid);
      if (ochn) {
		  foreach(sDPId, ochn.DPs()) {
		    object oDP = dom.GetObject(sDPId);
          if (oDP) {
            if (OPERATION_READ & oDP.Operations()) {
              WriteLine (ochn.Name() # "=" # oDP.Name() # "=" # oDP.$ccuget());
              c = c+1;
            }
          }
        }
      }
    }
  }
}
WriteLine (c);
		);
	}
	else {
		return -1;
	}

	my $response = HMCCU_HMScript ($hmccu_hash, $script);
	if ($ccuflags =~ /trace/) {
		Log3 $name, 2, "HMCCU: Addr=$addr Name=$nam";
		Log3 $name, 2, "HMCCU: Script response = \n".$response;
		Log3 $name, 2, "HMCCU: Script = \n".$script;
	}
	return -2 if ($response eq '');

	my @dpdef = split /\n/, $response;
	my $count = pop (@dpdef);
	return -10 if (!defined ($count) || $count == 0);

	my %events = ();
	foreach my $dp (@dpdef) {
		my ($chnname, $dpspec, $value) = split /=/, $dp;
		next if (!defined ($value));
		my ($iface, $chnadd, $dpt) = split /\./, $dpspec;
		next if (!defined ($dpt));
		my ($add, $chn) = HMCCU_SplitChnAddr ($chnadd);
		next if (!defined ($chn));
		$events{$add}{$chn}{$dpt} = $value;
	}
	
	HMCCU_UpdateSingleDevice ($hmccu_hash, $cl_hash, \%events);

	return 1;
}

######################################################################
# Get multiple datapoints of channels and update readings of client
# devices.
# Returncodes: -1 = Invalid channel/datapoint in list
#              -2 = CCU script execution failed
#              -3 = Cannot detect IO device
# On success number of updated readings is returned.
######################################################################

sub HMCCU_GetChannel ($$)
{
	my ($hash, $chnref) = @_;
	my $name = $hash->{NAME};
	my $type = $hash->{TYPE};
	my $count = 0;
	my $chnlist = '';
	my $result = '';
	my %chnpars;
	my %objects = ();
	my $objcount = 0;

	my $hmccuflags = AttrVal ($name, 'ccuflags', 'null');
	my $ccuget = AttrVal ($name, 'ccuget', 'Value');

	# Build channel list. Datapoints and substitution rules are ignored.
	foreach my $chndef (@$chnref) {
		my ($channel, $substitute) = split /\s+/, $chndef;
		next if (!defined ($channel) || $channel =~ /^#/ || $channel eq '');
		my ($int, $add, $chn, $dpt, $nam, $flags) = HMCCU_ParseObject ($hash, $channel,
		   $HMCCU_FLAG_INTERFACE | $HMCCU_FLAG_DATAPOINT);
		if ($flags == $HMCCU_FLAGS_IACD || $flags == $HMCCU_FLAGS_NCD) {
			$nam = HMCCU_GetChannelName ($hash, $add.':'.$chn, '') if ($flags == $HMCCU_FLAGS_IACD);
			$chnlist = $chnlist eq '' ? $nam : $chnlist.','.$nam;
			$chnpars{$nam}{sub} = $substitute;
			$chnpars{$nam}{dpt} = $dpt;
		}
		else {
			return (-1, $result);
		}
	}

	return (0, $result) if ($chnlist eq '');

	# CCU script to query datapoints
	my $script = qq(
string sDPId;
string sChannel;
string sChnList = "$chnlist";
foreach (sChannel, sChnList.Split(",")) {
  object oChannel = dom.GetObject (sChannel);
  if (oChannel) {
    foreach(sDPId, oChannel.DPs()) {
      object oDP = dom.GetObject(sDPId);
      if (oDP) {
        WriteLine (sChannel # "=" # oDP.Name() # "=" # oDP.$ccuget());
      }
    }
  }
}
	);

	my $response = HMCCU_HMScript ($hash, $script);
	return (-2, $result) if ($response eq '');
  
	# Output format is Channelname=Interface.Channeladdress.Datapoint=Value
	foreach my $dpdef (split /\n/, $response) {
		my ($chnname, $dptaddr, $value) = split /=/, $dpdef;
		next if (!defined ($value));
		my ($iface, $chnaddr, $dpt) = split /\./, $dptaddr;
		next if (!defined ($dpt));
		my ($add, $chn) = HMCCU_SplitChnAddr ($chnaddr);
		next if (!defined ($chn));
		if (defined ($chnpars{$chnname}{dpt}) && $chnpars{$chnname}{dpt} ne '') {
			next if ($dpt !~ $chnpars{$chnname}{dpt});
		}

		$value = HMCCU_Substitute ($value, $chnpars{$chnname}{sub}, 0, $chn, $dpt);
		
		$objects{$add}{$chn}{$dpt} = $value;
		$objcount++;
	}
	
	$count = HMCCU_UpdateMultipleDevices ($hash, \%objects) if ($objcount > 0);

	return ($count, $result);
}

######################################################################
# Get RPC paramSet or paramSetDescription
######################################################################

sub HMCCU_RPCGetConfig ($$$$)
{
	my ($hash, $param, $mode, $filter) = @_;
	my $name = $hash->{NAME};
	my $type = $hash->{TYPE};
	my $method = $mode eq 'listParamset' ? 'getParamset' : $mode;
	
	my $addr;
	my $result = '';

	my $hmccu_hash = HMCCU_GetHash ($hash);
	return (-3, $result) if (!defined ($hmccu_hash));
	return (-4, $result) if ($type ne 'HMCCU' && $hash->{ccudevstate} eq 'deleted');

	my $ccureadings = AttrVal ($name, 'ccureadings', 1);
	my $readingformat = HMCCU_GetAttrReadingFormat ($hash, $hmccu_hash);
	my $substitute = HMCCU_GetAttrSubstitute ($hash, $hmccu_hash);
	
	my ($int, $add, $chn, $dpt, $nam, $flags) = HMCCU_ParseObject ($hmccu_hash, $param,
		$HMCCU_FLAG_FULLADDR);
	return (-1, '') if (!($flags & $HMCCU_FLAG_ADDRESS));
	$addr = $add;
	$addr .= ':'.$chn if ($flags & $HMCCU_FLAG_CHANNEL);

	return (-9, '') if (!exists ($HMCCU_RPC_PORT{$int}));
	my $port = $HMCCU_RPC_PORT{$int};
	my $url = "http://".$hmccu_hash->{host}.":".$port."/";
	$url .= $HMCCU_RPC_URL{$port} if (exists ($HMCCU_RPC_URL{$port}));
	my $client = RPC::XML::Client->new ($url);

	my $res = $client->simple_request ($method, $addr, "MASTER");
	if (! defined ($res)) {
		return (-5, "Function not available");
	}
	elsif (ref ($res)) {
		my $parcount = scalar (keys %$res);
		if (exists ($res->{faultString})) {
			Log3 $name, 1, "HMCCU: ".$res->{faultString};
			return (-2, $res->{faultString});
		}
		elsif ($parcount == 0) {
			return (-5, "CCU returned no data");
		}
	}
	else {
		return (-2, defined ($RPC::XML::ERROR) ? $RPC::XML::ERROR : '');
	}

	if ($mode eq 'getParamsetDescription') {
		foreach my $key (sort keys %$res) {
			my $oper = '';
			$oper .= 'R' if ($res->{$key}->{OPERATIONS} & 1);
			$oper .= 'W' if ($res->{$key}->{OPERATIONS} & 2);
			$oper .= 'E' if ($res->{$key}->{OPERATIONS} & 4);
			$result .= $key.": ".$res->{$key}->{TYPE}." [".$oper."]\n";
		}
	}
	elsif ($mode eq 'listParamset') {
		foreach my $key (sort keys %$res) {
			next if ($key !~ /$filter/);
			my $value = $res->{$key};
			$result .= "$key=$value\n";
		}
	}
	else {
		readingsBeginUpdate ($hash) if ($ccureadings);

		foreach my $key (sort keys %$res) {
			next if ($key !~ /$filter/);
			my $value = $res->{$key};
			$result .= "$key=$value\n";
			next if (!$ccureadings);
			
			$value = HMCCU_FormatReadingValue ($hash, $value);
			$value = HMCCU_Substitute ($value, $substitute, 0, $chn, $key);
			my @readings = HMCCU_GetReadingName ($hash, $int, $add, $chn, $key, $nam, $readingformat);
			foreach my $rn (@readings) {
				next if ($rn eq '');
				$rn = "R-".$rn;
				readingsBulkUpdate ($hash, $rn, $value);
			}
		}

		readingsEndUpdate ($hash, 1) if ($ccureadings);
	}

	return (0, $result);
}

######################################################################
# Set RPC paramSet
######################################################################

sub HMCCU_RPCSetConfig ($$$)
{
	my ($hash, $param, $parref) = @_;
	my $name = $hash->{NAME};
	my $type = $hash->{TYPE};

	my $ccuflags = AttrVal ($name, 'ccuflags', 'null');
	my $addr;

	my $hmccu_hash = HMCCU_GetHash ($hash);
	return -3 if (!defined ($hmccu_hash));
	return -4 if ($type ne 'HMCCU' && $hash->{ccudevstate} eq 'deleted');
	
	my ($int, $add, $chn, $dpt, $nam, $flags) = HMCCU_ParseObject ($hmccu_hash, $param,
		$HMCCU_FLAG_FULLADDR);
	return -1 if (!($flags & $HMCCU_FLAG_ADDRESS));
	$addr = $add;
	$addr .= ':'.$chn if ($flags & $HMCCU_FLAG_CHANNEL);

	return -9 if (!exists ($HMCCU_RPC_PORT{$int}));
	my $port = $HMCCU_RPC_PORT{$int};
	my $url = "http://".$hmccu_hash->{host}.":".$port."/";
	$url .= $HMCCU_RPC_URL{$port} if (exists ($HMCCU_RPC_URL{$port}));

	if ($ccuflags =~ /trace/) {
		my $ps = '';
		foreach my $p (keys %$parref) {
			$ps .= ", ".$p."=".$parref->{$p};
		}
		Log3 $name, 2, "HMCCU: RPCSetConfig: addr=$addr".$ps;
	}
	
	my $client = RPC::XML::Client->new ($url);
	my $res = $client->simple_request ("putParamset", $addr, "MASTER", $parref);
	if (! defined ($res)) {
		return -5;
	}
	elsif (ref ($res)) {
		if (exists ($res->{faultString})) {
			Log3 $name, 1, "HMCCU: RPC request failed. ".$res->{faultString};
			return -2;
		}
	}
	
	return 0;
}

######################################################################
# Open file queue
######################################################################

sub HMCCU_QueueOpen ($$)
{
	my ($hash, $queue_file) = @_;
	
	my $idx_file = $queue_file . '.idx';
	$queue_file .= '.dat';
	my $mode = '0666';

	umask (0);
	
	$hash->{hmccu}{queue}{block_size} = 64;
	$hash->{hmccu}{queue}{seperator} = "\n";
	$hash->{hmccu}{queue}{sep_length} = length $hash->{hmccu}{queue}{seperator};

	$hash->{hmccu}{queue}{queue_file} = $queue_file;
	$hash->{hmccu}{queue}{idx_file} = $idx_file;

	$hash->{hmccu}{queue}{queue} = new IO::File $queue_file, O_CREAT | O_RDWR, oct($mode) or return 0;
	$hash->{hmccu}{queue}{idx} = new IO::File $idx_file, O_CREAT | O_RDWR, oct($mode) or return 0;

	### Default ptr to 0, replace it with value in idx file if one exists
	$hash->{hmccu}{queue}{idx}->sysseek(0, SEEK_SET); 
	$hash->{hmccu}{queue}{idx}->sysread($hash->{hmccu}{queue}{ptr}, 1024);
	$hash->{hmccu}{queue}{ptr} = '0' unless $hash->{hmccu}{queue}{ptr};
  
	if($hash->{hmccu}{queue}{ptr} > -s $queue_file)
	{
		$hash->{hmccu}{queue}{idx}->truncate(0) or return 0;
		$hash->{hmccu}{queue}{idx}->sysseek(0, SEEK_SET); 
		$hash->{hmccu}{queue}{idx}->syswrite('0') or return 0;
	}
	
	return 1;
}

######################################################################
# Close file queue
######################################################################

sub HMCCU_QueueClose ($)
{
	my ($hash) = @_;
	
	if (exists ($hash->{hmccu}{queue})) {
		$hash->{hmccu}{queue}{idx}->close();
		$hash->{hmccu}{queue}{queue}->close();
		delete $hash->{hmccu}{queue};
	}
}

sub HMCCU_QueueReset ($)
{
	my ($hash) = @_;

	$hash->{hmccu}{queue}{idx}->truncate(0) or return 0;
	$hash->{hmccu}{queue}{idx}->sysseek(0, SEEK_SET); 
	$hash->{hmccu}{queue}{idx}->syswrite('0') or return 0;

	$hash->{hmccu}{queue}{queue}->sysseek($hash->{hmccu}{queue}{ptr} = 0, SEEK_SET); 
  
	return 1;
}

######################################################################
# Put value in file queue
######################################################################

sub HMCCU_QueueEnq ($$)
{
	my ($hash, $element) = @_;

	return 0 if (!exists ($hash->{hmccu}{queue}));
	
	$hash->{hmccu}{queue}{queue}->sysseek(0, SEEK_END); 
	$element =~ s/$hash->{hmccu}{queue}{seperator}//g;
	$hash->{hmccu}{queue}{queue}->syswrite($element.$hash->{hmccu}{queue}{seperator}) or return 0;
  
	return 1;  
}

######################################################################
# Return next value in file queue
######################################################################

sub HMCCU_QueueDeq ($)
{
	my ($hash) = @_;
	my $name = $hash->{NAME};
	my $sep_length = $hash->{hmccu}{queue}{sep_length};
	my $element = '';

	return undef if (!exists ($hash->{hmccu}{queue}));

	$hash->{hmccu}{queue}{queue}->sysseek($hash->{hmccu}{queue}{ptr}, SEEK_SET);

	my $i;
	while($hash->{hmccu}{queue}{queue}->sysread($_, $hash->{hmccu}{queue}{block_size})) {
		$i = index($_, $hash->{hmccu}{queue}{seperator});
		if($i != -1) {
			$element .= substr($_, 0, $i);
			$hash->{hmccu}{queue}{ptr} += $i + $sep_length;
			$hash->{hmccu}{queue}{queue}->sysseek($hash->{hmccu}{queue}{ptr}, SEEK_SET);
			last;
		}
		else {
			# Seperator not found, go back 'sep_length' spaces to ensure we don't miss it between reads
			Log3 $name, 2, "HMCCU: HMCCU_QueueDeq seperator not found";
			$element .= substr($_, 0, -$sep_length, '');
			$hash->{hmccu}{queue}{ptr} += $hash->{hmccu}{queue}{block_size} - $sep_length;
			$hash->{hmccu}{queue}{queue}->sysseek($hash->{hmccu}{queue}{ptr}, SEEK_SET);
		}
	}

	## If queue seek pointer is at the EOF, truncate the queue file
	if($hash->{hmccu}{queue}{queue}->sysread($_, 1) == 0)
	{
		$hash->{hmccu}{queue}{queue}->truncate(0) or return undef;
		$hash->{hmccu}{queue}{queue}->sysseek($hash->{hmccu}{queue}{ptr} = 0, SEEK_SET);
	}

	## Set idx file contents to point to the current seek position in queue file
	$hash->{hmccu}{queue}{idx}->truncate(0) or return undef;
	$hash->{hmccu}{queue}{idx}->sysseek(0, SEEK_SET);
	$hash->{hmccu}{queue}{idx}->syswrite($hash->{hmccu}{queue}{ptr}) or return undef;

	return ($element ne '') ? $element : undef;
}

######################################################################
# HELPER FUNCTIONS
######################################################################

######################################################################
# Determine HomeMatic state considering datapoint values specified
# in attributes ccudef-hmstatevals and hmstatevals.
# Return (reading, channel, datapoint, value)
######################################################################

sub HMCCU_GetHMState ($$$)
{
	my ($name, $ioname, $defval) = @_;
	my @hmstate = ('hmstate', undef, undef, $defval);

	my $clhash = $defs{$name};
	my $cltype = $clhash->{TYPE};
	return @hmstate if ($cltype ne 'HMCCUDEV' && $cltype ne 'HMCCUCHN');
	
	my $ghmstatevals = AttrVal ($ioname, 'ccudef-hmstatevals',
		'^UNREACH!(1|true):unreachable;^LOW_?BAT!(1|true):warn_battery');
	my $hmstatevals = AttrVal ($name, 'hmstatevals', $ghmstatevals);
	$hmstatevals .= ";".$ghmstatevals if ($hmstatevals ne $ghmstatevals);
	
	# Get reading name
	if ($hmstatevals =~ /^=([^;]*);/) {
		$hmstate[0] = $1;
		$hmstatevals =~ s/^=[^;]*;//;
	}

	# Default hmstate is equal to state
	$hmstate[3] = ReadingsVal ($name, 'state', undef) if (!defined ($defval));

	# Substitute variables	
	$hmstatevals = HMCCU_SubstVariables ($clhash, $hmstatevals);

	my @rulelist = split (";", $hmstatevals);
	foreach my $rule (@rulelist) {
		my ($dptexpr, $subst) = split ('!', $rule, 2);
		my $dp = '';
		next if (!defined ($dptexpr) || !defined ($subst));
		foreach my $d (keys %{$clhash->{hmccu}{dp}}) {
			if ($d =~ /$dptexpr/) {
				$dp = $d;
				last;
			}
		}
		next if ($dp eq '');
		my ($chn, $dpt) = split (/\./, $dp);
		my $value = HMCCU_FormatReadingValue ($clhash, $clhash->{hmccu}{dp}{$dp}{VAL});
		my ($rc, $newvalue) = HMCCU_SubstRule ($value, $subst, 0);
		return ($hmstate[0], $chn, $dpt, $newvalue) if ($rc);
	}

	return @hmstate;
}

######################################################################
# Calculate time difference in seconds between current time and
# specified timestamp
######################################################################

sub HMCCU_GetTimeSpec ($)
{
	my ($ts) = @_;
	
	return -1 if ($ts !~ /^[0-9]{2}:[0-9]{2}$/ && $ts !~ /^[0-9]{2}:[0-9]{2}:[0-9]{2}$/);
	
	my (undef, $h, $m, $s)  = GetTimeSpec ($ts);
	return -1 if (!defined ($h));
	
	$s += $h*3600+$m*60;
	my @lt = localtime;
	my $cs = $lt[2]*3600+$lt[1]*60+$lt[0];
	$s += 86400 if ($cs > $s);
	
	return ($s-$cs);
}

######################################################################
# Calculate special readings. Requires hash of client device and
# channel number and datapoint.
# Return readings.
######################################################################

sub HMCCU_CalculateReading ($$$)
{
	my ($cl_hash, $chnno, $dpt) = @_;
	my $name = $cl_hash->{NAME};
	
	my @result = ();
	
	my $ccucalculate = AttrVal ($name, 'ccucalculate', '');
	return @result if ($ccucalculate eq '');
	
	my @calclist = split (';', $ccucalculate);
	foreach my $calculation (@calclist) {
		my ($valuetype, $reading, $datapoints) = split (':', $calculation);
		next if (!defined ($reading));

		my @dplist = defined ($datapoints) ? split (',', $datapoints) : ();
		next if (@dplist > 0 && !(grep { $_ eq "$chnno.$dpt"} @dplist));
		my @pars = ();
		foreach my $dp (@dplist) {
			if (exists ($cl_hash->{hmccu}{dp}{$dp}{VAL})) {
				push @pars, $cl_hash->{hmccu}{dp}{$dp}{VAL};
			}
		}
		
		if ($valuetype eq 'dewpoint' || $valuetype eq 'abshumidity') {
			next if (@pars < 2);
			my ($tmp, $hum) = @pars;
			if ($tmp >= 0.0) {
				$a = 7.5;
				$b = 237.3;
			}
			else {
				$a = 7.6;
				$b = 240.7;
			}

			my $sdd = 6.1078*(10.0**(($a*$tmp)/($b+$tmp)));
			my $dd = $hum/100.0*$sdd;
			if ($valuetype eq 'dewpoint') {
				my $v = log($dd/6.1078)/log(10.0);
				my $td = $b*$v/($a-$v);
				push (@result, $reading, (sprintf "%.1f", $td));
			}
			else {
				my $af = 100000.0*18.016/8314.3*$dd/($tmp+273.15);
				push (@result, $reading, (sprintf "%.1f", $af));
			}
		}
	}
	
	return @result;
}

######################################################################
# Encode command string for e-paper display
#
# Parameters:
#
#  msg := parameter=value[,...]
#
#  text1-3=Text
#  icon1-3=Icon
#  sound=
#  signal=
#  pause=1-160
#  repeat=0-15
#
# Returns undef on error or encoded string on success
######################################################################

sub HMCCU_EncodeEPDisplay ($)
{
	my ($msg) = @_;
	
	# set defaults
	$msg = '' if (!defined ($msg));
	
	my %disp_icons = (
		ico_off    => '0x80', ico_on => '0x81', ico_open => '0x82', ico_closed => '0x83',
		ico_error  => '0x84', ico_ok => '0x85', ico_info => '0x86', ico_newmsg => '0x87',
		ico_svcmsg => '0x88'
	);

	my %disp_sounds = (
		snd_off        => '0xC0', snd_longlong => '0xC1', snd_longshort  => '0xC2',
		snd_long2short => '0xC3', snd_short    => '0xC4', snd_shortshort => '0xC5',
		snd_long       => '0xC6'
	);

	my %disp_signals = (
		sig_off => '0xF0', sig_red => '0xF1', sig_green => '0xF2', sig_orange => '0xF3'
	);

	# Parse command string
	my @text = ('', '', '');
	my @icon = ('', '', '');
	my %conf = (sound => 'snd_off', signal => 'sig_off', repeat => 1, pause => 10);
	foreach my $tok (split (',', $msg)) {
		my ($par, $val) = split ('=', $tok);
		next if (!defined ($val));
		if ($par =~ /^text([1-3])$/) {
			$text[$1-1] = substr ($val, 0, 12);
		}
		elsif ($par =~ /^icon([1-3])$/) {
			$icon[$1-1] = $val;
		}
		elsif ($par =~ /^(sound|pause|repeat|signal)$/) {
			$conf{$1} = $val;
		}
	}
	
	my $cmd = '0x02,0x0A';

	for (my $c=0; $c<3; $c++) {
		if ($text[$c] ne '' || $icon[$c] ne '') {
			$cmd .= ',0x12';
			
			# Hex code
			if ($text[$c] =~ /^0x[0-9A-F]{2}$/) {
				$cmd .= ','.$text[$c];
			}
			# Predefined text code #0-9
			elsif ($text[$c] =~ /^#([0-9])$/) {
				$cmd .= sprintf (",0x8%1X", $1);
			}
			# Convert string to hex codes
			else {
				$text[$c] =~ s/\\_/ /g;
				foreach my $ch (split ('', $text[$c])) {
					$cmd .= sprintf (",0x%02X", ord ($ch));
				}
			}
			
			# Icon
			if ($icon[$c] ne '' && exists ($disp_icons{$icon[$c]})) {
				$cmd .= ',0x13,'.$disp_icons{$icon[$c]};
			}
		}
		
		$cmd .= ',0x0A';
	}
	
	# Sound
	my $snd = $disp_sounds{snd_off};
	$snd = $disp_sounds{$conf{sound}} if (exists ($disp_sounds{$conf{sound}}));
	$cmd .= ',0x14,'.$snd.',0x1C';

	# Repeat
	my $rep = $conf{repeat} if ($conf{repeat} >= 0 && $conf{repeat} <= 15);
	$rep = 1 if ($rep < 0);
	$rep = 15 if ($rep > 15);
	if ($rep == 0) {
		$cmd .= ',0xDF';
	}
	else {
		$cmd .= sprintf (",0x%02X", 0xD0+$rep-1);
	}
	$cmd .= ',0x1D';
	
	# Pause
	my $pause = $conf{pause};
	$pause = 1 if ($pause < 1);
	$pause = 160 if ($pause > 160);
	$cmd .= sprintf (",0xE%1X,0x16", int(($pause-1)/10));
	
	# Signal
	my $sig = $disp_signals{sig_off};
	$sig = $disp_signals{$conf{signal}} if (exists ($disp_signals{$conf{signal}}));
	$cmd .= ','.$sig.',0x03';
	
	return '"'.$cmd.'"';
}



######################################################################
#                     *** Subprocess part ***
######################################################################

# Child process. Must be global to allow access by RPC callbacks
my $hmccu_child;

# Queue file
my %child_queue;
my $cpqueue = \%child_queue;

# Statistic data of child process
my %child_hash = (
	"total", 0,
	"writeerror", 0,
	"EV", 0,
	"ND", 0,
	"DD", 0,
	"RD", 0,
	"RA", 0,
	"UD", 0,
	"IN", 0,
	"EX", 0,
	"SL", 0
);
my $cphash = \%child_hash;


######################################################################
# Subprocess: Write event to parent process
######################################################################

sub HMCCU_CCURPC_Write ($$)
{
	my ($et, $msg) = @_;
	my $name = $hmccu_child->{devname};

	$cphash->{total}++;
	$cphash->{$et}++;

	HMCCU_QueueEnq ($cpqueue, $et."|".$msg);
}

######################################################################
# Subprocess: Initialize RPC server. Return 1 on success.
######################################################################

sub HMCCU_CCURPC_OnRun ($)
{
	$hmccu_child = shift;
	my $name = $hmccu_child->{devname};
	my $serveraddr = $hmccu_child->{serveraddr};
	my $serverport = $hmccu_child->{serverport};
	my $callbackport = $hmccu_child->{callbackport};
	my $queuefile = $hmccu_child->{queue};
	my $clkey = "CB".$serverport;
	my $ccurpc_server;

	# Create, open and reset queue file
 	Log3 $name, 0, "CCURPC: $clkey Creating file queue $queuefile";
 	if (!HMCCU_QueueOpen ($cpqueue, $queuefile)) {
 		Log3 $name, 0, "CCURPC: $clkey Can't create queue";
 		return 0;
 	}

	# Reset event queue
 	HMCCU_QueueReset ($cpqueue);
 	while (defined (HMCCU_QueueDeq ($cpqueue))) { }

	# Create RPC server
	Log3 $name, 0, "CCURPC: Initializing RPC server $clkey";
	$ccurpc_server = RPC::XML::Server->new (port=>$callbackport);
	if (!ref($ccurpc_server))
	{
		Log3 $name, 0, "CCURPC: Can't create RPC callback server on port $callbackport. Port in use?";
		return 0;
	}
	else {
		Log3 $name, 0, "CCURPC: Callback server created listening on port $callbackport";
	}
	
	# Callback for events
	Log3 $name, 1, "CCURPC: $clkey Adding callback for events";
	$ccurpc_server->add_method (
	   { name=>"event",
	     signature=> ["string string string string int","string string string string double","string string string string boolean","string string string string i4"],
	     code=>\&HMCCU_CCURPC_EventCB
	   }
	);

	# Callback for new devices
	Log3 $name, 1, "CCURPC: $clkey Adding callback for new devices";
	$ccurpc_server->add_method (
	   { name=>"newDevices",
	     signature=>["string string array"],
             code=>\&HMCCU_CCURPC_NewDevicesCB
	   }
	);

	# Callback for deleted devices
	Log3 $name, 1, "CCURPC: $clkey Adding callback for deleted devices";
	$ccurpc_server->add_method (
	   { name=>"deleteDevices",
	     signature=>["string string array"],
             code=>\&HMCCU_CCURPC_DeleteDevicesCB
	   }
	);

	# Callback for modified devices
	Log3 $name, 1, "CCURPC: $clkey Adding callback for modified devices";
	$ccurpc_server->add_method (
	   { name=>"updateDevice",
	     signature=>["string string string int"],
	     code=>\&HMCCU_CCURPC_UpdateDeviceCB
	   }
	);

	# Callback for replaced devices
	Log3 $name, 1, "CCURPC: $clkey Adding callback for replaced devices";
	$ccurpc_server->add_method (
	   { name=>"replaceDevice",
	     signature=>["string string string string"],
	     code=>\&HMCCU_CCURPC_ReplaceDeviceCB
	   }
	);

	# Callback for readded devices
	Log3 $name, 1, "CCURPC: $clkey Adding callback for readded devices";
	$ccurpc_server->add_method (
	   { name=>"replaceDevice",
	     signature=>["string string array"],
	     code=>\&HMCCU_CCURPC_ReaddDeviceCB
	   }
	);
	
	# Dummy implementation, always return an empty array
	Log3 $name, 1, "CCURPC: $clkey Adding callback for list devices";
	$ccurpc_server->add_method (
	   { name=>"listDevices",
	     signature=>["array string"],
	     code=>\&HMCCU_CCURPC_ListDevicesCB
	   }
	);

	# Enter server loop
	HMCCU_CCURPC_Write ("SL", "$$|$clkey");

	Log3 $name, 0, "CCURPC: $clkey Entering server loop";
	$ccurpc_server->server_loop;
	Log3 $name, 0, "CCURPC: $clkey Server loop terminated";
	
	# Server loop exited by SIGINT
	HMCCU_CCURPC_Write ("EX", "SHUTDOWN|$$|$clkey");

	return 1;
}

######################################################################
# Subprocess: Called when RPC server loop is terminated
######################################################################

sub HMCCU_CCURPC_OnExit ()
{
	# Output statistics
	foreach my $et (sort keys %child_hash) {
		Log3 $hmccu_child->{devname}, 2, "CCURPC: Eventcount $et = ".$cphash->{$et};
	}
}

######################################################################
# Subprocess: Callback for new devices
######################################################################

sub HMCCU_CCURPC_NewDevicesCB ($$$)
{
	my ($server, $cb, $a) = @_;
	my $devcount = scalar (@$a);
	my $name = $hmccu_child->{devname};
	my $c = 0;
	my $msg = '';
	
	Log3 $name, 2, "CCURPC: $cb NewDevice received $devcount device specifications";	
	for my $dev (@$a) {
		my $msg = '';
		if ($dev->{ADDRESS} =~ /:[0-9]{1,2}$/) {
			$msg = "C|".$dev->{ADDRESS}."|".$dev->{TYPE}."|".$dev->{VERSION}."|null|null";
		}
		else {
			$msg = "D|".$dev->{ADDRESS}."|".$dev->{TYPE}."|".$dev->{VERSION}."|".
				$dev->{FIRMWARE}."|".$dev->{RX_MODE};
		}
		HMCCU_CCURPC_Write ("ND", $msg);
	}

	return;
}

######################################################################
# Subprocess: Callback for deleted devices
######################################################################

sub HMCCU_CCURPC_DeleteDevicesCB ($$$)
{
	my ($server, $cb, $a) = @_;
	my $name = $hmccu_child->{devname};
	my $devcount = scalar (@$a);
	
	Log3 $name, 2, "CCURPC: $cb DeleteDevice received $devcount device addresses";
	for my $dev (@$a) {
		HMCCU_CCURPC_Write ("DD", $dev);
	}

	return;
}

######################################################################
# Subprocess: Callback for modified devices
######################################################################

sub HMCCU_CCURPC_UpdateDeviceCB ($$$$)
{
	my ($server, $cb, $devid, $hint) = @_;
	
	HMCCU_CCURPC_Write ("UD", $devid."|".$hint);

	return;
}

######################################################################
# Subprocess: Callback for replaced devices
######################################################################

sub HMCCU_CCURPC_ReplaceDeviceCB ($$$$)
{
	my ($server, $cb, $devid1, $devid2) = @_;
	
	HMCCU_CCURPC_Write ("RD", $devid1."|".$devid2);

	return;
}

######################################################################
# Subprocess: Callback for readded devices
######################################################################

sub HMCCU_CCURPC_ReaddDevicesCB ($$$)
{
	my ($server, $cb, $a) = @_;
	my $name = $hmccu_child->{devname};
	my $devcount = scalar (@$a);
	
	Log3 $name, 2, "CCURPC: $cb ReaddDevice received $devcount device addresses";
	for my $dev (@$a) {
		HMCCU_CCURPC_Write ("RA", $dev);
	}

	return;
}

######################################################################
# Subprocess: Callback for handling CCU events
######################################################################

sub HMCCU_CCURPC_EventCB ($$$$$)
{
	my ($server, $cb, $devid, $attr, $val) = @_;
	my $name = $hmccu_child->{devname};
	
	HMCCU_CCURPC_Write ("EV", $devid."|".$attr."|".$val);
	if (($cphash->{EV} % 500) == 0) {
		Log3 $name, 3, "CCURPC: $cb Received 500 events from CCU since last check";
		my @stkeys = ('total', 'EV', 'ND', 'DD', 'RD', 'RA', 'UD', 'IN', 'SL', 'EX');
		my $msg = '';
		foreach my $stkey (@stkeys) {
			$msg .= '|' if ($msg ne '');
			$msg .= $cphash->{$stkey};
		}
		HMCCU_CCURPC_Write ("ST", $msg);
	}

	# Never remove this statement!
	return;
}

######################################################################
# Subprocess: Callback for list devices
######################################################################

sub HMCCU_CCURPC_ListDevicesCB ($$)
{
	my ($server, $cb) = @_;
	my $name = $hmccu_child->{devname};
	
	$cb = "unknown" if (!defined ($cb));
	Log3 $name, 1, "CCURPC: $cb ListDevices. Sending init to HMCCU";
	HMCCU_CCURPC_Write ("IN", "INIT|1|$cb");

	return RPC::XML::array->new();
}


1;


=pod
=item device
=item summary provides interface between FHEM and Homematic CCU2
=begin html

<a name="HMCCU"></a>
<h3>HMCCU</h3>
<ul>
   The module provides an interface between FHEM and a Homematic CCU2. HMCCU is the 
   I/O device for the client devices HMCCUDEV and HMCCUCHN. The module requires the
   additional Perl modules IO::File, RPC::XML::Client, RPC::XML::Server and SubProcess
   (part of FHEM).
   </br></br>
   <a name="HMCCUdefine"></a>
   <b>Define</b><br/><br/>
   <ul>
      <code>define &lt;name&gt; HMCCU &lt;HostOrIP&gt; [&lt;ccu-number&gt;]</code>
      <br/><br/>
      Example:<br/>
      <code>define myccu HMCCU 192.168.1.10</code>
      <br/><br/>
      The parameter <i>HostOrIP</i> is the hostname or IP address of a Homematic CCU2. If you have
      more than one CCU you can specifiy a unique CCU number with parameter <i>ccu-number</i>.
      <br/>
      For automatic update of Homematic device datapoints and FHEM readings one have to:
      <br/><br/>
      <ul>
      <li>Define used RPC interfaces with attribute 'rpcinterfaces'</li>
      <li>Start RPC servers with command 'set rpcserver on'</li>
      <li>Optionally enable automatic start of RPC servers with attribute 'rpcserver'</li>
      </ul><br/>
      Than start with the definition of client devices using modules HMCCUDEV (CCU devices)
      and HMCCUCHN (CCU channels) or with command 'get devicelist create'.<br/>
      Maybe it's helpful to set the following FHEM standard attributes for the HMCCU I/O
      device:<br/><br/>
      <ul>
      <li>Shortcut for RPC server control: eventMap /rpcserver on:on/rpcserver off:off/</li>
      </ul>
   </ul>
   <br/>
   
   <a name="HMCCUset"></a>
   <b>Set</b><br/><br/>
   <ul>
		<li><b>set &lt;name&gt; cleardefaults</b><br/>
			Clear default attributes imported from file.
		</li><br/>
		<li><b>set &lt;name&gt; defaults</b><br/>
		   Set default attributes for I/O device.
		</li><br/>
      <li><b>set &lt;name&gt; execute &lt;program&gt;</b><br/>
         Execute a CCU program.
         <br/><br/>
         Example:<br/>
         <code>set d_ccu execute PR-TEST</code>
      </li><br/>
      <li><b>set &lt;name&gt; hmscript &lt;script-file&gt; [dump] [&lt;parname&gt;=&lt;value&gt; 
         [...]]</b><br/>
         Execute Homematic script on CCU. If script code contains parameter in format $parname
         they are substituted by corresponding command line parameters <i>parname</i>.<br/>
         If output of script contains lines in format Object=Value readings in existing
         corresponding FHEM devices will be set. <i>Object</i> can be the name of a CCU system
         variable or a valid channel and datapoint specification. Readings for system variables
         are set in the I/O device. Datapoint related readings are set in client devices. If option
         'dump' is specified the result of script execution is displayed in FHEM web interface.
      </li><br/>
      <li><b>set &lt;name&gt; importdefaults &lt;filename&gt;</b><br/>
      	Import default attributes from file.
      </li><br/>
      <li><b>set &lt;name&gt; rpcserver {on | off | restart}</b><br/>
         Start, stop or restart RPC server(s). This command executed with option 'on'
         will fork a RPC server process for each RPC interface defined in attribute 'rpcinterfaces'.
         Until operation is completed only a few set/get commands are available and you
         may get the error message 'CCU busy'.
      </li><br/>
      <li><b>set &lt;name&gt; var &lt;variable&gt; &lt;Value&gt; [...]</b><br/>
        Set CCU system variable value. Special characters \_ in <i>value</i> are
        substituted by blanks.
      </li>
   </ul>
   <br/>
   
   <a name="HMCCUget"></a>
   <b>Get</b><br/><br/>
   <ul>
      <li><b>get &lt;name&gt; aggregation {&lt;rule&gt;|all}</b><br/>
      	Process aggregation rule defined with attribute ccuaggregation.
      </li><br/>
      <li><b>get &lt;name&gt; configdesc {&lt;device&gt;|&lt;channel&gt;}</b><br/>
         Get configuration parameter description of CCU device or channel (similar
         to device settings in CCU). Not every CCU device or channel provides a configuration
         parameter description. So result may be empty.
      </li><br/>
      <li><b>get &lt;name&gt; defaults</b><br/>
      	List device types and channels with default attributes available.
      </li><br/>
      <li><b>get &lt;name&gt; deviceinfo &lt;device-name&gt; [{State | <u>Value</u>}]</b><br/>
         List device channels and datapoints. If option 'State' is specified the device is
         queried directly. Otherwise device information from CCU is listed.
      </li><br/>
      <li><b>get &lt;name&gt; devicelist [dump]</b><br/>
         Read list of devices and channels from CCU. This command is executed automatically
         after the definition of an I/O device. It must be executed manually after
         module HMCCU is reloaded or after devices have changed in CCU (added, removed or
         renamed). With option 'dump' devices are displayed in browser window. If a RPC
         server is running HMCCU will raise events "<i>count</i> devices added in CCU" or
         "<i>count</i> devices deleted in CCU". It's recommended to set up a notification
         which reacts with execution of command 'get devicelist' on these events.
      </li><br/>
      <li><b>get &lt;name&gt; devicelist create &lt;devexp&gt; [t={chn|<u>dev</u>|all}]
      	[p=&lt;prefix&gt;] [s=&lt;suffix&gt;] [f=&lt;format&gt;] [defattr] 
      	[&lt;attr&gt;=&lt;value&gt; [...]]</b><br/>
         With option 'create' HMCCU will automatically create client devices for all CCU devices
         and channels matching specified regular expression. With option t=chn or t=dev (default) 
         the creation of devices is limited to CCU channels or devices.<br/>
         Optionally a <i>prefix</i> and/or a
         <i>suffix</i> for the FHEM device name can be specified. The parameter <i>format</i>
         defines a template for the FHEM device names. Prefix, suffix and format can contain
         format identifiers which are substituted by corresponding values of the CCU device or
         channel: %n = CCU object name (channel or device), %d = CCU device name, %a = CCU address.
         In addition a list of default attributes for the created client devices can be specified.
         If option 'defattr' is specified HMCCU tries to set default attributes for device.
      </li><br/>
      <li><b>get &lt;name&gt; dump {datapoints|devtypes} [&lt;filter&gt;]</b><br/>
      	Dump all Homematic devicetypes or all devices including datapoints currently
      	defined in FHEM.
      </li><br/>
      <li><b>get &lt;name&gt; exportdefaults &lt;filename&gt;</b><br/>
      	Export default attributes into file.
      </li><br/>
      <li><b>get &lt;name&gt; parfile [&lt;parfile&gt;]</b><br/>
         Get values of all channels / datapoints specified in <i>parfile</i>. The parameter
         <i>parfile</i> can also be defined as an attribute. The file must contain one channel /
         definition per line.
         <br/><br/>
         The syntax of Parfile entries is:
         <br/><br/>
         {[&lt;interface&gt;.]&lt;channel-address&gt; | &lt;channel-name&gt;}
         [.&lt;datapoint-expr&gt;] [&lt;subst-rules&gt;]
         <br/><br/>
         Empty lines or lines starting with a # are ignored.
      </li><br/>
      <li><b>get &lt;name&gt; rpcstate</b><br/>
         Check if RPC server process is running.
      </li><br/>
      <li><b>get &lt;name&gt; update [&lt;devexp&gt; [{State | <u>Value</u>}]]</b><br/>
         Update all datapoints / readings of client devices with <u>FHEM device name</u>(!) matching
         <i>devexp</i>. With option 'State' all CCU devices are queried directly. This can be
         time consuming.
      </li><br/>
      <li><b>get &lt;name&gt; updateccu [&lt;devexp&gt; [{State | <u>Value</u>}]]</b><br/>
         Update all datapoints / readings of client devices with <u>CCU device name</u>(!) matching
         <i>devexp</i>. With option 'State' all CCU devices are queried directly. This can be
         time consuming.
      </li><br/>
      <li><b>get &lt;name&gt; vars &lt;regexp&gt;</b><br/>
         Get CCU system variables matching <i>regexp</i> and store them as readings.
      </li>
   </ul>
   <br/>
   
   <a name="HMCCUattr"></a>
   <b>Attributes</b><br/>
   <br/>
   <ul>
      <li><b>ccuackstate {0 | <u>1</u>}</b><br/>
         If set to 1 state will be set to result of command (i.e. 'OK').
      </li><br/>
      <li><b>ccuaggregate &lt;rule&gt;[;...]</b><br/>
      	Define aggregation rules for client device readings. With an aggregation rule
      	it's easy to detect if some or all client device readings are set to a specific
      	value, i.e. detect all devices with low battery or detect all open windows.<br/>
      	Aggregation rules are automatically executed as a reaction on reading events of
      	HMCCU client devices. An aggregation rule consists of several parameters separated
      	by comma:<br/><br/>
      	<ul>
      	<li><b>name:&lt;rule-name&gt;</b><br/>
      	Name of aggregation rule</li>
      	<li><b>filter:{name|alias|group|room|type}=&lt;incl-expr&gt;[!&lt;excl-expr&gt;]</b><br/>
      	Filter criteria, i.e. "type=^HM-Sec-SC.*"</li>
      	<li><b>read:&lt;read-expr&gt;</b><br/>
      	Expression for reading names, i.e. "STATE"</li>
      	<li><b>if:{any|all|min|max|sum|avg|lt|gt|le|ge}=&lt;value&gt;</b><br/>
      	Condition, i.e. "any=open" or initial value, i.e. max=0</li>
      	<li><b>else:&lt;value&gt;</b><br/>
      	Complementary value, i.e. "closed"</li>
      	<li><b>prefix:{&lt;text&gt;|RULE}</b><br/>
      	Prefix for reading names with aggregation results</li>
      	<li><b>coll:{&lt;attribute&gt;|NAME}[!&lt;default-text&gt;]</b><br/>
      	Attribute of matching devices stored in aggregation results. Default text in case
      	of no matching devices found is optional.</li>
      	</ul><br/>
      	Aggregation results will be stored in readings <i>prefix</i>count, <i>prefix</i>
      	list, <i>prefix</i>match and <i>prefix</i>state<br/><br/>
      	Example: Find open windows<br/>
      	name=lock,filter:type=^HM-Sec-SC.*,read:STATE,if:any=open,else:closed,prefix:lock_,coll:NAME!All windows closed<br/><br/>
      	Example: Find devices with low batteries<br/>
      	name=battery,filter:name=.*,read:(LOWBAT|LOW_BAT),if:any=yes,else:no,prefix:batt_,coll:NAME<br/>
      </li><br/>
      <li><b>ccudef-hmstatevals &lt;subst-rule[;...]&gt;</b><br/>
      	Set global rules for calculation of reading hmstate.
      </li><br/>
      <li><b>ccudef-readingfilter &lt;filter-rule[;...]&gt;</b><br/>
         Set global reading/datapoint filter. This filter is added to the filter specified by
         client device attribute 'ccureadingfilter'.
      </li><br/>
      <li><b>ccudef-readingformat {name | address | <u>datapoint</u> | namelc | addresslc |
		   datapointlc}</b><br/>
		   Set global reading format. This format is the default for all readings except readings
		   of virtual device groups.
		</li><br/>
      <li><b>ccudef-readingname &lt;old-readingname-expr&gt;:[+]&lt;new-readingname&gt;
         [;...]</b><br/>
         Set global rules for reading name substitution. These rules are added to the rules
         specified by client device attribute 'ccureadingname'.
      </li><br/>
      <li><b>ccudef-substitute &lt;subst-rule&gt;[;...]</b><br/>
         Set global substitution rules for datapoint value. These rules are added to the rules
         specified by client device attribute 'substitute'.
      </li><br/>
      <li><b>ccudefaults &lt;filename&gt;</b><br/>
      	Load default attributes for HMCCUCHN and HMCCUDEV devices from specified file. Best
      	practice for creating a custom default attribute file is by exporting predefined default
      	attributes from HMCCU with command 'get exportdefaults'.
      </li><br/>
      <li><b>ccuflags {extrpc, <u>intrpc</u>}</b><br/>
      	Control RPC server process and datapoint validation:<br/>
      	intrpc - Use internal RPC server. This is the default.<br/>
      	extrpc - Use external RPC server provided by module HMCCURPC. If no HMCCURPC device
      	exists HMCCU will create one after command 'set rpcserver on'.<br/>
      	dptnocheck - Do not check within set or get commands if datapoint is valid<br/>
      </li><br/>
      <li><b>ccuget {State | <u>Value</u>}</b><br/>
         Set read access method for CCU channel datapoints. Method 'State' is slower than
         'Value' because each request is sent to the device. With method 'Value' only CCU
         is queried. Default is 'Value'.
      </li><br/>
      <li><b>ccureadings {0 | <u>1</u>}</b><br/>
         If set to 1 values read from CCU will be stored as readings. Otherwise output
         is displayed in browser window.
      </li><br/>
      <li><b>parfile &lt;filename&gt;</b><br/>
         Define parameter file for command 'get parfile'.
      </li><br/>
      <li><b>rpcdevice &lt;devicename&gt;</b><br/>
      	Specify name of external RPC device of type HMCCURPC.
      </li><br/>
      <li><b>rpcinterfaces &lt;interface&gt;[,...]</b><br/>
   		Specify list of CCU RPC interfaces. HMCCU will register a RPC server for each interface.
   		Valid interfaces are:<br/><br/>
   		<ul>
   		<li>BidCos-Wired (Port 2000)</li>
   		<li>BidCos-RF (Port 2001)</li>
   		<li>Homegear (Port 2003)</li>
   		<li>HmIP (Port 2010)</li>
   		<li>CUxD (Port 8701)</li>
   		<li>VirtualDevice (Port 9292)</li>
   		</ul>
      </li><br/>
      <li><b>rpcinterval &lt;Seconds&gt;</b><br/>
         Specifiy how often RPC queue is read. Default is 5 seconds.
      </li><br/>
      <li><b>rpcport &lt;value[,...]&gt;</b><br/>
         Deprecated, use 'rpcinterfaces' instead. Specify list of RPC ports on CCU. Default is
         2001. Valid RPC ports are:<br/><br/>
         <ul>
         <li>2000 = Wired components</li>
         <li>2001 = BidCos-RF (wireless 868 MHz components with BidCos protocol)</li>
         <li>2003 = Homegear (experimental)</li>
         <li>2010 = HM-IP (wireless 868 MHz components with IPv6 protocol)</li>
         <li>8701 = CUxD (only supported with external RPC server HMCCURPC)</li>
         <li>9292 = CCU group devices (especially heating groups)</li>
         </ul>
      </li><br/>
      <li><b>rpcqueue &lt;queue-file&gt;</b><br/>
         Specify name of RPC queue file. This parameter is only a prefix (including the
         pathname) for the queue files with extension .idx and .dat. Default is
         /tmp/ccuqueue. If FHEM is running on a SD card it's recommended that the queue
         files are placed on a RAM disk.
      </li><br/>
      <li><b>rpcserver {on | <u>off</u>}</b><br/>
         Specify if RPC server is automatically started on FHEM startup.
      </li><br/>
      <li><b>rpcserveraddr &lt;ip-or-name&gt;</b><br/>
      	Specify network interface by IP address or DNS name where RPC server should listen
      	on. By default HMCCU automatically detects the IP address. This attribute should be used
      	if the FHEM server has more than one network interface.
      </li><br/>
      <li><b>rpcserverport &lt;base-port&gt;</b><br/>
      	Specify base port for RPC server. The real listening port of an RPC server is
      	calculated by the formula: base-port + rpc-port + (10 * ccu-number). Default
      	value for <i>base-port</i> is 5400.<br/>
      	The value ccu-number is only relevant if more than one CCU is connected to FHEM.
      	Example: If <i>base-port</i> is 5000, protocol is BidCos (rpc-port 2001) and only
      	one CCU is connected the resulting RPC server port is 5000+2001+(10*0) = 7001.
      </li><br/>
      <li><b>substitute &lt;subst-rule&gt;:&lt;substext&gt;[,...]</b><br/>
         Define substitions for datapoint values. Syntax of <i>subst-rule</i> is<br/><br/>
         [[&lt;channelno.&gt;]&lt;datapoint&gt;[,...]!]&lt;{#n1-m1|regexp1}&gt;:&lt;text1&gt;[,...]
         <br/>
         Substitutions for parfile values must be specified in parfiles.
      </li><br/>
      <li><b>stripchar &lt;character&gt;</b><br/>
         Strip the specified character from variable or device name in set commands. This
         is useful if a variable should be set in CCU using the reading with trailing colon.
      </li>
   </ul>
</ul>

=end html
=cut


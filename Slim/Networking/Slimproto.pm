package Slim::Networking::Slimproto;

# $Id: Slimproto.pm,v 1.35 2003/11/03 23:22:33 dean Exp $

# Slim Server Copyright (c) 2001, 2002, 2003 Sean Adams, Slim Devices Inc.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use FindBin qw($Bin);
use IO::Socket;
use FileHandle;
use Net::hostent;              # for OO version of gethostbyaddr
use Sys::Hostname;
use File::Spec::Functions qw(:ALL);
use POSIX qw(:fcntl_h strftime);
use Fcntl qw(F_GETFL F_SETFL);

use Slim::Networking::Select;
use Slim::Player::Squeezebox;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string);

use Socket qw(IPPROTO_TCP TCP_KEEPALIVE TCP_MAXRT TCP_MAXSEG TCP_NODELAY TCP_STDURG);

use Errno qw(:POSIX);

my $SLIMPROTO_ADDR = 0;
my $SLIMPROTO_PORT = 3483;

my $slimproto_socket;

my %ipport;		# ascii IP:PORT
my %inputbuffer;  	# inefficiently append data here until we have a full slimproto frame
my %parser_state; 	# 'LENGTH', 'OP', or 'DATA'
my %parser_framelength; # total number of bytes for data frame
my %parser_frametype;   # frame type eg "HELO", "IR  ", etc.
my %sock2client;	# reference to client for each sonnected sock
my %status;

my %callbacks;

sub setEventCallback {
	my $event	= shift;
	my $funcptr = shift;
	$callbacks{$event} = $funcptr;
}

sub init {
	my ($listenerport, $listeneraddr) = ($SLIMPROTO_PORT, $SLIMPROTO_ADDR);

	$slimproto_socket = IO::Socket::INET ->new(
		Proto => 'tcp',
		LocalAddr => $listeneraddr,
		LocalPort => $listenerport,
		Listen    => SOMAXCONN,
		ReuseAddr     => 1,
		Reuse     => 1,
		Timeout   => 0.001
	) || die "Can't listen on port $listenerport for Slim protocol: $!";

	defined(Slim::Utils::Misc::blocking($slimproto_socket,0)) || die "Cannot set port nonblocking";

	Slim::Networking::Select::addRead($slimproto_socket, \&slimproto_accept);

	$::d_slimproto && msg "Squeezebox protocol listening on port $listenerport\n";	
}

sub slimproto_accept {
	my $clientsock = $slimproto_socket->accept();

	return unless $clientsock;

	defined(Slim::Utils::Misc::blocking($clientsock,0)) || die "Cannot set port nonblocking";

#	$clientsock->sockopt(Socket::TCP_NODELAY => 1);

	my $peer;

	if ($clientsock->connected) {
		$peer = $clientsock->peeraddr;
	} else {
		$::d_slimproto && msg ("Slimproto accept failed; not connected.\n");
		$clientsock->close();
		return;
	}

	if (!$peer) {
		$::d_slimproto && msg ("Slimproto accept failed; couldn't get peer address.\n");
		$clientsock->close();
		return;
	}
		
	my $tmpaddr = inet_ntoa($peer);

	if ((Slim::Utils::Prefs::get('filterHosts')) &&
		!(Slim::Utils::Misc::isAllowedHost($tmpaddr))) {
		$::d_slimproto && msg ("Slimproto unauthorized host, accept denied: $tmpaddr\n");
		$clientsock->close();
		return;
	}

	$ipport{$clientsock} = $tmpaddr.':'.$clientsock->peerport;
	$parser_state{$clientsock} = 'OP';
	$parser_framelength{$clientsock} = 0;
	$inputbuffer{$clientsock}='';

	Slim::Networking::Select::addRead($clientsock, \&client_readable);
	# Slim::Networking::Select::addWrite($clientsock, \&client_writable);  # for now assume it's always writeable.

	$::d_slimproto && msg ("Slimproto accepted connection from: $tmpaddr\n");
}

sub slimproto_close {
	my $clientsock = shift;
	$::d_slimproto && msg("Slimproto connection closed\n");

	# stop selecting
	Slim::Networking::Select::addRead($clientsock, undef);
	Slim::Networking::Select::addWrite($clientsock, undef);

	# close socket
	$clientsock->close();

	# forget state
	delete($ipport{$clientsock});
	delete($parser_state{$clientsock});
	delete($parser_framelength{$clientsock});
	delete($sock2client{$clientsock});
}		

sub client_writeable {
	my $clientsock = shift;

	# this prevent the "getpeername() on closed socket" error, which
	# is caused by trying to close the file handle after it's been closed during the
	# read pass but it's still in our writeable list. Don't try to close it twice - 
	# just ignore if it shouldn't exist.
	return unless (defined($ipport{$clientsock})); 
	
	$::d_slimproto_v && msg("Slimproto client writeable: ".$ipport{$clientsock}."\n");

	if (!($clientsock->connected)) {
		$::d_slimproto && msg("Slimproto connection closed by peer in writeable.\n");
		slimproto_close($clientsock);		
		return;
	}		
}

sub client_readable {
	my $s = shift;

	$::d_slimproto_v && msg("Slimproto client readable: ".$ipport{$s}."\n");

	my $total_bytes_read=0;

GETMORE:
	if (!($s->connected)) {
		$::d_slimproto && msg("Slimproto connection closed by peer in readable.\n");
		slimproto_close($s);		
		return;
	}			

	my $bytes_remaining;

	$::d_slimproto_v && msg(join(', ', 
		"state: ".$parser_state{$s},
		"framelen: ".$parser_framelength{$s},
		"inbuflen: ".length($inputbuffer{$s})
		)."\n");

	if ($parser_state{$s} eq 'OP') {
		$bytes_remaining = 4 - length($inputbuffer{$s});
                assert ($bytes_remaining <= 4);
	} elsif ($parser_state{$s} eq 'LENGTH') {
		$bytes_remaining = 4 - length($inputbuffer{$s});
		assert ($bytes_remaining <= 4);
	} else {
		assert ($parser_state{$s} eq 'DATA');
		$bytes_remaining = $parser_framelength{$s} - length($inputbuffer{$s});
	}
	assert ($bytes_remaining > 0);

	$::d_slimproto_v && msg("attempting to read $bytes_remaining bytes\n");

	my $indata;
	my $bytes_read = $s->sysread($indata, $bytes_remaining);

	if (!defined($bytes_read) || ($bytes_read == 0)) {
		if ($total_bytes_read == 0) {
			$::d_slimproto && msg("Slimproto half-close from client: ".$ipport{$s}."\n");
			slimproto_close($s);
			return;
		}

		$::d_slimproto_v && msg("no more to read.\n");
		return;
	}

	$total_bytes_read += $bytes_read;

	$inputbuffer{$s}.=$indata;
	$bytes_remaining -= $bytes_read;

	$::d_slimproto_v && msg ("Got $bytes_read bytes from client, $bytes_remaining remaining\n");

	assert ($bytes_remaining>=0);

	if ($bytes_remaining == 0) {
		if ($parser_state{$s} eq 'OP') {
			assert(length($inputbuffer{$s}) == 4);
			$parser_frametype{$s} = $inputbuffer{$s};
			$inputbuffer{$s} = '';
			$parser_state{$s} = 'LENGTH';

			$d::protocol && msg("got op: ". $parser_frametype{$s}."\n");

		} elsif ($parser_state{$s} eq 'LENGTH') {
			assert(length($inputbuffer{$s}) == 4);
			$parser_framelength{$s} = unpack('N', $inputbuffer{$s});
			$parser_state{$s} = 'DATA';
			$inputbuffer{$s} = '';

			if ($parser_framelength{$s} > 1000) {
				$::d_slimproto && msg ("Client gave us insane length ".$parser_framelength{$s}." for slimproto frame. Disconnecting him.\n");
				slimproto_close($s);
				return;
			}

		} else {
			assert($parser_state{$s} eq 'DATA');
			assert(length($inputbuffer{$s}) == $parser_framelength{$s});
			&process_slimproto_frame($s, $parser_frametype{$s}, $inputbuffer{$s});
			$inputbuffer{$s} = '';
			$parser_frametype{$s} = '';
			$parser_framelength{$s} = 0;
			$parser_state{$s} = 'OP';
		}
	}

	$::d_slimproto_v && msg("new state: ".$parser_state{$s}."\n");
	goto GETMORE;
}


sub process_slimproto_frame {
	my ($s, $op, $data) = @_;

	my $len = length($data);

	$::d_slimproto_v && msg("Got Slimproto frame, op $op, length $len, $s\n");

	if ($op eq 'HELO') {
		if ($len != 10) {
			$::d_slimproto && msg("bad length $len for HELO. Ignoring.\n");
			return;
		}
		my ($deviceid, $revision, @mac, $wlan_channellist);

		(	$deviceid, $revision, 
			$mac[0], $mac[1], $mac[2], $mac[3], $mac[4], $mac[5],
			$wlan_channellist
		) = unpack("CCH2H2H2H2H2H2H4", $data);
		my $mac = join(':', @mac);
		$::d_slimproto && msg(	
			"Squeezebox says hello.\n".
			"\tDeviceid: $deviceid\n".
			"\trevision: $revision\n".
			"\tmac: $mac\n".
			"\twlan_channellist: $wlan_channellist\n"
			);

		$::d_factorytest && msg("FACTORYTEST\tevent=helo\tmac=$mac\tdeviceid=$deviceid\trevision=$revision\twlan_channellist=$wlan_channellist\n");

		my $id=$mac;
		
		#sanity check on socket
		return if (!$s->peerport || !$s->peeraddr);
		
		my $paddr = sockaddr_in($s->peerport, $s->peeraddr);
		my $client = Slim::Player::Client::getClient($id); 
		
		if (!defined($client)) {
			$::d_slimproto && msg("creating new client, id:$id ipport: $ipport{$s}\n");
			$client = Slim::Player::Squeezebox->new(
				$id, 		# mac
				$paddr,		# sockaddr_in
				$revision,	# rev
				$s		# tcp sock
			);
			$client->macaddress($mac);
			$client->init();
		} else {
			$::d_slimproto && msg("hello from existing client: $id on ipport: $ipport{$s}\n");
			$client->reconnect($paddr, $revision, $s);
		}
		
		$sock2client{$s}=$client;
		
		if ($client->needsUpgrade()) {
			Slim::Hardware::VFD::vfdBrightness($client,$Slim::Hardware::VFD::MAXBRIGHTNESS);
			Slim::Buttons::Block::block($client, string('PLAYER_NEEDS_UPGRADE_1'), string('PLAYER_NEEDS_UPGRADE_2'));
		} else {
			Slim::Buttons::Block::unblock($client);
		 	$client->volume(Slim::Utils::Prefs::clientGet($client, "volume"));

		}
		return;
	} 

	my $client = $sock2client{$s};
	
	assert($client);

	if ($op eq 'IR  ') {
		# format for IR:
		# [4]   time since startup in ticks (1KHz)
		# [1]	code format
		# [1]	number of bits 
		# [4]   the IR code, up to 32 bits      
		if ($len != 10) {
			$::d_slimproto && msg("bad length $len for IR. Ignoring\n");
			return;
		}

		my ($irTime, $irCode) =unpack 'NxxH8', $data;
		Slim::Hardware::IR::enqueue($client, $irCode, $irTime);

		$::d_factorytest && msg("FACTORYTEST\tevent=ir\tmac=".$client->id."\tcode=$irCode\n");

	} elsif ($op eq 'RESP') {
		# HTTP stream headers
		$::d_slimproto && msg("Squeezebox got HTTP response:\n$data\n");
	} elsif ($op eq 'STAT') {

		#struct status_struct {
		#        u32_t event;
		#        u8_t num_crlf;          // number of consecutive cr|lf received while parsing headers
		#        u8_t mas_initialized;   // 'm' or 'p'
		#        u8_t mas_mode;          // serdes mode
		#        u32_t rptr;
		#        u32_t wptr;
		#        u64_t bytes_received;
        #		 u16_t  signal_strength;
		#        u32_t  jiffies;
		#
		
		# event types:
		# 	vfdc - vfd received
		#   i2cc - i2c command recevied
		#	STMa - AUTOSTART    
		#	STMc - CONNECT      
		#	STMe - ESTABLISH    
		#	STMf - CLOSE        
		#	STMh - ENDOFHEADERS 
		#	STMp - PAUSE        
		#	STMr - UNPAUSE           // "resume"
		#	STMt - TIMER        
		#	STMu - UNDERRUN     
		
		(	$status{$client}->{'event_code'},
			$status{$client}->{'num_crlf'},
			$status{$client}->{'mas_initialized'},
			$status{$client}->{'mas_mode'},
			$status{$client}->{'rptr'},
			$status{$client}->{'wptr'},
			$status{$client}->{'bytes_received_H'},
			$status{$client}->{'bytes_received_L'},
			$status{$client}->{'signal_strength'},
			$status{$client}->{'jiffies'}
		) = unpack ('a4CCCNNNNnN', $data);
		
		my $firststatus;
		if (!defined($status{$client}->{'bytes_received'}) && defined($status{$client}->{'byteoffset'})) {
			$firststatus = 1;
		}
		
		$status{$client}->{'bytes_received'} = $status{$client}->{'bytes_received_H'} * 2**32 + $status{$client}->{'bytes_received_L'}; 
		
		if ($firststatus) {
			$status{$client}->{'byteoffset'} += $status{$client}->{'bytes_received'};
		}
		
		my $fullness = 2*$status{$client}->{'wptr'} - 2*$status{$client}->{'rptr'};
		if ($fullness < 0) {
			$fullness = $client->buffersize() + $fullness;
		};

		$status{$client}->{'fullness'} = $fullness;

		$::d_factorytest && msg("FACTORYTEST\tevent=stat\tmac=".$client->id."\tsignalstrength=$status{$client}->{'signal_strength'}\n");

# TODO make a "verbose" option for this
		0 && $::d_slimproto && msg("Squeezebox stream status:\n".
		"	event_code:      $status{$client}->{'event_code'}\n".
		"	num_crlf:        $status{$client}->{'num_crlf'}\n".
		"	mas_initiliazed: $status{$client}->{'mas_initialized'}\n".
		"	mas_mode:        $status{$client}->{'mas_mode'}\n".
		"	rptr:            $status{$client}->{'rptr'}\n".
		"	wptr:            $status{$client}->{'wptr'}\n".
		"	bytes_rec_H      $status{$client}->{'bytes_received_H'}\n".
		"	bytes_rec_L      $status{$client}->{'bytes_received_L'}\n".
		"	fullness:        $status{$client}->{'fullness'}\n".
		"	byteoffset:      $status{$client}->{'byteoffset'}\n".
		"	bytes_received   $status{$client}->{'bytes_received'}\n".
		"	signal_strength: $status{$client}->{'signal_strength'}\n".
		"	jiffies:         $status{$client}->{'jiffies'}\n".
		"");
		Slim::Player::Sync::checkSync($client);
		
		my $callback = $callbacks{$status{$client}->{'event_code'}};

		&$callback($client) if $callback;
		
	} elsif ($op eq 'BYE!') {
		$::d_slimproto && msg("Slimproto: Saying goodbye\n");
		if ($data eq chr(1)) {
			$::d_slimproto && msg("Going out for upgrade...\n");
			# give the player a chance to get into upgrade mode
			sleep(2);

			my $success = $client->upgradeFirmware();
			if (defined($success)) {
				msg("Problem with upgrade: $success\n");
			}
		}
		
	} else {
		msg("Unknown slimproto op: $op\n");
	}
}

# returns the signal strength (0 to 100), outside that range, it's not a wireless connection, so return undef
sub signalStrength {

	my $client = shift;

	if (exists($status{$client}) && ($status{$client}->{'signal_strength'} <= 100)) {
		return $status{$client}->{'signal_strength'};
	} else {
		return undef;
	}
}

sub fullness {
	my $client = shift;
	my $set = shift;
	
	if (defined($set)) { $status{$client}->{'fullness'} = $set; }
	
	return $status{$client}->{'fullness'} || 0;
}

# returns how many bytes have been received by the player.  Can be reset to an arbitrary value.
sub bytesReceived {
	my $client = shift;
	my $preset = shift;

	if (defined($preset)) {
		$::d_slimproto && msg("presetting streamed bytes to: $preset\n");
		$status{$client}->{'byteoffset'} = $status{$client}->{'bytes_received'} + $preset;
	}

	return $status{$client}->{'bytes_received'} - $status{$client}->{'byteoffset'};
}
1;



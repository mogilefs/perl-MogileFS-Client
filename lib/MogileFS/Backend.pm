package MogileFS::Backend;

use strict;
no strict 'refs';

use Carp;
use IO::Socket::INET;
use Socket qw( MSG_NOSIGNAL PF_INET IPPROTO_TCP SOCK_STREAM );
use Errno qw( EINPROGRESS EWOULDBLOCK EISCONN );
use POSIX ();
use MogileFS::Client;
use List::Util qw/ shuffle /;

use fields ('hosts',        # arrayref of "$host:$port" of mogilefsd servers
            'host_dead',    # "$host:$port" -> $time  (of last connect failure)
            'lasterr',      # string: \w+ identifier of last error
            'lasterrstr',   # string: english of last error
            'sock_cache',   # cached socket to mogilefsd tracker
            'pref_ip',      # hashref; { ip => preferred ip }
            'timeout',      # time in seconds to allow sockets to become readable
            'last_host_connected',  # "ip:port" of last host connected to
            'last_host_idx', # array index of the last host we connected to
            'hooks',        # hash: hookname -> coderef
            );

use vars qw($FLAG_NOSIGNAL $PROTO_TCP);
eval { $FLAG_NOSIGNAL = MSG_NOSIGNAL; };

sub new {
    my MogileFS::Backend $self = shift;
    $self = fields::new($self) unless ref $self;

    return $self->_init(@_);
}

sub reload {
    my MogileFS::Backend $self = shift;
    return undef unless $self;

    return $self->_init(@_);
}

sub _init {
    my MogileFS::Backend $self = shift;

    my %args = @_;

    # FIXME: add actual validation
    {
        $self->{hosts} = $args{hosts} or
            _fail("constructor requires parameter 'hosts'");

        _fail("'hosts' argument must be an arrayref")
            unless ref $self->{hosts} eq 'ARRAY';

        _fail("'hosts' argument must be of form: 'host:port'")
            if grep(! /:\d+$/, @{$self->{hosts}});

        _fail("'timeout' argument must be a number")
            if $args{timeout} && $args{timeout} !~ /^\d+$/;
        $self->{timeout} = $args{timeout} || 3;
    }

    $self->{hosts} = [ shuffle(@{ $self->{hosts} }) ];

    $self->{host_dead} = {};

    return $self;
}

sub run_hook {
    my MogileFS::Backend $self = shift;
    my $hookname = shift || return;

    my $hook = $self->{hooks}->{$hookname};
    return unless $hook;

    eval { $hook->(@_) };

    warn "MogileFS::Backend hook '$hookname' threw error: $@\n" if $@;
}

sub add_hook {
    my MogileFS::Backend $self = shift;
    my $hookname = shift || return;

    if (@_) {
        $self->{hooks}->{$hookname} = shift;
    } else {
        delete $self->{hooks}->{$hookname};
    }
}

sub set_pref_ip {
    my MogileFS::Backend $self = shift;
    $self->{pref_ip} = shift;
    $self->{pref_ip} = undef
        unless $self->{pref_ip} &&
               ref $self->{pref_ip} eq 'HASH';
}

sub _wait_for_readability {
    my ($fileno, $timeout) = @_;
    return 0 unless $fileno && $timeout;

    my $rin = '';
    vec($rin, $fileno, 1) = 1;
    # FIXME: signals/ptrace attach can interrupt the select.  we should resume selecting
    # and keep track of hires time remaining
    my $nfound = select($rin, undef, undef, $timeout);

    # undef/0 are failure, 1 is success
    return $nfound ? 1 : 0;
}

sub do_request {
    my MogileFS::Backend $self = shift;
    my ($cmd, $args) = @_;

    _fail("invalid arguments to do_request")
        unless $cmd && $args;

    local $SIG{'PIPE'} = "IGNORE" unless $FLAG_NOSIGNAL;

    my $sock = $self->{sock_cache};
    my $argstr = _encode_url_string(%$args);
    my $req = "$cmd $argstr\r\n";
    my $reqlen = length($req);
    my $rv = 0;

    if ($sock) {
        # try our cached one, but assume it might be bogus
        $self->run_hook('do_request_start', $cmd, $self->{last_host_connected});
        _debug("SOCK: cached = $sock, REQ: $req");
        $rv = send($sock, $req, $FLAG_NOSIGNAL);
        if ($! || ! defined $rv) {
            # undef is error, but $! may not be populated, we've found
            $self->run_hook('do_request_send_error', $cmd, $self->{last_host_connected});
            undef $self->{sock_cache};
        } elsif ($rv != $reqlen) {
            $self->run_hook('do_request_length_mismatch', $cmd, $self->{last_host_connected});
            return _fail("send() didn't return expected length ($rv, not $reqlen)");
        }
    }

    unless ($rv) {
        $sock = $self->_get_sock
            or return _fail("couldn't connect to mogilefsd backend");
        $self->run_hook('do_request_start', $cmd, $self->{last_host_connected});
        _debug("SOCK: $sock, REQ: $req");
        $rv = send($sock, $req, $FLAG_NOSIGNAL);
        if ($!) {
            $self->run_hook('do_request_send_error', $cmd, $self->{last_host_connected});
            return _fail("error talking to mogilefsd tracker: $!");
        } elsif ($rv != $reqlen) {
            $self->run_hook('do_request_length_mismatch', $cmd, $self->{last_host_connected});
            return _fail("send() didn't return expected length ($rv, not $reqlen)");
        }
        $self->{sock_cache} = $sock;
    }

    # wait up to 3 seconds for the socket to come to life
    unless (_wait_for_readability(fileno($sock), $self->{timeout})) {
        close($sock);
        $self->run_hook('do_request_read_timeout', $cmd, $self->{last_host_connected});
        undef $self->{sock_cache};
        return _fail("timed out after $self->{timeout}s against $self->{last_host_connected} when sending command: [$req]");
    }

    # guard against externally-modified $/ changes.  patch from
    # Andreas J. Koenig.  in practice nobody should do this, though,
    # and this line should be unnecessary.
    local $/ = "\n";

    my $line = <$sock>;

    $self->run_hook('do_request_finished', $cmd, $self->{last_host_connected});

    _debug("RESPONSE: $line");

    unless (defined $line) {
        undef $self->{sock_cache};
        return _fail("socket closed on read");
    }

    # ERR <errcode> <errstr>
    if ($line =~ /^ERR\s+(\w+)\s*(\S*)/) {
        $self->{'lasterr'} = $1;
        $self->{'lasterrstr'} = $2 ? _unescape_url_string($2) : undef;
        _debug("LASTERR: $1 $2");
        return undef;
    }

    # OK <arg_len> <response>
    if ($line =~ /^OK\s+\d*\s*(\S*)/) {
        my $args = _decode_url_string($1);
        _debug("RETURN_VARS: ", $args);
        return $args;
    }

    undef $self->{sock_cache};
    _fail("invalid response from server: [$line]");
    return undef;
}

sub errstr {
    my MogileFS::Backend $self = shift;
    return unless $self->{'lasterr'};
    return join(" ", $self->{'lasterr'}, $self->{'lasterrstr'});
}

sub errcode {
    my MogileFS::Backend $self = shift;
    return $self->{lasterr};
}

sub last_tracker {
    my $self = shift;
    return $self->{last_host_connected};
}

sub err {
    my MogileFS::Backend $self = shift;
    return $self->{lasterr} ? 1 : 0;
}

sub force_disconnect {
    my MogileFS::Backend $self = shift;
    undef $self->{sock_cache};
    return;
}

################################################################################
# MogileFS::Backend class methods
#

sub _fail {
    croak "MogileFS::Backend: $_[0]";
}

*_debug = *MogileFS::Client::_debug;

sub _connect_sock { # sock, sin, timeout
    my ($sock, $sin, $timeout) = @_;
    $timeout ||= 0.25;

    # make the socket non-blocking for the connection if wanted, but
    # unconditionally set it back to blocking mode at the end

    if ($timeout) {
        IO::Handle::blocking($sock, 0);
    } else {
        IO::Handle::blocking($sock, 1);
    }

    my $ret = connect($sock, $sin);

    if (!$ret && $timeout && $!==EINPROGRESS) {

        my $win='';
        vec($win, fileno($sock), 1) = 1;

        if (select(undef, $win, undef, $timeout) > 0) {
            $ret = connect($sock, $sin);
            # EISCONN means connected & won't re-connect, so success
            $ret = 1 if !$ret && $!==EISCONN;
        }
    }

    # turn blocking back on, as we expect to do blocking IO on our sockets
    IO::Handle::blocking($sock, 1) if $timeout;

    return $ret;
}

sub _sock_to_host { # (host)
    my MogileFS::Backend $self = shift;
    my $host = shift;

    # create a socket and try to do a non-blocking connect
    my ($ip, $port) = $host =~ /^(.*):(\d+)$/;
    my $sock = "Sock_$host";
    my $connected = 0;
    my $proto = $PROTO_TCP ||= getprotobyname('tcp');
    my $sin;

    # try preferred ips
    if ($self->{pref_ip} && (my $prefip = $self->{pref_ip}->{$ip})) {
        _debug("using preferred ip $prefip over $ip");
        socket($sock, PF_INET, SOCK_STREAM, $proto);
        $sin = Socket::sockaddr_in($port, Socket::inet_aton($prefip));
        if (_connect_sock($sock, $sin, 0.1)) {
            $connected = 1;
            $self->{last_host_connected} = "$prefip:$port";
        } else {
            _debug("failed connect to preferred ip $prefip");
            close $sock;
        }
    }

    # now try the original ip
    unless ($connected) {
        socket($sock, PF_INET, SOCK_STREAM, $proto);
        my $aton_ip = Socket::inet_aton($ip)
            or return undef;
        $sin = Socket::sockaddr_in($port, $aton_ip);
        return undef unless _connect_sock($sock, $sin);
        $self->{last_host_connected} = $host;
    }

    # just throw back the socket we have so far
    return $sock;
}

# return a new mogilefsd socket, trying different hosts until one is found,
# or undef if they're all dead
sub _get_sock {
    my MogileFS::Backend $self = shift;
    return undef unless $self;

    my $size = scalar(@{$self->{hosts}});
    my $tries = $size > 15 ? 15 : $size;

    unless (defined($self->{last_host_idx})) {
        $self->{last_host_idx} = int(rand() * $size);
    }

    my $now = time();
    my $sock;
    foreach (1..$tries) {
        $self->{last_host_idx} = ($self->{last_host_idx}+1) % $size;
        my $host = $self->{hosts}->[$self->{last_host_idx}];

        # try dead hosts every 5 seconds
        next if $self->{host_dead}->{$host} &&
                $self->{host_dead}->{$host} > $now - 5;

        last if $sock = $self->_sock_to_host($host);

        # mark sock as dead
        _debug("marking host dead: $host @ $now");
        $self->{host_dead}->{$host} = $now;
    }

    return $sock;
}

sub _escape_url_string {
    my $str = shift;
    $str =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $str =~ tr/ /+/;
    return $str;
}

sub _unescape_url_string {
    my $str = shift;
    $str =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
    $str =~ tr/+/ /;
    return $str;
}

sub _encode_url_string {
    my %args = @_;
    return "" unless %args;
    return join("&",
                map { _escape_url_string($_) . '=' .
                      _escape_url_string($args{$_}) }
                grep { defined $args{$_} } keys %args
                );
}

sub _decode_url_string {
    my $arg = shift;
    my $buffer = ref $arg ? $arg : \$arg;
    my $hashref = {};  # output hash

    my $pair;
    my @pairs = split(/&/, $$buffer);
    my ($name, $value);
    foreach $pair (@pairs) {
        ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $name =~ tr/+/ /;
        $name =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $hashref->{$name} .= $hashref->{$name} ? "\0$value" : $value;
    }

    return $hashref;
}

1;

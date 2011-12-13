################################################################################
# MogileFS::HTTPFile object
# NOTE: This is meant to be used within IO::WrapTie...
#

package MogileFS::NewHTTPFile;

use strict;
no strict 'refs';

use Carp;
use POSIX qw( EAGAIN );
use Socket qw( PF_INET SOCK_STREAM );
use Errno qw( EINPROGRESS EISCONN );

use vars qw($PROTO_TCP);

use fields ('host',
            'sock',           # IO::Socket; created only when we need it
            'uri',
            'data',           # buffered data we have
            'pos',            # simulated file position
            'length',         # length of data field
            'content_length', # declared length of data we will be receiving (not required)
            'mg',
            'fid',
            'devid',
            'class',
            'key',
            'path',           # full URL to save data to
            'backup_dests',
            'bytes_out',      # count of how many bytes we've written to the socket
            'data_in',        # storage for data we've read from the socket
            'create_close_args',  # Extra arguments hashref for the do_request of create_close during CLOSE
            );

sub path  { _getset(shift, 'path');      }
sub class { _getset(shift, 'class', @_); }
sub key   { _getset(shift, 'key', @_);   }

sub _parse_url {
    my MogileFS::NewHTTPFile $self = shift;
    my $url = shift;
    return 0 unless $url =~ m!http://(.+?)(/.+)$!;
    $self->{host} = $1;
    $self->{uri} = $2;
    $self->{path} = $url;
    return 1;
}

sub TIEHANDLE {
    my MogileFS::NewHTTPFile $self = shift;
    $self = fields::new($self) unless ref $self;

    my %args = @_;
    return undef unless $self->_parse_url($args{path});

    $self->{data} = '';
    $self->{length} = 0;
    $self->{backup_dests} = $args{backup_dests} || [];
    $self->{content_length} = $args{content_length} + 0;
    $self->{pos} = 0;
    $self->{$_} = $args{$_} foreach qw(mg fid devid class key);
    $self->{bytes_out} = 0;
    $self->{data_in} = '';
    $self->{create_close_args} = $args{create_close_args} || {};

    return $self;
}
*new = *TIEHANDLE;

sub _sock_to_host { # (host)
    my MogileFS::NewHTTPFile $self = shift;
    my $host = shift;

    # setup
    my ($ip, $port) = $host =~ /^(.*):(\d+)$/;
    my $sock = "Sock_$host";
    my $proto = $PROTO_TCP ||= getprotobyname('tcp');
    my $sin;

    # create the socket
    socket($sock, PF_INET, SOCK_STREAM, $proto);
    $sin = Socket::sockaddr_in($port, Socket::inet_aton($ip));

    # unblock the socket
    IO::Handle::blocking($sock, 0);

    # attempt a connection
    my $ret = connect($sock, $sin);
    if (!$ret && $! == EINPROGRESS) {
        my $win = '';
        vec($win, fileno($sock), 1) = 1;

        # watch for writeability
        if (select(undef, $win, undef, 3) > 0) {
            $ret = connect($sock, $sin);

            # EISCONN means connected & won't re-connect, so success
            $ret = 1 if !$ret && $! == EISCONN;
        }
    }

    # just throw back the socket we have
    return $sock if $ret;
    return undef;
}

sub _connect_sock {
    my MogileFS::NewHTTPFile $self = shift;
    return 1 if $self->{sock};

    my @down_hosts;

    while (!$self->{sock} && $self->{host}) {
        # attempt to connect
        return 1 if
            $self->{sock} = $self->_sock_to_host($self->{host});

        push @down_hosts, $self->{host};
        if (my $dest = shift @{$self->{backup_dests}}) {
            # dest is [$devid,$path]
            _debug("connecting to $self->{host} (dev $self->{devid}) failed; now trying $dest->[1] (dev $dest->[0])");
            $self->_parse_url($dest->[1]) or _fail("bogus URL");
            $self->{devid} = $dest->[0];
        } else {
            $self->{host} = undef;
        }
    }

    _fail("unable to open socket to storage node (tried: @down_hosts): $!");
}

# abstracted read; implements what ends up being a blocking read but
# does it in terms of non-blocking operations.
sub _getline {
    my MogileFS::NewHTTPFile $self = shift;
    my $timeout = shift || 3;
    return undef unless $self->{sock};

    # short cut if we already have data read
    if ($self->{data_in} =~ s/^(.*?\r?\n)//) {
        return $1;
    }

    my $rin = '';
    vec($rin, fileno($self->{sock}), 1) = 1;

    # nope, we have to read a line
    my $nfound;
    my $t1 = Time::HiRes::time();
    while ($nfound = select($rin, undef, undef, $timeout)) {
        my $data;
        my $bytesin = sysread($self->{sock}, $data, 1024);
        if (defined $bytesin) {
            # we can also get 0 here, which means EOF.  no error, but no data.
            $self->{data_in} .= $data if $bytesin;
        } else {
            next if $! == EAGAIN;
            _fail("error reading from node for device $self->{devid}: $!");
        }

        # return a line if we got one
        if ($self->{data_in} =~ s/^(.*?\r?\n)//) {
            return $1;
        }

        # and if we got no data, it's time to return EOF
        unless ($bytesin) {
            $@ = "\$bytesin is 0";
            return undef;
        }
    }

    # if we got here, nothing was readable in our time limit
    my $t2 = Time::HiRes::time();
    $@ = sprintf("not readable in %0.02f seconds", $t2-$t1);
    return undef;
}

# abstracted write function that uses non-blocking I/O and checking for
# writeability to ensure that we don't get stuck doing a write if the
# node we're talking to goes down.  also handles logic to fall back to
# a backup node if we're on our first write and the first node is down.
# this entire function is a blocking function, it just uses intelligent
# non-blocking write functionality.
#
# this function returns success (1) or it croaks on failure.
sub _write {
    my MogileFS::NewHTTPFile $self = shift;
    return undef unless $self->{sock};

    my $win = '';
    vec($win, fileno($self->{sock}), 1) = 1;

    # setup data and counters
    my $data = shift();
    my $bytesleft = length($data);
    my $bytessent = 0;

    # main sending loop for data, will keep looping until all of the data
    # we've been asked to send is sent
    my $nfound;
    while ($bytesleft && ($nfound = select(undef, $win, undef, 3))) {
        my $bytesout = syswrite($self->{sock}, $data, $bytesleft, $bytessent);
        if (defined $bytesout) {
            # update our myriad counters
            $bytessent += $bytesout;
            $self->{bytes_out} += $bytesout;
            $bytesleft -= $bytesout;
        } else {
            # if we get EAGAIN, restart the select loop, else fail
            next if $! == EAGAIN;
            _fail("error writing to node for device $self->{devid}: $!");
        }
    }
    return 1 unless $bytesleft;

    # at this point, we had a socket error, since we have bytes left, and
    # the loop above didn't finish sending them.  if this was our first
    # write, let's try to fall back to a different host.
    unless ($self->{bytes_out}) {
        if (my $dest = shift @{$self->{backup_dests}}) {
            # dest is [$devid,$path]
            $self->_parse_url($dest->[1]) or _fail("bogus URL");
            $self->{devid} = $dest->[0];
            $self->_connect_sock;

            # now repass this write to try again
            return $self->_write($data);
        }
    }

    # total failure (croak)
    $self->{sock} = undef;
    _fail(
        sprintf(
            "unable to write to any allocated storage node, last tried dev %s on host %s uri %s path %s. Had sent %s bytes, %s bytes left",
            $self->{devid}, $self->{host},      $self->{uri},
            $self->{path},  $self->{bytes_out}, $bytesleft
        )
    );
}

sub PRINT {
    my MogileFS::NewHTTPFile $self = shift;

    # get data to send to server
    my $data = shift;
    my $newlen = length $data;
    $self->{pos} += $newlen;

    # now make socket if we don't have one
    if (!$self->{sock} && $self->{content_length}) {
        $self->_connect_sock;
        $self->_write("PUT $self->{uri} HTTP/1.0\r\nContent-length: $self->{content_length}\r\n\r\n");
    }

    # write some data to our socket
    if ($self->{sock}) {
        # save the first 1024 bytes of data so that we can seek back to it
        # and do some work later
        if ($self->{length} < 1024) {
            if ($self->{length} + $newlen > 1024) {
                $self->{length} = 1024;
                $self->{data} .= substr($data, 0, 1024 - $self->{length});
            } else {
                $self->{length} += $newlen;
                $self->{data} .= $data;
            }
        }

        # actually write
        $self->_write($data);
    } else {
        # or not, just stick it on our queued data
        $self->{data} .= $data;
        $self->{length} += $newlen;
    }
}
*print = *PRINT;

sub CLOSE {
    my MogileFS::NewHTTPFile $self = shift;

    # if we're closed and we have no sock...
    unless ($self->{sock}) {
        $self->_connect_sock;
        $self->_write("PUT $self->{uri} HTTP/1.0\r\nContent-length: $self->{length}\r\n\r\n");
        $self->_write($self->{data});
    }

    # set a message in $! and $@
    my $err = sub {
        $@ = "$_[0]\n";
        return undef;
    };

    # get response from put
    if ($self->{sock}) {
        my $line = $self->_getline(6);  # wait up to 6 seconds for response to PUT.

        return $err->("Unable to read response line from server ($self->{sock}) after PUT of $self->{length} to $self->{uri}.  _getline says: $@")
            unless defined $line;

        if ($line =~ m!^HTTP/\d+\.\d+\s+(\d+)!) {
            # all 2xx responses are success
            unless ($1 >= 200 && $1 <= 299) {
                my $errcode = $1;
                # read through to the body
                my ($found_header, $body);
                while (defined (my $l = $self->_getline)) {
                    # remove trailing stuff
                    $l =~ s/[\r\n\s]+$//g;
                    $found_header = 1 unless $l;
                    next unless $found_header;

                    # add line to the body, with a space for readability
                    $body .= " $l";
                }
                $body = substr($body, 0, 512) if length $body > 512;
                return $err->("HTTP response $errcode from upload of $self->{uri} to $self->{sock}: $body");
            }
        } else {
            return $err->("Response line not understood from $self->{sock}: $line");
        }
        $self->{sock}->close;
    }

    my MogileFS $mg = $self->{mg};
    my $domain = $mg->{domain};

    my $fid   = $self->{fid};
    my $devid = $self->{devid};
    my $path  = $self->{path};

    my $create_close_args = $self->{create_close_args};

    my $key = shift || $self->{key};

    my $rv = $mg->{backend}->do_request
        ("create_close", {
            %$create_close_args,
            fid    => $fid,
            devid  => $devid,
            domain => $domain,
            size   => $self->{content_length} ? $self->{content_length} : $self->{length},
            key    => $key,
            path   => $path,
        });
    unless ($rv) {
        # set $@, as our callers expect $@ to contain the error message that
        # failed during a close.  since we failed in the backend, we have to
        # do this manually.
        return $err->("$mg->{backend}->{lasterr}: $mg->{backend}->{lasterrstr}");
    }

    return 1;
}
*close = *CLOSE;

sub TELL {
    # return our current pos
    return $_[0]->{pos};
}
*tell = *TELL;

sub SEEK {
    # simply set pos...
    _fail("seek past end of file") if $_[1] > $_[0]->{length};
    $_[0]->{pos} = $_[1];
}
*seek = *SEEK;

sub EOF {
    return ($_[0]->{pos} >= $_[0]->{length}) ? 1 : 0;
}
*eof = *EOF;

sub BINMODE {
    # no-op, we're always in binary mode
}
*binmode = *BINMODE;

sub READ {
    my MogileFS::NewHTTPFile $self = shift;
    my $count = $_[1] + 0;

    my $max = $self->{length} - $self->{pos};
    $max = $count if $count < $max;

    $_[0] = substr($self->{data}, $self->{pos}, $max);
    $self->{pos} += $max;

    return $max;
}
*read = *READ;


################################################################################
# MogileFS::NewHTTPFile class methods
#

sub _fail {
    croak "MogileFS::NewHTTPFile: $_[0]";
}

sub _debug {
    MogileFS::Client::_debug(@_);
}

sub _getset {
    my MogileFS::NewHTTPFile $self = shift;
    my $what = shift;

    if (@_) {
        # note: we're a TIEHANDLE interface, so we're not QUITE like a
        # normal class... our parameters tend to come in via an arrayref
        my $val = shift;
        $val = shift(@$val) if ref $val eq 'ARRAY';
        return $self->{$what} = $val;
    } else {
        return $self->{$what};
    }
}

sub _fid {
    my MogileFS::NewHTTPFile $self = shift;
    return $self->{fid};
}

1;

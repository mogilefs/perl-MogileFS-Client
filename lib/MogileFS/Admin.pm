package MogileFS::Admin;
use strict;
use Carp;
use MogileFS::Backend;
use fields qw(backend readonly);

sub new {
    my MogileFS::Admin $self = shift;
    $self = fields::new($self) unless ref $self;

    my %args = @_;

    $self->{readonly} = $args{readonly} ? 1 : 0;
    my %backend_args = (  hosts => $args{hosts} );
    $backend_args{timeout} = $args{timeout} if $args{timeout};
    $self->{backend} = MogileFS::Backend->new( %backend_args )
        or _fail("couldn't instantiate MogileFS::Backend");

    return $self;
}

sub readonly {
    my MogileFS::Admin $self = shift;
    return $self->{readonly} = $_[0] ? 1 : 0 if @_;
    return $self->{readonly};
}

sub replicate_now {
    my MogileFS::Admin $self = shift;

    my $res = $self->{backend}->do_request("replicate_now", {})
        or return undef;
    return 1;
}

sub get_hosts {
    my MogileFS::Admin $self = shift;
    my $hostid = shift;

    my $args = $hostid ? { hostid => $hostid } : {};
    my $res = $self->{backend}->do_request("get_hosts", $args)
        or return undef;

    my @ret = ();
    foreach my $ct (1..$res->{hosts}) {
        push @ret, { map { $_ => $res->{"host${ct}_$_"} }
                     qw(hostid status hostname hostip http_port http_get_port altip altmask) };
    }

    return \@ret;
}

sub get_devices {
    my MogileFS::Admin $self = shift;
    my $devid = shift;

    my $args = $devid ? { devid => $devid } : {};
    my $res = $self->{backend}->do_request("get_devices", $args)
        or return undef;

    my @ret = ();
    foreach my $ct (1..$res->{devices}) {
        push @ret, { (map { $_ => $res->{"dev${ct}_$_"} } qw(devid hostid status observed_state await svctm utilization)),
                     (map { $_ => $res->{"dev${ct}_$_"}+0 } qw(mb_total mb_used weight)) };
    }

    return \@ret;

}

# get raw information about fids, for enumerating the dataset
#   ( $from_fid, $to_fid )
# returns:
#   { fid => { hashref with keys: domain, class, devcount, length, key } }
sub list_fids {
    my MogileFS::Admin $self = shift;
    my ($fromfid, $tofid) = @_;

    my $res = $self->{backend}->do_request('list_fids', { from => $fromfid, to => $tofid })
        or return undef;

    my $ret = {};
    foreach my $i (1..$res->{fid_count}) {
        $ret->{$res->{"fid_${i}_fid"}} = {
            key => $res->{"fid_${i}_key"},
            length => $res->{"fid_${i}_length"},
            class => $res->{"fid_${i}_class"},
            domain => $res->{"fid_${i}_domain"},
            devcount => $res->{"fid_${i}_devcount"},
        };
    }
    return $ret;
}

sub clear_cache {
    my MogileFS::Admin $self = shift;
    # do the request, default to request all stats if they didn't specify any
    push @_, 'all' unless @_;
    my $res = $self->{backend}->do_request("clear_cache", { map { $_ => 1 } @_ })
        or return undef;
    return 1;
}

# get a hashref of the domains we know about in the format of
#   { domain_name => { class_name => mindevcount, class_name => mindevcount, ... }, ... }
sub get_domains {
    my MogileFS::Admin $self = shift;

    my $res = $self->{backend}->do_request("get_domains", {})
        or return undef;

    my $ret = {};
    foreach my $i (1..$res->{domains}) {
        $ret->{$res->{"domain$i"}} = {
            map {
                $res->{"domain${i}class${_}name"} =>
                    { mindevcount => $res->{"domain${i}class${_}mindevcount"},
                      replpolicy  => $res->{"domain${i}class${_}replpolicy"} || '',
                    }
            } (1..$res->{"domain${i}classes"})
        };
    }

    return $ret;
}

# create a new domain
sub create_domain {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my $domain = shift;

    my $res = $self->{backend}->do_request("create_domain", { domain => $domain });
    return undef unless $res->{domain} eq $domain;

    return 1;
}

# delete a domain
sub delete_domain {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my $domain = shift;

    $self->{backend}->do_request("delete_domain", { domain => $domain })
        or return undef;

    return 1;
}

# create a class within a domain
sub create_class {
    my MogileFS::Admin $self = shift;

    # wrapper around _mod_class(create)
    return $self->_mod_class(@_, 'create');
}


# update a class's mindevcount within a domain
sub update_class {
    my MogileFS::Admin $self = shift;

    # wrapper around _mod_class(update)
    return $self->_mod_class(@_, 'update');
}

# delete a class
sub delete_class {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my ($domain, $class) = @_;

    $self->{backend}->do_request("delete_class", {
            domain => $domain,
            class => $class,
        }) or return undef;

    return 1;
}


# create a host
sub create_host {
    my MogileFS::Admin $self = shift;
    my $host = shift;
    return undef unless $host;

    my $args = shift;
    return undef unless ref $args eq 'HASH';
    return undef unless $args->{ip} && $args->{port};

    return $self->_mod_host($host, $args, 'create');
}

# edit a host
sub update_host {
    my MogileFS::Admin $self = shift;
    my $host = shift;
    return undef unless $host;

    my $args = shift;
    return undef unless ref $args eq 'HASH';

    return $self->_mod_host($host, $args, 'update');
}

# delete a host
sub delete_host {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my $host = shift;
    return undef unless $host;

    $self->{backend}->do_request("delete_host", { host => $host })
        or return undef;
    return 1;
}

# create a new device
sub create_device {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my (%opts) = @_;   #hostname or hostid, devid, state (optional)

    my $res = $self->{backend}->do_request("create_device", \%opts)
        or return undef;

    return 1;
}

# edit a device
sub update_device {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};
    my $host = shift;
    my $device = shift;
    return undef unless $host;
    return undef unless $device;

    my $args = shift;
    return undef unless ref $args eq 'HASH';

    # TODO: provide a native update_device in the MogileFS::Admin command set.
    if ($args->{status}){
        $self->change_device_state($host, $device, $args->{status}) or return undef;
    }
    if ($args->{weight}){
        $self->change_device_weight($host, $device, $args->{weight}) or return undef;
    }

    return 1;
}

# change the state of a device; pass in the hostname of the host the
# device is located on, the device id number, and the state you want
# the host to be set to.  returns 1 on success, undef on error.
sub change_device_state {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my ($host, $device, $state) = @_;

    my $res = $self->{backend}->do_request("set_state", {
        host => $host,
        device => $device,
        state => $state,
    }) or return undef;

    return 1;
}

# change the weight of a device by passing in the hostname and
# the device id
sub change_device_weight {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my ($host, $device, $weight) = @_;
    $weight += 0;

    my $res = $self->{backend}->do_request("set_weight", {
        host => $host,
        device => $device,
        weight => $weight,
    }) or return undef;

    return 1;
}

# returns a hash (list) of key => weight
sub _get_slave_keys {
    my MogileFS::Admin $self = shift;
    my $backend = $self->{backend};

    my $keys_res = $backend->do_request("server_setting", {
        key => "slave_keys",
    });

    return () unless $keys_res;

    my %slave_keys;

    foreach my $slave (split /,/, $keys_res->{value}) {
        my ($key, $weight) = split /=/, $slave, 2;

        # Weight can be zero, so don't default to 1 if it's defined and longer than 0 characters.
        unless (defined $weight && length $weight) {
            $weight = 1;
        }

        $slave_keys{$key} = $weight;
    }

    return %slave_keys;
}

# returns a hash (list) of key => options
sub _set_slave_keys {
    my MogileFS::Admin $self = shift;
    my $backend = $self->{backend};

    my %slave_keys = @_;

    my @keys;

    foreach my $key (keys %slave_keys) {
        my $weight = $slave_keys{$key};
        if (defined $weight && length $weight && $weight != 1) {
            $key .= "=$weight";
        }
        push @keys, $key;
    }

    my $keys_res = $backend->do_request("set_server_setting", {
        key => "slave_keys",
        value => join(',', @keys),
    });

    return 0 unless $keys_res;
    return 1;
}

# returns a hashref of key => [dsn, username, password] specifying slave nodes which can be connected to.
sub slave_list {
    my MogileFS::Admin $self = shift;

    my $backend = $self->{backend};

    my %slave_keys = $self->_get_slave_keys;
    my %return;

    foreach my $key (keys %slave_keys) {
        my $slave_res = $backend->do_request("server_setting", {
            key => "slave_$key",
        });
        next unless $slave_res;
        my ($dsn, $username, $password) = split /\|/, $slave_res->{value};
        $return{$key} = [$dsn, $username, $password];
    }

    return \%return;
}

sub slave_add {
    my MogileFS::Admin $self = shift;
    my ($key, $dsn, $username, $password) = @_;

    my $backend = $self->{backend};

    my %slave_keys = $self->_get_slave_keys;

    if (exists $slave_keys{$key}) {
        return 0;
    }

    my $res = $backend->do_request("set_server_setting", {
        key   => "slave_$key",
        value => join('|', $dsn, $username, $password),
    }) or return undef;

    $slave_keys{$key} = undef;

    $self->_set_slave_keys(%slave_keys);

    return 1;
}

sub slave_modify {
    my MogileFS::Admin $self = shift;
    my $key = shift;
    my %opts = @_;

    my $backend = $self->{backend};

    my %slave_keys = $self->_get_slave_keys;

    unless (exists $slave_keys{$key}) {
        return 0;
    }

    my $get_res = $backend->do_request("server_setting", {
        key => "slave_$key",
    }) or return undef;

    my ($dsn, $username, $password) = split /\|/, $get_res->{value};

    $dsn      = $opts{dsn}      if exists $opts{dsn};
    $username = $opts{username} if exists $opts{username};
    $password = $opts{password} if exists $opts{password};

    my $set_res = $backend->do_request("set_server_setting", {
        key   => "slave_$key",
        value => join('|', $dsn, $username, $password),
    }) or return undef;

    return 1;
}

sub slave_delete {
    my MogileFS::Admin $self = shift;
    my $key = shift;

    my $backend = $self->{backend};

    my %slave_keys = $self->_get_slave_keys;

    unless (exists $slave_keys{$key}) {
        return 0;
    }

    my $res = $backend->do_request("set_server_setting", {
        key   => "slave_$key",
        value => undef,
    }) or return undef;

    delete $slave_keys{$key};

    $self->_set_slave_keys(%slave_keys);

    return 1;
}

sub fsck_start {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("fsck_start", {});
}

sub fsck_stop {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("fsck_stop", {});
}

sub fsck_reset {
    my MogileFS::Admin $self = shift;
    my %opts = @_;
    my $polonly = delete $opts{policy_only};
    my $startpos = delete $opts{startpos};
    Carp::croak("Unknown options: ". join(", ", keys %opts)) if %opts;
    return $self->{backend}->do_request("fsck_reset", {
        policy_only => $polonly,
        startpos    => $startpos,
    });
}

sub fsck_clearlog {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("fsck_clearlog", {});
}

sub fsck_status {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("fsck_status", {});
}

sub fsck_log_rows {
    my MogileFS::Admin $self = shift;
    my %args = @_;
    my $after = delete $args{after_logid};
    die if %args;

    my $ret = $self->{backend}->do_request("fsck_getlog", {
        after_logid => $after,
    });
    my @ret;
    for (my $i = 1; $i <= $ret->{row_count}; $i++) {
        my $rec = {};
        foreach my $k (qw(logid utime fid evcode devid)) {
            $rec->{$k} = $ret->{"row_${i}_$k"};
        }
        push @ret, $rec;
    }
    return @ret;
}

sub set_server_setting {
    my MogileFS::Admin $self = shift;
    my ($key, $val) = @_;
    my $res = $self->{backend}->do_request("set_server_setting", {
        key   => $key,
        value => $val,
    });
    return 0 unless $res;
    return 1;
}

sub server_settings {
    my MogileFS::Admin $self = shift;
    my ($key, $val) = @_;
    my $res = $self->{backend}->do_request("server_settings", {});
    return 0 unless $res;
    my $ret = {};
    for (my $i = 1; $i <= $res->{key_count}; $i++) {
        $ret->{$res->{"key_$i"}} = $res->{"value_$i"};
    }
    return $ret;
}

sub rebalance_status {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("rebalance_status", {});
}

sub rebalance_start {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("rebalance_start", {});
}

sub rebalance_test {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("rebalance_test", {});
}

sub rebalance_stop {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("rebalance_stop", {});
}

sub rebalance_reset {
    my MogileFS::Admin $self = shift;
    return $self->{backend}->do_request("rebalance_reset", {});
}

sub rebalance_set_policy {
    my MogileFS::Admin $self = shift;

    my $policy = shift;
    return $self->{backend}->do_request("rebalance_set_policy", {
        policy => $policy,
    });
}

################################################################################
# MogileFS::Admin class methods
#

sub _fail {
    croak "MogileFS::Admin: $_[0]";
}

# FIXME: is this used?
sub _debug {
    return 1 unless $MogileFS::DEBUG;
    my $msg = shift;
    my $ref = shift;
    chomp $msg;
    eval "use Data::Dumper;";
    print STDERR "$msg\n" . Dumper($ref) . "\n";
    return 1;
}

# modify a class within a domain
sub _mod_class {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my ($domain, $class, $args, $verb) = @_;
    $verb ||= 'create';

    my $res = $self->{backend}->do_request("${verb}_class", {
        domain => $domain,
        class => $class,
        %$args,
    });
    return undef unless $res->{class} eq $class;

    return 1;
}

# modify a host
sub _mod_host {
    my MogileFS::Admin $self = shift;
    return undef if $self->{readonly};

    my ($host, $args, $verb) = @_;

    $args ||= {};
    $args->{host} = $host;
    $verb ||= 'create';

    my $res = $self->{backend}->do_request("${verb}_host", $args);
    return undef unless $res->{host} eq $host;

    return 1;
}

sub errstr {
    my MogileFS::Admin $self = shift;
    return undef unless $self->{backend};
    return $self->{backend}->errstr;
}

sub errcode {
    my MogileFS::Admin $self = shift;
    return undef unless $self->{backend};
    return $self->{backend}->errcode;
}

sub err {
    my MogileFS::Admin $self = shift;
    return undef unless $self->{backend};
    return $self->{backend}->err;
}

1;

#!/usr/bin/perl
package MogileFS::Client;

=head1 NAME

MogileFS::Client - Client library for the MogileFS distributed file system.

=head1 SYNOPSIS

 use MogileFS::Client;

 # create client object w/ server-configured namespace 
 # and IPs of trackers
 $mogc = MogileFS::Client->new(domain => "foo.com::my_namespace",
                               hosts  => ['10.0.0.2:7001', '10.0.0.3:7001']);

 # create a file
 # mogile is a flat namespace.  no paths.
 $key   = "image_of_userid:$userid";   
 # must be configured on server
 $class = "user_images";               
 $fh = $mogc->new_file($key, $class);

 print $fh $data;

 unless ($fh->close) {
    die "Error writing file: " . $mogc->errcode . ": " . $mogc->errstr;
 }

 # Find the URLs that the file was replicated to.
 # May change over time.
 @urls = $mogc->get_paths($key);

 # no longer want it?
 $mogc->delete($key);

=head1 DESCRIPTION

This module is a client library for the MogileFS distributed file system. The class method 'new' creates a client object against a
particular mogilefs tracker and domain. This object may then be used to store and retrieve content easily from MogileFS.

=cut

use strict;
use Carp;
use IO::WrapTie;
use LWP::UserAgent;
use fields (
            'domain',    # scalar: the MogileFS domain (namespace).
            'backend',   # MogileFS::Backend object
            'readonly',  # bool: if set, client won't permit write actions/etc.  just reads.
            'hooks',     # hash: hookname -> coderef
            );
use Time::HiRes ();
use MogileFS::Backend;
use MogileFS::NewHTTPFile;
use MogileFS::ClientHTTPFile;

our $VERSION = '1.17';

our $AUTOLOAD;

=head1 METHODS

=head2 new

  $client = MogileFS::Client->new( %OPTIONS );

Creates a new MogileFS::Client object.

Returns MogileFS::Client object on success, or dies on failure.

OPTIONS:

=over

=item hosts

Arrayref of 'host:port' strings to connect to as backend trackers in this client.

=item domain

String representing the mogile domain which this MogileFS client is associated with. (All create/delete/fetch operations
will be performed against this mogile domain). See the mogadm shell command and its 'domain' category of operations for
information on manipulating the list of possible domains on a MogileFS system.

=back

=cut

sub new {
    my MogileFS::Client $self = shift;
    $self = fields::new($self) unless ref $self;

    return $self->_init(@_);
}

=head2 reload

  $mogc->reload( %OPTIONS )

Re-init the object, like you'd just reconstructed it with 'new', but change it in-place instead.  Useful if you have a system which reloads a config file, and you want to update a singleton $mogc handle's config value.

=cut

sub reload {
    my MogileFS::Client $self = shift;
    return undef unless $self;

    return $self->_init(@_);
}

sub _init {
    my MogileFS::Client $self = shift;

    my %args = @_;

    # FIXME: add actual validation
    {
        # by default, set readonly off
        $self->{readonly} = $args{readonly} ? 1 : 0;

        # get domain (required)
        $self->{domain} = $args{domain} or
            _fail("constructor requires parameter 'domain'");

        # create a new backend object if there's not one already,
        # otherwise call a reload on the existing one
        if ($self->{backend}) {
            $self->{backend}->reload( hosts => $args{hosts} );
        } else {
            $self->{backend} = MogileFS::Backend->new( hosts => $args{hosts},
                                                       timeout => $args{timeout},
                                                       );
        }
        _fail("cannot instantiate MogileFS::Backend") unless $self->{backend};
    }

    _debug("MogileFS object: [$self]", $self);

    return $self;
}

=head2 last_tracker

Returns a scalar of form "ip:port", representing the last mogilefsd
'tracker' server which was talked to.

=cut

sub last_tracker {
    my MogileFS::Client $self = shift;
    return $self->{backend}->last_tracker;
}

=head2 errstr

Returns string representation of the last error that occurred.  It
includes the error code (same as method 'errcode') and a space before
the optional English error message.

This isn't necessarily guaranteed to reset after a successful
operation.  Only call it after another operation returns an error.


=cut

sub errstr {
    my MogileFS::Client $self = shift;
    return $self->{backend}->errstr;
}

=head2 errcode

Returns an error code.  Not a number, but a string identifier
(e.g. "no_domain") which is stable for use in error handling logic.

This isn't necessarily guaranteed to reset after a successful
operation.  Only call it after another operation returns an error.

=cut

sub errcode {
    my MogileFS::Client $self = shift;
    return $self->{backend}->errcode;
}

=head2 force_disconnect

Forces the client to disconnect from the tracker, causing it to reconnect
when the next request is made.  It will reconnect to a different tracker if
possible.  A paranoid application may wish to do to this before retrying a
failed command, on the off chance that another tracker may be working better.

=cut

sub force_disconnect {
    my MogileFS::Client $self = shift;
    return $self->{backend}->force_disconnect();
}

=head2 readonly

  $is_readonly = $mogc->readonly
  $mogc->readonly(1)

Getter/setter to mark this client object as read-only.  Purely a local
operation/restriction, doesn't do a network operation to the mogilefsd
server.

=cut

sub readonly {
    my MogileFS::Client $self = shift;
    return $self->{readonly} = $_[0] ? 1 : 0 if @_;
    return $self->{readonly};
}

=head2 new_file

  $mogc->new_file($key)
  $mogc->new_file($key, $class)
  $mogc->new_file($key, $class, $content_length)
  $mogc->new_file($key, $class, $content_length , $opts_hashref)

Start creating a new filehandle with the given key, and option given
class and options.

Returns a filehandle you should then print to, and later close to
complete the operation.  B<NOTE:> check the return value from close!
If your close didn't succeed, the file didn't get saved!

$opts_hashref can contain keys:

=over

=item fid

Explicitly specify the fid number to use, rather than it being automatically allocated.

=item create_open_args

Hashref of extra key/value pairs to send to mogilefsd in create_open phase.

=item create_close_args

Hashref of extra key/value pairs to send to mogilefsd in create_close phase.

=item largefile

Use MogileFS::ClientHTTPFile which will not load the entire file into memory
like the default MogileFS::NewHTTPFile but requires that the storage node
HTTP servers support the Content-Range header in PUT requests and is a little
slower.

=back

=cut

# returns MogileFS::NewHTTPFile object, or undef if no device
# available for writing
# ARGS: ( key, class, bytes?, opts? )
# where bytes is optional and the length of the file and opts is also optional
# and is a hashref of options.  supported options: fid = unique file id to use
# instead of just picking one in the database.
sub new_file {
    my MogileFS::Client $self = shift;
    return undef if $self->{readonly};

    my ($key, $class, $bytes, $opts) = @_;
    $bytes += 0;
    $opts ||= {};

    # Extra args to be passed along with the create_open and create_close commands.
    # Any internally generated args of the same name will overwrite supplied ones in
    # these hashes.
    my $create_open_args =  $opts->{create_open_args} || {};
    my $create_close_args = $opts->{create_close_args} || {};

    $self->run_hook('new_file_start', $self, $key, $class, $opts);

    my $res = $self->{backend}->do_request
        ("create_open", {
            %$create_open_args,
            domain => $self->{domain},
            class  => $class,
            key    => $key,
            fid    => $opts->{fid} || 0, # fid should be specified, or pass 0 meaning to auto-generate one
            multi_dest => 1,
        }) or return undef;

    my $dests = [];  # [ [devid,path], [devid,path], ... ]

    # determine old vs. new format to populate destinations
    unless (exists $res->{dev_count}) {
        push @$dests, [ $res->{devid}, $res->{path} ];
    } else {
        for my $i (1..$res->{dev_count}) {
            push @$dests, [ $res->{"devid_$i"}, $res->{"path_$i"} ];
        }
    }

    my $main_dest = shift @$dests;
    my ($main_devid, $main_path) = ($main_dest->[0], $main_dest->[1]);

    # create a MogileFS::NewHTTPFile object, based off of IO::File
    unless ($main_path =~ m!^http://!) {
        Carp::croak("This version of MogileFS::Client no longer supports non-http storage URLs.\n");
    }

    $self->run_hook('new_file_end', $self, $key, $class, $opts);

    return IO::WrapTie::wraptie( ( $opts->{largefile}
            ? 'MogileFS::ClientHTTPFile'
            : 'MogileFS::NewHTTPFile' ),
                                mg    => $self,
                                fid   => $res->{fid},
                                path  => $main_path,
                                devid => $main_devid,
                                backup_dests => $dests,
                                class => $class,
                                key   => $key,
                                content_length => $bytes+0,
                                create_close_args => $create_close_args,
                                overwrite => 1,
                            );
}

=head2 edit_file

  $mogc->edit_file($key, $opts_hashref)

Edit the file with the the given key.


B<NOTE:> edit_file is currently EXPERIMENTAL and not recommended for
production use. MogileFS is primarily designed for storing files
for later retrieval, rather than editing.  Use of this function may lead to
poor performance and, until it has been proven mature, should be
considered to also potentially cause data loss.

B<NOTE:> use of this function requires support for the DAV 'MOVE'
verb and partial PUT (i.e. Content-Range in PUT) on the back-end
storage servers (e.g. apache with mod_dav).

Returns a seekable filehandle you can read/write to. Calling this
function may invalidate some or all URLs you currently have for this
key, so you should call ->get_paths again afterwards if you need
them.

On close of the filehandle, the new file contents will replace the
previous contents (and again invalidate any existing URLs).

By default, the file contents are preserved on open, but you may
specify the overwrite option to zero the file first. The seek position
is at the beginning of the file, but you may seek to the end to append.

$opts_hashref can contain keys:

=over

=item overwrite

The edit will overwrite the file, equivalent to opening with '>'.
Default: false.

=back

=cut

sub edit_file {
    my MogileFS::Client $self = shift;
    return undef if $self->{readonly};

    my($key, $opts) = @_;

    my $res = $self->{backend}->do_request
        ("edit_file", {
            domain => $self->{domain},
            key    => $key,
        }) or return undef;

    my $moveReq = HTTP::Request->new('MOVE', $res->{oldpath});
    $moveReq->header(Destination => $res->{newpath});
    my $ua = LWP::UserAgent->new;
    my $resp = $ua->request($moveReq);
    unless ($resp->is_success) {
        warn "Failed to MOVE $res->{oldpath} to $res->{newpath}";
        return undef;
    }

    return IO::WrapTie::wraptie('MogileFS::ClientHTTPFile',
                                mg        => $self,
                                fid       => $res->{fid},
                                path      => $res->{newpath},
                                devid     => $res->{devid},
                                class     => $res->{class},
                                key       => $key,
                                overwrite => $opts->{overwrite},
                            );
}

=head2 read_file

  $mogc->read_file($key)

Read the file with the the given key.

Returns a seekable filehandle you can read() from. Note that you cannot
read line by line using <$fh> notation.

Takes the same options as get_paths (which is called internally to get
the URIs to read from).

=cut

sub read_file {
    my MogileFS::Client $self = shift;
    
    my @paths = $self->get_paths(@_);
    
    my $path = shift @paths;

    return if !$path;

    my @backup_dests = map { [ undef, $_ ] } @paths;

    return IO::WrapTie::wraptie('MogileFS::ClientHTTPFile',
                                path         => $path,
                                backup_dests => \@backup_dests,
                                readonly     => 1,
                                );
}

=head2 store_file

  $mogc->store_file($key, $class, $fh_or_filename[, $opts_hashref])

Wrapper around new_file, print, and close.

Given a key, class, and a filehandle or filename, stores the file
contents in MogileFS.  Returns the number of bytes stored on success,
undef on failure.

$opts_hashref can contain keys for new_file, and also the following:

=over

=item chunk_size

Number of bytes to read and write and write at once out of the larger file.
Defaults to 8192 bytes. Increasing this can increase performance at the cost
of more memory used while uploading the file.
Note that this mostly helps when using largefile => 1

=back

=cut

sub store_file {
    my MogileFS::Client $self = shift;
    return undef if $self->{readonly};

    my($key, $class, $file, $opts) = @_;
    $self->run_hook('store_file_start', $self, $key, $class, $opts);

    my $chunk_size = $opts->{chunk_size} || 8192;
    my $fh = $self->new_file($key, $class, undef, $opts) or return;
    my $fh_from;
    if (ref($file)) {
        $fh_from = $file;
    } else {
        open $fh_from, $file or return;
    }
    my $bytes;
    while (my $len = read $fh_from, my($chunk), $chunk_size) {
        $fh->print($chunk);
        $bytes += $len;
    }

    $self->run_hook('store_file_end', $self, $key, $class, $opts);

    close $fh_from unless ref $file;
    $fh->close or return;
    $bytes;
}

=head2 store_content

    $mogc->store_content($key, $class, $content[, $opts]);

Wrapper around new_file, print, and close.  Given a key, class, and
file contents (scalar or scalarref), stores the file contents in
MogileFS. Returns the number of bytes stored on success, undef on
failure.

=cut

sub store_content {
    my MogileFS::Client $self = shift;
    return undef if $self->{readonly};

    my($key, $class, $content, $opts) = @_;

    $self->run_hook('store_content_start', $self, $key, $class, $opts);

    my $fh = $self->new_file($key, $class, undef, $opts) or return;
    $content = ref($content) eq 'SCALAR' ? $$content : $content;
    $fh->print($content);

    $self->run_hook('store_content_end', $self, $key, $class, $opts);

    $fh->close or return;
    length($content);
}

=head2 get_paths

  @paths = $mogc->get_paths($key)
  @paths = $mogc->get_paths($key, $no_verify_bool); # old way
  @paths = $mogc->get_paths($key, { noverify => $bool }); # new way

Given a key, returns an array of all the locations (HTTP URLs) that
the file has been replicated to.

=over

=item noverify

If the "no verify" option is set, the mogilefsd tracker doesn't verify
that the first item returned in the list is up/alive.  Skipping that
check is faster, so use "noverify" if your application can do it
faster/smarter.  For instance, when giving L<Perlbal> a list of URLs
to reproxy to, Perlbal can intelligently find one that's alive, so use
noverify and get out of mod_perl or whatever as soon as possible.

=item zone

If the zone option is set to 'alt', the mogilefsd tracker will use the
alternative IP for each host if available, while constructing the paths.

=item pathcount

If the pathcount option is set to a positive integer greater than 2, the
mogilefsd tracker will attempt to return that many different paths (if
available) to the same file. If not present or out of range, this value
defaults to 2.

=back

=cut

# old style calling:
#   get_paths(key, noverify)
# new style calling:
#   get_paths(key, { noverify => 0/1, zone => "alt", pathcount => 2..N });
# but with both, second parameter is optional
#
# returns list of URLs that key can be found at, or the empty
# list on either error or no paths
sub get_paths {
    my MogileFS::Client $self = shift;
    my ($key, $opts) = @_;

    # handle parameters, if any
    my ($noverify, $zone);
    unless (ref $opts) {
        $opts = { noverify => $opts };
    }
    my %extra_args;

    $noverify = 1 if $opts->{noverify};
    $zone = $opts->{zone};

    if (my $pathcount = delete $opts->{pathcount}) {
        $extra_args{pathcount} = $pathcount;
    }

    $self->run_hook('get_paths_start', $self, $key, $opts);

    my $res = $self->{backend}->do_request
        ("get_paths", {
            domain => $self->{domain},
            key    => $key,
            noverify => $noverify ? 1 : 0,
            zone   => $zone,
	    %extra_args,
        }) or return ();

    my @paths = map { $res->{"path$_"} } (1..$res->{paths});

    $self->run_hook('get_paths_end', $self, $key, $opts);

    return @paths;
}

=head2 get_file_data

  $dataref = $mogc->get_file_data($key)

Wrapper around get_paths & LWP, which returns scalarref of file
contents in a scalarref.

Don't use for large data, as it all comes back to you in one string.

=cut

# given a key, returns a scalar reference pointing at a string containing
# the contents of the file. takes one parameter; a scalar key to get the
# data for the file.
sub get_file_data {
    # given a key, load some paths and get data
    my MogileFS::Client $self = $_[0];
    my ($key, $timeout) = ($_[1], $_[2]);

    my @paths = $self->get_paths($key, 1);
    return undef unless @paths;

    # iterate over each
    foreach my $path (@paths) {
        next unless defined $path;
        if ($path =~ m!^http://!) {
            # try via HTTP
            my $ua = new LWP::UserAgent;
            $ua->timeout($timeout || 10);

            my $res = $ua->get($path);
            if ($res->is_success) {
                my $contents = $res->content;
                return \$contents;
            }

        } else {
            # open the file from disk and just grab it all
            open FILE, "<$path" or next;
            my $contents;
            { local $/ = undef; $contents = <FILE>; }
            close FILE;
            return \$contents if $contents;
        }
    }
    return undef;
}

=head2 delete

    $mogc->delete($key);

Delete a key from MogileFS.

=cut

# this method returns undef only on a fatal error such as inability to actually
# delete a resource and inability to contact the server.  attempting to delete
# something that doesn't exist counts as success, as it doesn't exist.
sub delete {
    my MogileFS::Client $self = shift;
    return undef if $self->{readonly};

    my $key = shift;

    my $rv = $self->{backend}->do_request
        ("delete", {
            domain => $self->{domain},
            key    => $key,
        });

    # if it's unknown_key, not an error
    return undef unless defined $rv ||
                        $self->{backend}->{lasterr} eq 'unknown_key';

    return 1;
}

=head2 rename

  $mogc->rename($oldkey, $newkey);

Rename file (key) in MogileFS from oldkey to newkey.  Returns true on
success, failure otherwise.

=cut

# this method renames a file.  it returns an undef on error (only a fatal error
# is considered as undef; "file didn't exist" isn't an error).
sub rename {
    my MogileFS::Client $self = shift;
    return undef if $self->{readonly};

    my ($fkey, $tkey) = @_;

    my $rv = $self->{backend}->do_request
        ("rename", {
            domain   => $self->{domain},
            from_key => $fkey,
            to_key   => $tkey,
        });

    # if it's unknown_key, not an error
    return undef unless defined $rv ||
                        $self->{backend}->{lasterr} eq 'unknown_key';

    return 1;
}

=head2 file_debug

    my $info_gob = $mogc->file_debug(fid => $fid);
    ... or ...
    my $info_gob = $mogc->file_debug(key => $key);

Thoroughly search for any database notes about a particular fid. Searchable by
raw fidid, or by domain and key. B<Use sparingly>. Command hits the master
database numerous times, and if you're using it in production something is
likely very wrong.

To be used with troubleshooting broken/odd files and errors from mogilefsd.

=cut

sub file_debug {
    my MogileFS::Client $self = shift;
    my %opts = @_;
    $opts{domain} = $self->{domain} unless exists $opts{domain};

    my $res = $self->{backend}->do_request
        ("file_debug", {
            %opts,
        }) or return undef;
    return $res;
}

=head2 file_info

    my $fid = $mogc->file_info($key, { devices => 0 });

Used to return metadata about a file. Returns the domain, class, expected
length, devcount, etc. Optionally device ids (not paths) can be returned as
well.

Should be used for informational purposes, and not usually for dynamically
serving files.

=cut

sub file_info {
    my MogileFS::Client $self = shift;
    my ($key, $opts) = @_;

    my %extra = ();
    $extra{devices} = delete $opts->{devices};
    die "Unknown arguments: " . join(', ', keys %$opts) if keys %$opts;

    my $res = $self->{backend}->do_request
        ("file_info", {
            domain => $self->{domain},
            key    => $key,
            %extra,
        }) or return undef;
    return $res;
}

=head2 list_keys

    $keys = $mogc->list_keys($prefix, $after[, $limit]);
    ($after, $keys) = $mogc->list_keys($prefix, $after[, $limit]);

Used to get a list of keys matching a certain prefix.

$prefix specifies what you want to get a list of.  $after is the item
specified as a return value from this function last time you called
it.  $limit is optional and defaults to 1000 keys returned.

In list context, returns ($after, $keys).  In scalar context, returns
arrayref of keys.  The value $after is to be used as $after when you
call this function again.

When there are no more keys in the list, you will get back undef or
an empty list.

=cut

sub list_keys {
    my MogileFS::Client $self = shift;
    my ($prefix, $after, $limit) = @_;

    my $res = $self->{backend}->do_request
        ("list_keys", {
            domain => $self->{domain},
            prefix => $prefix,
            after => $after,
            limit => $limit,
        }) or return undef;

    # construct our list of keys and the new after value
    my $resafter = $res->{next_after};
    my $reslist = [];
    for (my $i = 1; $i <= $res->{key_count}+0; $i++) {
        push @$reslist, $res->{"key_$i"};
    }
    return wantarray ? ($resafter, $reslist) : $reslist;
}

=head2 foreach_key

  $mogc->foreach_key( %OPTIONS, sub { my $key = shift; ... } );
  $mogc->foreach_key( prefix => "foo:", sub { my $key = shift; ... } );


Functional interface/wrapper around list_keys.

Given some %OPTIONS (currently only one, "prefix"), calls your callback
for each key matching the provided prefix.

=cut

sub foreach_key {
    my MogileFS::Client $self = shift;
    my $callback = pop;
    Carp::croak("Last parameter not a subref") unless ref $callback eq "CODE";
    my %opts = @_;
    my $prefix = delete $opts{prefix};
    Carp::croak("Unknown option(s): " . join(", ", keys %opts)) if %opts;

    my $last = "";
    my $max = 1000;
    my $count = $max;

    while ($count == $max) {
        my $res = $self->{backend}->do_request
            ("list_keys", {
                domain => $self->{domain},
                prefix => $prefix,
                after => $last,
                limit => $max,
            }) or return undef;
        $count = $res->{key_count}+0;
        for (my $i = 1; $i <= $count; $i++) {
            $callback->($res->{"key_$i"});
        }
        $last = $res->{"key_$count"};
    }
    return 1;
}

# just makes some sleeping happen.  first and only argument is number of
# seconds to instruct backend thread to sleep for.
sub sleep {
    my MogileFS::Client $self = shift;
    my $duration = shift;

    $self->{backend}->do_request("sleep", { duration => $duration + 0 })
        or return undef;

    return 1;
}

=head2 update_class

    $mogc->update_class($key, $newclass);

Update the replication class of a pre-existing file, causing
the file to become more or less replicated.

=cut

sub update_class {
    my MogileFS::Client $self = shift;
    my ($key, $class) = @_;
    my $res = $self->{backend}->do_request
            ("updateclass", {
                domain => $self->{domain},
                key => $key,
                class => $class,
            }) or return undef;
    return $res;
}

=head2 set_pref_ip

  $mogc->set_pref_ip({ "10.0.0.2" => "10.2.0.2" });

Weird option for old, weird network architecture.  Sets a mapping
table of preferred alternate IPs, if reachable.  For instance, if
trying to connect to 10.0.0.2 in the above example, the module would
instead try to connect to 10.2.0.2 quickly first, then then fall back
to 10.0.0.2 if 10.2.0.2 wasn't reachable.

=cut

# expects as argument a hashref of "standard-ip" => "preferred-ip"
sub set_pref_ip {
    my MogileFS::Client $self = shift;
    $self->{backend}->set_pref_ip(shift)
        if $self->{backend};
}

=head1 PLUGIN METHODS

WRITEME

=cut

# used to support plugins that have modified the server, this builds things into
# an argument list and passes them back to the server
# TODO: there is no readonly protection here?  does it matter?  should we check
# with the server to see what methods they support?  (and if they should be disallowed
# when the client is in readonly mode?)
sub AUTOLOAD {
    # remove everything up to the last colon, so we only have the method name left
    my $method = $AUTOLOAD;
    $method =~ s/^.*://;

    return if $method eq 'DESTROY';

    # let this work
    no strict 'refs';

    # create a method to pass this on back
    *{$AUTOLOAD} = sub {
        my MogileFS::Client $self = shift;
        # pre-assemble the arguments into a hashref
        my $ct = 0;
        my $args = {};
        $args->{"arg" . ++$ct} = shift() while @_;
        $args->{"argcount"} = $ct;

        # now put in standard args
        $args->{"domain"} = $self->{domain};

        # now call and return whatever we get back from the backend
        return $self->{backend}->do_request("plugin_$method", $args);
    };

    # now pass through
    goto &$AUTOLOAD;
}

=head1 HOOKS

=head2 add_hook

WRITEME

=cut

sub add_hook {
    my MogileFS::Client $self = shift;
    my $hookname = shift || return;

    if (@_) {
        $self->{hooks}->{$hookname} = shift;
    } else {
        delete $self->{hooks}->{$hookname};
    }
}

sub run_hook {
    my MogileFS::Client $self = shift;
    my $hookname = shift || return;

    my $hook = $self->{hooks}->{$hookname};
    return unless $hook;

    eval { $hook->(@_) };

    warn "MogileFS::Client hook '$hookname' threw error: $@\n" if $@;
}

=head2 add_backend_hook

WRITEME

=cut

sub add_backend_hook {
    my MogileFS::Client $self = shift;
    my $backend = $self->{backend};

    $backend->add_hook(@_);
}


################################################################################
# MogileFS class methods
#

sub _fail {
    croak "MogileFS: $_[0]";
}

sub _debug {
    return 1 unless $MogileFS::DEBUG;

    my $msg = shift;
    my $ref = shift;
    chomp $msg;

    eval "use Data::Dumper;";
    print STDERR "$msg\n" . Dumper($ref) . "\n";
    return 1;
}


1;
__END__

=head1 SEE ALSO

L<http://www.danga.com/mogilefs/>

=head1 COPYRIGHT

This module is Copyright 2003-2004 Brad Fitzpatrick,
and copyright 2005-2007 Six Apart, Ltd.

All rights reserved.

You may distribute under the terms of either the GNU General Public
License or the Artistic License, as specified in the Perl README file.

=head1 WARRANTY

This is free software. IT COMES WITHOUT WARRANTY OF ANY KIND.

=head1 AUTHORS

Brad Fitzpatrick <brad@danga.com>

Brad Whitaker <whitaker@danga.com>

Mark Smith <marksmith@danga.com>


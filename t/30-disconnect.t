#!/usr/bin/perl -w

use strict;
use Test::More;
use MogileFS::Client;

my $obj = bless({
    backend => bless({
    }, 'MogileFS::Backend')
}, 'MogileFS::Client');

isa_ok($obj, 'MogileFS::Client');

$obj->{backend}->{sock_cache} = 'x';
is($obj->{backend}->{sock_cache}, 'x');

$obj->force_disconnect();
is($obj->{backend}->{sock_cache}, undef);

done_testing();

#!/usr/bin/perl -w

use strict;
use Test::More;
use MogileFS::Client;

my $obj = fields::new('MogileFS::Client');
$obj->{backend} = fields::new('MogileFS::Backend');

isa_ok($obj, 'MogileFS::Client');

$obj->{backend}->{sock_cache} = 'x';
is($obj->{backend}->{sock_cache}, 'x');

$obj->force_disconnect();
is($obj->{backend}->{sock_cache}, undef);

done_testing();

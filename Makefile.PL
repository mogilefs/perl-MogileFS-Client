#!/usr/bin/perl
#
#   Perl Makefile for MogileFS-Client
#   $Id$
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                    => 'MogileFS::Client',
    VERSION_FROM            => 'lib/MogileFS/Client.pm',
    AUTHOR                  => 'Brad Fitzpatrick <brad@danga.com>',
    ABSTRACT                => 'MogileFS client library',
    PREREQ_PM               => {
        'Time::HiRes'     => 0,
        'IO::WrapTie'     => '2.102',
        'LWP::Simple'     => 0,
        fields            => 0,
        'Test::More'      => 0,
        'List::Util'      => 0,
    },
    META_MERGE              => {
        'meta-spec' => { version => 2 },
        resources => {
            repository => {
                type => 'git',
                url  => 'https://github.com/mogilefs/perl-MogileFS-Client.git',
                web  => 'https://github.com/mogilefs/perl-MogileFS-Client',
            },
        },
    },
);


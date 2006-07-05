package TestApache::basic;

use strict;
use warnings;

use Apache::Test qw(-withtestmore);

use Apache::Constants qw(OK);
use Apache::SizeLimit;
use Config;

use constant ONE_MB => 1024;
use constant TEN_MB => 1024 * 10;

sub handler {
    my $r = shift;

    plan $r, tests => 12;

    ok( ! Apache::SizeLimit->_limits_are_exceeded(),
        'check that _limits_are_exceeded() returns false without any limits set' );

    {
        my ( $size, $shared ) = Apache::SizeLimit->_check_size();
        cmp_ok( $size, '>', 0, 'proc size is reported > 0' );

    SKIP:
        {
            skip 'I have no idea what getppid() on Win32 might return', 1
                if $Config{'osname'} eq 'MSWin32';

            cmp_ok( Apache::SizeLimit::real_getppid(), '>', 1,
                    'real_getppid() > 1' );
        }
    }

    {
        # We can assume this will use _at least_ 10MB of memory, based on
        # assuming a scalar consumes >= 1K.
        my @big = ('x') x TEN_MB;

        my ( $size, $shared ) = Apache::SizeLimit->_check_size();
        cmp_ok( $size, '>', TEN_MB, 'proc size is reported > ' . TEN_MB );

        Apache::SizeLimit->set_max_process_size(ONE_MB);

        ok( Apache::SizeLimit->_limits_are_exceeded(),
            'check that _limits_are_exceeded() returns true based on max process size' );

    SKIP:
        {
            skip 'We cannot get shared memory on this platform.', 3
                unless $shared > 0;

            cmp_ok( $size, '>', $shared, 'proc size is greater than shared size' );

            Apache::SizeLimit->set_max_process_size(0);
            Apache::SizeLimit->set_min_shared_size( ONE_MB * 100 );

            ok( Apache::SizeLimit->_limits_are_exceeded(),
                'check that _limits_are_exceeded() returns true based on min share size' );

            Apache::SizeLimit->set_min_shared_size(0);
            Apache::SizeLimit->set_max_unshared_size(1);

            ok( Apache::SizeLimit->_limits_are_exceeded(),
                'check that _limits_are_exceeded() returns true based on max unshared size' );
        }
    }

    {
        # Lame test - A way to check that setting this _does_
        # something would be welcome ;)
        Apache::SizeLimit->set_check_interval(10);
        is( $Apache::SizeLimit::CHECK_EVERY_N_REQUESTS, 10,
            'set_check_interval set global' );
    }

    {
        Apache::SizeLimit->set_max_process_size(0);
        Apache::SizeLimit->set_min_shared_size(0);
        Apache::SizeLimit->set_max_unshared_size(0);

        my $handlers = $r->get_handlers('PerlCleanupHandler');
        is( scalar @$handlers, 0,
            'there is no PerlCleanupHandler before add_cleanup_handler()' );

        Apache::SizeLimit->add_cleanup_handler($r);

        $handlers = $r->get_handlers('PerlCleanupHandler');
        is( scalar @$handlers, 1,
            'there is one PerlCleanupHandler after add_cleanup_handler()' );

        Apache::SizeLimit->add_cleanup_handler($r);

        $handlers = $r->get_handlers('PerlCleanupHandler');
        is( scalar @$handlers, 1,
            'there is stil one PerlCleanupHandler after add_cleanup_handler() a second time' );
    }

    return OK;
}


1;

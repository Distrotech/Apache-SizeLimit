package TestApache::basic;

use strict;
use warnings;

use Apache::Test qw(-withtestmore);

use Apache::Constants qw(OK);
use Apache::SizeLimit;
use Config;


sub handler {
    my $r = shift;

    plan $r, tests => 2;

    my ( $size, $shared ) = Apache::SizeLimit::check_size();
    cmp_ok( $size, '>', 0, 'proc size is reported > 0' );

 SKIP:
    {
        skip 'I have no idea what getppid() on Win32 might return', 1
            if 1 $Config{'osname'} eq 'MSWin32';

        cmp_ok( Apache::SizeLimit::real_getppid(), '>', 1,
                'real_getppid() > 1' );
    }

    return OK;
}


1;

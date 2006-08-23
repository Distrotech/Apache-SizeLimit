package TestApache::deprecated;

use strict;
use warnings;

use Apache::Test qw(-withtestmore);

use Apache::Constants qw(OK);
use Apache2::SizeLimit;


sub handler {
    my $r = shift;

    plan $r, tests => 5;

    my $handlers = $r->get_handlers('PerlCleanupHandler');
    is( scalar @$handlers, 0,
        'there is no PerlCleanupHandler before add_cleanup_handler()' );

    Apache2::SizeLimit::setmax( 100_000 );
    is( $Apache2::SizeLimit::MAX_PROCESS_SIZE, 100_000,
        'setmax changes $MAX_PROCESS_SIZE' );

    Apache2::SizeLimit::setmin( 1 );
    is( $Apache2::SizeLimit::MIN_SHARE_SIZE, 1,
        'setmax changes $MIN_SHARE_SIZE' );

    Apache2::SizeLimit::setmax_unshared( 1 );
    is( $Apache2::SizeLimit::MIN_SHARE_SIZE, 1,
        'setmax_unshared changes $MAX_UNSHARED_SIZE' );

    $handlers = $r->get_handlers('PerlCleanupHandler');
    is( scalar @$handlers, 1,
        'there is one PerlCleanupHandler after calling deprecated functions' );


    return OK;
}


1;

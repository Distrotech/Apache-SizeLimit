package TestApache::basic;

use strict;
use warnings;

use Test::More;

use Apache::Constants qw(OK);
use Apache::SizeLimit;


sub handler {
    my $r = shift;

    Test::Builder->new->output(*STDOUT);
    Test::Builder->new->failure_output(*STDOUT);

    $r->content_type('text/plain');
    $r->send_http_header();

    plan tests => 3;

    Apache::SizeLimit::setmax( 100_000 );
    Apache::SizeLimit::setmin( 1 );

    ok( $r->pnotes('size_limit_cleanup'),  'Set size_limit_cleanup in pnotes' );

    my ( $size, $shared ) = Apache::SizeLimit::check_size();
    cmp_ok( $size, '>', 0, 'proc size is reported > 0' );

    cmp_ok( Apache::SizeLimit::real_getppid(), '>', 1,
            'real_getppid() > 1' );

    return OK;
}

my $count = 1;
sub _test {
    my $ok = shift;
    my $desc = shift;
    my $r = shift;

    my $string = $ok ? 'ok' : 'not ok';
    $r->print( "$string $count - $desc\n" );

    $count++;
}


1;

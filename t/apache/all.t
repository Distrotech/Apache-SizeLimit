use strict;
use warnings FATAL => 'all';

use Config;
use Apache::Test;

# skip all tests in this directory unless mod_perl is enabled
plan tests => 1, \&my_need;

ok 1;

sub my_need {

    my $ok = 1;

    if ( $Config{'osname'} eq 'linux' ) {
        $ok = need_module('Linux::Pid');
        if ( -e '/proc/self/smaps' ) {
            $ok &= need_module('Linux::Smaps');
        }
    }
    elsif ( $Config{'osname'} =~ /(bsd|aix|darwin)/i ) {
        $ok &= need_module('BSD::Resource');
    }
    elsif ( $Config{'osname'} eq 'MSWin32' ) {
        $ok &= need_module('Win32::API');
    }

    $ok &= need_module('mod_perl.c');

    $ok &= need_min_apache_version(1);

    $ok &= need_min_module_version('Test::Builder' => '0.18_01');

    return $ok;
}

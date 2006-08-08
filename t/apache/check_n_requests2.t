use strict;
use warnings FATAL => 'all';

use Apache::Test;
use Apache::TestUtil qw(t_start_error_log_watch t_finish_error_log_watch);
use Apache::TestRequest;

my $module = 'TestApache::check_n_requests2';
my $url    = Apache::TestRequest::module2url($module);

plan tests => 1, need_min_module_version('Apache::Test' => 1.29);

t_start_error_log_watch();
my $res = GET $url;
my $c = grep { /Apache::SizeLimit httpd process too big/ } t_finish_error_log_watch();
ok $c == 0;

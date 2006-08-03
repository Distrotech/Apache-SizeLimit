use strict;
use warnings FATAL => 'all';

use Apache::Test;
use Apache::TestUtil;
use Apache::TestRequest;

my $module = 'TestApache::check_n_requests2';
my $url    = Apache::TestRequest::module2url($module);

print GET_BODY_ASSERT $url;

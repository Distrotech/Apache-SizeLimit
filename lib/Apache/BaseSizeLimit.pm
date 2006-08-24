# Copyright 2001-2006 The Apache Software Foundation or its licensors, as
# applicable.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

package Apache::BaseSizeLimit;

use strict;

use Config;

use vars qw(
    $VERSION
    $REQUEST_COUNT
    $USE_SMAPS
);

$VERSION = '0.91-dev';

$REQUEST_COUNT          = 1;

use constant IS_WIN32 => $Config{'osname'} eq 'MSWin32' ? 1 : 0;

use vars qw($MAX_PROCESS_SIZE);
sub set_max_process_size {
    my $class = shift;

    $MAX_PROCESS_SIZE = shift;
}

use vars qw($MAX_UNSHARED_SIZE);
sub set_max_unshared_size {
    my $class = shift;

    $MAX_UNSHARED_SIZE = shift;
}

use vars qw($MIN_SHARE_SIZE);
sub set_min_shared_size {
    my $class = shift;

    $MIN_SHARE_SIZE = shift;
}

use vars qw($CHECK_EVERY_N_REQUESTS);
sub set_check_interval {
    my $class = shift;

    $CHECK_EVERY_N_REQUESTS = shift;
}

sub get_check_interval { return $CHECK_EVERY_N_REQUESTS; }


use vars qw($START_TIME);
sub set_start_time { $START_TIME ||= time(); }

sub get_start_time { return $START_TIME; }

sub get_and_pinc_request_count { return $REQUEST_COUNT++; }

sub get_request_count { return $REQUEST_COUNT++; }

# REVIEW - Why doesn't this use $r->warn or some other
# Apache/Apache::Log API?
sub _error_log {
    my $class = shift;

    print STDERR "[", scalar( localtime(time) ),
        "] ($$) Apache::SizeLimit @_\n";
}

sub _limits_are_exceeded {
    my $class = shift;

    my ($size, $share, $unshared) = $class->_check_size();

    return 1 if $MAX_PROCESS_SIZE  && $size > $MAX_PROCESS_SIZE;

    return 0 unless $share;

    return 1 if $MIN_SHARE_SIZE    && $share < $MIN_SHARE_SIZE;

    return 1 if $MAX_UNSHARED_SIZE && $unshared > $MAX_UNSHARED_SIZE;

    return 0;
}

sub _check_size {
    my ($size, $share) = _platform_check_size();

    return ($size, $share, $size - $share);
}

sub _load {
    my $mod = shift;

    eval "require $mod"
        or die 
            "You must install $mod for Apache::SizeLimit to work on your" .
            " platform.";
}

BEGIN {
    if ($Config{'osname'} eq 'solaris' && $Config{'osvers'} >= 2.6 ) {
        *_platform_check_size   = \&_solaris_2_6_size_check;
        *_platform_getppid = \&_perl_getppid;
    }
    elsif ($Config{'osname'} eq 'linux') {
        _load('Linux::Pid');

        *_platform_getppid = \&_linux_getppid;

        if (eval { require Linux::Smaps } && Linux::Smaps->new($$)) {
            $USE_SMAPS = 1;
            *_platform_check_size = \&_linux_smaps_size_check;
        }
        else {
            $USE_SMAPS = 0;
            *_platform_check_size = \&_linux_size_check;
        }
    }
    elsif ($Config{'osname'} =~ /(?:bsd|aix)/i) {
        # on OSX, getrusage() is returning 0 for proc & shared size.
        _load('BSD::Resource');

        *_platform_check_size   = \&_bsd_size_check;
        *_platform_getppid = \&_perl_getppid;
    }
    elsif (IS_WIN32) {
        _load('Win32::API');

        *_platform_check_size   = \&_win32_size_check;
        *_platform_getppid = \&_perl_getppid;
    }
    else {
        die "Apache::SizeLimit is not implemented on your platform.";
    }
}

sub _linux_smaps_size_check {
    my $class = shift;

    return $class->_linux_size_check() unless $USE_SMAPS;

    my $s = Linux::Smaps->new($$)->all;
    return ($s->size, $s->shared_clean + $s->shared_dirty);
}

sub _linux_size_check {
    my $class = shift;

    my ($size, $share) = (0, 0);

    if (open my $fh, '<', '/proc/self/statm') {
        ($size, $share) = (split /\s/, scalar <$fh>)[0,2];
        close $fh;
    }
    else {
        $class->_error_log("Fatal Error: couldn't access /proc/self/status");
    }

    # linux on intel x86 has 4KB page size...
    return ($size * 4, $share * 4);
}

sub _solaris_2_6_size_check {
    my $class = shift;

    my $size = -s "/proc/self/as"
        or $class->_error_log("Fatal Error: /proc/self/as doesn't exist or is empty");
    $size = int($size / 1024);

    # return 0 for share, to avoid undef warnings
    return ($size, 0);
}

# rss is in KB but ixrss is in BYTES.
# This is true on at least FreeBSD, OpenBSD, & NetBSD
sub _bsd_size_check {

    my @results = BSD::Resource::getrusage();
    my $max_rss   = $results[2];
    my $max_ixrss = int ( $results[3] / 1024 );

    return ($max_rss, $max_ixrss);
}

sub _win32_size_check {
    my $class = shift;

    # get handle on current process
    my $get_current_process = Win32::API->new(
        'kernel32',
        'get_current_process',
        [],
        'I'
    );
    my $proc = $get_current_process->Call();

    # memory usage is bundled up in ProcessMemoryCounters structure
    # populated by GetProcessMemoryInfo() win32 call
    my $DWORD  = 'B32';    # 32 bits
    my $SIZE_T = 'I';      # unsigned integer

    # build a buffer structure to populate
    my $pmem_struct = "$DWORD" x 2 . "$SIZE_T" x 8;
    my $mem_counters
        = pack( $pmem_struct, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );

    # GetProcessMemoryInfo is in "psapi.dll"
    my $get_process_memory_info = new Win32::API(
        'psapi',
        'GetProcessMemoryInfo',
        [ 'I', 'P', 'I' ],
        'I'
    );

    my $bool = $get_process_memory_info->Call(
        $proc,
        $mem_counters,
        length $mem_counters,
    );

    # unpack ProcessMemoryCounters structure
    my $peak_working_set_size =
        (unpack($pmem_struct, $mem_counters))[2];

    # only care about peak working set size
    my $size = int($peak_working_set_size / 1024);

    return ($size, 0);
}

sub _perl_getppid { return getppid }
sub _linux_getppid { return Linux::Pid::getppid() }

{
    # Deprecated APIs

    sub setmax {

        my $class = __PACKAGE__;

        $class->set_max_process_size(shift);

        $class->add_cleanup_handler();
    }

    sub setmin {

        my $class = __PACKAGE__;

        $class->set_min_shared_size(shift);

        $class->add_cleanup_handler();
    }

    sub setmax_unshared {

        my $class = __PACKAGE__;

        $class->set_max_unshared_size(shift);

        $class->add_cleanup_handler();
    }
}

1;

__END__

=head1 NAME

Apache::BaseLimit - Because size does matter.

=head1 SYNOPSIS

             DO NOT USE ME DIRECTLY

    See Apache::SizeLimit  for mod_perl 1.x

    See Apache2::SizeLimit for mod_perl 2.x

=cut
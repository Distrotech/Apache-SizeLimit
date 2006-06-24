package Apache::SizeLimit;

use Apache::Constants qw(DECLINED OK);
use Config;
use strict;
use vars qw(
    $VERSION
    $MAX_PROCESS_SIZE
    $REQUEST_COUNT
    $CHECK_EVERY_N_REQUESTS
    $MIN_SHARE_SIZE
    $MAX_UNSHARED_SIZE
    $START_TIME
    $IS_WIN32
    $USE_SMAPS
);

$VERSION                = '0.06';
$CHECK_EVERY_N_REQUESTS = 1;
$REQUEST_COUNT          = 1;
$MAX_PROCESS_SIZE       = 0;
$MIN_SHARE_SIZE         = 0;
$MAX_UNSHARED_SIZE      = 0;
$IS_WIN32               = 0;
$USE_SMAPS              = 1;

BEGIN {

    # decide at compile time how to check for a process' memory size.
    if (   $Config{'osname'} eq 'solaris'
        && $Config{'osvers'} >= 2.6 ) {
        *check_size   = \&_solaris_2_6_size_check;
        *real_getppid = \&_perl_getppid;
    }
    elsif ( $Config{'osname'} eq 'linux' ) {
        eval { require Linux::Pid }
            or die "You must install Linux::Pid for Apache::SizeLimit to work on your platform.";

        *real_getppid = \&_linux_getppid;

        if ( eval { require Linux::Smaps } && Linux::Smaps->new($$) ) {
            *check_size = \&_linux_smaps_size_check;
        }
        else {
            $USE_SMAPS = 0;
            *check_size = \&_linux_size_check;
        }
    }
    elsif ( $Config{'osname'} =~ /(?:bsd|aix|darwin)/i ) {

        # will getrusage work on all BSDs?  I should hope so.
        eval "require BSD::Resource;"
            or die
            "You must install BSD::Resource for Apache::SizeLimit to work on your platform.";

        *check_size   = \&_bsd_size_check;
        *real_getppid = \&_perl_getppid;
    }
    elsif ( $Config{'osname'} eq 'MSWin32' ) {
        eval { require Win32::API }
            or die
            "You must install Win32::API for Apache::SizeLimit to work on your platform.";

        $IS_WIN32 = 1;

        *check_size   = \&_win32_size_check;
        *real_getppid = \&_perl_getppid;
    }
    else {
        die "Apache::SizeLimit is not implemented on your platform.";
    }
}

sub _linux_smaps_size_check {
    goto &linux_size_check unless $USE_SMAPS;

    my $s = Linux::Smaps->new($$)->all;
    return ($s->size, $s->shared_clean + $s->shared_dirty);
}

sub _linux_size_check {
    my ( $size, $resident, $share ) = ( 0, 0, 0 );

    if ( open my $fh, '<', '/proc/self/statm' ) {
        ( $size, $resident, $share ) = split /\s/, scalar <$fh>;
        close $fh;
    }
    else {
        _error_log("Fatal Error: couldn't access /proc/self/status");
    }

    # linux on intel x86 has 4KB page size...
    return ( $size * 4, $share * 4 );
}

sub _solaris_2_6_size_check {
    my $size = -s "/proc/self/as"
        or _error_log("Fatal Error: /proc/self/as doesn't exist or is empty");
    $size = int( $size / 1024 );

    # return 0 for share, to avoid undef warnings
    return ( $size, 0 );
}

sub _bsd_size_check {
    return ( BSD::Resource::getrusage() )[ 2, 3 ];
}

sub _win32_size_check {
    # get handle on current process
    my $GetCurrentProcess = Win32::API->new(
        'kernel32',
        'GetCurrentProcess',
        [],
        'I'
    );
    my $hProcess = $GetCurrentProcess->Call();

    # memory usage is bundled up in ProcessMemoryCounters structure
    # populated by GetProcessMemoryInfo() win32 call
    my $DWORD  = 'B32';    # 32 bits
    my $SIZE_T = 'I';      # unsigned integer

    # build a buffer structure to populate
    my $pmem_struct = "$DWORD" x 2 . "$SIZE_T" x 8;
    my $pProcessMemoryCounters
        = pack( $pmem_struct, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 );

    # GetProcessMemoryInfo is in "psapi.dll"
    my $GetProcessMemoryInfo = new Win32::API(
        'psapi',
        'GetProcessMemoryInfo',
        [ 'I', 'P', 'I' ],
        'I'
    );

    my $bool = $GetProcessMemoryInfo->Call(
        $hProcess,
        $pProcessMemoryCounters,
        length($pProcessMemoryCounters)
    );

    # unpack ProcessMemoryCounters structure
    my (
        $cb,
        $PageFaultCount,
        $PeakWorkingSetSize,
        $WorkingSetSize,
        $QuotaPeakPagedPoolUsage,
        $QuotaPagedPoolUsage,
        $QuotaPeakNonPagedPoolUsage,
        $QuotaNonPagedPoolUsage,
        $PagefileUsage,
        $PeakPagefileUsage
    ) = unpack( $pmem_struct, $pProcessMemoryCounters );

    # only care about peak working set size
    my $size = int( $PeakWorkingSetSize / 1024 );

    return ( $size, 0 );
}

sub _perl_getppid { return getppid }
sub _linux_getppid { return Linux::Pid::getppid() }

sub _exit_if_too_big {
    my $r = shift;

    return DECLINED
        if ( $CHECK_EVERY_N_REQUESTS
        && ( $REQUEST_COUNT++ % $CHECK_EVERY_N_REQUESTS ) );

    $START_TIME ||= time;

    my ( $size, $share ) = check_size();
    my $unshared = $size - $share;

    if (   ( $MAX_PROCESS_SIZE  && $size > $MAX_PROCESS_SIZE )
        || ( $MIN_SHARE_SIZE    && $share < $MIN_SHARE_SIZE )
        || ( $MAX_UNSHARED_SIZE && $unshared > $MAX_UNSHARED_SIZE ) ) {
        # wake up! time to die.
        if ( $IS_WIN32 || real_getppid() > 1 ) {
            # this is a child httpd
            my $e   = time - $START_TIME;
            my $msg = "httpd process too big, exiting at SIZE=$size KB";
            $msg .= " SHARE=$share KB UNSHARED=$unshared" if ($share);
            $msg .= " REQUESTS=$REQUEST_COUNT  LIFETIME=$e seconds";
            _error_log($msg);

            if ($IS_WIN32) {
                # child_terminate() is disabled in win32 Apache
                CORE::exit(-2);
            }
            else {
                $r->child_terminate();
            }
        }
        else {
            # this is the main httpd, whose parent is init?
            my $msg = "main process too big, SIZE=$size KB ";
            $msg .= " SHARE=$share KB" if ($share);
            _error_log($msg);
        }
    }
    return OK;
}

# setmax can be called from within a CGI/Registry script to tell the httpd
# to exit if the CGI causes the process to grow too big.
sub setmax {
    $MAX_PROCESS_SIZE = shift;

    _set_post_conn();
}

sub setmin {
    $MIN_SHARE_SIZE = shift;

    _set_post_conn();
}

sub setmax_unshared {
    $MAX_UNSHARED_SIZE = shift;

    _set_post_conn();
}

sub _set_post_conn {
    my $r = Apache->request
        or return;

    return if $Apache::Server::Starting || $Apache::Server::ReStarting;
    return if $r->pnotes('size_limit_cleanup');

    $r->post_connection( \&_exit_if_too_big );
    $r->pnotes( size_limit_cleanup => 1 );
}

sub handler {
    my $r = shift || Apache->request;

    return DECLINED unless $r->is_main();

    # we want to operate in a cleanup handler
    if ( $r->current_callback eq 'PerlCleanupHandler' ) {
        return _exit_if_too_big($r);
    }
    else {
        $r->post_connection( \&_exit_if_too_big );
    }

    return DECLINED;
}

sub _error_log {
    print STDERR "[", scalar( localtime(time) ),
        "] ($$) Apache::SizeLimit @_\n";
}

1;


__END__

=head1 NAME

Apache::SizeLimit - Because size does matter.

=head1 SYNOPSIS

    <Perl>
     $Apache::SizeLimit::MAX_UNSHARED_SIZE = 120000; # 120MB
    </Perl>

    PerlCleanupHandler Apache::SizeLimit

=head1 DESCRIPTION

This module allows you to kill off Apache httpd processes if they grow
too large. You can make the decision to kill a process based on its
overall size, by setting a minimum limit on shared memory, or a
maximum on unshared memory.

You can set limits for each of these sizes, and if any limit is not
met, the process will be killed.

You can also limit the frequency that these sizes are checked so that
this module only checks every N requests.

This module is highly platform dependent, please read the CAVEATS
section.

=head1 API

You can set set the size limits from a Perl module or script loaded by
Apache:

    use Apache::SizeLimit;

    Apache::SizeLimit::setmax(150_000);           # Max size in KB
    Apache::SizeLimit::setmin(10_000);            # Min share in KB
    Apache::SizeLimit::setmax_unshared(120_000);  # Max unshared size in KB

Then in your Apache configuration, make Apache::SizeLimit a
C<PerlCleanupHandler>:

    PerlCleanupHandler Apache::SizeLimit

If you want to use C<Apache::SizeLimit> from a registry script, you
must call one of the above functions for every request:

    use Apache::SizeLimit

    main();

    sub {
        Apache::SizeLimit::setmax(150_000);

        # handle request
    };

Calling any one of C<setmax()>, C<setmin()>, or C<setmax_unshared()>
will install C<Apache::SizeLimit> as a cleanup handler, if it's not
already installed.

If you want to combine this module with a cleanup handler of your own,
make sure that C<Apache::SizeLimit> is the last handler run:

    PerlCleanupHandler  Apache::SizeLimit My::CleanupHandler

Remember, mod_perl will run stacked handlers from right to left, as
they're defined in your configuration.

You can explicitly call the C<Apache::SizeLimit::handler()> function
from your own handler:

    package My::CleanupHandler

    sub handler {
        my $r = shift;

        # do my thing

        return Apache::SizeLimit::handler($r);
    }

Since checking the process size can take a few system calls on some
platforms (e.g. linux), you may want to only check the process size
every N times. To do so, simple set the
C<$Apache::SizeLimit::CHECK_EVERY_N_REQUESTS> global.

    $Apache::SizeLimit::CHECK_EVERY_N_REQUESTS = 2;

Now C<Apache::SizeLimit> will only check the process size on every
other request.

=head2 Deprecated API

Previous versions of this module documented three globals for defining
memory size limits:

=over 4

=item * $Apache::SizeLimit::MAX_PROCESS_SIZE

=item * $Apache::SizeLimit::MIN_SHARE_SIZE

=item * $Apache::SizeLimit::MAX_UNSHARED_SIZE

=back

Direct use of these globals is deprecated, but will continue to work
for the foreseeable future.

=head1 ABOUT THIS MODULE

This module was written in response to questions on the mod_perl
mailing list on how to tell the httpd process to exit if it gets too
big.

Actually, there are two big reasons your httpd children will grow.
First, your code could have a bug that causes the process to increase
in size very quickly. Second, you could just be doing operations that
require a lot of memory for each request. Since Perl does not give
memory back to the system after using it, the process size can grow
quite large.

This module will not really help you with the first problem. For that
you should probably look into C<Apache::Resource> or some other means
of setting a limit on the data size of your program.  BSD-ish systems
have C<setrlimit()>, which will kill your memory gobbling processes.
However, it is a little violent, terminating your process in
mid-request.

This module attempts to solve the second situation, where your process
slowly grows over time. It checks memory usage after every request,
and if it exceeds a threshold, exits gracefully.

By using this module, you should be able to discontinue using the
Apache configuration directive B<MaxRequestsPerChild>, although for
some folks, using both in combination does the job.

=head1 SHARED MEMORY OPTIONS

In addition to simply checking the total size of a process, this
module can factor in how much of the memory used by the process is
actually being shared by copy-on-write. If you don't understand how
memory is shared in this way, take a look at the mod_perl Guide at
http://perl.apache.org/guide/.

You can take advantage of the shared memory information by setting a
minimum shared size and/or a maximum unshared size. Experience on one
heavily trafficked mod_perl site showed that setting maximum unshared
size and leaving the others unset is the most effective policy. This
is because it only kills off processes that are truly using too much
physical RAM, allowing most processes to live longer and reducing the
process churn rate.

=head1 CAVEATS

This module is highly platform dependent, since finding the size of a
process is different for each OS, and some platforms may not be
supported. In particular, the limits on minimum shared memory and
maximum shared memory are currently only supported on Linux and BSD.
If you can contribute support for another OS, patches are very
welcome.

Currently supported OSes:

=over 4

=item linux

For linux we read the process size out of F</proc/self/statm>.  This
is a little slow, but usually not too bad. If you are worried about
performance, try only setting up the the exit handler inside CGIs
(with the C<setmax()> function), and see if the CHECK_EVERY_N_REQUESTS
option is of benefit.

Since linux 2.6 F</proc/self/statm> does not report the amount of
memory shared by the copy-on-write mechanism as shared memory. Hence
decisions made on the basis of C<MAX_UNSHARED_SIZE> or
C<MIN_SHARE_SIZE> are inherently wrong.

To correct this situation, as of the 2.6.14 release of the kernel,
there is F</proc/self/smaps> entry for each
process. F</proc/self/smaps> reports various sizes for each memory
segment of a process and allows us to count the amount of shared
memory correctly.

If C<Apache::SizeLimit> detects a kernel that supports
F</proc/self/smaps> and if the C<Linux::Smaps> module is installed it
will use them instead of F</proc/self/statm>. You can prevent
C<Apache::SizeLimit> from using F</proc/self/smaps> and turn on the
old behaviour by setting C<$Apache::SizeLimit::USE_SMAPS> to 0.

C<Apache::SizeLimit> itself will C<$Apache::SizeLimit::USE_SMAPS> to 0
if it cannot load C<Linux::Smaps> or if your kernel does not support
F</proc/self/smaps>. Thus, you can check it to determine what is
actually used.

NOTE: Reading F</proc/self/smaps> is expensive compared to
F</proc/self/statm>. It must look at each page table entry of a process.
Further, on multiprocessor systems the access is synchronized with
spinlocks. Hence, you are encouraged to set the C<CHECK_EVERY_N_REQUESTS>
option.

The following example shows the effect of copy-on-write:

  <Perl>
    require Apache::SizeLimit;
    package X;
    use strict;
    use Apache::Constants qw(OK);

    my $x= "a" x (1024*1024);

    sub handler {
      my $r = shift;
      my ($size, $shared) = $Apache::SizeLimit::check_size();
      $x =~ tr/a/b/;
      my ($size2, $shared2) = $Apache::SizeLimit::check_size();
      $r->content_type('text/plain');
      $r->print("1: size=$size shared=$shared\n");
      $r->print("2: size=$size2 shared=$shared2\n");
      return OK;
    }
  </Perl>

  <Location /X>
    SetHandler modperl
    PerlResponseHandler X
  </Location>

The parent apache allocates a megabyte for the string in C<$x>. The
C<tr>-command then overwrites all "a" with "b" if the handler is
called with an argument. This write is done in place, thus, the
process size doesn't change. Only C<$x> is not shared anymore by
means of copy-on-write between the parent and the child.

If F</proc/self/smaps> is available curl shows:

  r2@s93:~/work/mp2> curl http://localhost:8181/X
  1: size=13452 shared=7456
  2: size=13452 shared=6432

Shared memory has lost 1024 kB. The process' overall size remains unchanged.

Without F</proc/self/smaps> it says:

  r2@s93:~/work/mp2> curl http://localhost:8181/X
  1: size=13052 shared=3628
  2: size=13052 shared=3636

One can see the kernel lies about the shared memory. It simply doesn't
count copy-on-write pages as shared.

=item solaris 2.6 and above

For solaris we simply retrieve the size of F</proc/self/as>, which
contains the address-space image of the process, and convert to KB.
Shared memory calculations are not supported.

NOTE: This is only known to work for solaris 2.6 and above. Evidently
the F</proc> filesystem has changed between 2.5.1 and 2.6. Can anyone
confirm or deny?

=item *bsd*

Uses C<BSD::Resource::getrusage()> to determine process size.  This is
pretty efficient (a lot more efficient than reading it from the
F</proc> fs anyway).

=item AIX?

Uses C<BSD::Resource::getrusage()> to determine process size.  Not
sure if the shared memory calculations will work or not.  AIX users?

=item Win32

Uses C<Win32::API> to access process memory information.
C<Win32::API> can be installed under ActiveState perl using the
supplied ppm utility.

=back

If your platform is not supported, then please send a patch to check
the process size. The more portable/efficient/correct the solution the
better, of course.

=head1 AUTHOR

Doug Bagley <doug+modperl@bagley.org>, channeling Procrustes.

Brian Moseley <ix@maz.org>: Solaris 2.6 support

Doug Steinwand and Perrin Harkins <perrin@elem.com>: added support 
    for shared memory and additional diagnostic info

Matt Phillips <mphillips@virage.com> and Mohamed Hendawi
<mhendawi@virage.com>: Win32 support

Dave Rolsky <autarch@urth.org>, maintenance and fixes outside of
mod_perl tree (0.06).

=cut


use strict;

use Config;
use ExtUtils::MakeMaker;

my %prereqs = ( mod_perl => 0 );

unless ( $ARGV[0] eq '--dist' ) {
    if ( $Config{'osname'} eq 'linux' ) {
        $prereqs{'Linux::Pid'} = 0;
        if ( -e '/proc/self/smaps' ) {
            $prereqs{'Linux::Smaps'} = 0;
        }
    }
    elsif ( $Config{'osname'} =~ /(bsd|aix|darwin)/i ) {
        $prereqs{'BSD::Resource'} = 0;
    }
    elsif ( $Config{'osname'} eq 'MSWin32' ) {
        $prereqs{'Win32::API'} = 0;
    }

    if ( -f 't/apache/basic.t'
         && eval { require Apache::TestMM } ) {
        $prereqs{'Apache::Test'} = 0;

        Apache::TestMM::filter_args();
        Apache::TestMM::generate_script('t/TEST');
    }
}

WriteMakefile( VERSION_FROM    => "lib/Apache/SizeLimit.pm",
               NAME            => "Apache::SizeLimit",
               PREREQ_PM       => \%prereqs,
               ABSTRACT_FROM   => 'lib/Apache/SizeLimit.pm',
               clean           => { FILES => 't/TEST' },
             );

sub MY::postamble {
    my $self = shift;

    my $string = $self->MM::postamble;

    $string .= <<'EOF';
tag :
	svn copy https://svn.apache.org/repos/asf/perl/Apache-SizeLimit/trunk https://svn.apache.org/repos/asf/perl/Apache-SizeLimit/tags/$(VERSION_SYM)
	@echo update lib/Apache/SizeLimit.pm VERSION now
EOF

    return $string;
}

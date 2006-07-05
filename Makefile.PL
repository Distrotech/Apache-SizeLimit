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
}

use constant HAS_APACHE_TEST => check_for_apache_test();

WriteMakefile( VERSION_FROM    => "lib/Apache/SizeLimit.pm",
               NAME            => "Apache::SizeLimit",
               PREREQ_PM       => \%prereqs,
               ABSTRACT_FROM   => 'lib/Apache/SizeLimit.pm',
               clean           => { FILES => 't/TEST' },
             );

sub check_for_apache_test {
    return eval {
        require Apache::Test;
        require Apache::TestMM;
        require Apache::TestRunPerl;

        Apache::TestMM->import(qw(test clean));
        Apache::TestMM::filter_args();

        my %args = @Apache::TestMM::Argv;

        die 'suitable httpd required'
          unless ($args{apxs} or $args{httpd} or
                  $ENV{APACHE_TEST_HTTPD} or $ENV{APACHE_TEST_APXS});

        Apache::TestRunPerl->generate_script();

        return Apache::TestMM->test;
    };
}

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

sub MY::test {

    my $test = shift->MM::test(@_);

  eval { require Test::More } or return <<EOF;
test::
\t\@echo sorry, cannot run tests without Test::More
EOF

    return HAS_APACHE_TEST if HAS_APACHE_TEST;

    return $test;
}

sub MY::clean {

    if (HAS_APACHE_TEST) {
        require Apache::TestMM;

        return Apache::TestMM::clean(@_);
    }

    return shift->MM::clean(@_);
}

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
    elsif ( $Config{'osname'} =~ /(bsd|aix)/i ) {
        $prereqs{'BSD::Resource'} = 0;
    }
    elsif ( $Config{'osname'} eq 'MSWin32' ) {
        $prereqs{'Win32::API'} = 0;
    }
}

my $HAS_APACHE_TEST = check_for_apache_test();

WriteMakefile( VERSION_FROM    => "lib/Apache/SizeLimit.pm",
               NAME            => "Apache::SizeLimit",
               PREREQ_PM       => \%prereqs,
               ABSTRACT_FROM   => 'lib/Apache/SizeLimit.pm',
               clean           => { FILES => 't/TEST' },
             );

sub check_for_apache_test {
    return unless eval {
        require Apache::Test;
        require Apache::TestMM;
        require Apache::TestRunPerl;
        1;
    };

    Apache::TestMM::filter_args();

    my %args = @Apache::TestMM::Argv;

    return 0
        unless (( Apache::TestConfig->can('custom_config_path')
                  and -f Apache::TestConfig->custom_config_path())
                or $args{apxs} or $args{httpd}
                or $ENV{APACHE_TEST_HTTPD} or $ENV{APACHE_TEST_APXS});


    Apache::TestRunPerl->generate_script();

    return 1;
}

package MY;

sub postamble {
    my $self = shift;

    my $string = $self->SUPER::postamble;

    $string .= <<'EOF';
tag :
	svn copy https://svn.apache.org/repos/asf/perl/Apache-SizeLimit/trunk https://svn.apache.org/repos/asf/perl/Apache-SizeLimit/tags/$(VERSION_SYM)
	@echo update lib/Apache/SizeLimit.pm VERSION now
EOF

    return $string;
}

sub test {
    my $self = shift;

    eval { require Test::More } or return <<EOF;
test::
\t\@echo sorry, cannot run tests without Test::More
EOF

    return $self->Apache::TestMM::test(@_) if $HAS_APACHE_TEST;

    return $self->SUPER::test(@_);
}

sub clean {
    my $self = shift;

    return $self->Apache::TestMM::clean(@_) if $HAS_APACHE_TEST;

    return $self->SUPER::clean(@_);
}

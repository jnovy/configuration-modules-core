# -*- mode: cperl -*-
# ${license-info}
# ${author-info}
# ${build-info}

=pod

=head1 DESCRIPTION

Tests for the C<installed_pkgs> method. This method queries the RPM
database and returns a C<Set::Scalar> with all the installed packages.

=head1 TESTS

These tests will run only if the RPM binary is present.  They consist
on retrieving the

=head2 Basic test

Ensure that an ordinary execution works. Two cases here: the RPM
command succeeds and then returns a set of installed packages, or it
doesn't, and the method should return it as appropriate.

=cut

use strict;
use warnings;
use Readonly;
use Test::More;
use Test::Quattor;
use NCM::Component::spma;
use CAF::Object;
use Readonly;

$CAF::Object::NoAction = 1;

Readonly my $CMD => q(rpm -qa --qf %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n);

plan skip_all => "No RPM database to play with" if ! -x "/bin/rpm";


my $cmp = NCM::Component::spma->new("spma");

set_desired_output($CMD, "");

my $pkgs = $cmp->installed_pkgs();
isa_ok($pkgs, "Set::Scalar", "Received an empty set, with no errors");

set_desired_output($CMD, q{glibc-2.5.16-1.x86_64
kernel-3.0.2-34.x86_64
});

$pkgs = $cmp->installed_pkgs();
is(scalar(@$pkgs), 2, "Set contains two packages");
ok($pkgs->has(q{kernel-3.0.2-34.x86_64}), "Set contains the expected list of packages");


set_command_status($CMD, 1);
$pkgs = $cmp->installed_pkgs();
is($pkgs, undef, "Failures of the RPM command are handled gracefully");

done_testing();

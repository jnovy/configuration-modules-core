# ${license-info}
# ${developer-info}
# ${author-info}

package NCM::Component::spma::dnf;

#
# a few standard statements, mandatory for all components
#
use strict;
use warnings;
use NCM::Component;
our $EC  = LC::Exception::Context->new->will_store_all;
our @ISA = qw(NCM::Component);
use EDG::WP4::CCM::Element qw(unescape);

use CAF::Process;
use CAF::FileWriter;
use Set::Scalar;
use File::Path qw(rmtree);
use Text::Glob qw(match_glob);

use constant REPOS_DIR           => "/etc/yum.repos.d";
use constant REPOS_TREE          => "/software/repositories";
use constant PKGS_TREE           => "/software/packages";
use constant CMP_TREE            => "/software/components/spma";
use constant DNF_PACKAGE_LIST    => "/etc/dnf/plugins/versionlock.list";
use constant DNF_CONF_FILE       => "/etc/dnf/dnf.conf";
use constant RPM_QUERY_INSTALLED => qw(rpm -qa --nosignature --nodigest --qf %{NAME}-%{EPOCH}:%{VERSION}-%{RELEASE}.%{ARCH}\n);
use constant RPM_QUERY_INSTALLED_NAMES => qw(rpm -qa --nosignature --nodigest --qf %{EPOCH}:%{NAME}\n);
use constant RPM_QUERY_INSTALLED_NAMES_NOEPOCH => qw(rpm -qa --nosignature --nodigest --qf %{NAME}\n);
use constant REPO_AVAIL_PKGS     => qw(dnf repoquery --show-duplicates --all --qf %{EPOCH}:%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH});
use constant DNF_PLUGIN_OPTS     => "--disableplugin=\* --enableplugin=fastestmirror --enableplugin=versionlock --enableplugin=priorities";
use constant DNF_TEST_CHROOT     => qw(/tmp/spma_dnf_testroot);
use constant SPMAPROXY           => "/software/components/spma/proxy";

our $NoActionSupported = 1;

=pod

=head2 C<execute_command>

Executes C<$command> for reason C<$why>. Optionally with standard
input C<$stdin>.  The command may be executed even under --noaction if
C<$keeps_state> has a true value.

If the command is executed, this method returns its standard output
upon success or C<undef> in case of error.  If the command is not
executed the method always returns a true value (usually 1, but don't
rely on this!).

The return value is ordered set of (exit code, stdout, stderr) as a
result of the executed command.

=cut

sub execute_command
{
    my ( $self, $command, $why, $keeps_state, $stdin, $nolog ) = @_;

    my ( %opts, $out, $err, @missing );

    %opts = ( log => $self,
        stdout      => \$out,
        stderr      => \$err,
        keeps_state => $keeps_state );

    $opts{stdin} = $stdin if defined($stdin);

    my $cmd = CAF::Process->new( $command, %opts );

    $cmd->info("$why");
    $self->log("[EXEC] ", join(" ", @$command));
    $cmd->execute();
    if ( !defined($nolog) ) {
        $self->log("$why stderr:\n$err") if ( defined($err) && $err ne '' );
        $self->log("$why stdout:\n$out") if ( defined($out) && $out ne '' );
    }

    if ( $NoAction && !$keeps_state ) {
        return ( 0, undef, undef );
    }

    return ( $?, $out, $err );
}

sub get_installed_rpms
{
    my ( $self ) = @_;
    my ( $cmd_exit, $cmd_out, $cmd_err ) = $self->execute_command( [RPM_QUERY_INSTALLED], "getting list of installed packages", 1, "/dev/null", 1 );
    if ( $cmd_exit ) {
        $self->error("Error getting list of installed packages.");
        return undef;
    }
    my $preinstalled_rpms = $cmd_out;
    $preinstalled_rpms =~ s/\(none\)/0/g;
    return Set::Scalar->new( split ( /\n/, $preinstalled_rpms ) );
}

sub Configure
{
    my ( $self, $config ) = @_;

    # Make sure stdout and stderr is flushed every time to not to
    # put mess on serial console
    autoflush STDOUT 1;
    autoflush STDERR 1;

    # We are parsing some outputs in this component. We must set a
    # locale that we can understand.
    local $ENV{LANG}   = 'C';
    local $ENV{LC_ALL} = 'C';

    my $repos = $config->getElement(REPOS_TREE)->getTree();
    my $t     = $config->getElement(CMP_TREE)->getTree();
    
    # Display system info
    if ( defined($t->{quattor_os_release}) ) {
        $self->info("target OS build: ", $t->{quattor_os_release});
    }
    
    # Detect OS
    my $fhi;
    my $os_major;
    if ( open( $fhi, '<', "/etc/redhat-release" ) ) {
        while ( my $line = <$fhi> ) {
            my $i = index($line, 'release ');
            if ( $i >= 0 ) {
                chomp($line);
                $self->info("local OS: ".$line);
                $os_major = substr($line, $i+8, 1);
                last;
            }
        }
        $fhi->close();
    }

    if ( $os_major eq "" ) {
        $self->error("Unable to determine OS release.");
        return 0;
    }

    my ( $cmd_exit, $cmd_out, $cmd_err ) = $self->execute_command( ["rpm -q --qf %{NAME}-%{VERSION}-%{RELEASE}.%{ARCH} ncm-spma"], "checking for spma version", 1);
    if ( $cmd_exit ) {
        $self->warn("Error getting SPMA version.");
    } else {
        $self->info("SPMA version: ", $cmd_out);
    }

    # Convert these crappily-defined fields into real Perl booleans.
    $t->{run}      = $t->{run} eq 'yes';

    # Test if we are supposed to be running spma in package modification mode.
    if ( -e "/.spma-run" ) {
        if ( !unlink "/.spma-run" ) {
            $self->error("Unable to remove file /.spma-run: $!");
        }
        $t->{run} = 1;
    }

    # Generate DNF config file
    my $dnf_conf_file = CAF::FileWriter->new( DNF_CONF_FILE, log => $self );
    my $excludes      = $t->{excludes};
    print $dnf_conf_file $t->{dnfconf};
    print $dnf_conf_file "exclude=" . join ( " ", sort @$excludes );
    $dnf_conf_file->close();

    if (!$NoAction) {
        my @repos = glob "/etc/yum.repos.d/*.repo";
        foreach my $repo (@repos) {
            if ( !unlink $repo ) {
                $self->error("Unable to remove file $repo: $!");
                return 0;
            }
        }
    }

    # Generate new installation repositories from host profile
    my $proxy = !defined($t->{proxy}) ? 'yes' : $t->{proxy};
    foreach my $repo (@$repos) {
        my $fh = CAF::FileWriter->new( REPOS_DIR . "/spma-$repo->{name}.repo", log => $self );
        my $prots = $repo->{protocols}->[0];
        my $url   = $prots->{url};
        my $urls;
        my $repo_proxy = defined($repo->{proxy}) ? 'yes' : 'no';
        my $disable_proxy = defined($repo->{disableproxy}) ? 'yes' : 'no';
        if ( $url =~ /http/ && $proxy eq 'yes' && $disable_proxy eq 'no' ) {
            if ( $config->elementExists(SPMAPROXY) ) {
                my $spma       = $config->getElement(CMP_TREE)->getTree;
                my $proxyhost = $spma->{proxyhost};
                my $proxyport;
                my @proxies    = split /,/, $proxyhost;
                if ( $spma->{proxyport} ) {
                    $proxyport = $spma->{proxyport};
                }
                if ($proxyhost) {
                    if ( $repo_proxy eq 'no' ) {
                        while (@proxies) {
                            my $prx = shift(@proxies);
                            $prx .= ":$proxyport" if $spma->{proxyport};
                            $url =~ s{(https?)://([^/]*)/}{$1://$prx/};
                            $urls .= $url . ' ';
                        }
                    } else {
                        $url .= ":$proxyport" if $spma->{proxyport};
                        $url =~ s,http?://,,;
                        $url =~ s,[^/]*/,,;
                        $url = $repo->{proxy} . $url;
                    }
                }
            }
        }
        if (!defined($urls)) {
            $urls = $url;
        }
        my $repofile = "[$repo->{name}]\nname=$repo->{name}\nbaseurl=$urls\nenabled=$repo->{enabled}\n";
        if ( defined( $repo->{mirrorlist} ) && $repo->{mirrorlist} ) {
            $repofile = "[$repo->{name}]\nname=$repo->{name}\nmirrorlist=$url\nenabled=$repo->{enabled}\n";
        }
        $repofile .= "priority=$repo->{priority}\n" if ( defined($repo->{priority}) );
        $repofile .= "gpgcheck=$repo->{gpgcheck}\n" if ( defined($repo->{gpgcheck}) );
        print $fh "# File generated by ", __PACKAGE__, ". Do not edit\n";
        print $fh $repofile;
        $fh->close();
    }

    # Preprocess required packages and separate version-locked
    #    - also skip package dualities - e.g. kernel and kernel-2.6.32-504.1.3.el6.x86_64
    #      specified on dnf install commandline will skip older version-locked package but
    #      will install the latest what is undesired. Simply keep only version-locked variant.
    my $pkgs               = $config->getElement(PKGS_TREE)->getTree();
    my $wanted_pkgs        = Set::Scalar->new();
    my $wanted_pkgs_locked = Set::Scalar->new();
    my $found_spma         = 0;
    my @pkl;
    my @pkl_v;
    my @pkl_a;

    for my $name ( keys %$pkgs ) {
        if ( !$found_spma && substr( (unescape $name), 0, 8 ) eq 'ncm-spma' ) {
            $found_spma = 1;
        }
        my $vra = $pkgs->{$name};
        while ( my ( $vers, $a ) = each(%$vra) ) {
            my $arches = $a->{arch};
            if ( exists( $a->{repository} ) ) {
                foreach my $arch (@$arches) {
                    if ( $vers ne '_' ) {
                        push ( @pkl_v, (unescape $name) . ';' . (unescape $vers) . '.' . $arch );
                    } else {
                        if ( $arch eq '_' ) {
                            push ( @pkl, (unescape $name) . ';' );
                        } else {
                            push ( @pkl_a, (unescape $name) . ';' . $arch );
                        }
                    }
                }
            } else {
                foreach my $arch ( keys %$arches ) {
                    if ( $vers ne '_' ) {
                        push ( @pkl_v, (unescape $name) . ';' . (unescape $vers) . '.' . $arch );
                    } else {
                        if ( $arch eq '_' ) {
                            push ( @pkl, (unescape $name) . ';' );
                        } else {
                            push ( @pkl_a, (unescape $name) . ';' . $arch );
                        }
                    }
                }
            }
        }
    }

    if ( !$found_spma ) {
        $self->error('Package ncm-spma is not present among required packages.');
        return 0;
    }

    my $wanted_pkgs_uv = Set::Scalar->new(@pkl);          # packages without version/arch specified
    my $wanted_pkgs_v  = Set::Scalar->new(@pkl_v);        # packages with only version specified
    my $wanted_pkgs_a  = Set::Scalar->new(@pkl_a);        # packages with only arch specified
    while ( defined( my $p = $wanted_pkgs_uv->each ) ) {
        while ( defined( my $p2 = $wanted_pkgs_v->each ) ) {
            if ( index( $p2, $p ) == 0 ) {
                my $pkg = $p;
                chop($pkg);
                my $pkg_locked = $p2;
                $pkg_locked =~ tr/;/-/;
                $self->info("preferring version-locked $pkg_locked over unlocked $pkg");
                $wanted_pkgs_uv->delete($p);
            }
        }
    }
    while ( defined( my $p = $wanted_pkgs_uv->each ) ) {
        chop($p);
        $wanted_pkgs->insert($p);
    }
    while ( defined( my $p = $wanted_pkgs_v->each ) ) {
        $p =~ s/;/-/;
        $wanted_pkgs_locked->insert($p);
    }
    while ( defined( my $p = $wanted_pkgs_a->each ) ) {
        $p =~ s/;/./;
        $wanted_pkgs->insert($p);
    }

    # Remove old (also possibly duplicated) GPG keys
    ( $cmd_exit, $cmd_out, $cmd_err ) = $self->execute_command( ["rpm -e --allmatches gpg-pubkey"], "removing old GPG keys" );
    if ( $cmd_exit ) {
        $self->warn("Failed to remove old GPG keys from rpmdb. None installed?");
    }
    # Import GPG keys
    foreach my $file ( glob "/etc/pki/rpm-gpg/*" ) {
        ( $cmd_exit, $cmd_out, $cmd_err ) = $self->execute_command( ["rpm -v --import $file"], "importing GPG key $file" );
        if ( $cmd_exit ) {
            $self->error("Failed to import $file GPG key to rpmdb.");
            return 0;
        }
    }

    # Get list of packages installed on system before any package modifications.
    my $preinstalled = $self->get_installed_rpms();
    return 1 if !defined($preinstalled);

    # Clean up DNF state - worth to be thorough there
    $self->execute_command( ["dnf clean all " . DNF_PLUGIN_OPTS], "resetting DNF state", 0 );

    # Test whether repositories are sane.
    ( $cmd_exit, $cmd_out, $cmd_err ) = $self->execute_command( [ "dnf info glibc " . DNF_PLUGIN_OPTS ], "testing sanity of repositories", 1 );
    if ( $cmd_exit ) {
        $self->error("Repositories are in broken state. Will not continue.");
        return 0;
    }

    # Query metadata for version locked packages including Epoch and write versionlock.list
    ( $cmd_exit, $cmd_out, $cmd_err ) = $self->execute_command( [REPO_AVAIL_PKGS], "fetching full package list", 1, "/dev/null", 1 );
    if ( $cmd_exit ) {
        $self->error("Error fetching full package list.");
        return 0;
    }
    my $repodata_rpms = $cmd_out;

    # Test whether locked packages are present in the metadata
    my $repoquery_list = Set::Scalar->new( reverse(split ( /\n/, $repodata_rpms)) );
    my $repoquery_list_noepoch = Set::Scalar->new();
    my $locked_found           = Set::Scalar->new();
    my $locked_found_noepoch   = Set::Scalar->new();
    $self->info( "(" . $repoquery_list->size . " total packages)" );
    while ( defined( my $p = $repoquery_list->each ) ) {
        my $t = $p;
        $t =~ s/^.*://;
        if ( !$repoquery_list_noepoch->has($t) ) { $repoquery_list_noepoch->insert($t); }
        if ( $wanted_pkgs_locked->has($t) ) {
            if ( !$locked_found->has($p) ) {
                $self->verbose("Found package $p");
                $locked_found->insert($p);
                $locked_found_noepoch->insert($t);
            }
        }
    }
    {
        my $fh = CAF::FileWriter->new( DNF_PACKAGE_LIST, log => $self );
        print $fh join ( "\n", @$locked_found );
        $fh->close();
        if ( $wanted_pkgs_locked->size != $locked_found->size ) {
            $self->error( "Version-locked packages are missing from repositories - expected ", $wanted_pkgs_locked->size, ", available ", $locked_found->size, "\n",
                          "Missing packages: ", $wanted_pkgs_locked - $locked_found_noepoch );
            return 0;
        } else {
            $self->info("all version locked packages available in repositories");
        }
    }

    # Test also whether version unlocked packages are present in repositories.
    {
        my $found = Set::Scalar->new();
        while ( defined( my $r = $repoquery_list->each ) ) {
            my $t = $r;
            $t =~ s/^.*://;
            my $name = $t;
            my $arch = substr($name, rindex($t, '.'));
            while( (my $end = rindex($name, '-')) != -1) {
                $name = substr($t, 0, $end);
                if ( $wanted_pkgs->has("$name$arch") ) {
                    $found->insert("$name$arch");
                    last;
                }
                if ( $wanted_pkgs->has("$name") ) {
                    $found->insert("$name");
                    last;
                }
            }
        }
        if ( $found->size != $wanted_pkgs->size ) {
            $self->error("Requested packages are missing from repositories.");
            $self->error("Missing packages: ", $wanted_pkgs - $found);
            return 0;
        }
    }

    # Continue only if package content is supposed to be changed
    return 1 unless $t->{run};

    # Run test transaction to get complete list of packages to be present on the system
    $self->execute_command( [ "rm -rf " . DNF_TEST_CHROOT ], "cleaning DNF test chroot", 1 );
    $self->execute_command( [ "mkdir -p " . DNF_TEST_CHROOT . "/var/cache" ],                 "setting up DNF test chroot",    1 );
    $self->execute_command( [ "ln -s /var/cache/dnf " . DNF_TEST_CHROOT . "/var/cache/dnf" ], "setting DNF test chroot cache", 1 );
    my $dnf_install_test_command = "dnf install " . DNF_PLUGIN_OPTS . " --assumeno --releasever=/ --installroot=" . DNF_TEST_CHROOT;
    if (@$wanted_pkgs_locked) { $dnf_install_test_command .= " " . join    ( " ",    sort @$wanted_pkgs_locked ); }
    if (@$wanted_pkgs)        { $dnf_install_test_command .= " " . join    ( " ",    sort @$wanted_pkgs ); }
    ( $cmd_exit, $cmd_out, $cmd_err ) = $self->execute_command( [$dnf_install_test_command], "performing DNF chroot install test", 1, "/dev/null", "verbose", 1 );
    $self->info($cmd_err) if $cmd_err;
    my $dnf_install_test = $cmd_out;
    $self->info($dnf_install_test);

    # Parse DNF output to get full package list
    my $to_install = Set::Scalar->new;
    my $to_install_names = Set::Scalar->new;
    
    {
        # DNF lacks yumtx transaction support - parse output directly instead
        my $start_found          = 0;
        my $aftername_wrapped    = 0;
        my $afterversion_wrapped = 0;
        my ( $epoch, $name, $versionrelease, $arch );
        my @lines = split /\n/, $dnf_install_test;
        foreach my $l (@lines) {
            if ($afterversion_wrapped) {
                $afterversion_wrapped = 0;
                next;
            }
            if ( $l ne "Installing:" ) {
                next if ( !$start_found );
            } else {
                $start_found = 1;
                next;
            }
            next if ( $l eq "Installing dependencies:" );
            if ( $l eq "Skipped (dependency problems):" ) {
                my $skipped = index( $dnf_install_test, "Skipped (dependency problems):" );
                if ( $skipped != -1 ) {
                    $self->info($dnf_install_test);
                    $self->error("Dependency problems in test transaction, see log.");
                    return 0;
                }
            }
            last if ( substr( $l, 0, 1 ) ne ' ' );
            next if ( substr( $l, 1, 1 ) eq ' ' && !$aftername_wrapped && !$afterversion_wrapped );
            $l =~ s/^\s+|\s+$//g;
            if ( !$aftername_wrapped ) {
                ( $name, $l ) = split ( / /, $l, 2 );
                if ( !defined($l) || $l eq "" ) {
                    $aftername_wrapped = 1;
                    next;
                }
                $l =~ s/^\s+//;
            } else {
                $aftername_wrapped = 0;
            }
            ( $arch, $l ) = split ( / /, $l, 2 );
            $l =~ s/^\s+//;
            my $eindex = index( $l, ':' );
            if ( $eindex > 0 ) {
                $epoch = substr( $l, 0, $eindex );
                $l = substr( $l, $eindex + 1 );
            } else {
                $epoch = 0;
            }
            ( $versionrelease, $l ) = split ( / /, $l, 2 );
            $to_install->insert( $name . '-' . $epoch . ':' . $versionrelease . '.' . $arch );
            $to_install_names->insert($name) if !$to_install_names->has($name);
            if ( !defined($l) || $l eq "" ) {
                $afterversion_wrapped = 1;
            }
        }
    }
    $self->info( "supposed to be installed: ", $to_install->size, " packages." );
    if ( $to_install->is_empty ) {
        $self->error("DNF failed: no packages to be installed to clean root.");
        return 0;
    }

    # Do not remove currently running kernel.
        my $running_kernel = "kernel-0:".`uname -r`;
        $running_kernel =~ s/\R//g;
        $self->info("Will skip removal of running: " . $running_kernel);

    # Compose list of packages to be installed and removed.
        my $will_remove = $preinstalled - $to_install - $running_kernel;
        my $will_install = $to_install - $preinstalled;
        my $whitelist = $t->{whitelist};
        my $whitelisted = Set::Scalar->new();
        for my $rpm ( $will_remove->elements ) {    # do not remove imported GPG keys
            if ( substr( $rpm, 0, 11 ) eq 'gpg-pubkey-' ) {
                $will_remove->delete($rpm);
            }
            # Do not remove whitelisted packages.
            if ( defined($whitelist) ) {
                for my $white_pkg (@$whitelist) {
                    my $rpm_noepoch = $rpm;
                    $rpm_noepoch =~ s/^.*://;
                    if ( index($rpm_noepoch, $white_pkg) == 0 || match_glob($white_pkg, $rpm_noepoch) ) {
                        $will_remove->delete($rpm);
                        $whitelisted->insert($rpm);
                    }
                }
            }
        }

    # Print summary what is supposed to be done.
    $self->info("Transaction summary --------------------");
    if ( defined($whitelisted) && scalar @$whitelisted > 0 ) {
        $self->info( "whitelist ", scalar @$whitelisted, " package(s): ", join ( " ", sort @$whitelisted ) );
    }
    if (@$excludes) {
        $self->info( "exclude   ", scalar @$excludes, " package(s): ", join ( " ", sort @$excludes ) );
    }
    $self->info( "install   " , $will_install->size, " package(s): ", join ( " ", sort @$will_install ) );
    $self->info( "remove    ", $will_remove->size, " package(s): ", join ( " ", sort @$will_remove ) );
    $self->info("----------------------------------------");

    # End here in case of --noaction.
    if ($NoAction) {
        return 1;
    }
    
    # Execute the transaction.
    my $transaction = "";
    if ( $will_remove->size ) {
        $transaction = "remove " . join ( " ", sort @$will_remove ) . "\n";
    }
    if ( $will_install->size ) {
        $transaction .= "install " . join ( " ", sort @$will_install ) . "\n";
    }
    if ( !($transaction eq "") ) {
        $transaction .= "run\n";
        # Remove all protected packages (especially systemd).
        my @files = glob "/etc/dnf/protected.d/*";
        foreach my $file (@files) {
            if ( !unlink $file ) {
                $self->error("Unable to remove file $file: $!");
                return 0;
            }
        }
        # Keep only DNF among protected packages.
        my $fh = CAF::FileWriter->new( "/etc/dnf/protected.d/dnf.conf", log => $self );
        print $fh join ( "dnf\n" );
        $fh->close();

        ( $cmd_exit, $cmd_out, $cmd_err ) = $self->execute_command([ "dnf shell -y " . DNF_PLUGIN_OPTS . " " ], 'executing transaction', 1, $transaction);
        $self->info($cmd_err) if $cmd_err;
    }

    # Sign-off successful SPMA installation by generating quattor_os_file.
    if ( defined($t->{quattor_os_file}) && defined($t->{quattor_os_release}) ) {
        my $fh = CAF::FileWriter->new( $t->{quattor_os_file}, log => $self );
        print $fh $t->{quattor_os_release} . "\n";
        $fh->close();
    }

    # Final statistics of spma changes of packages.
    my $installed = $self->get_installed_rpms();
    my $newly_installed = $installed - $preinstalled;
    my $newly_removed   = $preinstalled - $installed;
    $self->info("Summary of package changes -------------");
    if ( defined($whitelisted) && scalar @$whitelisted > 0 ) {
        $self->info( "whitelisted " . scalar @$whitelisted . " package(s) ", join ( " ", sort @$whitelisted ) );
    }
    if (@$excludes) {
        $self->info( "excluded    ", scalar @$excludes, " package(s):  ", join ( " ", sort @$excludes ) );
    }
    if ( defined($whitelist) || @$excludes ) {
        $self->info("----------------------------------------");
    }
    $self->info( "installed   " . $newly_installed->size . " package(s) ", join ( " ", sort @$newly_installed ) );
    $self->info( "removed     " . $newly_removed->size . " package(s) ", join ( " ", sort @$newly_removed ) );
    $self->info("----------------------------------------");

    # Test whether transaction fully completed/results are expected.
    if ( $newly_installed->size < $will_install->size ) {
        my $missing = $will_install - $newly_installed;
        $self->error("Installed less packages than requested. Not installed: ", join ( " ", sort @$missing ));
    } elsif ( $newly_installed->size > $will_install->size ) {
        my $additional = $newly_installed - $will_install;
        $self->info("Installed more packages than expected. Extra packages installed: ", join ( " ", sort @$additional ));
    }
    if ( $newly_removed->size < $will_remove->size ) {
        my $missing = $will_remove - $newly_removed;
        $self->warn("Removed less packages than requested. Not removed: ", join ( " ", sort @$missing ));
    } elsif ( $newly_removed->size > $will_remove->size ) {
        my $additional = $newly_removed - $will_remove;
        $self->info("Removed more packages than expected. Extra packages removed: ", join ( " ", sort @$additional ));
    }

    return 1;
}

1;    # required for Perl modules

use strict;
use warnings;
use Gearman::Worker;
use Getopt::Long;
use Parallel::Prefork;
use Pod::Usage;
use UNIVERSAL::require;
use Class::Inspector;
use Parallel::Scoreboard;

my $max_workers            = 10;
my $max_requests_per_child = 100;
GetOptions(
    's|server=s@'              => \my $servers,
    'prefix=s'                 => \my $prefix,
    'max-workers=i'            => \$max_workers,
    'max-requests-per-child=i' => \$max_requests_per_child,
    'scoreboard-dir=s'         => \my $scoreboard_dir,
    'h|help'                   => \my $help,
) or pod2usage();
pod2usage() unless $servers && @$servers;
pod2usage() if $help;

my $worker = Gearman::Worker->new();
$worker->job_servers(@$servers);
$worker->prefix($prefix) if $prefix;
for my $klass (@ARGV) {
    $klass->use or die $@;
    my @jobs = grep /^job_/, @{Class::Inspector->functions($klass)};
    for my $job (@jobs) {
        (my $job_name = $job) =~ s/^job_//; # Sledgeish dispatching
        $worker->register_function($job_name, $klass->can($job));
    }
}

my $pm = Parallel::Prefork->new(
    {
        max_workers  => $max_workers,
        trap_signals => {
            TERM => 'TERM',
            HUP  => 'TERM',
            USR1 => undef,
        }
    }
);
while ( $pm->signal_received ne 'TERM' ) {
    $pm->start and next;

    if ($scoreboard_dir) {
        my $scoreboard = Parallel::Scoreboard->new(
            base_dir => $scoreboard_dir,
        );

        my $i = 0;
        while ($i++ < $max_requests_per_child) {
            $scoreboard->update('.');
            $worker->work(
                on_start => sub {
                    $scoreboard->update('S');
                },
                on_fail  => sub {
                    $scoreboard->update('F');
                },
                on_complete  => sub {
                    $scoreboard->update('.');
                },
            );
        }
    } else {
        my $i = 0;
        while ($i++ < $max_requests_per_child) {
            $worker->work();
        }
    }

    $pm->finish;
}

$pm->wait_all_children();

__END__

=head1 SYNOPSIS

    % gearman-starter.pl --server=127.0.0.1 MyApp::Worker::Foo

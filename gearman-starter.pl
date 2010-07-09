use strict;
use warnings;
use Gearman::Worker;
use Getopt::Long;
use Parallel::Prefork;
use Pod::Usage;
use UNIVERSAL::require;
use Class::Inspector;
use Parallel::Scoreboard;
use IO::Socket::INET;
use Filesys::Notify::Simple;

my $max_workers            = 10;
my $max_requests_per_child = 100;
my $listen = '0.0.0.0';
GetOptions(
    's|server=s@'              => \my $servers,
    'prefix=s'                 => \my $prefix,
    'max-workers=i'            => \$max_workers,
    'max-requests-per-child=i' => \$max_requests_per_child,
    'scoreboard-dir=s'         => \my $scoreboard_dir,
    'listen=s'                 => \$listen,
    'port=i'                   => \my $port,
    'h|help'                   => \my $help,
    'R|Reload=s@'              => \my $reload,
) or pod2usage();
pod2usage() unless $servers && @$servers;
pod2usage() if $help;

if ( $reload && @$reload ) {

    RELOAD: while ( 1 ) {

        my $pid = fork;
        die "fork failed: $!" unless defined $pid;

        if ( $pid ) {
            #main process
            my $watcher = Filesys::Notify::Simple->new([@$reload,$0]);
            warn "Watching @$reload for file updates.\n";

            NOTIFY: while ( 1 ) {
                my @restart;

                # this is blocking
                $watcher->wait(sub {
                    my @events = @_;
                    @events = grep {
                        $_->{path} !~ m![/\\][\._]|\.bak$|~$!
                    } @events;
                    return unless @events;
                    @restart = @events;
                });

                next NOTIFY unless @restart;
            
                for my $ev (@restart) {
                    warn "-- $ev->{path} updated.\n";
                }

                warn "Killing the existing worker (pid:$pid)\n";
                kill 'TERM', $pid;
                waitpid( $pid, 0 );
                warn "Successfully killed! Restarting the new worker process.\n";
                last NOTIFY;
            }
        }
        else {
            # child process
            last RELOAD;
        }
    }
    
}

my $start_time = time();

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

my $scoreboard;
if ( $scoreboard_dir ) {
    $scoreboard = Parallel::Scoreboard->new(
        base_dir => $scoreboard_dir,
    );
}

my @pid;
if ( $port ) {

    my $sock = IO::Socket::INET->new(
        Listen => 5,
        LocalAddr => $listen,
        LocalPort => $port,
        Proto  => 'tcp',
        Reuse  => 1,
    );
    die $! unless $sock;

    my $pid = fork;
    die "fork failed: $!" unless defined $pid;

    if ( $pid ) {
        #main process
        push @pid, $pid;
    }
    else {
        # status worker
        $0 = "$0 (status worker)";
        $SIG{TERM} = sub { exit(0) };
        while ( 1 ) {
            my $client = $sock->accept();
            my $system_info = 'gearman_servers: ' . join ",", @$servers;
            $system_info .= ' prefix: ' . $prefix if $prefix;
            $system_info .= ' class: ' . join ",", @ARGV;
            my $uptime = time - $start_time;

            if ( $scoreboard ) {
                my $stats = $scoreboard->read_all();
                my $raw_stats;
                my $busy = 0;
                my $idle = 0;
                for my $pid ( sort { $a <=> $b } keys %$stats) {
                    if ( $stats->{$pid} =~ m!^A! ) {
                        $busy++;
                    }
                    else {
                        $idle++;
                    }
                    $raw_stats .= sprintf "%-14d %s\n", $pid, $stats->{$pid}
                }
                $raw_stats = <<EOF;
System: $system_info
Uptime: $uptime
BusyWorkers: $busy
IdleWorkers: $idle
--
pid       Status Counter Comment
$raw_stats
EOF
                print $client $raw_stats;
            }
            else {
                print $client <<EOF;
System: $system_info
Uptime: $uptime
ERROR: scoreboard is disabled
EOF
            }
            $client->close;
        }
    }
}

while ( $pm->signal_received ne 'TERM' ) {
    $pm->start and next;

    $0 = "$0 (worker)";

    my $counter = 0;
    $SIG{TERM} = sub { $counter = $max_requests_per_child };
    if ( $scoreboard ) {
        $scoreboard->update('. 0');
    }

    $worker->work(
        on_start => sub {
            $counter++;
            if ( $scoreboard ) {
                $scoreboard->update( sprintf "%s %s %s", 'A',  $counter, shift);
            }
        },
        on_complete => sub {
            if ( $scoreboard ) {
                $scoreboard->update( sprintf "%s %s", '_', $counter );
            }
        },
        stop_if => sub {
            $counter >= $max_requests_per_child;
        }
    );

    $pm->finish;
}

$pm->wait_all_children();

for my $pid ( @pid ) {
    next unless $pid;
    kill 'TERM', $pid;
    waitpid( $pid, 0 );
}


__END__

=head1 SYNOPSIS

    % gearman-starter.pl --server=127.0.0.1 MyApp::Worker::Foo

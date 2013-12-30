package Gearman::Starter;
use 5.008001;
use strict;
use warnings;

our $VERSION = "0.01";

use Getopt::Long;
use Pod::Usage qw/pod2usage/;

use Gearman::Worker;
use Parallel::Prefork;
use Class::Inspector;
use Parallel::Scoreboard;
use IO::Socket::INET;
use Filesys::Notify::Simple;
use Module::Load ();

use Class::Accessor::Lite (
    new => 1,
    ro => [qw/prefix port listen/],
    rw => [qw/start_time scoreboard/],
);

sub reload {
    my $self = shift;
    @{$self->{Reload} || []};
}

sub servers                {@{shift->{server}}                 }
sub max_workers            { shift->{'max-workers'}            }
sub max_requests_per_child { shift->{'max-requests-per-child'} }
sub scoreboard_dir         { shift->{'scoreboard-dir'}         }
sub modules                {@{shift->{modules}}                }

sub pid                    {shift->{pid} ||= []}

sub new_with_options {
    my ($class, @argv) = @_;

    my $p = Getopt::Long::Parser->new(
        config => [qw/default posix_default no_ignore_case auto_help pass_through/]
    );
    my %opt = (
        'max-workers'             => 10,
        'max-requests-per-child' => 100,
        'listen'                  => '0.0.0.0',
    );
    $p->getoptionsfromarray(\@argv, \%opt, qw/
        server|s=s@
        prefix=s
        max-workers=i
        max-requests-per-child=i
        scoreboard-dir=s
        listen=s
        port=i
        Reload|R=s@
    /) or pod2usage;
    pod2usage unless $opt{server} && @{$opt{server}};

    $opt{modules} = \@argv;

    $class->new(%opt);
}

sub run {
    my $self = shift;

    if ($self->reload) {
        $self->_launch_watcher;
    }

    $self->start_time(time);

    if ( $self->scoreboard_dir ) {
        $self->scoreboard(Parallel::Scoreboard->new(
            base_dir => $self->scoreboard_dir,
        ));
    }

    if ( defined $self->port ) {
        my $pid = $self->_launch_monitor_socket;
        push @{$self->pid}, $pid;
    }

    $self->_run;
}

sub _jobs {
    my $self = shift;
    $self->{_jobs} ||= do {
        my %jobs;
        for my $klass ($self->modules) {
            Module::Load::load($klass);
            my @jobs = grep /^job_/, @{Class::Inspector->functions($klass)};
            for my $job (@jobs) {
                (my $job_name = $job) =~ s/^job_//; # Sledgeish dispatching
                $jobs{$job_name} = $klass->can($job);
            }
        }
        \%jobs;
    }
}

sub _run {
    my $self = shift;

    my $pm = Parallel::Prefork->new({
        max_workers  => $self->max_workers,
        trap_signals => {
            TERM => 'TERM',
            HUP  => 'TERM',
            USR1 => undef,
        }
    });

    while ( $pm->signal_received ne 'TERM' ) {
        $pm->start and next;

        # Gearman::Worker isn't fork-safe
        my $worker = Gearman::Worker->new;
        $worker->job_servers($self->servers);
        $worker->prefix($self->prefix) if $self->prefix;
        my %jobs = %{$self->_jobs};
        for my $job_name (keys %jobs) {
            $worker->register_function($job_name, $jobs{$job_name});
        }

        $0 = "$0 (worker)";
        my $counter = 0;
        local $SIG{TERM} = sub { $counter = $self->max_requests_per_child };
        if ( $self->scoreboard ) {
            $self->scoreboard->update('. 0');
        }

        $worker->work(
            on_start => sub {
                $counter++;
                $self->scoreboard && $self->scoreboard->update( sprintf "%s %s %s", 'A',  $counter, shift);
            },
            on_complete => sub {
                $self->scoreboard && $self->scoreboard->update( sprintf "%s %s", '_', $counter );
            },
            stop_if => sub {
                $counter >= $self->max_requests_per_child;
            }
        );
        $pm->finish;
    }

    $pm->wait_all_children;

    for my $pid ( @{ $self->pid } ) {
        next unless $pid;
        kill 'TERM', $pid;
        waitpid( $pid, 0 );
    }
}

sub _launch_watcher {
    my $self = shift;
    while ( 1 ) {
        my $pid = fork;
        die "fork failed: $!" unless defined $pid;
        if ( $pid ) {
            #main process
            my $watcher = Filesys::Notify::Simple->new([$self->reload, $0]);
            warn "Watching @{[$self->reload]} for file updates.\n";
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
            return;
        }
    }
}

sub _launch_monitor_socket {
    my $self = shift;

    my $sock = IO::Socket::INET->new(
        Listen => 5,
        LocalAddr => $self->listen,
        LocalPort => $self->port,
        Proto  => 'tcp',
        Reuse  => 1,
    );
    die $! unless $sock;

    my $pid = fork;
    die "fork failed: $!" unless defined $pid;

    if ( $pid ) {
        #main process
        return $pid;
    }
    else {
        # status worker
        $0 = "$0 (status worker)";
        local $SIG{TERM} = sub { exit(0) };
        while ( 1 ) {
            my $client = $sock->accept();
            my $system_info = 'gearman_servers: ' . join ",", $self->servers;
            $system_info .= ' prefix: ' . $self->prefix if $self->prefix;
            $system_info .= ' class: ' . join ",", $self->modules;
            my $uptime = time - $self->start_time;

            if ( $self->scoreboard ) {
                my $stats = $self->scoreboard->read_all;
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


1;
__END__

=encoding utf-8

=head1 NAME

Gearman::Starter - It's new $module

=head1 SYNOPSIS

    use Gearman::Starter;

=head1 DESCRIPTION

Gearman::Starter is ...

=head1 LICENSE

Copyright (C) Songmu.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Songmu E<lt>y.songmu@gmail.comE<gt>

=cut


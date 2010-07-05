use strict;
use warnings;
use Parallel::Scoreboard;

my $path = shift || die "Usage: $0 /path/to/scoreboard";

my $board = Parallel::Scoreboard->new(base_dir => $path);
my $stats = $board->read_all();
for my $pid (sort { $a <=> $b } keys %$stats) {
    print "status for pid:$pid is: ", $stats->{$pid}, "\n";
}

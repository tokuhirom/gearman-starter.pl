use strict;
use warnings;
use Gearman::Starter;
Gearman::Starter->new_with_options(@ARGV)->run;

__END__

=head1 SYNOPSIS

    % gearman-starter.pl --server=127.0.0.1 MyApp::Worker::Foo

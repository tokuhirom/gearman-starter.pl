requires 'perl', '5.008001';

requires 'Gearman::Worker';
requires 'Parallel::Prefork';
requires 'UNIVERSAL::require';
requires 'Class::Inspector';
requires 'Parallel::Scoreboard';
requires 'Filesys::Notify::Simple';

on 'test' => sub {
    requires 'Test::More', '0.98';
};

use inc::Module::Install;

name 'gearman-starter';
author 'Tokuhiro Matsuno';
version '0.01';
license 'bsd';
perl_version '5.8.5';

requires 'Gearman::Worker';
requires 'Parallel::Prefork';
requires 'UNIVERSAL::require';
requires 'Class::Inspector';
requires 'Parallel::Scoreboard';
requires 'Filesys::Notify::Simple';

install_script 'gearman-starter.pl';


WriteAll;


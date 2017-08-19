#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use Getopt::Long qw(GetOptions);
use YAML::Syck;

use lib "$FindBin::RealBin/../lib";

use MassHighlight::Event;

my $config_file;

GetOptions("config|c=s" => \$config_file);

exit MassHighlight::Event->new({
    config => YAML::Syck::LoadFile("./data/config.yaml"),
})->run_all();


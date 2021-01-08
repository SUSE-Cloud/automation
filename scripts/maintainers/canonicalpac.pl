#!/usr/bin/perl

use strict;
use warnings;

# canonicalpac.pl - look up IBS package's canonical name from a solvable and
#                   replace it in package list output by cloudpackages.py
#
# usage:
#
# canonicalpac.pl <binary name file> <file with cloudpackages.py output>
#
# <binary name file> can be created as follows:
#   iosc co SUSE:Channels
#   grep -w binary $(find SUSE:Channels -name _channel) > binaries

my $binaries_file = shift(@ARGV);

open BINLIST, $binaries_file or die "Couldn't open $binaries_file for reading: $!";

my %packages;

while (my $line = <BINLIST> )
  {
  chomp $line;
  $line =~ /name="(\S*)"/;
  my $name = $1;
  $line =~ /package="(\S*)"/;
  my $package = $1;

  $packages{$name} = $package;
  }

while ( my $line = <> )
  {
  chomp $line;
  my @line = split(/\s/, $line);
  $line[0] = $packages{$line[0]};
  print(join(" ", @line), "\n");
  }

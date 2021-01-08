#!/usr/bin/perl

use strict;
use warnings;
use Getopt::Std;

# You can acquire the raw data for this script to process on as follows:
#
# iosc co SUSE:Channels
# cd SUSE:Channels
# 
# for p in $(grep -w binary OpenStack*/_channel | cut -d'"' -f4 | grep -v _product | sort -u)
#   do
#   iosc maintainer $p 2>&1 | tee maintainers
#   done
#
# This will take about an hour, so caching it locally is highly recommended.
# Once you have this data, you can process it as follows:
#
#   parse_maintainers.pl maintainers
#
# By default, output will be pretty printed for human readability. Use the '-c'
# option to get CSV output:
#
#   parse_maintainers.pl -c maintainers


# Headers for output
my @headers = ("package", "project", "bugowner", "maintainer");

# Column widths for fixed length output
my %widths = ( "package" => 55,
               "project" => 46,
               "bugowner" => 25,
               "maintainer" => 3
             );

# Column separator
my $separator = "  ";

# Command line options
my %opts;
getopts('c', \%opts);



# Parse a record where a maintainer was found
sub parse_normal_record
  {
  my @lines = @{shift @_};
  my %columns;

  $lines[0] =~ qr"bugowner of ([^/]*)/([^/]*)";
  $columns{'project'} = $1;
  $columns{'package'} = $2;

  $lines[1] =~ s/\s*//g;
  $columns{'bugowner'} = $lines[1];

  $lines[4] =~ s/\s*//g;
  $columns{'maintainer'} = $lines[4];

  # Designate empty columns by "N/A"
  foreach my $key ( keys(%columns) )
    {
    if ( $columns{$key} =~ /^\s*$/ ) { $columns{$key} = "N/A"; }
    }

  return %columns;
  }


sub parse_404_record
  {
  my @lines = @{shift @_};
  my %columns;

  $lines[1] =~ qr"Error getting meta for project '(.*)' package '(.*)'";
  $columns{'project'} = $1;
  $columns{'package'} = $2;

  $columns{'bugowner'} = "N/A";
  $columns{'maintainer'} = "N/A";

  return %columns;
  }


sub parse_record
  {
  my $record_type = shift @_;
  my $record = shift @_;

  my %columns;
  if ( $record_type eq 'normal' )
    {
    %columns = parse_normal_record($record);
    }

  if ( $record_type eq '404' )
    {
    %columns = parse_404_record($record);
    }

  return %columns;
  }

sub format_csv
  {
  my $columns = shift @_;
  my %columns = %$columns;

  my @line;

  foreach my $header (@headers)
    {
    push @line, "\"$columns{$header}\"";
    }

  return @line;
  }

sub format_pretty
  {
  my $columns = shift @_;
  my %columns = %$columns;

  my @line;

  foreach my $header (@headers)
    {
    push @line, sprintf("%-$widths{$header}s", $columns{$header});
    }

  return @line;
  }


sub print_record
  {
  my @output;

  my $record_type = shift @_;

  my $record = shift @_;
  my @record = @$record;

  unless ( $record_type ) { return; }

  if ( $record_type eq '400' )
    {
    # No data in this case
    return;
    }

  my %columns = parse_record($record_type, \@record);

  unless ( $columns{'package'} ) { return; }

  if ( $opts{'c'} )
    {
    print(join($separator, format_csv(\%columns)), "\n");
    }
  else
    {
    print(join($separator, format_pretty(\%columns)), "\n");
    }
  }



if ( ${opts}{'c'} ) { $separator = ","; }


my @record = ();
my $record_type = undef;
my @headline;

foreach my $header (@headers)
  {
  if ( $opts{'c'} )
    {
    push @headline, '"' . $header . '"';
    }
  else
    {
    push @headline, sprintf("%-$widths{$header}s", $header);
    }
  }

print(join($separator, @headline), "\n");

while (my $line = <>)
  {
  chomp $line;

  if ( $line =~ /^bugowner of/ )
    {
    # Parse and print previous record
    print_record($record_type, \@record);

    @record = ();
    $record_type = 'normal';
    }

  if ( $line =~ /^Defined in project/ ) 
    {
    # Parse and print previous record
    print_record($record_type, \@record);

    @record = ();
    $record_type = 'normal';
    }

  if ( $line =~ /HTTP Error 404/ )
    {
    # Parse and print previous record
    print_record($record_type, \@record);

    @record = ();
    $record_type = '404';
    }

  if ( $line =~ /400: Bad Request/ )
    {
    if ( $record_type ne '400' )
      {
      # Parse and print previous record
      print_record($record_type, \@record);
      }

    @record = ();
    $record_type = '400';
    }

  push @record, $line;
  }

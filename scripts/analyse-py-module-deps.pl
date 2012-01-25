#!/usr/bin/perl

use strict;
use warnings;

use File::Find;
use Getopt::Long;

sub usage {
    warn @_, "\n" if @_;

    (my $ME = $0) =~ s,.*/,,;

    die <<EOUSAGE;
Usage: $ME [options] SOURCE-DIRECTORY
Options:
  -h, --help               Show this help
  -1, --oneline-importers  Show importers of each module,
                           one line per module
  -m, --multiline-sources  Show importers of each module,
                           split over multiple lines
EOUSAGE
}

my %opts = ( );
GetOptions(
    \%opts,
    'help|h',
    'oneline-importers|1',
    'multiline-importers|m',
) or usage();
usage() if $opts{help};
@ARGV or unshift @ARGV, '.';
usage() unless @ARGV == 1 && -d $ARGV[0];

my %imports = ();
my %std_libs = get_std_libs();
find(\&detect_imports, @ARGV);
my $pip_requires_file = find_pip_requires();
my %pip_requires = get_pip_requires($pip_requires_file);
report(\%imports, \%pip_requires);

sub get_std_libs {
    # Yes, I should have written this whole hack in Python :-(
    my %std_libs;
    my $python = <<'EOPYTHON';
# http://stackoverflow.com/a/8992937/179332
import distutils.sysconfig as sysconfig
import os
import sys

std_lib = sysconfig.get_python_lib(standard_lib=True)

for top, dirs, files in os.walk(std_lib):
    for nm in files:
        prefix = top[len(std_lib)+1:]
        if prefix[:13] == 'site-packages':
            continue
        if nm == '__init__.py':
            print top[len(std_lib)+1:].replace(os.path.sep,'.')
        elif nm[-3:] == '.py':
            print os.path.join(prefix, nm)[:-3].replace(os.path.sep,'.')
        elif nm[-3:] == '.so' and top[-11:] == 'lib-dynload':
            print nm[0:-3]

for builtin in sys.builtin_module_names:
    print builtin
EOPYTHON
    open(PYTHON, qq{python -c "$python" |})
        or die "Couldn't run python: $!\n";
    while (<PYTHON>) {
        chomp;
        $std_libs{$_}++;
        #print "stdlib: [$_]\n";
    }
    close(PYTHON) or die "close(python|) failed: $!\n";
    return %std_libs;
}

sub detect_imports {
    return unless /\.py$/;

    search_file($File::Find::dir, $_);
}

sub search_file {
    my ($dir, $file) = @_;
    (my $path = "$dir/$file") =~ s!^\./!!;
    open(FILE, $file) or die qq{open(FILE, $file) failed: $!\n};
    while (<FILE>) {
        s/^\s+//;
        s/#.*//;
        s/\s+$//;
        if (/^import\s+(.+?)(\s+as\s+(\w\S+))?$/) {
            my $imports = $1;
            for (split /\s*,\s*/, $imports) {
                $imports{$_}{$path}++ unless $std_libs{$_};
                # print "Detected import: $_\n" unless $std_libs{$_};
                # print "Ignoring standard library import: $_\n" if $std_libs{$_};
            }
        }
        elsif (/^from\s+(.+)\s+import\s+/) {
            $imports{$1}{$path}++ unless $std_libs{$1};
            # print "Detected from import: $_\n" unless $std_libs{$_};
            # print "Ignoring standard library import: $_\n" if $std_libs{$_};
        }
    }
    close(FILE);
}

sub find_pip_requires {
    chomp(my $lazy_hack = `find @ARGV -name pip-requires`);
    die "Found more than one pip-requires?!\n$lazy_hack\n"
        if $lazy_hack =~ /\n/;
    die "No pip_requires found in: @ARGV\n" unless $lazy_hack;
    return $lazy_hack;
}

sub get_pip_requires {
    my %pip_requires = ();
    my ($pip_requires_file) = @_;
    open(PIP, $pip_requires_file)
        or die qq{open(PIP, $pip_requires_file) failed: $!\n};
    while (<PIP>) {
        chomp;
        s/[<=>]=.+//;
        $pip_requires{$_}++;
    }
    close(PIP);
    return %pip_requires;
}

sub header {
    my ($header) = @_;
    print "$header\n", "=" x length($header), "\n\n";
}

sub report {
    my ($imports, $pip_requires) = @_;

    header("packages imported and in pip-requires");
    my %union = (%$imports, %$pip_requires);
    for my $package (sort keys %union) {
        if ($imports->{$package} && $pip_requires->{$package}) {
            show_imports($imports, $package);
        }
    }
    print "\n";

    header("packages imported but not in pip-requires");
    for my $package (sort keys %$imports) {
        unless ($pip_requires->{$package}) {
            show_imports($imports, $package);
        }
    }
    print "\n";

    header("packages in pip-requires but not imported");
    for my $package (sort keys %$pip_requires) {
        print "$package\n" unless $imports->{$package};
    }
}

sub show_imports {
    my ($imports, $package) = @_;
    my @imports = sort keys %{ $imports->{$package} };
    if ($opts{'oneline-importers'}) {
        printf "%-20s from: %s\n", $package, join(" ", @imports);
    }
    elsif ($opts{'multiline-importers'}) {
        print "$package imported from:\n";
        my $previous_path = '#$non-existent!$';
        foreach my $import (@imports) {
            my ($path, $file) = $import =~ m!(.+)/(.+)! ? ($1, $2) : ('.', $import);
            print "      $path/\n" if $path ne $previous_path;
            print "          $file\n";
            $previous_path = $path;
        }
    }
    else {
        print "$package\n";
    }
}

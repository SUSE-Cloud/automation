#!/usr/bin/perl -w
#
# 2013 Bernhard M. Wiedemann <bwiedemann@suse.de>
#
# zypper ar http://download.opensuse.org/repositories/devel:/languages:/perl/SLE_11_SP3/ perl
# zypper in perl-JSON-XS
use JSON::XS;

my $nagmode=0;
our $dbdir="/var/lib/jenkinsnotify/db";
system("mkdir", "-p", $dbdir);

use strict;
use CGI ":standard";
print header;

open(LOG, ">>/tmp/jenkinsnotify.log");
my @p=param();
my @v;
foreach my $p (@p) { push(@v, param($p)); }
print LOG "@p @v\n\n";
close LOG;

#open(my $f, "/dev/shm/example.json"); my $json=<$f>; close $f;
my $json=param("POSTDATA");
die unless $json;

my $data=decode_json($json);

our @relevant=qw(cloudsource networkingplugin WITHREBOOT);

sub hashparams($)
{
        my $data=shift;
        my $params=$data->{build}{parameters};
        my @relevantparams=();
        for my $p (@relevant) {
                push(@relevantparams, "$p=$params->{$p}");
        }
        unshift(@relevantparams, $data->{name});
        return join(" ", @relevantparams);
}

sub getoldresult($)
{
        my $data=shift;
        my $h=hashparams($data);
        open(my $f, "<", "$dbdir/$h") or return undef;
        my $status=<$f>;
        close $f;
        return $status;
}

sub setoldresult($)
{
        my $data=shift;
        my $h=hashparams($data);
        open(my $f, ">", "$dbdir/$h") or die $!;
        print $f $data->{build}{status};
        close $f;
}

sub sendmail($)
{
        my $data=shift;
        my $m="$data->{name} $data->{build}{status}\n$data->{build}{full_url}\nparams: ".hashparams($data)."\n\n";
        print "sending about $m";
        open(my $mail, "|mail -s '$data->{name} $data->{build}{status}' -r cloud-devel+fromjenkins\@suse.de bwiedemann\@suse.de") or die $!;
        print $mail $m;
        close $mail;
}

sub notify($)
{
        my $data=shift;
        return unless $data && $data->{name} eq "openstack-mkcloud";
        my $b=$data->{build};
        return unless $b->{phase} eq "FINISHED";
        my $old=getoldresult($data);
        setoldresult($data);
        return unless $old; # be quiet about first time
        if($old eq $b->{status}) {
                # nothing changed
                if($nagmode && $old eq "FAILURE") {sendmail($data)}
        } else {
                sendmail($data);
        }
}

notify($data)

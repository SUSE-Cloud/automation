#!/usr/bin/perl -w
# input productioncloud/usagedump.sh JSON on stdin or via file:
# username: {id:X, project: Y, ... name: }
use strict; use JSON;
my $debug=1;
my $cloudname=`cat /etc/cloudname`; chomp($cloudname);
my $shortcloudname=$cloudname; $shortcloudname=~s/\.suse\.de//;
my $adminaddr=qq,bwiedemann+$shortcloudname\@suse.de,;
$/=undef; my $userdata=decode_json(<>);
foreach my $u (sort keys %$userdata) {
  foreach my $e (@{$userdata->{$u}}) { $e->{URI}="https://$cloudname/auth/switch/$e->{project}/?next=/project/instances/$e->{id}/"}
  my $userdb=`openstack user show $u --format shell`;
  $userdb=~m/^name="(.*)"$/m or next;
  my $username=$1;
  my $useremail="";
  if($u =~ m/^\d{1,7}$/) { # LDAP ID
    $useremail=`ldapsearch -h ldap.suse.de -b dc=suse,dc=de -x uid=$username | awk '/^mail:/{print \$2}'`;
    chop($useremail);
  } else {
    $userdb=~m/^email="(.*)"$/m and $useremail=$1;
  }
  if(!$useremail) {
    warn "no email addr found for $username";
    $useremail=$adminaddr;
  }
  my $mailcmd="mail -s \"usage stats for $username on $cloudname\" -R $adminaddr $useremail";
  if($debug) {
    open(MAIL, ">&STDOUT");
    print MAIL "mailcmd: $mailcmd\n";
  } else {
    open(MAIL, "|$mailcmd");
  }
  print MAIL "Dear $username,
this is an automated email from your cloud operator to inform you that
you currently have the following instances on $cloudname.
If they are not needed, please delete them.
###
", JSON->new->canonical(1)->pretty->encode($userdata->{$u});
  close(MAIL);
  last if $debug;
}

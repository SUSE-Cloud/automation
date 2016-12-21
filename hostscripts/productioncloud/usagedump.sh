#!/bin/sh
echo '\pset border 0 \\ \pset format unaligned \\ \pset fieldsep '\'\\t\'' \\ SELECT user_id,vm_state,instances.created_at,instances.updated_at,name,uuid,project_id,display_name FROM instances,instance_types WHERE instances.deleted_at is NULL AND instance_type_id=instance_types.id ORDER BY user_id;' | \
su - postgres -c 'psql -t -d nova' | \
perl -we 'use strict; use JSON;
    my $skip=3;
    my @values=qw"state created updated flavor id project name";
    my %user;
    while(<>) {
        next if(--$skip >= 0);
        chop;
        my @a=split("\t");
        my %value=();
        for(my $i=$#values; $i>=0; $i--) {
            $value{$values[$i]} = $a[$i+1];
        }
        die if not $value{project};
        push(@{$user{$a[0]}}, \%value);
    }
    print JSON->new->canonical(1)->pretty->encode(\%user);
' > /root/usage.json

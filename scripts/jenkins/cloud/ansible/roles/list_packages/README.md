Role list and diff installed packages on the all nodes
======================================================

Description
-----------
Role which gets installed packages from the nodes and saves output into files
in dir `$workspace/rpms/`(for manual deployment see var `local_tmp_dir`) on localhost.
It also do the diff of packages from two states. Role accepts 3 variables (action, 
state1, state2). 'Diff' task fails when **NO** diffs found.

When action is
- list: get the list of packages based on state1
- diff: get the list of packages based on state2

TODO
----
- yaml/json handling

Vars
----
`action` - defines the action, valid values 'list'(default value) & 'diff'  
`state1` - default value 'after_deployment'  
`state2` - default value 'after_update'  
variable for manual deployment `local_tmp_dir` - default is */tmp/*

Tasks
-----
- main.yml (agreggator )
- list-packages.yml (lists packages and adds filename suffix based on state1 or state2 variable)
- diff-packages.yml (do diff of packages between state1 and state2)



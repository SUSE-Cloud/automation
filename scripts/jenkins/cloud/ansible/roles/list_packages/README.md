Role list and diff installed packages on the all nodes
======================================================

Description
-----------
Role which gets installed packages from the nodes and saves output into files
in dir `$workspace/rpms/`(for manual deployment see var `local_tmp_dir`) on
localhost. It also do the diff of packages from two states. Role accepts 3
variables (action, state1, state2). 'Diff' task can fail when **NO** diffs found
if var `die_when_no_diff_package_changes` is defined. Package informations are
handled by python script `parse_xml.py` and can be called via role `parse_xml`.

When action is:
- list: get the list of packages based on state1
- diff: get the list of packages based on state2

Vars
----
`action` - defines the action, valid values 'list'(default value) & 'diff'  
`state1` - default value 'after_deployment'  
`state2` - default value 'after_update'  
variable for manual deployment `local_tmp_dir` - default is */tmp/*
`die_when_no_diff_package_changes` - default value 'not defined'

Tasks
-----
- main.yml (agreggator)
- list-packages.yml (lists packages and adds filename suffix based on state1 or
  state2 variable)
- diff-packages.yml (do diff of packages between state1 and state2)

Library - Module
-------
- parse_xml.py
  + grabs information about installed packages from: 
    + zypper - repo of origin,
    + rpm - disturl, version infos)
  + module can be called on a file or read xmlstructure from ansible var
  Example of module usage in the role:
  ```
  - parse_xml:
      path: path/to/xml/file        (or ansible var variable)
      schema: zypper                (can be zypper or rpm)
    register: _result
  ```



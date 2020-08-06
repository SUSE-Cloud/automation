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
Now also diff between job runs in jenkins and it is on by default (for 5 runs).
To use diffs between job runs in manual deployment you have to define `build_id`.

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
`no_diff_old_builds` - if true no diff between runs.

Tasks
-----
- main.yml (agreggator)
- list-packages.yml (lists packages and adds filename suffix based on state1 or
  state2 variable)
- diff-packages.yml (do diff of packages between state1 and state2)
- packages_from_old_jobs.yml (do diffs between runs in the ci)

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
- diff_yaml.py
  + compares 2 given files and print diff into output file on the system
  + output in yaml
  Example of module usage in the role:
  ```
  - diff_yaml:
      file1: path/to/yaml/file
      file2: path/to/yaml/file
      output: path/where/to/save/output
    register: _result
  ```
- combine_files.py
  + combine 2 given files and produce a dictionary
  + output is variable
  Example of module usage in the role:
  ```
  - combine_files:
      filenames1: path/to/yaml/file
      filenames2: path/to/yaml/file
    register: _result
  ```


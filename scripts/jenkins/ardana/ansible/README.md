# Deploying Ardana

## Requirements:

  1. A host configured with libvirt (where the deployer VMs will be hosted)
  2. A fresh SLES VM disk in: `{{ libvirt_fresh_images_dir }}/ardana-{{ qe_env }}.sles12sp3.qcow2`


## Adding a new enviroment:

  1. Add the envinroment in the `inventory` file
  2. On the host, create a fresh SLES VM image for the environment, the image should be located at: `{{ libvirt_fresh_images_dir }}/ardana-{{ qe_env }}.sles12sp3.qcow2`
  3. Add the ardana input model in `roles/ardana_run/files/{{ qe_env }}`

## Running:
```sh
ansible-playbook ardana-deploy.yml -e qe_env=*target-qe-environemnt*
```

## Overriding variables:

* Take a look at `roles/*/defaults/main.yml` for variables that can be overriden.
* To override variables for all hosts add them to `group_vars/all.yml`
* To override variables for a group add them to `group_vars/'groupname'.yml`
* To override variables only for a specific host add them to `host_vars/'hostname'.yml`

## Documentation:

* [Preparing QE environments for ardana-deploy] (gate node)
* [Adding a new Environment to ardana-deploy]
* [Running ardana-deploy from your Workstation]

    [Preparing QE environments for ardana-deploy]: <https://suse-wiki.dyndns.org/display/HHE/Preparing+QE+environments+for+ardana-deploy>
    [Adding a new Environment to ardana-deploy]: <https://suse-wiki.dyndns.org/display/HHE/Adding+a+new+Environment+to+ardana-deploy>
    [Running ardana-deploy from your Workstation]: <https://suse-wiki.dyndns.org/display/HHE/Running+ardana-deploy+from+your+Workstation>

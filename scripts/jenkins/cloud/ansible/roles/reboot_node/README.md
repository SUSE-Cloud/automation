Role Reboot node
================

Description
-----------
Simple playbook handling reboot of nodes with simple service ready check. 
Takes variable which determine if deployer or nodes should be rebooted.  
Determinates cloud_product based on `cloud_product` var. Role will reboot  
node based on variable `reboot_target`.  
For now rebooting works for **deployer** (works for both ardana & crowbar) and  
**cloud_nodes_crowbar** (crowbar only).

TODO
----
Modify ardana playbooks for updating to include this role or adjust roles `setup_zypper_repos` and `ardana_update`)

Vars
----
`reboot_target` - deployer | cloud_nodes_crowbar

Tasks
-----
- main.yml (agreggator)
- reboot_deployer.yml (reboots ardana deployer or crowbar equivalent - admin node)
- reboot_cloud_nodes_crowbar.yml (reboots crowbar nodes)

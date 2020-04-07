##Information

This playbook supports deployment of caaspv4 using terraform against SOC deployments.

##Jenkins jobs 
Introduced a parameter want_caaspv4 to the jenkins jobs that handles SOC deployment. To enable deployment of 
caasp cluster using terraform, check the parameter want_caapsv4 as part of your jenkins job for SOC deployment.
For default installations with_caaspv4 enabled, we use the cloud-ardana-job-controller-large flavor from ECP 
for compute nodes.
 
It can be run post-SOC deployment using jobs like https://ci.suse.de/job/openstack-caaspv4/ 
providing the cloud_env parameter. Make sure you have enough compute resources.

## Login to management machine
From your deployer node (ardana) or the from the first controller node (crowbar):
You can login into the management machine by running 
ssh -i caaspmanagementkey.pem sles@<managementmachinefloatingip>

Once you are in the management machine, the caasp bits are in /home/sles/caasp/deployment/openstack

Make sure you run ssh agent by running eval "$(ssh-agent)" and ssh-add to add the key

You can run kubectl get nodes -o wide to see the status.

There will be a sub-folder for the cluster under /home/sles/caasp/deployment/openstack starting with the name 
"auto-caasp-<timestamp>-cluster"

You can also run skuba cluster status from the above sub-folder to check the status.

You can source the openstack_caasp.osrc file in /home/sles/caasp/deployment/openstack and 
manually interact with the terraform cli from /home/sles/caasp/deployment/openstack

To login into the master or worker nodes from the management machine: ssh sles@<floatingipofthenode>

## Additional Info

If caaspv4 is deployed against cloud 8 environment, it will use the haproxy provider for load balancer and for cloud 9 
environments it will use octavia provider.

Default number of workers and masters is 1 in the caasp cluster. However, if your openstack environment has enough 
resources to create more nodes in the cluster, you can tweak the number by using the extra_params parameter in the jenkins
jobs

num_workers=3
num_masters=3 

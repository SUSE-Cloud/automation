# this file contains help and usage functions of qa_crowbarsetup
# which are called from mkcloud help as well

function qacrowbarsetup_help
{
    cat <<EOUSAGE
    want_neutronsles12=1 (default 0)
        if there is a SLE12 node, deploy neutron-network role into the SLE12 node
    want_mtu_size=<size> (default='')
        Option to set variable MTU size or select Jumbo Frames for Admin and Storage nodes. 1500 is used if not set.
    want_raidtype (default='raid1')
        The type of RAID to create.
    want_node_aliases=list of aliases to assign to nodes
        Takes all provided aliases and assign them to available nodes successively.
        Note that this doesn't take care about node assignment itself.
        Examples:
            want_node_aliases='controller=1,ceph=2,compute=1'
              assigns the aliases to 4 nodes as controller, ceph1, ceph2, compute
            want_node_aliases='data=1,services=2,storage=2'
              assigns the aliases to 5 nodes as data, service1, service2, storage1, storage2
    want_node_os=list of OSs to assign to nodes
        Takes all provided OS values and assign them to available nodes successively.
        Example:
            want_node_os=suse-12.1=3,suse-12.0=3,hyperv-6.3=1
              assigns SLES12SP1 to first 3 nodes, SLES12 to next 3 nodes, HyperV to last one
    want_node_roles=list of intended roles to assign to nodes
        Takes all provided intended role values and assign them to available nodes successively.
        Possible role values: controller, compute, storage, network.
        Example:
            want_node_roles=controller=1,compute=2,storage=3
    want_test_updates=0 | 1  (default=1 if TESTHEAD is set, 0 otherwise)
        add test update repositories
    want_timescaling=2 (default 1)
        increase all wait_for sleeps by this factor
    want_sbd=1 (default 0)
        Setup SBD over iSCSI for cluster nodes, with iSCSI target on admin node. Only usable for HA configuration.
    want_devel_repos=list of Devel Projects to use for other products
        Adds Devel Projects for other products on deployed nodes
        Example:
            want_devel_repos=storage,virt
        Valid values: ha, storage, virt
    want_cloud6_iso_path=path to search for Cloud 6 ISO image in
        Search for Cloud 6 ISO image files in this path.
    want_cloud6_iso=ISO filename
        Name of Cloud 6 ISO image file.
    want_cloud7_iso_path=path to search for Cloud 7 ISO image in
        Search for Cloud 7 ISO image files in this path.
    want_cloud7_iso=ISO filename
        Name of Cloud 7 ISO image file.
EOUSAGE
}

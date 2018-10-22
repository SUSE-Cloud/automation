#!/bin/sh -e

if [ -z "$namespace" -o -z "$openstacksshkey" ] ; then
    echo "usage: namespace=$USER openstacksshkey=xxx $0"
    exit 21
fi

stackname=mkcc-$namespace
openstack stack create --wait -t setup.yaml --parameter key_name=$openstacksshkey --parameter namespace=$namespace $stackname
openstack stack output show -f value -c output_value $stackname floating_ip | tee .admin_ip

echo be sure to clean up later: openstack stack delete -y --wait $stackname

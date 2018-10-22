#!/bin/sh

if [ -z "$namespace" -o -z "$openstacksshkey" ] ; then
    echo "usage: namespace=$USER openstacksshkey=xxx $0"
fi

stackname=mkcc-$namespace
openstack stack create --wait -t setup.yaml --parameter key_name=$openstacksshkey --parameter namespace=$namespace $stackname
openstack stack output show -f value -c output_value $stackname floating_ip

# TODO

openstack stack delete -y --wait $stackname

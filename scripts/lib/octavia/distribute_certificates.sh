#!/bin/bash

if [ $# -eq 0 ]; then
    echo "usage: $0 CONTROLLER_IP_1 [CONTROLLER_IP_2 ...]"
    exit 1
fi

set -x

for controller in "$@" ; do
    echo "Setup $controller"
    ssh $controller mkdir -p /etc/octavia
    ssh $controller mkdir -p /etc/octavia/certs
    ssh $controller groupadd octavia
    ssh $controller useradd -G octavia octavia
    scp -r ./* $controller:/etc/octavia/certs
    ssh $controller chown -R octavia:octavia /etc/octavia/certs
    ssh $controller rm /etc/octavia/certs/*.sh
    ssh $controller rm /etc/octavia/certs/openssl.cnf
done

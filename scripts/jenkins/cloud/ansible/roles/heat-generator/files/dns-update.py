#!/usr/bin/env python

import argparse

import yaml


def parse_commandline():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dns-servers",
        metavar="NAME",
        help="A list of nameservers",
        nargs="+",
        default=[])
    parser.add_argument(
        "--ntp-servers",
        metavar="NAME",
        help="A list of ntp servers",
        nargs="+",
        default=[])
    return parser.parse_args()


if __name__ == "__main__":
    options = parse_commandline()
    print(options)

    with open('cloudConfig.yml') as f:
        data = yaml.load(f.read(), Loader=yaml.SafeLoader)

    data['cloud']['dns-settings'] = dict(nameservers=options.dns_servers)
    data['cloud']['ntp-servers'] = options.ntp_servers

    with open('cloudConfig.yml', 'w') as f:
        f.write(yaml.safe_dump(data, default_flow_style=False))

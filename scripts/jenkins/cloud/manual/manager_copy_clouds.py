#!/usr/bin/env python

import argparse
from os import path, scandir
from pathlib import Path

import yaml


def parse_commandline():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "SRC",
        help="The source directory or file for the clouds")
    parser.add_argument(
        "DEST",
        help="The full path of the finaly clouds.yaml")
    parser.add_argument(
        "--set",
        metavar="KEY:VALUE",
        help="Set KEY to VALUE",
        default=[],
        action="append")
    return parser.parse_args()


def build_file_list(source):
    if path.isdir(source):
        return [f.path for f in scandir(source)
                if f.is_file() and f.name.endswith(".yaml")]
    else:
        if path.isfile(source):
            return [source]
        else:
            raise Exception(
                "{} is neither file nor directory".format(source))


def merge_dictionaires(a, b):
    if not (isinstance(a, dict) and isinstance(b, dict)):
        raise Exception("Expected two dictionaries but got {} and {}".format(
            a.__class__.__name__, b.__class__.__name__))

    result = a.copy()
    for k, v in b.items():
        if k in result and isinstance(result[k], dict) and isinstance(v, dict):
            result[k] = merge_dictionaires(result[k], v)
        else:
            result[k] = v

    return result


def read_config(files):
    config = {}
    for f in files:
        with open(f) as fd:
            config = merge_dictionaires(config, yaml.load(
                fd.read(), Loader=yaml.SafeLoader))

    return config


def replace_one_key(config, key, new_value):
    for k, v in config.items():
        if k == key:
            config[k] = new_value
        elif isinstance(config[k], dict):
            replace_one_key(config[k], key, new_value)


def replace_keys(config, updates):
    new_config = config.copy()
    for update in updates:
        replace_one_key(new_config, *update.split(":"))

    return new_config


def main(options):
    config = replace_keys(read_config(
        build_file_list(options.SRC)), options.set)
    Path(path.dirname(options.DEST)).mkdir(parents=True, exist_ok=True)
    with open(options.DEST, "w") as fd:
        fd.write(yaml.dump(config))


if __name__ == "__main__":
    main(parse_commandline())

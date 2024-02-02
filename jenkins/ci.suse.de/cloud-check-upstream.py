#!/usr/bin/python3

import inspect
import pprint
import re
from functools import lru_cache

import requests


def get_jobs(tenant="openstack", api_prefix="https://zuul.opendev.org"):
    r = requests.get(
        "{prefix}/api/tenant/{tenant}/jobs".format(
            tenant=tenant, prefix=api_prefix
        )
    )
    r.raise_for_status()
    return r.json()


@lru_cache(maxsize=3)
def get_job_details(
    job_name, tenant="openstack", api_prefix="https://zuul.opendev.org"
):
    r = requests.get(
        "{prefix}/api/tenant/{tenant}/job/{job_name}".format(
            job_name=job_name, tenant=tenant, prefix=api_prefix
        )
    )
    r.raise_for_status()
    return r.json()


def get_builds(
    job_name=None,
    limit=50,
    skip=0,
    branch=None,
    uuid=None,
    newrev=None,
    ref=None,
    patchset=None,
    change=None,
    pipeline=None,
    project=None,
    tenant="openstack",
    api_prefix="https://zuul.opendev.org",
):
    arginfo = inspect.getargvalues(inspect.currentframe())
    params = {}
    for a in arginfo.args:
        if a not in ["api_prefix"] and arginfo.locals[a] is not None:
            params[a] = arginfo.locals[a]
    r = requests.get(
        "{prefix}/api/tenant/{tenant}/builds".format(
            tenant=tenant, prefix=api_prefix
        ),
        params,
    )
    r.raise_for_status()
    return r.json()


def filter_jobs(substring):
    for j in get_jobs():
        if re.search(r"(?i)suse", j["name"]):
            yield j


def list_all_suse():
    jobs = filter_jobs("suse")
    pprint.pprint(list(jobs))


def job_status(
    job_name,
    branch="master",
    pipeline="periodic-weekly",
    tenant="openstack",
    api_prefix="https://zuul.opendev.org",
):
    builds = get_builds(
        job_name,
        branch=branch,
        pipeline=pipeline,
        tenant=tenant,
        api_prefix=api_prefix,
        limit=1,
    )
    last = {"result": "NOTFOUND"}
    if len(builds) > 0:
        last = builds[0]
    print("Last job run:")
    pprint.pprint(last)
    web = (
        "{api_prefix}/t/{tenant}/builds"
        "?job_name={job_name}&branch={branch}&pipeline={pipeline}".format(
            api_prefix=api_prefix,
            tenant=tenant,
            job_name=job_name,
            branch=branch,
            pipeline=pipeline,
        )
    )
    print("\nList these jobs at: {web}".format(web=web))
    print("\n\n")
    if last["result"] == "SUCCESS":
        print("Last job was a success.")
        return True
    else:
        print("ERROR: Last job was a {}. ".format(last["result"]))
        return False


def main_without_exit():
    result = job_status("devstack-platform-opensuse-15")
    if result is True:
        return 0
    return 1


def main():
    result = main_without_exit()
    exit(result)


if __name__ == "__main__":
    main()

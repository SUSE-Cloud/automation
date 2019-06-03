#!/usr/bin/python2
import os
import re
import sys

import osc.babysitter
import osc.commandline
import osc.core

try:
    from urllib.error import HTTPError
except ImportError:
    from urllib2 import HTTPError

try:
    from xml.etree import cElementTree as ET
except ImportError:
    import cElementTree as ET


# copied from newer osc/core.py
def get_package_results(apiurl, project, package=None, wait=False,
                        *args, **kwargs):
    """generator that returns a the package results as an xml structure"""
    xml = ''
    waiting_states = ('blocked', 'scheduled', 'dispatching', 'building',
                      'signing', 'finished')
    while True:
        waiting = False
        try:
            xml = ''.join(osc.core.show_results_meta(apiurl, project, package,
                                                     *args, **kwargs))
        except HTTPError as e:
            # check for simple timeout error and fetch again
            if e.code == 502 or e.code == 504:
                # re-try result request
                continue
            root = ET.fromstring(e.read())
            if (e.code == 400 and kwargs.get('multibuild') and
                    re.search('multibuild',
                              getattr(root.find('summary'), 'text', ''))):
                kwargs['multibuild'] = None
                kwargs['locallink'] = None
                continue
            raise
        root = ET.fromstring(xml)
        kwargs['oldstate'] = root.get('state')
        for result in root.findall('result'):
            if result.get('dirty') is not None:
                waiting = True
                break
            elif result.get('code') in waiting_states:
                waiting = True
                break
            else:
                packages = result.find('status')
                for p in packages:
                    if p.get('code') in waiting_states:
                        waiting = True
                        break
                if waiting:
                    break

        if not wait or not waiting:
            break
        else:
            yield xml
    yield xml


# copied from newer osc/core.py
def is_package_results_success(xmlstring):
    ok = ('succeeded', 'disabled', 'excluded', 'published', 'unpublished')

    root = ET.fromstring(xmlstring)
    for result in root.findall('result'):
        if result.get('dirty') is not None:
            return False
        if result.get('code') not in ok:
            return False
        if result.get('state') not in ok:
            return False
        packages = result.find('status')
        for p in packages:
            if p.get('code') not in ok:
                return False
    return True


class _OscModifiedPrjresults(osc.commandline.Osc):
    # reduced from newer osc/commandline.py
    @osc.cmdln.option('-w', '--watch', action='store_true',
                      help='watch the results until all finished building')
    @osc.cmdln.option('', '--xml', action='store_true', default=False,
                      help='generate output in XML')
    def do_prjresults(self, subcmd, opts, *args):
        project = args[0]
        apiurl = self.get_api_url()
        kwargs = {}
        kwargs['wait'] = True
        last = None
        for results in get_package_results(apiurl, project, package=None,
                                           **kwargs):
            last = results
            print(results)
        if last and is_package_results_success(last):
            return
        return 3


def run_osc(*args):
    cli = _OscModifiedPrjresults()
    argv = ['osc', '-A', 'https://api.opensuse.org']
    argv.extend(args)
    exit = osc.babysitter.run(cli, argv=argv)
    return exit


def run_osc_prjstatus(project):
    # TODO replace _OscModifiedPrjresults once
    # the osc here is new enough to have
    # https://github.com/openSUSE/osc/pull/461 and
    # https://github.com/openSUSE/osc/pull/465
    return run_osc('prjresults', '--watch', '--xml', project)


def run_osc_release(project):
    # TODO replace this once the osc here is new enough to have
    # https://github.com/openSUSE/osc/commit/fb80026651
    return run_osc('api', '-m', 'POST',
                   '/source/%s?cmd=release&nodelay=1' % project)


def prepare(branch):
    project = 'Cloud:OpenStack:' + branch
    project_staging = project + ':Staging'
    project_totest = project + ':ToTest'
    exit = run_osc_release(project_staging)
    if exit is not None:
        print("Failed to release %s to %s .",
              project_staging, project_totest)
        return exit
    exit = run_osc_prjstatus(project_totest)
    if exit is not None:
        print(project_totest + " failed.")
        return exit


def main():
    branch = os.environ['openstack_project']
    if branch in ('Rocky', 'Stein'):
        sys.exit(prepare(branch))
    else:
        print("%s not supported for argument openstack_project." % branch)
        # don't fail so the previous staging implementation
        # still works for older releases
        sys.exit(0)


if __name__ == "__main__":
    main()

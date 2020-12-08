#!/usr/bin/python3

# cloudpackages.py
#
# This script operates on *.product files for SUSE OpenStack cloud and will
# attempt to determine the provenance of all packages pulled in by a particular
# product. Alternatively, packages can be supplied on the command line using
# the -u option. For this script to work correctly, you need to:
#
#  1) Run it on an IBS working copy of a _product package (not needed for -u).
#  2) Have a working osc configuration that can be used against api.suse.de.
#
# usage:
#
#   cloudpackages.py <product file> [ ... <product file> ]
#   cloudpackages.py -u <project> <package> [ ... <package> ]


import argparse
import optparse
import osc.conf
import osc.core
import os
import re
import sys

try:
    from xml.etree import cElementTree as ET
    from xml.etree import ElementInclude as EI
except ImportError:
    import cElementTree as ET
    import ElementInclude as EI



# Packages that cause trouble for some reason (usually conflicts) and that get
# their own buildinfo run. Full names are not needed: any package listed here
# will be matched using str.startswith().

_BLACKLIST = {
  7: [
    'patterns-cloud-admin', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-compute', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-controller', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-network', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'ansible1', # Conflicts with ansible
    'ardana-ceph', # nothing provides ardana-ceph
    'ardana-cephlm', # nothing provides ardana-cephlm
    'ardana-cinderlm', # nothing provides ardana-cinderlm
    'ardana-ui-common', # nothing provides ardana-ui-common
    'ardana-vmfactory', # nothing provides ardana-vmfactory
    'ardana-extensions-ses', # provider ardana-ses obsoletes ardana-extensions-ses
    'crowbar-core-branding-upstream', # Conflicts with SUSE branding
    'suse-openstack-cloud-upstream', # Obsoleted by documentation-* packages
    'suse-openstack-cloud-user', # Obsoleted by documentation-* packages
    'mongodb', # nothing provides mongodb
    'python-docker-py', # provider python-docker obsoletes python-docker-py
    'python-pycryptodome', # python-pycryptodome conflicts with python-pycrypto
    'ruby2.1-rubygem-bson', # nothing provides ruby2.1-rubygem-bson-1_11
    'ruby2.1-rubygem-mongo' # nothing provides ruby2.1-rubygem-mongo
    'openstack-ec2-api' # unresolvable: nothing provides python-urllib3 &gt;= 1.20 needed by python-botocore, (got version 1.16-3.9.2)
    'python-ec2-api' # unresolvable: nothing provides python-urllib3 &gt;= 1.20 needed by python-botocore, (got version 1.16-3.9.2)
    ],
  8: [
    'patterns-cloud-admin', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-compute', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-controller', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-network', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'ansible1', # Conflicts with ansible
    'ardana-ceph', # nothing provides ardana-ceph
    'ardana-cephlm', # nothing provides ardana-cephlm
    'ardana-cinderlm', # nothing provides ardana-cinderlm
    'ardana-ui-common', # nothing provides ardana-ui-common
    'ardana-vmfactory', # nothing provides ardana-vmfactory
    'ardana-extensions-ses', # provider ardana-ses obsoletes ardana-extensions-ses
    'crowbar-core-branding-upstream', # Conflicts with SUSE branding
    'suse-openstack-cloud-upstream', # Obsoleted by documentation-* packages
    'suse-openstack-cloud-user', # Obsoleted by documentation-* packages
    'mongodb', # nothing provides mongodb
    'python-docker-py', # provider python-docker obsoletes python-docker-py
    'python-pycryptodome', # python-pycryptodome conflicts with python-pycrypto
    'ruby2.1-rubygem-bson', # nothing provides ruby2.1-rubygem-bson-1_11
    'ruby2.1-rubygem-mongo' # nothing provides ruby2.1-rubygem-mongo
    ],
  9: [
    'patterns-cloud-admin', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-compute', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-controller', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'patterns-cloud-network', # have choice for product_flavor(suse-openstack-cloud-crowbar) needed by suse-openstack-cloud-crowbar-release: suse-openstack-cloud-crowbar-release-POOL suse-openstack-cloud-crowbar-release-cd
    'crowbar-core-branding-upstream', # Conflicts with SUSE branding
    'octavia-test' # unresolvable: nothing provides octavia-test Devel:Cloud:9{,:Staging}
    ]
  }

# Mapping of IBS project to SUSE OpenStack Cloud release.
_PROJECT_VERSION = {
  'Devel:Cloud:7': 7,
  'Devel:Cloud:8': 8,
  'Devel:Cloud:9': 9,
  'SUSE:SLE-12-SP2:Update:Products:Cloud7': 7,
  'SUSE:SLE-12-SP3:Update:Products:Cloud8': 8,
  'SUSE:SLE-12-SP4:Update:Products:Cloud9': 9
}

# Mapping of IBS project to repository to use.
_PROJECT_REPO = {
  'Devel:Cloud:7': 'SLE_12_SP2',
  'Devel:Cloud:8': 'SLE_12_SP3',
  'Devel:Cloud:9': 'SLE_12_SP4',
  'SUSE:SLE-12-SP2:Update:Products:Cloud7': 'standard',
  'SUSE:SLE-12-SP3:Update:Products:Cloud8': 'standard',
  'SUSE:SLE-12-SP4:Update:Products:Cloud9': 'standard'
}



def get_cloud_version(project):
  """
  Determine the SUSE OpenStack Cloud version we are dealing with from IBS
  project.
  """
  for key in _PROJECT_VERSION:
    if project.startswith(key):
      return _PROJECT_VERSION[key]
  return None


def get_repository(project):
  """
  Determine the package repository to use from IBS project.
  """
  for key in _PROJECT_REPO:
    if project.startswith(key):
      return _PROJECT_REPO[key]
  return None


def find_groupfiles(product_file):
  """
  Extract a list of all group files being included from a product file.
  """
  group_files = []
  f = open(product_file)
  for line in f.readlines():
    if 'xi:include' in line:
      match = re.search('href="(.*\.group)"', line)
      if match:
        group_files.append(os.path.join(os.path.dirname(product_file), match.groups()[0]))
  f.close
  return group_files


def find_packages(search_file):
  """
  Extract a list of packages being pulled in from a .product or .group file.
  """
  packages = set()
  with open(search_file) as f:
    raw = f.read()
  # Group files may not have a DTD
  if not raw.startswith('<?'):
    raw = "<rootnode>\n" + raw + "</rootnode>"
  try:
    tree = ET.fromstring(raw)
  except Exception as e:
    print("Failed to parse %s" % search_file, file=sys.stderr)
    print(e.msg, file=sys.stderr)
  for node in tree.findall('package'):
    packages.add(node.attrib['name'])
  f.close()
  return packages


def check_blacklist(package, cloud_version):
  """
  Check whether a package's name starts with any of the patterns in the black
  list for a given SUSE OpenStack Cloud version.
  """
  for start in _BLACKLIST[cloud_version]:
    if package.startswith(start):
      return True
  return False


def get_buildinfo(project, api, repository, arch, packages):
  """
  Generate a spec from a list of packages and retrieve the buildinfo data for
  that spec from IBS.
  """
  cloud_version = get_cloud_version(project)
  spec = 'Name: _product\n'

  packages.add('qemu-kvm') # unresolvable: have choice for kvm needed by patterns-cloud-compute: kvm qemu-kvm

  packages.add('libpq5') # unresolvable: have choice for libpq.so.5()(64bit) needed by python-psycopg2: libpq5 postgresql12-devel-mini

  if 'patterns-cloud-ardana' in packages:
    # This needs special treatment: we have a choice between atftp and tftp to
    # fullfil cobbler's Requires.
    packages.add('tftp')

    if cloud_version <= 8:
      # have choice for ardana-installer-ui needed by patterns-cloud-ardana: ardana-installer-ui ardana-installer-ui-hpe,
      packages.add('ardana-installer-ui-hpe')
      # have choice for ardana-installer-ui needed by patterns-cloud-ardana: ardana-installer-ui ardana-installer-ui-hpe
      packages.add('ardana-opsconsole-ui-hpe')
      # have choice for venv-openstack-horizon-x86_64 needed by patterns-cloud-ardana: venv-openstack-horizon-hpe-x86_64 venv-openstack-horizon-x86_64
      packages.discard('venv-openstack-horizon')
      packages.add('venv-openstack-horizon-hpe-x86_64')

  for p in packages:
    if p.startswith('venv') and not p.endswith('-x86_64'):
      # These are listed in ardana.group but do not exist
      continue
    if check_blacklist(p, cloud_version):
      continue
    spec += "BuildRequires: %s\n" % p

  # initialize osc configuration
  osc.conf.get_config()

  buildinfo = osc.core.get_buildinfo(api, project, '_product', repository, arch, spec)
  return buildinfo





def process_package_args(arch, api, args):
  """
  Process a user provided IBS project/package(s) combination.
  """
  if len(sys.argv) < 2:
    print("usage: %s -u <project> <package> [ ... <package> ]" % sys.argv[0])
    sys.exit(1)

  project = args[0]
  packages = set(args[1:])
  repository = get_repository(project)
  packages_all = dict()

  buildinfo = get_buildinfo(project, api, repository, arch, packages)

  tree = ET.fromstring(buildinfo)
  bdeps = tree.findall('bdep')

  if len(bdeps) == 0:
    print("Package list generated buildinfo without packages. Raw buildinfo follows.", file=sys.stderr)
    sys.stderr.buffer.write(buildinfo)
    return

  for node in bdeps:
    packages_all[node.attrib['name']] = { 'version':  node.attrib['version'],
                                          'release': node.attrib['release'],
                                          'project': node.attrib['project']}

  for p in sorted(packages_all.keys()):
    print("%s %s %s %s" % (p,
                           packages_all[p]['version'],
                           packages_all[p]['release'],
                           packages_all[p]['project']))


def process_product_files(arch):
  """
  Process one or more *.product files.
  """
  if len(sys.argv) < 2:
    print("usage: %s <product file> [ ... <product file> ]" % sys.argv[0])
    sys.exit(1)

  for product_file in sys.argv[1:]:
    packages_all = dict()
    package_files = [product_file]
    package_files.extend(find_groupfiles(product_file))


    if os.path.exists(os.path.dirname(product_file)):
      project = osc.core.store_read_project(os.path.dirname(product_file))
      api = osc.core.store_read_apiurl(os.path.dirname(product_file))
    else:
      # relative path with no leading component
      project = osc.core.store_read_project(os.path.dirname(os.curdir))
      api = osc.core.store_read_apiurl(os.path.dirname(os.curdir))

    repository = get_repository(project)

    for package_file in package_files:
      packages = find_packages(package_file)
      buildinfo = get_buildinfo(project, api, repository, arch, packages)

      tree = ET.fromstring(buildinfo)
      bdeps = tree.findall('bdep')

      if len(bdeps) == 0:
        print("%s generated buildinfo without packages. Raw buildinfo follows." % package_file, file=sys.stderr)
        sys.stderr.buffer.write(buildinfo)
        continue

      for node in bdeps:
        packages_all[node.attrib['name']] = { 'version':  node.attrib['version'],
                                              'release': node.attrib['release'],
                                              'project': node.attrib['project']}

    for p in sorted(packages_all.keys()):
      print("%s %s %s %s" % (p,
                             packages_all[p]['version'],
                             packages_all[p]['release'],
                             packages_all[p]['project']))



parser = optparse.OptionParser(
  version="0.1.0",
  description=(
    "This script operates on *.product files for SUSE OpenStack cloud and will"
    " attempt to determine the provenance (i.e. IBS project) of all packages"
    " pulled in by a particular product. Alternatively, the -u option can be"
    " used to specify a project and list of packages"),
  usage=(
    "\n    %s <product file> [ ... <product file> ]\n"
    "    %s -u <project> <package> [ ... <package> ]" % (sys.argv[0], sys.argv[0])
  ))

parser.add_option(
      "-u",
      "--user-packages",
      action="store_true",
      default=False,
      help="Instead of parsing product files, operate on a user provided list of packages.")

parser.add_option(
      "-A",
      "--api",
        default="https://api.suse.de",
        help="API URL to use in --user-packages mode.")

(options, args) = parser.parse_args(sys.argv[1:])

arch = 'x86_64'

if options.user_packages:
  process_package_args(arch, options.api, args)
else:
  process_product_files(arch)

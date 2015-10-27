#! /usr/bin/env python
# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

import argparse
import os
import re
import sys

import sh

#
# Example of use
# ==============
#
# If we have a network with three nodes (N1, N2, N3), we can use
# iscsictl script to deploy different iscsi configuations.
#
# Use case 1: Single device
# -------------------------
#
# Create the target service in N1
# ./iscsictl.py --service target --host N1
#
# Discover and connect both initiators
# ./iscsictl.py --service initiator --target_host N1 --host N2
# ./iscsictl.py --service initiator --target_host N1 --host N3
#
#
# Use case 2: Add a new target
# ----------------------------
#
# Create second target in N1
# ./iscsictl.py --service target --host N1 --device /dev/loop1 --id id02
#
# Discover and connect both initiators
# ./iscsictl.py --service initiator --target_host N1 --host N2 --id id02
# ./iscsictl.py --service initiator --target_host N1 --host N3 --id id02
#
#
# Use case 3: Share a block device
# --------------------------------
#
# Create a target for a existent block device:
# ./iscsictl.py --service target --host N1 --device /dev/sdc --id id03
#
# Discover and connect both initiators
# ./iscsictl.py --service initiator --target_host N1 --host N2 --id id03
# ./iscsictl.py --service initiator --target_host N1 --host N3 --id id03
#

# open stdout in unbuffered mode
sys.stdout = os.fdopen(sys.stdout.fileno(), "wb", 0)


class Key(object):
    """Class used to create and reuse temporal SSH keys."""

    def __init__(self, name=None):
        """Create a new key without passphrase if there is any."""
        if not name:
            name = '.iscsi_fake_id_dsa'

        self.name = name

        if not os.path.exists(self.name):
            sh.ssh_keygen('-t', 'dsa', '-f', self.name, '-N', '')

        os.chmod(self.key(), 0600)
        os.chmod(self.pub_key(), 0600)

    def key(self):
        """Return the private key filename."""
        return self.name

    def pub_key(self):
        """Return the public key filename."""
        return self.name + '.pub'

    def clean_key(self):
        """Remove private and public temporal keys."""
        if os.path.exists(self.key()):
            os.remove(self.key())
            os.remove(self.pub_key())


class SSH(object):
    """Simplify SSH connections to a remote machine."""

    def __init__(self, host, user, password, key=None):
        if not key:
            key = Key(name='.%s_iscsi_fake_id_dsa' % host)

        self.host = host
        self.user = user
        self.password = password
        self.key = key

        self._copy_id = False
        self._connect = None

    def ssh_copy_id(self):
        """Copy a fake key (key without passphrase) into a node."""
        # If the ID is already there, do nothing
        if self._copy_id:
            return

        def _interact(char, stdin):
            sys.stdout.write(char.encode())
            _interact.aggregated += char
            if _interact.aggregated.endswith("Password: "):
                stdin.put('%s\n' % self.password)
            elif char == '\n':
                _interact.aggregated = ''

        _interact.aggregated = ''
        sh.ssh_copy_id('-i', self.key.pub_key(),
                       '-o', 'StrictHostKeyChecking=no',
                       '-o', 'UserKnownHostsFile=/dev/null',
                       '%s@%s' % (self.user, self.host),
                       _out=_interact, _out_bufsize=0, _tty_in=True)

    def clean_key(self):
        """Remove key from the remote server."""
        if not self._connect:
            return

        key = "'%s'" % open(self.key.pub_key()).read().strip()
        self._connect.grep('-v', key, '~/.ssh/authorized_keys',
                           '> ~/.ssh/authorized_keys.TMP')
        self._connect.cp('-a', '~/.ssh/authorized_keys',
                         '~/.ssh/authorized_keys.BAK')
        self._connect.mv('~/.ssh/authorized_keys.TMP',
                         '~/.ssh/authorized_keys')
        self._connect = None

        # Remove locally generated keys
        self.key.clean_key()

    def connect(self):
        """Create an SSH connection to the remote host."""
        if not self._copy_id:
            self.ssh_copy_id()

        self._connect = sh.ssh.bake('-i', self.key.key(),
                                    '-o', 'StrictHostKeyChecking=no',
                                    '-o', 'UserKnownHostsFile=/dev/null',
                                    '%s@%s' % (self.user, self.host))
        return self._connect

    def __getattr__(self, name):
        """Delegate missing attributes to local connection."""
        if not self._connect:
            self.connect()
        if self._connect:
            return getattr(self._connect, name)


class ISCSI(object):
    """Class for basic iSCSI management."""

    START = 'start'
    STOP = 'stop'
    RESTART = 'restart'

    def __init__(self, ssh):
        self.ssh = ssh

    def service(self, service, action):
        if action == ISCSI.START:
            self.ssh.systemctl('enable', '%s.service' % service)
            self.ssh.systemctl('start', '%s.service' % service)
        elif action == ISCSI.STOP:
            self.ssh.systemctl('stop', '%s.service' % service)
            self.ssh.systemctl('disable', '%s.service' % service)
        elif action == ISCSI.RESTART:
            self.ssh.systemctl('restart', '%s.service' % service)
        else:
            raise Exception('Service action not recognized.')

    def zypper(self, package):
        self.ssh.zypper('--non-interactive', 'install',
                        '--no-recommends', package)

    def append_cfg(self, fname, lines):
        """Append only new lines in a configuration file."""
        cfg = str(self.ssh.cat(fname))

        # Only append the line if is not there
        for line in lines:
            if not re.search('^%s$' % line, cfg, re.MULTILINE):
                self.ssh.echo('-e', line, '>> %s' % fname)

    def remove_cfg(self, fname, lines):
        """Remove lines in a configuration file."""
        cfg = str(self.ssh.cat(fname))

        # Remove all matching lines, appending and EOL
        for line in lines:
            cfg = cfg.replace(line + '\n', '')

        # Make a backup of the configuration file and replace the
        # content.  Check that the new content is the expected and if
        # so, remove the backup.
        fbackup = fname + '.BACKUP'
        self.ssh.cp('-a', fname, fbackup)
        self.ssh.echo('-e', '-n', '"%s"' % cfg, '> %s' % fname)
        new_cfg = str(self.ssh.cat(fname))
        if cfg != new_cfg:
            fedit = fname + '.EDIT'
            self.ssh.cp('-a', fname, fedit)
            self.ssh.mv(fbackup, fname)
            raise Exception('Configuration file reverted. '
                            'Check %s for more details' % fedit)
        else:
            self.ssh.rm(fbackup)

    def deploy(self):
        raise NotImplementedError('Deploy method not implemented')


class Target(ISCSI):
    """Define and manage an iSCSI target node."""

    def __init__(self, ssh, device, path, iqn_id, size=1, reuse=False):
        super(Target, self).__init__(ssh)

        self.device = device
        self.path = path
        self.iqn_id = iqn_id
        # `size` is expressed in mega (M)
        self.size = size
        self.reuse = reuse

    def find_loop(self, loop):
        """Find an attached loop devide."""
        pattern = re.compile(r'^(/dev/loop\d+):.*\((.*)\)')
        for line in self.ssh.losetup('-a'):
            ldev, lfile = pattern.match(line).groups()
            if loop == ldev:
                return (ldev, lfile)

    def destroy_loop(self, loop):
        """Destroy loopback devices."""
        is_in = self.find_loop(loop)
        if is_in:
            _, path = is_in
            out = str(self.ssh.losetup('-d', loop))
            if "can't delete" in out:
                raise Exception(out)
            self.ssh.rm(path)

    def create_loop(self, loop, path, size):
        """Create a new loopback device."""
        is_in = self.find_loop(loop)
        if is_in and self.reuse:
            return
        elif is_in:
            raise Exception('loop device already installed: %s / %s' %
                            is_in)

        self.ssh.dd('if=/dev/zero', 'of=%s' % path, 'bs=1M',
                    'count=%d' % size)
        self.ssh.fdisk(sh.echo('-e', r'o\nn\np\n1\n\n\nw'), path)
        self.ssh.losetup(loop, path)

        is_in = self.find_loop(loop)
        if not is_in:
            raise Exception('fail to create loop device: %s / %s' %
                            is_in)

    def deploy(self):
        """Deploy, configure and launch iSCSI target."""
        print 'Installing lio-utils ...'
        self.zypper('lio-utils')
        self.service('target', ISCSI.START)

        if self.device.startswith('/dev/loop'):
            if self.path:
                print 'Creating loopback ...'
                self.create_loop(self.device, self.path, self.size)
            else:
                raise Exception('Please, provide a path for a loop device')

        # Detecting IP
        print 'Looking for host IP ...'
        ip = str(self.ssh.ip('a', 's', 'eth0'))
        ip = re.findall(r'inet (\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/\d+', ip)
        if ip:
            ip = ip[0]
        else:
            raise Exception('IP address not found')

        iqn = 'iqn.2015-01.qa.cloud.suse.de:%s' % self.iqn_id

        print 'Registering target for %s ...' % iqn
        self.ssh.tcm_node('--block', 'iblock_0/id01', '/dev/loop0')
        self.ssh.lio_node('--addlun', iqn, '1', '0', 'iscsi_port',
                          'iblock_0/id01')
        self.ssh.lio_node('--addnp', iqn, '1', '%s:3260' % ip)
        self.ssh.lio_node('--disableauth', iqn, '1')
        self.ssh.lio_node('--enabletpg', iqn, '1')

        # Persist configuration
        print 'Persisting configuration ...'
        self.ssh.tcm_dump('--b=OVERWRITE')

        # Add in /etc/rc.d/boot.local
        if self.device.startswith('/dev/loop'):
            print 'Adding loopback to boot.local ...'
            lines = (
                'losetup %s %s' % (self.device, self.path),
            )
            self.append_cfg('/etc/rc.d/boot.local', lines)

        # Check if the device is exported
        print 'Checking that the target is exported ...'
        result = str(self.ssh.lio_node('--listtargetnames'))
        if iqn not in result:
            raise Exception('Unable to deploy the iSCSI target')


class Initiator(ISCSI):
    """Define and manage an iSCSI initiator node."""

    # For now, we are going to use the discovery option for iSCSI to
    # populate the database.  This simplify the deployment of a basic
    # iSCSI scenario, with a single target point and multiple
    # initiators.

    def __init__(self, ssh, target_ssh, iqn_id):
        """Initialize the Initiator instance with an ip and a mount point."""
        super(Initiator, self).__init__(ssh)
        self.target_ssh = target_ssh
        self.iqn_id = iqn_id
        self.name = None

    def deploy(self):
        """Deploy, configure and persist an iSCSI initiator."""
        print 'Installing open-iscsi ...'
        self.zypper('open-iscsi')

        # Default configuration only takes care of autentication
        print 'Configuring open-iscsi for automatic startup ...'
        lines = (
            'node.startup = automatic',
        )
        self.append_cfg('/etc/iscsid.conf', lines)

        # Persist and start the service
        print 'Reloading the configuration ...'
        self.service('iscsid', ISCSI.START)
        self.service('iscsid', ISCSI.RESTART)

        iqn = 'iqn.2015-01.qa.cloud.suse.de:%s' % self.iqn_id

        # Get the initiator name for the ACL
        print 'Detecting initiator name ...'
        initiator = str(self.ssh.cat('/etc/iscsi/initiatorname.iscsi'))
        initiator = re.findall(r'InitiatorName=(iqn.*)', initiator)
        if initiator:
            initiator = initiator[0]
        else:
            raise Exception('Initiator name not found')

        # Add the initiator name in the target ACL
        print 'Adding initiator name [%s] in target ACL ...' % initiator
        try:
            self.target_ssh.lio_node('--dellunacl', iqn, '1',
                                     initiator, '0')
        except:
            pass
        finally:
            self.target_ssh.lio_node('--addlunacl', iqn, '1',
                                     initiator, '0', '0')
            self.target_ssh.tcm_dump('--b=OVERWRITE')

        # Discovery and login
        print 'Initiator discovery and login ...'
        discovered = self.ssh.iscsiadm('-m', 'discovery', '--type=st',
                                       '--portal=%s' % self.target_ssh.host)
        for name in discovered.split('\n'):
            _, name = name.split()
            if self.iqn_id in name:
                self.name = name
                break

        if not self.name:
            raise Exception('Target with ID %s not found: [%s]' %
                            (self.iqn_id, discovered))

        self.ssh.iscsiadm('-m', 'node', '-n', self.name, '--login')

    def logout(self):
        """Logout shared device."""
        self.ssh.iscsiadm('-m', 'node', '-n', self.name, '--logout')


def test():
    """Testing against local mkcloud."""
    # Adming node is going to be the target
    admin = SSH('192.168.124.10', 'root', 'linux')
    # Initiators
    node1 = SSH('192.168.124.81', 'root', 'linux')
    node2 = SSH('192.168.124.82', 'root', 'linux')

    target = Target(admin)
    target.deploy()

    initiator1 = Initiator(node1, admin)
    initiator1.deploy()
    assert '/dev/sda' in node1.lsscsi(), 'iSCSI device not found in node1'

    initiator2 = Initiator(node2, admin)
    initiator2.deploy()
    assert '/dev/sda' in node2.lsscsi(), 'iSCSI device not found in node2'

    # Reboot and reconnect. The devices are still there
    node1.reboot()
    node2.reboot()

    from time import sleep
    sleep(60)

    node1 = SSH('192.168.124.81', 'root', 'linux')
    node2 = SSH('192.168.124.82', 'root', 'linux')
    assert '/dev/sda' in node1.lsscsi(), 'iSCSI device not found in node1'
    assert '/dev/sda' in node2.lsscsi(), 'iSCSI device not found in node2'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Help iSCSI deployment.')
    parser.add_argument('-s', '--service', choices=['target', 'initiator'],
                        default=None,
                        help='type of service deployment')
    parser.add_argument('-o', '--host', default=None,
                        help='Host address for the machine to configure')
    parser.add_argument('-t', '--target_host', default=None,
                        help='Host address where the initiator search the '
                        'target')
    parser.add_argument('-d', '--device', default='/dev/loop0',
                        help='Device for the target (/dev/loop0)')
    parser.add_argument('-r', '--reuse', action='store_true', default=False,
                        help='If the loop device is there, reuse it')
    parser.add_argument('--id', default='id01',
                        help='Suffix ID for the iSCSI name')
    parser.add_argument('--test', action='store_true', default=False,
                        help='Test the code against a local mkcloud '
                        'installation')
    args = parser.parse_args()

    if args.test:
        test()
    else:
        if not args.service:
            msg = 'Please, provide a kind of service: {target, initiator}'
            parser.error(msg)
        if not args.host:
            msg = 'Please, provide the host name or IP address of the ' \
                  'machine to be configured'
            parser.error(msg)
        if args.service == 'initiator' and not args.target_host:
            msg = 'Please, provide the host name or IP address of the ' \
                  'machine with the target role'
            parser.error(msg)

        if args.service == 'target':
            node = SSH(args.host, 'root', 'linux')
            path = '/tmp/%s-iscsi.loop' % args.id \
                   if args.device.startswith('/dev/loop') else None
            try:
                target = Target(node, args.device, path, args.id,
                                reuse=args.reuse)
                target.deploy()
            finally:
                node.clean_key()
        elif args.service == 'initiator':
            node = SSH(args.host, 'root', 'linux')
            node_target = SSH(args.target_host, 'root', 'linux')
            try:
                initiator = Initiator(node, node_target, args.id)
                initiator.deploy()
            finally:
                node.clean_key()

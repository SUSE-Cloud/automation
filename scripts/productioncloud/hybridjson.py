# Copyright 2014 Hewlett-Packard Development Company, L.P.
# Copyright 2014-2015 SUSE Linux Products GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

from oslo_config import cfg
from keystone import config
from keystone.assignment.backends import sql as sql_assign
from keystone.assignment.role_backends import sql as sql_role
from keystone.common import sql
from keystone.common import manager
from keystone import exception
from keystone.i18n import _
from keystone.identity.backends import ldap as ldap_backend

from oslo_utils import importutils
from oslo_log import log
import yaml

LOG = log.getLogger(__name__)

hybrid_opts = [
    cfg.ListOpt('default_roles',
                default=['_member_', ],
                help='List of roles assigned by default to an LDAP user'),
    cfg.StrOpt('default_project',
               default='demo',
               help='Default project'),
    cfg.StrOpt('default_domain',
               default='default',
               deprecated_name='default_domain',
               deprecated_for_removal=True,
               help='(Deprecated) Default domain. Use "default_domain_id" '
                    'instead.'),
]

CONF = config.CONF
CONF.register_opts(hybrid_opts, 'ldap_hybrid')


class Assignment(sql_assign.Assignment):
    _default_roles = list()
    _default_project = None

    def __init__(self, *args, **kwargs):
        super(Assignment, self).__init__(*args, **kwargs)
        self.ldap_user = ldap_backend.UserApi(CONF)
	with open('/etc/keystone/user-project-map.json', 'r') as f:
            self.userprojectmap = yaml.load(f)
        self.resource_driver = manager.load_driver(
            'keystone.resource', self.default_resource_driver())

    def _get_metadata(self, user_id=None, tenant_id=None,
                      domain_id=None, group_id=None, session=None):
        # We only want to apply 'default_roles' to users from LDAP, so
        # check if this is an LDAP User first
        is_ldap = False
        try:
            self.ldap_user.get(user_id)
        except exception.UserNotFound:
            # Not an LDAP User
            pass
        else:
            is_ldap = True

        try:
            res = super(Assignment, self)._get_metadata(
                user_id, tenant_id, domain_id, group_id, session)
        except exception.MetadataNotFound:
            LOG.warning('xxhybrid MetadataNotFound: user=%(user)s', {'user': user_id})
            if self.default_project_id == tenant_id and is_ldap:
                LOG.warning('xxhybrid MetadataNotFound eq')
                return {
                    'roles': [
                        {'id': role_id} for role_id in self.default_roles
                    ]
                }
            else:
                LOG.warning('xxhybrid MetadataNotFound raise')
                raise
        else:
            LOG.warning('xxhybrid else: user=%(user)s', {'user': user_id})
            if is_ldap:
                roles = res.get('roles', [])
                res['roles'] = roles + [
                    {'id': role_id} for role_id in self.default_roles
                ]
            return res

    @property
    def default_project(self):
        if self._default_project is None:
            self._default_project = self.resource_driver.get_project_by_name(
                CONF.ldap_hybrid.default_project,
                CONF.identity.default_domain_id)
        return dict(self._default_project)

    @property
    def default_project_id(self):
        return self.default_project['id']

    @property
    def default_roles(self):
        if not self._default_roles:
            with sql.transaction() as session:
                query = session.query(sql_role.RoleTable)
                query = query.filter(sql_role.RoleTable.name.in_(
                    CONF.ldap_hybrid.default_roles))
                role_refs = query.all()

            if len(role_refs) != len(CONF.ldap_hybrid.default_roles):
                raise exception.RoleNotFound(
                    message=_('Could not find one or more roles: %s') %
                    ', '.join(CONF.ldap_hybrid.default_roles))

            self._default_roles = [role_ref.id for role_ref in role_refs]
        return self._default_roles

    def list_role_assignments(self, role_id=None, user_id=None, group_ids=None,
                              domain_id=None, project_ids=None,
                              inherited_to_projects=None):
        role_assignments = super(Assignment, self).list_role_assignments(
            role_id=role_id, user_id=user_id, group_ids=group_ids,
            domain_id=domain_id, project_ids=project_ids,
            inherited_to_projects=inherited_to_projects)
        if user_id:
            ldap_users = [self.ldap_user.get_filtered(user_id)]
        else:
            ldap_users = self.ldap_user.get_all_filtered(None)
        # This will be really slow for setups with lots of users, but there
        # is not other way to achieve it currently
        for user in ldap_users:
            # Skip LDAP User if it already as an assignemt, else add the default
            # assignment
            if any(a for a in role_assignments if
                   ('user_id'in a and a['user_id'] == user['id'])):
                continue
            else:
                for role in self.default_roles:
                    role_assignments.append({
                        'role_id': role,
                        'project_id': self.default_project_id,
                        'user_id': user['id']
                    })
        return role_assignments

    def list_project_ids_for_user(self, user_id, group_ids, hints):
        project_ids = super(Assignment, self).list_project_ids_for_user(
            user_id, group_ids, hints)

        # Make sure the default project is in the project list for the user
        # user_id
        for project_id in project_ids:
            if project_id == self.default_project_id:
                return project_ids

        # We only want to apply 'default_project' to users from LDAP, so
        # check if this is an LDAP User first
        try:
            self.ldap_user.get(user_id)
        except exception.UserNotFound:
            # Not an LDAP User
            pass
        else:
            project_ids.append(self.default_project_id)

        return project_ids

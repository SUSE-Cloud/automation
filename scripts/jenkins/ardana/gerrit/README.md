# Gerrit automation scripts

The python scripts in this folder are used to implement a series of automated processes
targeting Ardana Gerrit repositories tracked by [IBS packages](#source-tracking-packages):

* building IBS packages corresponding to Gerrit changes, for testing purposes
* posting comments and/or label values for open Gerrit changes
* merging  Gerrit changes
* implementing event handling mechanisms supporting inter- and intra-project dependencies

All these processes are tightly inter-related, as they all implement different sides of the
[Gerrit CI Strategy](https://github.com/SUSE/cloud-specs/blob/master/specs/release-independent/gerrit-ci-strategy.rst).

Most of the complexity built into these scripts come from the need to manage dependencies
between Gerrit changes, both explicit (indicated via `Depends-On` statements present in the
commit message, usually indicating cross-project dependencies) or implicit (uploaded together
or rebased one on top of another). This affects the way test packages are built, the criteria
a change must meet in order to be merged successfully and, last but not least, the effect that
updating or merging a Gerrit change may have on other Gerrit changes.

## Gerrit dependencies

Most of the time, a Gerrit code change can be verified and merged on its own, implicitly depending
only on the contents of the target development git branch against which it was based when it was created.
At other times, a group of two or more Gerrit code changes are linked together by dependency relationships,
either functional or structural. At the same time, these dependency relationships may be
be spanned across Gerrit projects.

## Implicit dependencies

An _implicit dependency_ links two or more Gerrit changes in the same Gerrit project when a direct parent-child
relationship exists between their associated git commits. Two simple ways of creating such a dependency relationship,
are uploading Gerrit changes together, e.g.:

```
<file changes for A>
git commit
<file changes for B>
git commit
git review

```

or rebasing one change on top of another, at a later time, e.g.:

```
git review -d <change A>
git review -d <change B>
git rebase <branch for change A>
git review
```

Implicit dependencies may be structural - they both change the same file or set of files in a way that would otherwise
create conflicts if merged separately - or purely functional, in which case they may also be modeled as
[explicit dependencies](#explicit-dependencies), although that is not recommended, because functional dependencies can
easily turn into structural ones over their lifetime.

Gerrit has built-in support for implicit dependencies. In Gerrit nomenclature these are also referred to as changes
that are _submitted together_, because they can be merged together as a group when they meet the required criteria,
or as _related changes_.

## Explicit dependencies

An _explicit dependency_, also known as a _cross-project dependency_ links two or more Gerrit changes in different
Gerrit projects by including explicit references in the commit message, using one of the following supported formats:

* Gerrit change ID (deprecated):

```
Depends-On: I75b266da99e7dcb948f10d182e7f00bb3debfac6

```

* Gerrit change URL (recommended):

```
Depends-On: https://gerrit.suse.provo.cloud/#/c/1234
```

or:

```
Depends-On: https://gerrit.suse.provo.cloud/1234
```

Explicit dependencies are purely functional. While it is possible to use an explicit dependency between Gerrit changes
targeting the same Gerrit project, this is not recommended, because it may lead to merge conflicts if they target the
same file or set of files. An [implicit dependency](#implicit-dependencies) should be used in that case.

## Source tracking packages

Starting with cloud 8, several of the Ardana Gerrit projects are _source-tracked_ by IBS packages.
The mapping between IBS packages and Gerrit projects is tracked in the [gerrit-settings.json](gerrit-settings.json)
file, which is used by python scripts in this folder, as well as by Jenkins jobs triggered by
Gerrit events.

Source tracking essentially involves the following:

* the IBS cloud staging project includes a package corresponding to each of the target Gerrit projects,
containing sources from the tracked git branch (e.g. the [Devel:Cloud:8:Staging/ardana-keystone](https://build.suse.de/package/show/Devel:Cloud:8:Staging/ardana-keystone)
package corresponds to the _stable/pike_ branch of the [keystone-ansible](http://git.suse.provo.cloud/cgit/ardana/keystone-ansible/) Ardana Gerrit project.
* every time a change is merged in Gerrit in one of these projects, the [ardana-trigger-trackupstream](https://ci.suse.de/job/ardana-trigger-trackupstream/)
Jenkins job is triggered to rebuild the associated IBS package to reflect the latest sources in the Gerrit repository
and the tracked git branch.
* consequently, the automated testing validating open Gerrit changes always builds packages corresponding to the most
recent Gerrit repository state available at the time the testing process starts.

## Building test IBS packages

The [build_test_package.py](build_test_package.py) script can be used to build test RPM packages in IBS
corresponding to one or more Gerrit changes, e.g.:

```
./build_test_package.py --homeproject home:username -c 1234 -c 1235
```

For this to work, the `osc` utility needs to be correctly installed and configured on the local host.

The process of building test RPM packages can be summarized as follows:

* first, a complete list of Gerrit change dependencies is compiled, collected recursively by following the chains of
[explicit](#explicit-dependencies) and [implicit](#implicit-dependencies) dependencies.
* next, the Gerrit changes are merged together on top of the target branch:
  * a local git clone is created for every encountered project and a `test-branch` branch is set up based on the
  tip of the branch that the packages are targeting
  * merged Gerrit changes are skipped, because they are already included in the `test-branch` branch
  * Gerrit changes that are not mapped to a corresponding IBS package according to
  [gerrit-settings.json](gerrit-settings.json) are skipped
  * all other changes are merged on top of the `test-branch` branch
* finally, OBS packages corresponding to collected Gerrit changes are built, starting as copies of their existing IBS
counterparts taken from the Cloud non-staging project (also configured in [gerrit-settings.json](gerrit-settings.json) unless
otherwise specified), and updated to package the sources in the local git clones and the populated `test-branch` branch.
Furthermore, remaining packages in the [gerrit-settings.json](gerrit-settings.json) list, that do not have corresponding
Gerrit changes in the list of changes collected at the first step, are also updated to include the latest merged sources
in Gerrit, where this is needed. 


## Posting Gerrit comments and/or labels

The [gerrit_review.py](gerrit_review.py) script can be used to post comments and/or vote on Gerrit changes, e.g.:

```
./gerrit_review.py --label Code-Review --vote +1 --message "LGTM" 1234
```

This script requires [Gerrit credentials](#gerrit-credentials) to be configured on the host.

```
machine gerrit.suse.provo.cloud
  login gerrituser
  password QLvl2Ktft6n3dFGFJ+VbGwvrAdU1kQsNVrzniZt8lA
```

## Merging Gerrit changes

The [gerrit_merge.py](gerrit_merge.py) script can be used to merge a Gerrit change, provided that it
meets the required criteria, e.g.:

```
./gerrit_merge.py 1234
```

This script requires [Gerrit credentials](#gerrit-credentials) to be configured on the host.

The following criteria must be met by a Gerrit change REST API object in order to be merged:

1. the `status` value must be `NEW` (not `MERGED` or `ABANDONED`, obviously)
2. the `mergeable` flag must be set, meaning there are no merge conflicts
between the Gerrit change and the target branch.
3. the `submittable` flag must be set, meaning that the change has been
approved by the project submit rules configured on the Gerrit server, In the case of
`gerrit.suse.provo.cloud`, these rules are:

 * at least one `Code-Review+2` label value
 * no `Code-Review-2` label values
 * at least one `Verified+2` label value
 * no `Verified-2` label value
 * at least one `Workflow+1` label value
 * no `Workflow-1` label value

*NOTE*: the `submittable` and `mergeable` flags do not reflect the status of [implicit dependencies](#implicit-dependencies),
when these are present. These flags only reflect the status of the change on its own.

*UPDATE*: with the introduction of the `QE-Review` label, the `gerrit.suse.provo.cloud`
submit rules were modified to also include the following for branches corresponding to released Cloud versions:

 * at least one `QE-Review+1` label value
 * no `QE-Review-1` label values

4. all changes representing direct and indirect [implicit](#implicit-dependencies) and [explicit](#explicit-dependencies)
dependencies are merged.

These same criteria are reflected in the way [test IBS packages are built](#building-test-ibs-packages)
and [dependency triggered events are handled](#handling-gerrit-dependency-events).

## Handling Gerrit dependency events

Whenever a Gerrit change is updated with a new patchset, or merged, the other Gerrit
changes that depend on it, either directly or indirectly, need to be re-checked.
Depending on the trigger event, these Gerrit changes may themselves end up being
merged or may need to be re-validated by the CI.

These cause-effect relationships are modeled based on the same criteria used to [merge Gerrit changes](#merging-gerrit-changes)
and to [build test IBS packages](#building-test-ibs-packages) for the CI and implemented
by the [gerit_handle_event.py](gerit_handle_event.py) script, which can also be launched
manually, e.g.:

```
./gerrit_handle_event.py 1234 merged
```

for a merged change, or:

```
./gerrit_handle_event.py 1234 updated
```

for a newly updated patchset.

This script requires [Gerrit credentials](#gerrit-credentials) to be configured on the host.


## Gerrit credentials

Scripts that perform any type of update on Gerrit changes require that the `~/.netrc` file be populated
with valid HTTP Gerrit credentials, e.g.:

```
machine gerrit.suse.provo.cloud
  login gerrituser
  password QLvl2Ktft6n3dFGFJ+VbGwvrAdU1kQsNVrzniZt8lA
```

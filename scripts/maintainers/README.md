# Maintainer List Generator scripts

This directory contains scripts for generating (mostly complete) lists
of maintainers for packages in the following SUSE OpenStack Cloud products:

* SUSE OpenStack Cloud 7
* SUSE OpenStack Cloud 8
* SUSE OpenStack Cloud 9

For these scripts to work you need access to SUSE's internal OBS
instance. The lists contain the following data:

* `package`: The package's name in IBS
* `project`: The IBS project the package is drawn from
* `maintainer`: The package's maintainer(s)
* `bugowner`: The package's bugowner(s)

## Scripts (in order of usage)

* `genmaintainers.sh` - main entry point. Will run all the other scripts.
* `cloudpackages.py` - generates a list of packages and the project they
                       come from on the basis of the `*.product` files
                       in a `_product` package.
* `canonicalpac.pl` - sanitizes package names in the `cloudpackages.py`
                      output by figuring out by substituting the
                      defining OBS package name/spec name for any sub
                      package listed.
* `parse_maintainers.pl` - parses `osc maintainer` output and generates
                           a cleanly formatted table on from it.

# Usage

```
genmaintainers.sh <SUSE Cloud Version> <working directory>
```

where _SUSE Cloud Version_ is one of _7_, _8_ or _9_ and _working
directory_ specifies an arbitrary working directory to be used for
storing temporary files and the final list of maintainers. Working
directories between runs, which reduces run time a bit since some
temporary data is shared.

Example:

```
./genmaintainers.sh 7 /tmp/maintainers
./genmaintainers.sh 8 /tmp/maintainers
./genmaintainers.sh 9 /tmp/maintainers
```

Running these  3 commands will create the directory `/tmp/maintainers`
and write the list of maintainers for Cloud 7, Cloud 8 and Cloud 9 to
`/tmp/maintainers/maintainers-Devel:Cloud:7`,
`/tmp/maintainers/maintainers-Devel:Cloud:8` and
`/tmp/maintainers/maintainers-Devel:Cloud:9`, respectively.

Please note that one single run of `genmaintainers.sh` takes about 30 minutes
to complete since it issues a large number of OBS API requests.

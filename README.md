# supportutils-plugin-ses

Plugin for supportutils which gathers log files and other useful state from
SUSE Enterprise Storage systems.

## Development & Maintenance

### Branches

The master branch is where development for the latest SES version happens.
Right now (2019-11-13), that's SES7.  Any new functionality needed for SES7
should thus go straight into master.  If it's also needed for SES6, it should
be cherry picked from master to the ses6 branch.  Likewise SES5 to the ses5
branch.  If some change is only applicable for an older release, it's fine
to just do the work straight in the relevant branch.

### The RPM List

The file ses-rpm-list includes a list of SUSE Enterprise Storage RPMs, which
we run `rpm -V` against.  This needs to be kept up to date with the packages
shipped in each SES release.  To do this, mount the relevant SES DVD image,
then run `update-rpm-list.sh`, check to ensure ses-rpm-list looks sane, then
commit that change.

### Packaging

supportutils-plugin-ses is packaged as an RPM.  Maintenance of the spec file
and changelogs happens in IBS with changelogs auto-generated from git commits.
There's a Makefile in IBS to help with packaging, so once you've checked out
the supportutils-plugin-ses package from IBS, running `make` will pull in the
latest updates from github, then it's just `isc ar ; isc ci` to commit the
change to the IBS project.  Do check the changelog though and ensure it looks
clean, and tweak if necessary.

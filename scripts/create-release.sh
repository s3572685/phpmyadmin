#!/bin/sh
#
# vim: expandtab sw=4 ts=4 sts=4:
#

# More documentation about making a release is available at:
# http://wiki.phpmyadmin.net/pma/Releasing

# Fail on undefined variables
set -u
# Fail on failure
set -e

KITS="all-languages english"
COMPRESSIONS="zip-7z tbz txz tgz 7z"

if [ $# -lt 2 ]
then
  echo "Usages:"
  echo "  create-release.sh <version> <from_branch> [--tag] [--stable]"
  echo ""
  echo "If --tag is specified, release tag is automatically created (use this for all releases including pre-releases)"
  echo "If --stable is specified, the STABLE branch is updated with this release"
  echo ""
  echo "Examples:"
  echo "  create-release.sh 2.9.0-rc1 QA_2_9"
  echo "  create-release.sh 2.9.0 MAINT_2_9_0 --tag --stable"
  exit 65
fi

# Process parameters

version=""
branch=""
do_tag=0
do_stable=0

while [ $# -gt 0 ] ; do
    case "$1" in
        --tag)
            do_tag=1
            ;;
        --stable)
            do_stable=1
            ;;
        *)
            if [ -z "$version" ] ; then
                version="$1"
            elif [ -z "$branch" ] ; then
                branch="$1"
            else
                echo "Unknown parameter: $1!"
                exit 1
            fi
    esac
    shift
done

if [ -z "$version" -o -z "$branch" ] ; then
    echo "Branch and version have to be specified!"
    exit 1
fi

# Checks whether remote branch has local tracking branch
ensure_local_branch() {
    if ! git branch | grep -q '^..'"$1"'$' ; then
        git branch --track $1 origin/$1
    fi
}

# Marks current head of given branch as head of other branch
# Used for STABLE tracking
mark_as_release() {
    branch=$1
    rel_branch=$2
    echo "* Marking release as $rel_branch"
    ensure_local_branch $rel_branch
    git checkout $rel_branch
    git merge -s recursive -X theirs $branch
    git checkout master
}

# Ensure we have tracking branch
ensure_local_branch $branch

# Check if we're releasing older
if [ -n "`git ls-files $branch -- libraries/Config.class.php`" ] ; then
    CONFIG_LIB=libraries/Config.php
else
    CONFIG_LIB=libraries/Config.class.php
fi

cat <<END

Please ensure you have incremented rc count or version in the repository :
     - in $CONFIG_LIB PMA\libraries\Config::__constructor() the line
          " \$this->set( 'PMA_VERSION', '$version' ); "
     - in doc/conf.py the line
          " version = '$version' "
     - in README
     - set release date in ChangeLog

Continue (y/n)?
END
read do_release

if [ "$do_release" != 'y' ]; then
    exit 100
fi

# Create working copy
mkdir -p release
workdir=release/phpMyAdmin-$version
if [ -d $workdir ] ; then
    echo "Working directory '$workdir' already exists, please move it out of way"
    exit 1
fi

# Add worktree with chosen branch
git worktree add $workdir $branch
cd $workdir

# Check release version
if ! grep -q "'PMA_VERSION', '$version'" $CONFIG_LIB ; then
    echo "There seems to be wrong version in $CONFIG_LIB!"
    exit 2
fi
if ! grep -q "version = '$version'" doc/conf.py ; then
    echo "There seems to be wrong version in doc/conf.py"
    exit 2
fi
if ! grep -q "Version $version\$" README ; then
    echo "There seems to be wrong version in README"
    exit 2
fi

# Cleanup release dir
LC_ALL=C date -u > RELEASE-DATE-${version}

# Building documentation
echo "* Generating documentation"
LC_ALL=C make -C doc html
find doc -name '*.pyc' -print0 | xargs -0 -r rm -f

# Check for gettext support
if [ -d po ] ; then
    echo "* Generating mo files"
    ./scripts/generate-mo
    if [ -f ./scripts/remove-incomplete-mo ] ; then
        echo "* Removing incomplete translations"
        ./scripts/remove-incomplete-mo
    fi
    echo "* Removing gettext source files"
    rm -rf po
fi

if [ -f ./scripts/line-counts.sh ] ; then
    echo "* Generating line counts"
    ./scripts/line-counts.sh
fi

echo "* Removing unneeded files"

# Remove test directory from package to avoid Path disclosure messages
# if someone runs /test/wui.php and there are test failures
rm -rf test

# Remove developer information
rm -rf .github

# Remove phpcs coding standard definition
rm -rf PMAStandard

# Testsuite setup
rm -f build.xml phpunit.xml.dist .travis.yml .jshintrc

# Remove readme for github
rm -f README.rst

# Remove git metadata
rm -rf .git
find . -name .gitignore -print0 | xargs -0 -r rm -f

cd ..

# Prepare all kits
for kit in $KITS ; do
    # Copy all files
    name=phpMyAdmin-$version-$kit
    cp -r phpMyAdmin-$version $name

    # Cleanup translations
    cd phpMyAdmin-$version-$kit
    scripts/lang-cleanup.sh $kit

    # Remove developer scripts
    rm -rf scripts

    cd ..

    # Remove tar file possibly left from previous run
    rm -f $name.tar

    # Prepare distributions
    for comp in $COMPRESSIONS ; do
        case $comp in
            tbz|tgz|txz)
                if [ ! -f $name.tar ] ; then
                    echo "* Creating $name.tar"
                    tar cf $name.tar $name
                fi
                if [ $comp = tbz ] ; then
                    echo "* Creating $name.tar.bz2"
                    bzip2 -9k $name.tar
                fi
                if [ $comp = txz ] ; then
                    echo "* Creating $name.tar.xz"
                    xz -9k $name.tar
                fi
                if [ $comp = tgz ] ; then
                    echo "* Creating $name.tar.gz"
                    gzip -9c $name.tar > $name.tar.gz
                fi
                ;;
            zip)
                echo "* Creating $name.zip"
                zip -q -9 -r $name.zip $name
                ;;
            zip-7z)
                echo "* Creating $name.zip"
                7za a -bd -tzip $name.zip $name > /dev/null
                ;;
            7z)
                echo "* Creating $name.7z"
                7za a -bd $name.7z $name > /dev/null
                ;;
            *)
                echo "WARNING: ignoring compression '$comp', not known!"
                ;;
        esac
    done


    # Cleanup
    rm -f $name.tar
    # Remove directory with current dist set
    rm -rf $name
done

# Cleanup
rm -rf phpMyAdmin-${version}
git worktree prune

# Signing of files with default GPG key
echo "* Signing files"
for file in *.gz *.zip *.xz *.bz2 *.7z ; do
    gpg --detach-sign --armor $file
    md5sum $file > $file.md5
    sha1sum $file > $file.sha1
done


echo ""
echo ""
echo ""
echo "Files:"
echo "------"

ls -la *.gz *.zip *.xz *.bz2 *.7z

cd ..

# Tag as release
if [ $do_tag -eq 1 ] ; then
    echo
    echo "Additional tasks:"
    tagname=RELEASE_`echo $version | tr . _ | tr '[:lower:]' '[:upper:]' | tr -d -`
    echo "* Tagging release as $tagname"
    git tag -a -m "Released $version" $tagname $branch
    echo "   Dont forget to push tags using: git push --tags"
fi

# Mark as stable release
if [ $do_stable -eq 1 ] ; then
    mark_as_release $branch STABLE
fi

cat <<END


Todo now:
---------

1. If not already done, tag the repository with the new revision number
   for a plain release or a release candidate:
    version 2.7.0 gets RELEASE_2_7_0
    version 2.7.1-rc1 gets RELEASE_2_7_1RC1

 2. prepare a release/phpMyAdmin-$version-notes.html explaining in short the goal of
    this release and paste into it the ChangeLog for this release, followed
    by the notes of all previous incremental versions (i.e. 4.4.9 through 4.4.0)
 3. upload the files to our file server, use scripts/upload-release, eg.:

        ./scripts/upload-release $version release
 4. add a news item to our website; a good idea is to include a link to the release notes such as https://www.phpmyadmin.net/files/4.4.10/
 5. send a short mail (with list of major changes) to
        developers@phpmyadmin.net
        news@phpmyadmin.net

    Don't forget to update the Description section in the announcement,
    based on documentation.

 6. increment rc count or version in the repository :
        - in $CONFIG_LIB PMA\libraries\Config::__constructor() the line
              " \$this->set( 'PMA_VERSION', '2.7.1-dev' ); "
        - in Documentation.html (if it exists) the 2 lines
              " <title>phpMyAdmin 2.2.2-rc1 - Documentation</title> "
              " <h1>phpMyAdmin 2.2.2-rc1 Documentation</h1> "
        - in doc/conf.py (if it exists) the line
              " version = '2.7.1-dev' "

 7. on https://github.com/phpmyadmin/phpmyadmin/milestones close the milestone corresponding to the released version (if this is a stable release) and open a new one for the next minor release

 8. if a maintenance version (z in x.y.z) was released, delete the branch corresponding to the previous one; for example git push origin --delete MAINT_4_4_12

 9. for a stable version, update demo/php/versions.ini in the scripts repository so that the demo server shows current versions

10. in case of a new major release ('y' in x.y.0), update the pmaweb/settings.py in website repository to include the new major releases

11. the end :-)

END

#!/bin/bash -ex

# We assume "repo" has already run, placing the build git as
# ${WORKSPACE}/cbbuild and voltron as ${WORKSPACE}/voltron.
#
# Required job parameters (expected to be in environment):
#
# RELEASE - in the form x.x.x
# EDITION - "enterprise" or "community"
# BLD_NUM - xxxx
#
# (At some point these will instead be read from the manifest.)
#
# Required script command-line parameter:
#
#   Linux Distribution name (eg., "ubuntu12.04", "debian7", "centos6")
#
# This will be used to determine the pacakging format (.deb or .rpm).

DISTRO=$1
case "$DISTRO" in
    centos*)
        PKG=rpm
        ;;
    debian*|ubuntu*)
        PKG=deb
        ;;
    *)
        echo "Usage: $0 [ ubuntu12.04 | debian7 | centos6 | ... ]"
        exit 2
        ;;
esac

# Step 0: Derived values and cleanup. (Some of these are RPM- or
# DEB-specific, but will safely do nothing on other systems.)
PRODUCT_VERSION=${RELEASE}-${BLD_NUM}-rel
rm -f *.rpm *.deb
rm -rf ~/rpmbuild
rm -rf ${WORKSPACE}/voltron/build/deb
rm -rf /opt/couchbase/*
find goproj godeps -name \*.a -print0 | xargs -0 rm -f

# Step 1: Building prerequisites.
# This step will hopefully be obsoleted by moving all prereqs to cbdeps.
# For now this still uses Voltron's Makefile.

echo
echo =============== 1. Build prerequisites using voltron
echo =============== `date`
echo

# Voltron's Makefile do a "git pull" in grommit, so we have to ensure
# that works. This depends on the remote name in the manifest. All ugly.
cd ${WORKSPACE}/grommit
git checkout -B master membase-priv/master

cd ${WORKSPACE}/voltron
make GROMMIT=${WORKSPACE}/grommit BUILD_DIR=${WORKSPACE} \
     TOPDIR=${WORKSPACE}/voltron dep-couchbase.tar.gz

# I don't know why this doesn't cause problems for the normal build, but
# ICU sticks stuff in /opt/couchbase/sbin that the RPM template file
# doesn't want.
rm -rf /opt/couchbase/sbin

# Voltron's Makefile also assumes /opt/couchbase/lib/python is a directory.
# I don't actually know where this is supposed to come from. It also appears
# to be deleted by something in the dep-couchbase.tar.gz build, so I need to
# re-create it here before building the pystuff.
mkdir -p /opt/couchbase/lib/python
make GROMMIT=${WORKSPACE}/grommit BUILD_DIR=${WORKSPACE} \
     TOPDIR=${WORKSPACE}/voltron pysqlite2 pysnappy2


# Step 2: Build Couchbase Server itself, using CMake.

echo
echo =============== 2. Build Couchbase Server using CMake
echo =============== `date`
echo
cd ${WORKSPACE}
mkdir -p build
cd build
if [ "${EDITION}" = "enterprise" ]
then
    BUILD_ENTERPRISE=TRUE
else
    BUILD_ENTERPRISE=FALSE
fi
cmake -D CMAKE_INSTALL_PREFIX=/opt/couchbase \
      -D CMAKE_PREFIX_PATH=/opt/couchbase \
      -D CMAKE_BUILD_TYPE=Release \
      -D PRODUCT_VERSION=${PRODUCT_VERSION} \
      -D BUILD_ENTERPRISE=${BUILD_ENTERPRISE} \
      -D CB_DOWNLOAD_DEPS=1 \
      -D SNAPPY_OPTION=Disable \
      ..
make -j8 || (
    echo; echo; echo -------------
    echo make -j8 failed - re-running with no -j8 to hopefully get better debug output
    echo -------------; echo; echo
    make
    exit 2
)
make install

# Step 3: Create installer, using Voltron.  Goal is to incorporate the
# "build-filter" and "overlay" steps here into server-rpm/deb.rb, so
# we can completely drop voltron's Makefile.

echo
echo =============== 3. Building installation package
echo =============== `date`
echo

# First we need to create the current.xml manifest. This will eventually be
# passed into the job, but for now we use what repo knows.
cd ${WORKSPACE}
repo manifest -r > current.xml

cd ${WORKSPACE}/voltron
make PRODUCT_VERSION=${PRODUCT_VERSION} LICENSE=LICENSE-enterprise.txt \
     GROMMIT=${WORKSPACE}/grommit BUILD_DIR=${WORKSPACE} \
     TOPDIR=${WORKSPACE}/voltron build-filter overlay
cp -R server-overlay-${PKG}/* /opt/couchbase
PRODUCT_VERSION=${PRODUCT_VERSION} ./server-${PKG}.rb /opt/couchbase \
   couchbase-server couchbase server 1.0.0
if [ "${PKG}" = "rpm" ]
then
    cp ~/rpmbuild/RPMS/x86_64/*.rpm \
        ${WORKSPACE}/couchbase-server-${EDITION}-${RELEASE}-${BLD_NUM}-${DISTRO}.x86_64.rpm
else
    cp build/deb/*.deb \
        ${WORKSPACE}/couchbase-server-${EDITION}_${RELEASE}-${BLD_NUM}-${DISTRO}_amd64.deb
fi

echo
echo =============== DONE!
echo =============== `date`
echo
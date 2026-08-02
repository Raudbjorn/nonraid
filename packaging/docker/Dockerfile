# Build environment for the nonraid-dkms .deb on hosts that are not Debian.
#
# debian/control build-depends on dh-sequence-dkms, which only Debian's dh-dkms
# ships, so 'dh --with dkms' cannot run elsewhere. 'make package' builds this
# image and runs it against the working tree.
#
# The toolchain lives in its own layer so it is installed once and reused, and
# the build context is this directory alone - the source arrives at run time as
# a read-only bind mount, not as a COPY, so the image stays valid across edits.
ARG DEB_IMAGE=debian:13
FROM ${DEB_IMAGE}

# fakeroot is required by 'dpkg-buildpackage -rfakeroot'. dpkg-dev only
# Recommends it, so --no-install-recommends would otherwise leave it out.
ARG DEB_BUILD_DEPS="build-essential debhelper dkms dh-dkms fakeroot"

RUN apt-get update -qq \
    && apt-get install -y --no-install-recommends ${DEB_BUILD_DEPS} \
    && rm -rf /var/lib/apt/lists/*

COPY build-deb.sh /usr/local/bin/build-deb

ENTRYPOINT ["/usr/local/bin/build-deb"]

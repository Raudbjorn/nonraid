obj-y := md_nonraid/ raid6/
PWD := $(shell pwd)
KVERSION := $(shell uname -r)
HEADERS := /lib/modules/$(KVERSION)/build/

.PHONY: modules clean package package-native package-docker

modules:
	make -C $(HEADERS) M=$(PWD) modules CONFIG_UBSAN=n

clean:
	make -C $(HEADERS) M=$(PWD) clean

# 'package' builds natively on Debian/Ubuntu with debhelper installed, and
# otherwise falls back to a container. debian/control needs dh-sequence-dkms,
# which only Debian's dh-dkms provides, so a native build cannot work elsewhere.
# This file is installed into /usr/src and re-parsed on every DKMS build, so the
# probing below is skipped unless a packaging goal was actually asked for.
ifneq ($(filter package package-native package-docker,$(MAKECMDGOALS)),)

DOCKER ?= docker
DEB_IMAGE ?= debian:13
DEB_BUILD_DEPS ?= build-essential debhelper dkms dh-dkms

IS_DEBIAN := $(shell test -f /etc/debian_version && echo yes)
HAVE_DH := $(shell command -v dh >/dev/null 2>&1 && echo yes)
HAVE_DOCKER := $(shell command -v $(DOCKER) >/dev/null 2>&1 && echo yes)

ifeq ($(IS_DEBIAN)$(HAVE_DH),yesyes)
package: package-native
else
package: package-docker
endif

package-native:
	dpkg-buildpackage -b -rfakeroot -us -uc

# The source tree is copied into the container before building: dh_install uses
# 'cp -a', which fails with ENODATA when it tries to write ACLs onto a bind mount.
package-docker:
ifneq ($(HAVE_DOCKER),yes)
	@echo "make package: no native Debian toolchain and no '$(DOCKER)' in PATH." >&2
	@echo "" >&2
	@echo "  The .deb needs dh-sequence-dkms, which only exists on Debian/Ubuntu." >&2
	@echo "  Either build on Debian/Ubuntu with:" >&2
	@echo "      apt install $(DEB_BUILD_DEPS)" >&2
	@echo "  or install $(DOCKER) and re-run 'make package' to build in $(DEB_IMAGE)." >&2
	@echo "  Set DOCKER=podman to use podman instead." >&2
	@exit 1
else
	@$(DOCKER) info >/dev/null 2>&1 || { \
	    echo "make package: cannot reach the $(DOCKER) daemon." >&2; \
	    echo "  Is it running ('systemctl start docker')," >&2; \
	    echo "  and are you in the 'docker' group (log out and back in after adding)?" >&2; \
	    exit 1; }
	@echo "Not a Debian build host; building in $(DEB_IMAGE) via $(DOCKER)."
	$(DOCKER) run --rm \
	    -v "$(PWD)":/src:ro \
	    -v "$(dir $(patsubst %/,%,$(PWD)))":/out \
	    -e DEB_BUILD_DEPS="$(DEB_BUILD_DEPS)" \
	    -e OUT_UID="$(shell id -u)" -e OUT_GID="$(shell id -g)" \
	    $(DEB_IMAGE) sh -c 'set -e; \
	        apt-get update -qq; \
	        apt-get install -y --no-install-recommends $$DEB_BUILD_DEPS; \
	        mkdir -p /work; \
	        tar -C /src --exclude=.git -cf - . | tar -C /work -xf -; \
	        cd /work && dpkg-buildpackage -b -rfakeroot -us -uc; \
	        for f in /*.deb /*.changes /*.buildinfo; do \
	            [ -e "$$f" ] || continue; \
	            install -m 0644 -o "$$OUT_UID" -g "$$OUT_GID" "$$f" /out/; \
	        done'
endif

endif

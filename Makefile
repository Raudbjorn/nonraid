obj-y := md_nonraid/ raid6/
PWD := $(shell pwd)
KVERSION := $(shell uname -r)
HEADERS := /lib/modules/$(KVERSION)/build/

.PHONY: modules clean package package-native package-docker package-plugin

modules:
	make -C $(HEADERS) M=$(PWD) modules CONFIG_UBSAN=n

clean:
	make -C $(HEADERS) M=$(PWD) clean

# 'package' builds natively on Debian/Ubuntu with a complete toolchain, and
# otherwise falls back to a container. debian/control needs dh-sequence-dkms,
# which only Debian's dh-dkms provides, so a native build cannot work elsewhere.
# This file is installed into /usr/src and re-parsed on every DKMS build, so the
# probing below is skipped unless a packaging goal was actually asked for.
ifneq ($(filter package package-native package-docker package-plugin,$(MAKECMDGOALS)),)

# dpkg-buildpackage writes its artifacts to the PARENT of the source tree. That
# is the Debian convention (tree and .orig tarball share a directory), but it
# drops files outside the checkout where no VCS tracks or ignores them - and for
# a checkout directly under '/', into the root. Collect them in a gitignored
# directory inside the tree instead.
#
# They cannot be redirected at build time: dpkg-genbuildinfo and dpkg-genchanges
# read the just-built .deb from '..' by the name debian/files records, so
# 'dh_builddeb --destdir' makes the build die with 'cannot fstat file'. Build
# where dpkg expects, then move the set - the same shape as package-docker.
OUTDIR ?= $(PWD)/out
PARENT := $(dir $(patsubst %/,%,$(PWD)))

# Errors are silenced because these run on hosts with no dpkg-dev at all, where
# the container fallback is taken and the prefixes are never used.
DEB_PREFIX := nonraid-dkms_$(shell dpkg-parsechangelog -SVersion 2>/dev/null)
PLUGIN_PREFIX := libpve-storage-nonraid-perl_$(shell dpkg-parsechangelog -l pve-plugin/debian/changelog -SVersion 2>/dev/null)

# $(1) is the directory dpkg-buildpackage wrote to, $(2) the name_version prefix.
# Matching on a trailing glob rather than a full filename because .changes and
# .buildinfo are always named for the HOST architecture while the .deb carries
# the package's own - '_all.deb' alongside '_amd64.changes' for the plugin. The
# version pins the match, so no other package's artifacts can be swept up.
define collect_artifacts
	@set -e; \
	for f in $(1)$(2)_*.deb $(1)$(2)_*.changes $(1)$(2)_*.buildinfo; do \
	    [ -e "$$f" ] || continue; \
	    mv "$$f" "$(OUTDIR)/"; \
	    echo "  -> $(OUTDIR)/$$(basename "$$f")"; \
	done
endef

DOCKER ?= docker
# Floating tag, so the toolchain drifts across point releases. Override with a
# digest (DEB_IMAGE=debian@sha256:...) when a reproducible build matters.
DEB_IMAGE ?= debian:13
# fakeroot is needed by 'dpkg-buildpackage -rfakeroot'. dpkg-dev only Recommends
# it, so --no-install-recommends leaves it out and the container build fails.
DEB_BUILD_DEPS ?= build-essential debhelper dkms dh-dkms fakeroot
DEB_BUILDER_IMAGE ?= nonraid-deb-builder

IS_DEBIAN := $(shell test -f /etc/debian_version && echo yes)
HAVE_DH := $(shell command -v dh >/dev/null 2>&1 && echo yes)
HAVE_FAKEROOT := $(shell command -v fakeroot >/dev/null 2>&1 && echo yes)
# dpkg-checkbuilddeps reads debian/control, so this also covers dh-sequence-dkms
# and anything added there later. Gating on Debian + dh alone would pick the
# native path on a Debian host missing dh-dkms and fail, rather than fall back.
# dpkg-checkbuilddeps and dpkg-buildpackage both ship in dpkg-dev, so probing
# for the former also establishes that the latter is present.
HAVE_BUILDDEPS := $(shell command -v dpkg-checkbuilddeps >/dev/null 2>&1 && dpkg-checkbuilddeps >/dev/null 2>&1 && echo yes)

# These belong outside the conditional below: 'make package-docker' is a
# documented way to force the container path, and a native-capable host is
# exactly where someone would use it. Defining them only on the fallback branch
# left HAVE_DOCKER empty there, so the target refused with "no docker in PATH"
# on machines that had docker installed.
HAVE_DOCKER := $(shell command -v $(DOCKER) >/dev/null 2>&1 && echo yes)

# Rootless podman (and rootless docker) map container uid 0 to the invoking user
# and container uid N to a subordinate host id. Chowning artifacts to the real
# uid there lands them on a subuid the user cannot easily read or delete - the
# opposite of what the chown is for. Writing as container root is already
# correct in that case; under rootful docker it is not, hence the real uid.
IS_ROOTLESS := $(shell { $(DOCKER) info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -qx true \
	|| $(DOCKER) info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; } && echo yes)
ifeq ($(IS_ROOTLESS),yes)
OUT_UID := 0
OUT_GID := 0
else
OUT_UID := $(shell id -u)
OUT_GID := $(shell id -g)
endif

# Failure advice differs by engine: podman has no daemon to start and no group
# to join, so the docker wording would send a podman user down a dead end.
ifeq ($(findstring podman,$(DOCKER)),podman)
ENGINE_ADVICE := podman is daemonless - run 'podman info' to see the underlying error (often storage or subuid configuration).
ENGINE_SWITCH :=
else
ENGINE_ADVICE := Is it running ('systemctl start docker'), and are you in the 'docker' group (log out and back in after adding)?
ENGINE_SWITCH := Set DOCKER=podman to use podman instead.
endif

# Only the default for a bare 'make package' depends on the host toolchain;
# package-native and package-docker stay individually reachable either way.
ifeq ($(IS_DEBIAN)$(HAVE_DH)$(HAVE_FAKEROOT)$(HAVE_BUILDDEPS),yesyesyesyes)
package: package-native
else
package: package-docker
endif

package-native:
	@mkdir -p $(OUTDIR)
	dpkg-buildpackage -d -b -rfakeroot -us -uc
	$(call collect_artifacts,$(PARENT),$(DEB_PREFIX))

# The PVE storage plugin package is Arch: all and needs only debhelper, so it
# has no container fallback of its own. Built from pve-plugin/, so dpkg drops
# its artifacts in the repository root rather than one level above it.
package-plugin:
	@mkdir -p $(OUTDIR)
	cd pve-plugin && dpkg-buildpackage -d -b -rfakeroot -us -uc
	$(call collect_artifacts,$(PWD)/,$(PLUGIN_PREFIX))

# Artifacts land in a temporary directory bind-mounted as /out and are moved
# into $(OUTDIR) afterwards, so the container never gets write access to the
# source tree itself.
#
# NOTE: the conditional below is a Make ifneq evaluated at parse time, not a
# shell branch - only one of the two blocks ever becomes part of the recipe.
package-docker:
ifneq ($(HAVE_DOCKER),yes)
	@echo "make package: no native Debian toolchain and no '$(DOCKER)' in PATH." >&2
	@echo "" >&2
	@echo "  The .deb needs dh-sequence-dkms, which only exists on Debian/Ubuntu." >&2
	@echo "  Either build on Debian/Ubuntu with:" >&2
	@echo "      apt install $(DEB_BUILD_DEPS)" >&2
	@echo "  or install $(DOCKER) and re-run 'make package' to build in $(DEB_IMAGE)." >&2
	$(if $(ENGINE_SWITCH),@echo "  $(ENGINE_SWITCH)" >&2)
	@exit 1
else
	@$(DOCKER) info >/dev/null 2>&1 || { \
	    echo "make package: cannot run $(DOCKER)." >&2; \
	    echo "  $(ENGINE_ADVICE)" >&2; \
	    exit 1; }
	@echo "Not a Debian build host; building in $(DEB_IMAGE) via $(DOCKER)."
	$(DOCKER) build -q \
	    --build-arg DEB_IMAGE="$(DEB_IMAGE)" \
	    --build-arg DEB_BUILD_DEPS="$(DEB_BUILD_DEPS)" \
	    -t $(DEB_BUILDER_IMAGE) packaging/docker
	@set -e; \
	mkdir -p "$(OUTDIR)"; \
	outdir=$$(mktemp -d); \
	trap 'rm -rf "$$outdir"' EXIT; \
	$(DOCKER) run --rm \
	    --security-opt label=disable \
	    -v "$(PWD)":/src:ro \
	    -v "$$outdir":/out \
	    -e OUT_UID="$(OUT_UID)" -e OUT_GID="$(OUT_GID)" \
	    $(DEB_BUILDER_IMAGE); \
	for f in "$$outdir"/*; do \
	    [ -e "$$f" ] || continue; \
	    mv "$$f" "$(OUTDIR)/"; \
	    echo "  -> $(OUTDIR)/$$(basename "$$f")"; \
	done
endif

endif

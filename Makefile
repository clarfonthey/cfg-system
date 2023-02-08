ARCHES = x86_64 aarch64

.PHONY: clean $(ARCHES)

.PRECIOUS: \
	build \
	build/base.%.tar \
	build/bootstrap.%.tar \
	build/%/etc \
	build/%/etc/pacman.conf \
	build/%/var \
	build/%/var/cache \
	build/%/var/cache/pacman \
	build/%/var/cache/pacman/pkg \
	build/%/var/key \
	build/%/var/key/pacman \
	build/%/var/key/pacman/gpg.conf \
	build/%/var/key/pacman/gpg-agent.conf \
	build/%/var/lib \
	build/%/var/lib/pacman

%.tar.zst: %.tar
	zstd --threads=0 --long --zstd=strat=8 --force $*.tar

%.tar.zst.sha512: %.tar.zst
	sha512sum $*.tar.zst > $*.tar.zst.sha512

all: $(ARCHES)

$(ARCHES): %: build/base.%.tar.zst build/base.%.tar.zst.sha512

clean:
	if test -d build; then \
		fd '.*' -t d build -x chmod 755 '{}'; \
		fd '.*' -t f build -x chmod 644 '{}'; \
	fi
	rm -rf build

cache:
	mkdir --parents cache

cache/pkg: | cache
	mkdir --parents cache/pkg
	rsync --recursive /var/cache/pacman/pkg/ cache/pkg

build:
	mkdir --parents build

$(patsubst %,build/%,$(ARCHES)): | build
	install --mode 0755 --directory $@

build/bootstrap.%.pkgs: src/pkgs/bootstrap.any src/pkgs/bootstrap.%
	cat src/pkgs/bootstrap.any src/pkgs/bootstrap.$* | \
		sort -u > build/bootstrap.$*.pkgs

build/base.%.pkgs: src/pkgs/base.any src/pkgs/base.% build/bootstrap.%.pkgs
	cat build/bootstrap.$*.pkgs src/pkgs/base.any src/pkgs/base.$* | \
		sort -u > build/base.$*.pkgs

build/mask.%.units: src/units/mask.any src/units/mask.%
	cat src/units/mask.any src/units/mask.$* | \
		sort -u > build/mask.$*.units

build/system.%.units: src/units/system.any src/units/system.%
	cat src/units/system.any src/units/system.$* | \
		sort -u > build/system.$*.units

build/user.%.units: src/units/user.any src/units/user.%
	cat src/units/user.any src/units/user.$* | \
		sort -u > build/user.$*.units

build/base.%.tar: src/Containerfile src/pacnew.bash build/base.%.pkgs build/mask.%.units build/system.%.units build/user.%.units build/bootstrap.%.tar
	podman build --file src/Containerfile --build-arg ARCH=$* . | \
		tee /dev/stderr | \
		tail -n 1 | \
		xargs podman container create | \
		xargs podman container export --output=build/base.$*.tar

build/bootstrap.%.tar: src/exclude.% src/exclude.any src/pkgs/bootstrap.% src/pkgs/bootstrap.any cache/pkg build/%/etc/pacman.conf build/%/var/key/pacman/gpg-agent.conf build/%/var/key/pacman/gpg.conf | build/%/var/cache/pacman/pkg build/%/var/lib/pacman
	unshare --map-root-user --map-auto \
		pacman \
			--root build/$*/ \
			--config build/$*/etc/pacman.conf \
			--dbpath build/$*/var/lib/pacman \
			--cachedir cache/pkg/ \
			--noscriptlet \
			--noconfirm \
			--needed \
			--sync \
			--refresh \
			$(shell cat src/pkgs/bootstrap.any src/pkgs/bootstrap.$*)
	unshare --map-root-user --map-auto \
		pacman \
			--root build/$*/ \
			--config build/$*/etc/pacman.conf \
			--dbpath build/$*/var/lib/pacman \
			--query \
			--check --check
	unshare --map-root-user --map-auto \
		tar \
			--xattrs \
			--acls \
			--exclude-from=src/exclude.any \
			--exclude-from=src/exclude.$* \
			--directory build/$* \
			--create . \
			--file build/bootstrap.$*.tar

build/%/etc: | build/%
	install --mode 0755 --directory build/$*/etc

build/%/etc/pacman.conf: src/pacman/pacman.conf.% | build/%/etc
	install --mode 0644 src/pacman/pacman.conf.$* build/$*/etc/pacman.conf

build/%/var: | build/%
	install --mode 0755 --directory build/$*/var

build/%/var/cache: | build/%/var
	install --mode 0755 --directory build/$*/var/cache

build/%/var/cache/pacman: | build/%/var/cache
	install --mode 0755 --directory build/$*/var/cache/pacman

build/%/var/cache/pacman/pkg: | build/%/var/cache/pacman
	install --mode 0755 --directory build/$*/var/cache/pacman/pkg

build/%/var/key: | build/%/var
	install --mode 0755 --directory build/$*/var/key

build/%/var/key/pacman/gpg.conf: src/pacman/gpg.conf | build/%/var/key/pacman
	install --mode 0644 src/pacman/gpg.conf build/$*/var/key/pacman/gpg.conf

build/%/var/key/pacman/gpg-agent.conf: src/pacman/gpg-agent.conf | build/%/var/key/pacman
	install --mode 0644 src/pacman/gpg-agent.conf build/$*/var/key/pacman/gpg-agent.conf

build/%/var/key/pacman: | build/%/var/key
	install --mode 0700 --directory build/$*/var/key/pacman

build/%/var/lib: | build/%/var
	install --mode 0755 --directory build/$*/var/lib

build/%/var/lib/pacman: | build/%/var/lib
	install --mode 0755 --directory build/$*/var/lib/pacman

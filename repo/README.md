# KolinOS local APT repository layout (Phase 5 groundwork for Phase 9).

Nothing here is published yet. `scripts/build-repo.sh` populates `repo/public/`
from `.deb` files placed in `packages/custom/debs/`.

Layout produced (one architecture per dist, chosen with `--arch`):

```
repo/public/
├── pool/main/*.deb
└── dists/<codename>/main/binary-<arch>/{Packages,Packages.gz,Packages.xz,Release,InRelease}
```

Only `.deb` matching the target architecture (plus `Architecture: all`) are
indexed; a package built for another architecture is skipped with a warning.
The tree is rebuilt from scratch on every run and is reproducible
(`SOURCE_DATE_EPOCH` + `gzip -9n`).

Serve it locally for testing:

```sh
cd repo/public && python3 -m http.server 8080
```

Create the signing key:

```sh
bash repo/scripts/make-gpg-key.sh
```

Build the repository:

```sh
bash repo/scripts/build-repo.sh                 # architecture from VERSION
bash repo/scripts/build-repo.sh --arch amd64    # override for a test build
bash repo/scripts/build-repo.sh --unsigned      # local tests, no signature
```

Consumers point APT at it (see `/etc/apt/sources.list.d/kolinos.sources.disabled`
inside the built rootfs; `apt-kolinos enable` flips it on).

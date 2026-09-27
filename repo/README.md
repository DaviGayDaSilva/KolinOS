# KolinOS local APT repository layout (Phase 9 groundwork).

Nothing here is published yet. `scripts/build-repo.sh` populates `repo/public/`
from `.deb` files placed in `packages/custom/debs/`.

Layout produced:

```
repo/public/
├── pool/main/*.deb
└── dists/<codename>/main/binary-arm64/{Packages,Packages.gz,Release,InRelease}
```

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
bash repo/scripts/build-repo.sh
```

Consumers point APT at it (see `/etc/apt/sources.list.d/kolinos.sources.disabled`
inside the built rootfs).

zigbee2mqtt CI build for Wiren Board
====================================

This repository contains scripts and extra files required to build
zigbee2mqtt package for Wiren Board repository.

| Path | What is there |
|---|---|
| `Jenkinsfile` | build parameters and the order of the stages |
| `scripts/build.sh` | installs Node.js and the toolchain, builds with pnpm, packs with fpm |
| `scripts/test-deb.sh` | checks the built package before it is uploaded |
| `package/` | what goes into the package: the service unit, the default config, the upgrade scripts |

How to build
------------

Using devenv (https://github.com/wirenboard/wirenboard). `BUILD_AND_REQUIRE_NODEJS` says which
Node.js the build installs and the package then requires; there is no default:

```console
$ git clone https://github.com/Koenkk/zigbee2mqtt
$ WBDEV_TARGET=bullseye-armhf WBDEV_BUILD_METHOD=qemuchroot wbdev chroot \
      env BUILD_AND_REQUIRE_NODEJS=22 scripts/build.sh zigbee2mqtt <version> ./zigbee2mqtt ./result
$ # .deb files are in result/ dir
```

To take packages from testing sets (trixie targets, devenv image from 2026-09-15 or newer),
add their names:

```console
$ WBDEV_TARGET=trixie-armhf WBDEV_BUILD_METHOD=qemuchroot WBDEV_TESTING_SETS=<set>[,<set>...] wbdev chroot \
      env BUILD_AND_REQUIRE_NODEJS=24 scripts/build.sh zigbee2mqtt <version> ./zigbee2mqtt ./result
```

The amd64 target has no rootfs in devenv: it is built in the devenv container itself, which
is trixie amd64, and takes its Node.js from the dev-tools repository, the only Wiren Board
repository in the image. The package it produces goes to dev-tools too, for development
machines, not to the release repository the controllers take theirs from.

There is no WBDEV_TARGET here: it names a rootfs, and `wbdev root` never enters one. The image
is what decides, and `wbdev` takes it from WBDEV_IMAGE, `contactless/devenv:latest` by default.
In the job the parameter keeps its meaning: it says which way to build and where to upload.

```console
$ wbdev root env BUILD_AND_REQUIRE_NODEJS=24 bash scripts/build.sh zigbee2mqtt <version> ./zigbee2mqtt ./result
```

To check the package the build produced, on the same rootfs and the same Node.js:

```console
$ WBDEV_TARGET=trixie-armhf WBDEV_BUILD_METHOD=qemuchroot wbdev chroot \
      env BUILD_AND_REQUIRE_NODEJS=24 scripts/test-deb.sh ./result
```

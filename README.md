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

To check the package the build produced, on the same rootfs and the same Node.js:

```console
$ WBDEV_TARGET=trixie-armhf WBDEV_BUILD_METHOD=qemuchroot wbdev chroot \
      env BUILD_AND_REQUIRE_NODEJS=24 scripts/test-deb.sh ./result
```

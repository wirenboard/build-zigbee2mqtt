zigbee2mqtt CI build for Wiren Board
====================================

This repository contains scripts and extra files required to build
zigbee2mqtt package for Wiren Board repository.

| Path | What is there |
|---|---|
| `Jenkinsfile` | build parameters and the order of the stages |
| `scripts/build.sh` | installs Node.js and the toolchain, builds with pnpm, packs with fpm |
| `scripts/test-deb.sh` | checks the built package before it is uploaded |
| `package/` | what goes into the package: the service unit, the configuration template, the maintainer scripts |

The configuration on the controller
-----------------------------------

`/mnt/data/root/zigbee2mqtt/data/configuration.yaml` is not part of the package and is not a dpkg
conffile: zigbee2mqtt rewrites it itself and keeps the network key, the pan id and the paired
devices there, so it is state rather than a setting from the maintainer. As a conffile it made
dpkg ask whether to replace the file whenever the default changed, and an answered "replace"
destroyed the Zigbee network.

The package carries `package/configuration.default.yaml` as the template, installed as
`/usr/share/zigbee2mqtt/configuration.default.yaml`, and `package/setup-z2m-config.sh`, installed
as `/usr/lib/zigbee2mqtt/setup-z2m-config.sh`. That script runs from the maintainer scripts on
install and upgrade, and from `ExecStartPre` of the service, so a module declared after the
install is picked up on the next start. It:

- creates the configuration from the template when the controller has none, and never replaces
  one that is already there;
- fills in `serial.port` from the hardware configuration of the controller, that is from the slot
  the user picked in Settings, Extension Modules and Ports. Nothing is probed: talking to ports
  the user did not declare would disturb whatever else is plugged into the other slots;
- writes the port only when exactly one Zigbee module is declared and the configuration still
  carries the port from the template. Zero or several modules, or a port somebody has chosen, and
  the script only says so in the log.

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

zigbee2mqtt CI build for Wiren Board
====================================

This repository contains scripts and extra files required to build
zigbee2mqtt package for Wiren Board repository.

| Path | What is there |
|---|---|
| `Jenkinsfile` | build parameters and the order of the stages |
| `scripts/build.sh` | installs Node.js and the toolchain, builds with pnpm (`--step build`), packs with fpm (`--step pack`) |
| `scripts/prune-files.sh` | between the two steps: removes what nobody can use on a controller, and answers `--check` |
| `scripts/test-deb.sh` | checks the built package before it is uploaded |
| `package/` | what goes into the package: the service unit, the configuration template, the maintainer scripts |
| `debian/changelog` | the version of the package, the only place it is set; packed as the changelog of the package |
| `TODO.md` | questions left open, to settle with the team |

Files the package does not carry
-------------------------------

`scripts/prune-files.sh` runs between the build and the packing, in a step of its own, and
`scripts/build.sh` asks the same script with `--check` before it packs, so a package cannot come
out with these files in it by accident.

Removed, because nothing on a controller can run or read them:

- `test`, the test suite of zigbee2mqtt: it needs vitest and the other development dependencies,
  and `pnpm prune --prod` has already removed those;
- `tsconfig.tsbuildinfo`, the state of an incremental TypeScript compile: there is no compiler on
  a controller.

Kept for now, with a reason to think first:

| What | Files | Size | Why it is still there |
|---|---|---|---|
| `node_modules/**/*.map` | 1622 | 18.6 MB | `index.js` turns source maps on with `setSourceMapsEnabled(true)`, and 1230 of these belong to zigbee-herdsman and its converters: without them a stack trace names a position in the compiled bundle instead of a line of the original TypeScript |
| `node_modules/**/*.d.ts` | 1126 | 8.7 MB | type definitions, read only by the TypeScript compiler |
| `*.md` | 211 | 3.8 MB | readme and changelog texts, readable by a person |

Licence texts stay everywhere: they have to travel with the code.

Copy of the data before an install
----------------------------------

**This is temporary and can go after January 2027.** It guards one change: `configuration.yaml`
is no longer a dpkg conffile, the package ships a template and the file is created on the
controller. The copies are how we tell that controllers went through that change without losing
their configuration. `package/backup-z2m-data.sh` copies `/mnt/data/root/zigbee2mqtt/data` into
`/var/backups/zigbee2mqtt/<date>T<time>` before every install and every upgrade, and keeps the
three newest copies.

The reason is a real case: an upgrade stopped half way, the tree of the application was left
without `data`, and the configuration went with it, network key and paired devices included. Until
such a run is impossible, every install leaves a copy behind, and a week later the answer to "my
configuration is gone" is a path.

`/var/backups` was picked because it is where Debian itself keeps copies of `dpkg`, `apt` and
`alternatives` state, it survives `apt purge` of this package, nothing rotates it by a timer, and
it does not depend on where the application keeps its data.

It is on the root filesystem on purpose, and not on `/mnt/data`: the controllers are moving
towards one large root partition, with `/mnt/data` gone, and a copy written under `/var` keeps
working after that change without anyone remembering this script.

A copy is not an archive: it is a directory with the files as they were, copied with `cp -a`.
Only the files that lie in `data` itself are taken, so `log` does not travel; `wb-backup-info.txt`
is written by the script and says when the copy was made and what was installed before:

```
/var/backups/zigbee2mqtt/2026-09-23T14-05-01/
    configuration.yaml
    coordinator_backup.json
    database.db
    state.json
    wb-backup-info.txt
```

The words in `wb-backup-info.txt` are kept plain, because it is read on a controller by whoever is
looking for the lost configuration:

```
# Written automatically by the zigbee2mqtt package, before dpkg changed anything.
# For whoever is looking for a configuration that went missing.

backup time: 2026-09-23 14:05:01 +0300 (MSK)
made before dpkg action: upgrade
package: zigbee2mqtt
old version: 2.14.1-wb101
copy of: /mnt/data/root/zigbee2mqtt/data
put back: stop zigbee2mqtt, copy the files that lie next to this one into the directory above, start zigbee2mqtt
```

`made before dpkg action` has three values, and they are all a maintainer script can tell apart:

| dpkg action | what it was | old version |
|---|---|---|
| `upgrade` | dpkg was replacing the package that was installed | the version being replaced |
| `install after remove` | the package had been removed, its settings stayed, now it is back | the version it had then |
| `install` | dpkg knew no package of that name | `none` |

A reinstall of the same version says `upgrade` too: the version being installed is not among the
things dpkg hands to a maintainer script, so there is nothing here to tell the two apart, and
there is no `new version` line for the same reason. `old version` comes from the argument fpm
passes to `before_upgrade`, and `dpkg-query` is the fallback. `package` is the name the package
really has: with `VERSION_TO_NAME` it is `zigbee2mqtt-1.18.1` and not `zigbee2mqtt`.

A copy that did not work out leaves nothing behind. The files go into `<date>T<time>.partial`,
and the directory gets its real name only after the last file and
`wb-backup-info.txt` are in place. The rename happens inside one directory, so it costs no space
and no time, and both the rotation above and a person looking into `/var/backups` see whole copies
only. When anything fails, the script says so on stderr and removes the `.partial` directory.

This is not a theoretical worry. The copy used to be made with `find ... -exec cp -a {} ... \;`,
and with `;` find returns 0 even when `cp` failed. Measured on a controller with GNU findutils
4.10 and 16 KB of free space: `cp` filled the disk, `find` returned 0, the script reported the
copy as made, and `/var/backups` got a directory of empty files that took one of the three slots.
Three such upgrades in a row would have left no whole copy at all. Hence `-exec ... +`, which does
return a non-zero status, and hence the `.partial` name.

To put such a copy back, with the service stopped:

```
$ systemctl stop zigbee2mqtt
$ cp -a /var/backups/zigbee2mqtt/<date>T<time>/*.yaml \
        /var/backups/zigbee2mqtt/<date>T<time>/*.json \
        /var/backups/zigbee2mqtt/<date>T<time>/database.db \
        /mnt/data/root/zigbee2mqtt/data/
$ systemctl start zigbee2mqtt
```

The three copies are the newest three by time. They are there for the usual way trouble is
noticed: an upgrade breaks something, the user tries once more, and only then starts looking for
what was there before.

To remove this logic: delete `package/backup-z2m-data.sh`; in `scripts/build.sh` the two fpm flags
that inline it, `before_upgrade_with_backup()`, the `before_upgrade` local it fills and the `rm -f`
that follows the fpm call; and `test_data_copied_to_var_backups` in `scripts/test-deb.sh`.

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

The maintainer scripts
----------------------

`package/after-install.sh`, `package/before-upgrade.sh`, `package/after-upgrade.sh` and
`package/backup-z2m-data.sh` run on the controller, and fpm inlines each of them into the body of
a function of the maintainer script it generates. The shebang and any `set` in such a file have no
effect there, and a failing command does not stop the install: that is why every step in them
reports for itself instead of relying on an exit code.

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
repository in the image. The package it produces goes to dev-tools too, not to the release
repository the controllers take theirs from.

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

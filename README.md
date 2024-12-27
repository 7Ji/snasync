# Snasync - A **sna**pper snapshots **sync**er

Snasync is a simple and naive Bash script to help you sync Btrfs snapshots created by [snapper](http://snapper.io/) from hot storage (i.e. the one `.snapshots` resides on) to warm, cold and/or remote storage.

Do note that although it's named "sync", it is mostly a **one-way sync** by design: the names of subvolume containers that was send-and-received are different from the source containers, e.g. a source container `/.snapshots/127` could be synced to `/srv/backup/warm/snapshots/mypc-20241223150000`, while the inner `snapshot` and `info.xml` are kept the same nontheless. This is mostly to work around the fact that snapper snapshots could be purged altogether and everything would start from ID 1 again, and you surely shouldn't also purge your cold backups in most case.

## Usage

```sh
snasync --source [source] (--prefix [prefix]) --target [target] (--target [target] (--target [target])) ...
```

The definition of the most-used options are as follows:

- `--source [source]` is either the mountpoint containing .snapshots mountpoint, or .snapshots mountpoint itself, this is always required, multiple `source` could be declared and snasync would handle them one by one.
- `--prefix [prefix]` is the sycned subvols prefix applied to the previous `[source]`, by default this is `[source]` with all path-seperators and dots swapped to _
- `--target [target]` is either absolute path starting with / to put snapshots in, or a scp-style remote prefix to remotely send snapshots to, applied to the previous `[source]`. Can be specified multiple times so multiple targets can be used.
  - A local path should start with `/`, e.g. `/mnt/backup/snapshots`
  - Anything else is considered a remote path, and it should be in the scp-style, e.g. `root@backup.my.lan:/`

Usually you should not set the following options:

- `--wrapper-local [wrapper]` is the "wrapper" that should be placed before the local permission-sensitive operations, by default it is "sudo", e.g. `--wrapper-local doas`
- `--wrapper-remote:[remote] [wrapper]` is the "wrapper" that should be placed before the remote permission-sensitive operations, by default it is "sudo", e.g. `--wrapper-remote-nas.lan doas`

A common invocation of snasync is usually like this:
```sh
snasync \
  --source / --prefix pc_root \
    --target /srv/backup/warm/snapshots \
    --target nas.lan:/srv/backup/snapshots \
    --target /mnt/cold-backup/snapshots \
  --source /home --prefix pc_home \
    --target /srv/backup/warm/snapshots \
    --target nas.lan:/srv/backup/snapshots \
  --source /srv --prefix pc_srv \
    --target /srv/backup/warm/snapshots \
    --target /mnt/cold-backup/snapshot
```

Due to the nature of warm/cold/remote backups that they could be unreachable in some cases, missing of `[target]` would only cause it to be skipped, and snasync would continue running until the end.

It is highly recommended to sync multiple `[source]`s and multiple `[target]`s in a single snasync run, so pre- and post- logics would only be run once, and resources like remote SSH tunnels could be re-used efficiently (remember to set up your `ssh_config` to re-use connections, disbale compression, etc, following [Arch Wiki](https://wiki.archlinux.org/title/OpenSSH#Speeding_up_SSH))

## License
**snasync** (snapper snapshots syncer) is licensed under [**GPL3**](https://gnu.org/licenses/gpl.html)
 * Copyright (C) 2024-present Guoxin "7Ji" Pu (pugokushin@gmail.com)
 * This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version * of the License, or (at your option) any later version.

 * This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>
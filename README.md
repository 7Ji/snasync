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

## Site-to-site syncing

A dedicated script `site-to-site.sh` is provided for site-to-site syncing (i.e. from server A with snasync Btrfs snapshots storage, to server B with snasync Btrfs snapshots storage), which, in most cases happens offline and does not require the inter-storage to be Btrfs-based.

The logic goes like the following:
- At site A, clients run snasync routinely to sync to server A (e.g. to its `/srv/backup/snapshots`)
- At site A, on server A with snasync Btrfs snapshots storage, mount an external drive formatted with any FS, and run `site-to-site.sh send` with needed arguments, the snapshots (in their raw Btrfs send-receive format) would be "archived" onto the external drive. Umount that after syncing.
- Carry the external drive to site B
- At site B, on server B with snasync Btrfs snapshots storage, mount that external drive, and run `site-to-site.sh receive` with needed arguments, the snapshots (in their raw Btrfs send-receive format) would be "restored" into its snasync Btrfs snapshots storage.

As a side effect this can also be used for cold backup if you skip the steps for site B or even for recovery if server A = server B. But do not rely on this as the raw Btrfs send-receive format might change and your offline "backup" would in most cases become useless.

My recommendation is to do this with a longer interval, 2 more orders of magnitude than how often you do snasync at the same site. (E.g. if your clients sync nightly to a in-site backup server, do site-to-site sync monthly).

The command-line usage is pretty simple:
```
site-to-site.sh [send/receive] [source path] [target path]
```
Note the following requirements:
- On `send`, the `[source path]` must be the snasync Btrfs snapshots storage, storing those `[name]-[timestamp]` folders each storing `info.xml` and `snapshot`. The `[target path]` can be any FS.
- On `receive`, the `[target path]` must reside on a Btrfs filesystem and runinng `btrfs receive` there should be allowed. The `[source path]` can be any FS, as long as it stores the previously sent "snapshots".
- Both `send` and `receive` commands shall be run on exactly the server with snasync storage.

Optionally the following arguments can be specified for `send`:
```
--with [snasync container name] (--with [snasync contaainer name])
```
If that is given, the site-to-site syncer would consider the specified container  (and any container older than it) already exists at the receiver end, and use it as the parent, and only send containers newer than it.


## License
**snasync** (snapper snapshots syncer) is licensed under [**GPL3**](https://gnu.org/licenses/gpl.html)
 * Copyright (C) 2024-present Guoxin "7Ji" Pu (pugokushin@gmail.com)
 * This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version * of the License, or (at your option) any later version.

 * This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>

# Snasync - A **sna**pper snapshots **sync**er

Snasync is a simple and naive Bash script to help you to sync Btrfs snapshots created by [snapper](http://snapper.io/) to cold and remote backups.

Do note the although it's named "sync", it is mostly a **one-way sync**: the storage layout of subvolumes that was send-and-received are totally differeent from the source subvolumes, see below for the [In-and-out chapter](#in-and-out)

## Usage

```sh
snasync --source [source] (--prefix [prefix]) --target [target] (--target [target] (--target [target]))
```

- `--source [source]` is either the mountpoint containing .snapshots mountpoint, or .snapshots mountpoint itself, this is always required
- `--prefix [prefix]` is the sycned subvols prefix, by default this is `[source]` with all path-seperators and dots swapped to _
- `--target [target]` is either absolute path starting with / to put snapshots in, or a scp-style remote prefix to remotely send snapshots to. Can be specified so multiple targets can be used.
  - A local path should start with `/`, e.g. `/mnt/backup/snapshots`
  - Anything else is considered a remote path, and it should be in the scp-style, e.g. `root@backup.my.lan:/`

Due to the nature that a cold backup drive would not always be connected, by default a missing `[target]` would not cause snasync to fail. If

## In-and-out

Snasync runs independently of the snapper daemon, it just iterates through the to-be-synced snapshots folder and come up with the list to sync, and then sync them up. As such and the fact that a running snapper daemon instance could totally create new / delete old snapshots, it does the syncing in an atomic way:

1. For the given `[source]`, try to get the corresponding `/.snapshots` mountpoint, iterate through there
2. If there is `.snapshots/.snasync` folder, remove it
3. Create a `.snapshots/.snasync` folder, this is where all our later operations happen
4. For each snapshots under `.snapshots`, create a read-only snapshot at `.snapshots/.snasync/[prefix]-[timestamp].snapshot`, in which `[timestamp]` is parsed from the accompanying `info.xml` and it in `[YYYYMMDDHHMMSS]` format, and then copy that info file to `.snapshots/.snasync/[prefix]-[timestamp].info.xml`. As we store our snapshots under our own folders they won't be removed by snapper cleaner while we're at work.
5. Now snasync has an internal list of all timestamps, sort them up 
6. For each to-be-synced-to-target, check if there is a `[target]/[prefix]-[timestamp].snapshot` existing, if it exists then do nothing; if it does not exist then create a folder `[target]/[prefix]-[timestamp].snapshot.temp`, and send the snapshots to there. After it's received and the info.xml is copied to there, move both the snapshot and info out. This is so that the received snapshot is atomic: it is either not received, or fully received.

## License
**snasync** (snapper snapshots syncer) is licensed under [**GPL3**](https://gnu.org/licenses/gpl.html)
 * Copyright (C) 2024-present Guoxin "7Ji" Pu (pugokushin@gmail.com)
 * This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version * of the License, or (at your option) any later version.

 * This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>
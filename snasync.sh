#!/bin/bash

# snasync (snapper snapshots syncer) is licensed under [**GPL3**](https://gnu.org/licenses/gpl.html)
# Copyright (C) 2024-present Guoxin "7Ji" Pu (pugokushin@gmail.com)
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version * of the License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>

set -euo pipefail
export LANG=C
path_sources=''
prefix_snapshots=''
targets=()

while (( $# )); do
    case "$1" in
    '--source')
        path_sources=$(echo "$2" | sed 's|/\+$||')
        if [[ "${path_sources}" != */.snapshots ]]; then
            path_sources+='/.snapshots'
        fi
        shift
        ;;
    '--prefix')
        prefix_snapshots="$2"
        shift
        ;;
    '--target')
        targets+=($(echo "$2" | sed 's|/\+$||'))
        shift
        ;;
    '--help')
        echo 'snasyncer --source [source] (--prefix [prefix]) --target [target] (--target [target] (--target [target]))'
        echo
        printf '  --%-20s%s\n' \
            'source [source]' 'either the mountpoint containing .snapshots mountpoint, or .snapshots mountpoint itself' \
            'prefix [prefix]' 'the sycned subvols prefix, by default this is [source] with all path-seperators swapped to _ and then all leading _ removed' \
            'target [target]' 'either absolute path starting with / to put snapshots in, or a scp-style remote prefix to remotely send snapshots to'
        exit
        ;;
    *)
        echo "Unknown argument '$1', run snasyncer --help to check for help message"
        exit 1
        ;;
    esac
    shift
done

if [[ -z "${path_sources}" ]]; then
    echo 'Source is not set, refuse to continue'
    exit 1
fi

echo "Syncing ${path_sources}..."

if [[ -z "${prefix_snapshots}" ]]; then
    prefix_snapshots="${path_sources::-10}"
fi

prefix_snapshots="${prefix_snapshots//\//_}"

echo "Prefix is ${prefix_snapshots}"

if ! (( "${#targets[@]}" )); then
    echo "No targets, early exiting..."
    exit 1
fi

echo 'Checking if we need to stop snapper-cleanup.timer...'
if systemctl is-active snapper-cleanup.timer; then
    trap 'echo "Bringing back snapper-cleanup.timer..."; systemctl start snapper-cleanup.timer' INT TERM EXIT
    echo 'Stopping snapper-cleanup.timer, would start it after all operations'
    systemctl stop snapper-cleanup.timer
fi

echo 'Waiting fort possible running snapper cleanup instances...'
while systemctl is-active snapper-cleanup.service; do
    echo 'Waiting for snapper-cleanup.service to finish...'
    sleep 1
done


dates_snapshot=()
declare -A paths_source names_snapshot
for path_snapshot in $(find "${path_sources}" -mindepth 2 -maxdepth 2 -name snapshot); do
    path_info="${path_snapshot::-9}/info.xml"
    date_snapshot=$(sed -n '/^  <date>/s/[^0-9]//gp' "${path_info}")
    if (( ${#date_snapshot} != 14 )); then
        echo "Warning: timestamp ${date_snapshot} dumped from ${path_info} is not valid, skip snapshot ${path_snapshot}"
        continue
    fi
    dates_snapshot+=("${date_snapshot}")
    paths_source["${date_snapshot}"]="${path_snapshot::-9}"
    names_snapshot["${date_snapshot}"]="${prefix_snapshots}-${date_snapshot}"
done

dates_snapshot=($(printf '%s\n' "${dates_snapshot[@]}" | sort))

for target in "${targets[@]}"; do
    echo "Syncing ${path_sources} to ${target}..."
    if [[ "${target::1}" == '/' ]]; then
        if [[ ! -d "${target}" ]]; then
            echo "Skipping non-existing target ${target}"
            continue
        fi
        echo "Syncing locally to ${target}"
        args_parent=()
        for date_snapshot in "${dates_snapshot[@]}"; do
            should_sync='y'
            name_snapshot="${names_snapshot["${date_snapshot}"]}"
            path_target="${target}/${name_snapshot}"
            path_source="${paths_source["${date_snapshot}"]}"
            echo "Checking if we need to sync ${path_source} to ${path_target}..."
            if [[ -d "${path_target}" ]]; then
                if [[ -d "${path_target}/snapshot" ]]; then
                    uuid_target=$(btrfs subvolume show "${path_target}/snapshot" | awk '/Received UUID/{print $3}')
                    if [[ "${#uuid_target}" == 36 ]]; then
                        if [[ ! -f "${path_target}/info.xml" ]]; then
                            cp "${path_source}/info.xml" "${path_target}/info.xml"
                        fi
                        echo "Skipping already synced snapshot ${path_target}"
                        should_sync=''
                    else
                        echo "A previous sync to ${path_target} was failed, deleting it..."
                        btrfs subvolume delete "${path_target}/snapshot"
                        rm -f "${path_target}/info.xml"
                    fi
                fi
            else
                mkdir "${path_target}"
            fi
            if [[ "${should_sync}" ]]; then
                echo "Syncing ${path_source} to ${path_target}..."
                btrfs send "${args_parent[@]}" "${path_source}/snapshot" | btrfs receive "${path_target}"
                cp "${path_source}/info.xml" "${path_target}/info.xml"
            fi
            args_parent=(-p "${path_source}/snapshot")
        done
    else
        echo "Remote syncing not implemented yet, skipping ${target}"

    fi
done

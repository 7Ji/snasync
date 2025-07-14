#!/bin/bash

# snasync cross site helper (snapper snapshots syncer) is licensed under [**GPL3**](https://gnu.org/licenses/gpl.html)
# Copyright (C) 2025-present Guoxin "7Ji" Pu (pugokushin@gmail.com)
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version * of the License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>

log() {
    echo "[snasync site-to-site] ${FUNCNAME[1]}@${BASH_LINENO[0]}: $*"
}

initialize() {
    set -euo pipefail
    export LANG=C
    if (( $(id -u) != 0 )); then
        log 'Site-to-site syncer must be run with root permission'
        return 1
    fi
    declare -gA sent
    path_source=''
    path_target=''
}

is_container_name() {
    if [[ "$1" =~ ^.+-[0-9]{14}$ ]]; then
        return 0
    else
        return 1
    fi
}

update_sent() {
    if ! is_container_name "$1"; then
        log "Argumrnt '$1' for --with does not look like a container name"
        return 1
    fi

    local prefix_this="${1::-15}"
    local date_this=${1: -14}
    local date_last="${sent["${prefix_this}"]:-}"
    if [[ "${date_last}" ]]; then
        if [[ "${date_last}" -lt "${date_this}" ]]; then
            sent["${1::-15}"]="${1: -14}"
        fi
    else
        sent["${1::-15}"]="${1: -14}"
    fi
}

is_snapshot() {
    if [[ -d "$1" ]] &&
        btrfs subvolume show "$1" &>/dev/null &&
        [[ $(btrfs property get "$1" ro) == 'ro=true' ]]
    then
        return 0
    else
        return 1
    fi
}

check_source_target() {
    if [[ -z "${path_source}" ]]; then
        log 'Path for source not specified'
        return 1
    fi
    if [[ ! -d "${path_source}" ]]; then
        log "Path for source does not point to a folder '${path_source}'"
        return 1
    fi
    if [[ -z "${path_target}" ]]; then
        log 'Path for target not specified'
        return 1
    fi
    if [[ ! -d "${path_target}" ]]; then
        log "Path for target does not point to a folder '${path_target}'"
        return 1
    fi
}

send() {
    local path_container name_container path_snapshot prefix_container date_container date_last name_parent path_parent path_parent_snapshot args_parent=() path_archived path_archived_snapshot with_raw=''
    for path_container in "${path_source}/"*; do
        name_container="${path_container##*/}"
        if ! is_container_name "${name_container}"; then
            continue
        fi
        path_snapshot="${path_container}/snapshot"
        if ! is_snapshot "${path_snapshot}"; then
            log "Skipped container ${path_container} which does not contain a valid snapshot"
            continue
        fi
        prefix_container="${name_container::-15}"
        date_container="${name_container: -14}"
        date_last="${sent[${prefix_container}]:-}"
        if [[ "${date_last}" ]]; then
            name_parent="${prefix_container}-${date_last}"
            path_parent="${path_source}/${name_parent}"
            path_parent_snapshot="${path_parent}/snapshot"
            if  [[ -d "${path_parent_snapshot}" ]] &&
                btrfs subvolume show "${path_parent_snapshot}" &>/dev/null &&
                [[ $(btrfs property get "${path_parent_snapshot}" ro) == 'ro=true' ]]
            then
                if [[ "${date_container}" -le "${date_last}" ]]; then
                    log "Skipped ${path_container} as it is older than latest parent ${path_parent}"
                    continue
                else
                    args_parent=(-p "${path_parent_snapshot}")
                fi
            else
                args_parent=()
                log "Ignored invalid parent '${path_parent}'"
            fi
        else
            args_parent=()
        fi
        path_archived="${path_target}/${name_container}"
        mkdir -p "${path_archived}"
        if [[ ! -f "${path_archived}/info.xml" ]]; then
            cp -f "${path_container}/info.xml" "${path_archived}/info.xml"
        fi
        path_archived_snapshot="${path_archived}/snapshot"
        if [[ -e "${path_archived_snapshot}" ]]; then
            if [[ -f "${path_archived_snapshot}" ]]; then
                log "Skipped already synced ${path_container}"
                sent["${prefix_container}"]="${date_container}"
                continue
            fi
            rm -rf "${path_archived_snapshot}"
        fi
        rm -rf "${path_archived_snapshot}".temp
        log "Syncing ${path_container}, args_parent: ${args_parent[*]}"
        btrfs send --compressed-data "${args_parent[@]}" -- "${path_snapshot}" > "${path_archived_snapshot}".temp
        mv "${path_archived_snapshot}"{.temp,}
        sent["${prefix_container}"]="${date_container}"
    done

    for prefix_container in "${!sent[@]}"; do
        if [[ "${with_raw}" ]]; then
            with_raw+=' '
        fi
        with_raw+="--with '${prefix_container}-${sent[${prefix_container}]}'"
    done
    echo "${with_raw}" > "${path_target}/SEND_NEXT_WITH"
    log "In the next send run, you can specify the following arguments to omit the already sent snapshots (also stored in file SEND_NEXT_WITH inside target folder): ${with_raw}"
}

receive() {
    local path_archived name_container path_archived_snapshot
    for path_archived in "${path_source}/"*; do
        name_container="${path_archived##*/}"
        if ! is_container_name "${name_container}"; then
            continue
        fi
        path_archived_snapshot="${path_archived}/snapshot"
        if ! [[ -f "${path_archived_snapshot}" ]]; then
            log "Skipped archive at ${path_archived} as it misses plain-file snapshot"
            continue
        fi
        prefix_container="${name_container::-15}"
        date_container="${name_container: -14}"
        path_container="${path_target}/${name_container}"
        mkdir -p "${path_container}"
        if [[ ! -e "${path_container}/info.xml" && -f "${path_archived}/info.xml" ]]; then
            cp {"${path_archived}","${path_container}"}/info.xml
        fi
        path_snapshot="${path_container}/snapshot"
        if [[ -e "${path_snapshot}" ]]; then
            if is_snapshot "${path_snapshot}"; then
                log "Skipped already synced ${path_snapshot}"
                continue
            fi
            log "Deleting ${path_snapshot} which does not appear to be a snapshot"
            if ! btrfs subvolume delete "${path_snapshot}"; then
                log "Failed to remove ${path_snapshot} as a Btrfs subvolume, removing it as plain folder"
                rm -rf "${path_snapshot}"
            fi
        fi
        log "Syncing ${path_container}"
        btrfs receive --force-decompress "${path_container}" < "${path_archived_snapshot}"
    done
}


cli() {
    initialize
    case "$1" in
    'send')
        shift
        while (( $# )); do
            case "$1" in
            '--with')
                if ! update_sent "$2"; then
                    log "Failed to update sent data with '$2'"
                    return 1
                fi
                shift
                ;;
            -*)
                log "Unknown argument '$1'"
                return 1
                ;;
            *)
                if [[ -z "${path_source}" ]]; then
                    path_source="$1"
                elif [[ -z "${path_target}" ]]; then
                    path_target="$1"
                else
                    log "Unknown argument '$1'"
                    return 1
                fi
                ;;
            esac
            shift
        done
        check_source_target
        send
        ;;
    'receive')
        shift
        while (( $# )); do
            case "$1" in
            -*)
                log "Unknown argument '$1'"
                return 1
                ;;
            *)
                if [[ -z "${path_source}" ]]; then
                    path_source="$1"
                elif [[ -z "${path_target}" ]]; then
                    path_target="$1"
                else
                    log "Unknown argument '$1'"
                    return 1
                fi
                ;;
            esac
            shift
        done
        check_source_target
        receive
        ;;
    *)
        log "Invalid mode '$1', only send and receive are allowed"
        return 1
        ;;
    esac
}

cli "$@"

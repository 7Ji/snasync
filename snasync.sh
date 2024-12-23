#!/bin/bash

# snasync (snapper snapshots syncer) is licensed under [**GPL3**](https://gnu.org/licenses/gpl.html)
# Copyright (C) 2024-present Guoxin "7Ji" Pu (pugokushin@gmail.com)
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version * of the License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>

log() {
    echo "[snasync] ${FUNCNAME[1]}@${BASH_LINENO[0]}: $*"
}

initialize() {
    set -euo pipefail
    export LANG=C
    if (( $(id -u) == 0 )); then
        log 'Refuse to be executed with root permission'
        return 1
    fi
  
    paths_source=()
    prefixes_snapshot=()
    targets=()
    sources_target_start=()
    sources_target_end=()
    declare -gA targets_offset
    declare -gA targets_end
    wrapper_local='sudo'
    declare -gA wrappers_remote
}

check_options() {
    if ! (( "${#paths_source[@]}" )); then
        log 'No source was defined, refuse to continue'
        return 1
    fi
    if ! (( "${#targets[@]}" )); then
        log 'No target was defined, refuse to continue'
        return 1
    fi
}

show_options() {
    local i=0 j path_source source_target_end
    log "Options:"
    for path_source in "${paths_source[@]}"; do
        j="${sources_target_start[$i]}"
        source_target_end="${sources_target_end[$i]}"
        while (( "$j" <= "${source_target_end}" )); do
            log "Sync ${path_source} (prefix ${prefixes_snapshot[$i]}) => ${targets[$j]}"
            j=$(( "$j" + 1 ))
        done
        i=$(( "$i" + 1 ))
    done
    log "Wrapper for local permission-sensitive operations: ${wrapper_local}"
    for i in "${!wrappers_remote[@]}"; do
        log "Wrapper for remote permission-sensitive operations at $i: ${wrappers_remote[$i]}"
    done
}

finish_options() {
    local target remote
    for target in "${targets[@]}"; do
        [[ "${target::1}" == '/' ]] && continue
        remote="${target%%:*}"
        if [[ -z "${wrappers_remote[${remote}]+set}" ]]; then
            wrappers_remote[${remote}]='sudo'
        fi
    done
    check_options
    show_options
}

systemd_post() {
    log 'Bringing back snapper-cleanup.timer...'
    "${wrapper_local}" systemctl start snapper-cleanup.timer
}

systemd_pre() {
    log 'Checking if we need to stop snapper-cleanup.timer...'
    if "${wrapper_local}" systemctl is-active snapper-cleanup.timer > /dev/null; then
        log 'Unit snapper-cleanup.timer is running, stopping it...'
        trap "systemd_post" INT TERM EXIT
        "${wrapper_local}" systemctl stop snapper-cleanup.timer
        log 'Stopped snapper-cleanup.timer, would start it after all operations'
    else
        log 'No need to stop snapper-cleanup.timer as it is not running'
    fi

    log 'Waiting for possible running snapper-cleanup.service instances...'
    while "${wrapper_local}" systemctl is-active snapper-cleanup.service > /dev/null; do
        log 'Waiting for snapper-cleanup.service to finish... (check interval 1s)'
        sleep 1
    done
}

sync_local_target() {
    log "Syncing source ${path_source} to local target ${target}..."
    if [[ ! -d "${target}" ]]; then
        log "Skipped non-existing local target ${target}"
        return
    fi
    local \
        args_parent=() \
        date_snapshot \
        should_sync \
        name_snapshot \
        path_{source,target}_{container,snapshot,info} \
        uuid_received

    for date_snapshot in "${dates_snapshot[@]}"; do
        should_sync='y'
        name_snapshot="${names_snapshot["${date_snapshot}"]}"
        path_target_container="${target}/${name_snapshot}"
        path_target_snapshot="${path_target_container}/snapshot"
        path_target_info="${path_target_container}/info.xml"
        path_source_container="${paths_source_container["${date_snapshot}"]}"
        path_source_snapshot="${path_source_container}/snapshot"
        path_source_info="${path_source_container}/info.xml"
        log "Checking if it is needed to sync ${path_source_container} to ${path_target_container}..."
        if "${wrapper_local}" test -d "${path_target_container}"; then
            if "${wrapper_local}" test -d "${path_target_snapshot}"; then
                uuid_received=$("${wrapper_local}" btrfs subvolume show "${path_target_snapshot}" | awk '/Received UUID/{print $3}')
                if [[ "${#uuid_received}" == 36 ]]; then
                    if [[ ! -f "${path_target_info}" ]]; then
                        "${wrapper_local}" cp --no-preserve=ownership "${path_source_info}" "${path_target_info}"
                    fi
                    log "Skipping already synced snapshot ${path_target_container}"
                    should_sync=''
                else
                    log "A previous sync to ${path_target_container} was failed, deleting it..."
                    "${wrapper_local}" btrfs subvolume delete "${path_target_snapshot}"
                    "${wrapper_local}" rm -f "${path_target_info}"
                fi
            fi
        else
            "${wrapper_local}" mkdir "${path_target_container}"
        fi
        if [[ "${should_sync}" ]]; then
            log "Syncing ${path_source} to ${path_target_container} (args parent: ${args_parent[*]})..."
            "${wrapper_local}" btrfs send "${args_parent[@]}" "${path_source_snapshot}" | "${wrapper_local}" btrfs receive "${path_target_container}"
            "${wrapper_local}" cp --no-preserve=ownership "${path_source_info}" "${path_target_info}"
        fi
        args_parent=(-p "${path_source_snapshot}")
    done

}

sync_remote_target() {
    log "Syncing source ${path_source} to remote target ${target} at ${remote}..."
    log "Remote syncing not implemented yet, skipping"
    # for target in "${targets[@]}"; do
    #     echo "Syncing ${path_source} to ${target}..."
    #     if [[ "${target::1}" == '/' ]]; then
    #         if [[ ! -d "${target}" ]]; then
    #             echo "Skipping non-existing target ${target}"
    #             continue
    #         fi
    #         echo "Syncing locally to ${target}"
    #         args_parent=()

    #     else
    #         remote="${target%%:*}"
    #         args_remote=(ssh -o ConnectTimeout=5 "${remote}" --)
    #         if ! "${args_remote[@]}" true; then
    #             echo "Skipped unreachable remote ${remote}"
    #             continue
    #         fi
    #         target="${target#*:}"
    #         if ! "${args_remote[@]}" "test -d '${target}'"; then
    #             echo "Skipped non-existing remote target ${target} at ${remote}"
    #             continue
    #         fi
    #         echo "Syncing remotely to ${target} at ${remote}..."
    #         args_parent=()
    #         for date_snapshot in "${dates_snapshot[@]}"; do
    #             should_sync='y'
    #             name_snapshot="${names_snapshot["${date_snapshot}"]}"
    #             path_target="${target}/${name_snapshot}"
    #             path_source="${paths_source["${date_snapshot}"]}"
    #             echo "Checking if we need to sync ${path_source} to ${path_target} at ${remote}..."
    #             if "${args_remote[@]}" "test -d '${path_target}'"; then
    #                 if "${args_remote[@]}" "test -d '${path_target}/snapshot'" ; then
    #                     uuid_target=$("${args_remote[@]}" "btrfs subvolume show '${path_target}/snapshot'" | awk '/Received UUID/{print $3}')
    #                     if [[ "${#uuid_target}" == 36 ]]; then
    #                         if ! "${args_remote[@]}" "test -f '${path_target}/info.xml'" ]]; then
    #                             "${args_remote[@]}" "tee '${path_target}/info.xml'" < "${path_source}/info.xml" > /dev/null
    #                         fi
    #                         echo "Skipping already synced snapshot ${path_target} at ${remote}"
    #                         should_sync=''
    #                     else
    #                         echo "A previous sync to ${path_target} was failed, deleting it..."
    #                         "${args_remote[@]}" btrfs subvolume delete "${path_target}/snapshot"
    #                         "${args_remote[@]}" rm -f "${path_target}/info.xml"
    #                     fi
    #                 fi
    #             else
    #                 mkdir "${path_target}"
    #             fi
    #             if [[ "${should_sync}" ]]; then
    #                 echo "Syncing ${path_source} to ${path_target} (args parent: ${args_parent[*]})..."
    #                 btrfs send "${args_parent[@]}" "${path_source}/snapshot" | "${args_remote[@]}" btrfs receive "${path_target}"
    #                 "${args_remote[@]}" "tee '${path_target}/info.xml'" < "${path_source}/info.xml" > /dev/null
    #             fi
    #             args_parent=(-p "${path_source}/snapshot")
    #         done

    #     fi
    # done
}

sync_target() {
    if [[ "${target::1}" == '/' ]]; then
        sync_local_target
    else
        local \
            remote="${target%%:*}"
            target="${target#*:}"
        sync_remote_target
    fi
}

sync_source() {
    log "Syncing source ${path_source}..."
    declare -A \
        paths_source_container \
        names_snapshot
    local \
        dates_snapshot=() \
        date_snapshot \
        path_source_snapshot \
        path_source_info \
        path_source_container

    for path_source_snapshot in $("${wrapper_local}" find "${path_source}" -mindepth 2 -maxdepth 2 -type d -name snapshot); do
        path_source_container="${path_source_snapshot::-9}"
        path_source_info="${path_source_container}/info.xml"
        date_snapshot=$("${wrapper_local}" sed -n '/^  <date>/s/[^0-9]//gp' "${path_source_info}")
        dates_snapshot+=("${date_snapshot}")
        paths_source_container[${date_snapshot}]="${path_source_container}"
        names_snapshot[${date_snapshot}]="${prefix_snapshot}-${date_snapshot}"
    done

    dates_snapshot=($(printf '%s\n' "${dates_snapshot[@]}" | sort))

    local \
        target \
        i="${source_target_start}"

    while (( "$i" <= "${source_target_end}" )); do
        target="${targets[$i]}"
        sync_target
        i=$(("$i" + 1))
    done
}

work() {
    systemd_pre
    local \
        path_source \
        prefix_snapshot \
        source_target_start \
        source_target_end \
        i=0
    for path_source in "${paths_source[@]}"; do
        prefix_snapshot="${prefixes_snapshot[$i]}"
        source_target_start="${sources_target_start[$i]}"
        source_target_end="${sources_target_end[$i]}"
        sync_source
        i=$(( "$i" + 1 ))
    done
}

init_source() {
    prefix_snapshot=''
    source_target_start=-1
}

finish_source() {
    if [[ -z "${path_source}" ]]; then
        log 'Source path is empty, refuse to continue'
        return 1
    fi
    paths_source+=("${path_source}")

    if [[ -z "${prefix_snapshot}" ]]; then
        prefix_snapshot="${path_source::-10}"
        prefix_snapshot="${prefix_snapshot////_}" # all / to _
    fi
    prefixes_snapshot+=("${prefix_snapshot}")

    if (( "${source_target_start}" >= 0 )); then
        if (( "${target_id}" < "${source_target_start}" )); then
            log "Imposisble: target ID ${target_id} smaller than current source target start ID ${source_target_start}"
            return 1
        fi
        sources_target_start+=("${source_target_start}")
        sources_target_end+=("${target_id}")
    else
        sources_target_start+=('-1')
        sources_target_end+=('-1')
    fi
}

path_source_from() {
    path_source=$(echo "$1" | sed 's|/\+$||')
    if [[ "${path_source}" != */.snapshots ]]; then
        path_source+='/.snapshots'
    fi
}

cli() {
    initialize
    local path_source=''
    local \
        prefix_snapshot \
        source_target_start \
        target_id=-1
    init_source
    while (( $# )); do
        case "$1" in
        '--source')
            if [[ "${path_source}" ]]; then
                finish_source
                init_source
            fi
            path_source_from "$2"
            shift
            ;;
        '--prefix')
            prefix_snapshot="$2"
            shift
            ;;
        '--target')
            targets+=("$2")
            target_id=$(( "${target_id}" + 1 ))
            if (( "${source_target_start}" < 0 )); then
                source_target_start="${target_id}"
            fi
            shift
            ;;
        '--help')
            echo 'snasyncer --source [source] (--prefix [prefix]) --target [target] (--target [target] (--target [target]))'
            echo
            printf '  --%-20s%s\n' \
                'source [source]' 'either the mountpoint containing .snapshots mountpoint, or .snapshots mountpoint itself, this begins the declaration of a single syncing operation, multiple [source] could be defined, e.g. "/.snapshots", "/home"' \
                'prefix [prefix]' 'the sycned subvols prefix, by default this is [source] with all path-seperators swapped to _ and then all leading _ removed, e.g. for source "/home" the default would be _home' \
                'target [target]' 'either absolute path starting with / to put snapshots in, or a scp-style remote prefix to remotely send snapshots to, e.g. "/srv/backup/warm/snapshots", "nas.lan:/srv/snapshots", etc' \
                'wrapper [wrapper]' 'a "wrapper" for local permission-sensitive operations, by default this is sudo, it could also be a script'
            exit
            ;;
        '--wrapper-local')
            wrapper_local="$2"
            shift
            ;;
        '--wrapper-remote:'*)
            wrappers_remote["${1:17}"]="$2"
            shift
            ;;
        *)
            echo "Unknown argument '$1', run snasyncer --help to check for help message"
            exit 1
            ;;
        esac
        shift
    done
    finish_source
    finish_options
    work
}

cli "$@"
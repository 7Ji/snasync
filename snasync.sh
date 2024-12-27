#!/bin/bash

# snasync (snapper snapshots syncer) is licensed under [**GPL3**](https://gnu.org/licenses/gpl.html)
# Copyright (C) 2024-present Guoxin "7Ji" Pu (pugokushin@gmail.com)
# This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version * of the License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

# You should have received a copy of the GNU General Public License along with this program. If not, see <https://www.gnu.org/licenses/>

log() {
    echo "[snasync #${BASHPID}] ${FUNCNAME[1]}@${BASH_LINENO[0]}: $*"
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
    declare -gA status_remote
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
            log "Syncing ${path_source_container} to ${path_target_container} (args parent: ${args_parent[*]})..."
            "${wrapper_local}" btrfs send --compressed-data "${args_parent[@]}" -- "${path_source_snapshot}" | "${wrapper_local}" btrfs receive --force-decompress -- "${path_target_container}"
            "${wrapper_local}" cp --no-preserve=ownership "${path_source_info}" "${path_target_info}"
        fi
        args_parent=(-p "${path_source_snapshot}")
        paths_target_container+=("${path_target_container}")
    done

    for name_snapshot in $("${wrapper_local}" find "${target}" -maxdepth 1 -mindepth 1 -type d -name "${prefix_snapshot}"'-*' | sed -n 's|.*/\('"${prefix_snapshot}"'-[0-9]\{14\}\)$|\1|p'); do
        if ! grep -q -- "${name_snapshot}" "${path_note_names_snapshot}"; then
            log "Marking snapshot ${name_snapshot} at ${target} as orphan as its source snapshot was gone"
            "${wrapper_local}" mv "${target}/${name_snapshot}"{,.orphan}
        fi
    done
}

get_args_remote() {
    args_remote=(ssh 
        -o ConnectTimeout=5 
        -o ConnectionAttempts=1
        -o Compression=no
        -o Ciphers=aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
        -o ControlMaster=auto
        -o ControlPersist=15
        -o ControlPath=~/.ssh/sockets/socket@snasync-%r@%h:%p
        "${remote}" --)
}

sync_remote_target() {
    log "Syncing source ${path_source} to remote target ${target} at ${remote}..."
    declare -a args_remote
    get_args_remote
    if ! "${args_remote[@]}" "test -d '${target}'"; then
        log "Skipped non-existing remote target ${target} at ${remote} or a bad remote"
        continue
    fi
    local \
        args_parent=() \
        date_snapshot \
        should_sync \
        name_snapshot \
        path_{source,target}_{container,snapshot,info} \
        uuid_received \
        wrapper_remote="${wrappers_remote[${remote}]}"

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
        if "${args_remote[@]}" "${wrapper_remote} test -d '${path_target_container}'"; then
            if "${args_remote[@]}" "${wrapper_remote} test -d '${path_target_snapshot}'"; then
                uuid_received=$("${args_remote[@]}" "${wrapper_remote} btrfs subvolume show '${path_target_snapshot}'" | awk '/Received UUID/{print $3}')
                if [[ "${#uuid_received}" == 36 ]]; then
                    if [[ ! -f "${path_target_info}" ]]; then
                        "${wrapper_local}" cat "${path_source_info}" | 
                            "${args_remote[@]}" "${wrapper_remote} tee '${path_target_info}'" \
                            > /dev/null
                    fi
                    log "Skipping already synced snapshot ${path_target_container}"
                    should_sync=''
                else
                    log "A previous sync to ${path_target_container} was failed, deleting it..."
                    "${args_remote[@]}" "${wrapper_remote} btrfs subvolume delete '${path_target_snapshot}'"
                    "${args_remote[@]}" "${wrapper_remote} rm -f '${path_target_info}'"
                fi
            fi
        else
            "${args_remote[@]}" "${wrapper_remote} mkdir '${path_target_container}'"
        fi
        if [[ "${should_sync}" ]]; then
            log "Syncing ${path_source_container} to ${path_target_container} at ${remote} (args parent: ${args_parent[*]})..."
            "${wrapper_local}" btrfs send --compressed-data "${args_parent[@]}" -- "${path_source_snapshot}" | "${args_remote[@]}" "${wrapper_local} btrfs receive --force-decompress -- '${path_target_container}'"
            "${wrapper_local}" cat "${path_source_info}" | 
                "${args_remote[@]}" "${wrapper_remote} tee '${path_target_info}'" \
                > /dev/null
        fi
        args_parent=(-p "${path_source_snapshot}")
    done

    for name_snapshot in $("${args_remote[@]}" "${wrapper_remote} find '${target}' -maxdepth 1 -mindepth 1 -type d -name '${prefix_snapshot}-*'" | sed -n 's|.*/\('"${prefix_snapshot}"'-[0-9]\{14\}\)$|\1|p'); do
        if ! grep -q -- "${name_snapshot}" "${path_note_names_snapshot}"; then
            log "Marking snapshot ${name_snapshot} at ${target} at ${remote} as orphan as its source snapshot was gone"
            "${args_remote[@]}" "${wrapper_remote} mv '${target}/${name_snapshot}' '${target}/${name_snapshot}.orphan'"
        fi
    done
}

sync_target() {
    if [[ "${target::1}" == '/' ]]; then
        sync_local_target
    else
        local \
            remote="${target%%:*}"
            target="${target#*:}"
        case "${status_remote[${remote}]}" in
        'good')
            sync_remote_target
            ;;
        'bad')
            log "Skipped syncing ${path_source} to target ${target} at"\
                "${remote} as we failed to warm up it"
            ;;
        *)
            log "Previous warmed up status for remote ${remote} is illegal"
            return 1
            ;;
        esac
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
        if [[ $("${wrapper_local}" btrfs property get "${path_source_snapshot}" ro) == 'ro=false' ]]; then
            log "Skipping read-write snapshot ${path_source_snapshot}"
            continue
        fi
        path_source_container="${path_source_snapshot::-9}"
        path_source_info="${path_source_container}/info.xml"
        date_snapshot=$("${wrapper_local}" sed -n '/^  <date>/s/[^0-9]//gp' "${path_source_info}")
        dates_snapshot+=("${date_snapshot}")
        paths_source_container[${date_snapshot}]="${path_source_container}"
        names_snapshot[${date_snapshot}]="${prefix_snapshot}-${date_snapshot}"
    done

    dates_snapshot=($(printf '%s\n' "${dates_snapshot[@]}" | sort))

    local path_note_names_snapshot=$(mktemp)
    for date_snapshot in "${dates_snapshot[@]}"; do
        echo "${names_snapshot[${date_snapshot}]}"
    done > "${path_note_names_snapshot}"

    local \
        target \
        i="${source_target_start}"

    while (( "$i" <= "${source_target_end}" )); do
        target="${targets[$i]}"
        sync_target &
        i=$(("$i" + 1))
    done

    wait

    rm -f "${path_note_names_snapshot}"
}

warm_up_remotes() {
    local remote
    declare -a args_remote
    mkdir -p ~/.ssh/sockets
    for remote in "${!wrappers_remote[@]}"; do
        log "Warming up remote ${remote}..."
        get_args_remote
        if "${args_remote[@]}" 'exit'; then
            status_remote["${remote}"]='good'
            log "Warmed up remote ${remote}"
        else
            status_remote["${remote}"]='bad'
            log "Failed to warm up remote ${remote}, would skip it when syncing"
        fi
    done
}

work() {
    systemd_pre
    warm_up_remotes
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
        sync_source &
        i=$(( "$i" + 1 ))
    done

    wait
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
    if [[ "${1::1}" != '/' ]]; then
        log "Source '$1' is not an absolute path"
        return 1
    fi
    path_source=$(echo "$1" | sed 's|/\+$||')
    if [[ "${path_source}" != */.snapshots ]]; then
        path_source+='/.snapshots'
    fi
}

add_target() {
    if [[ "${1::1}" != '/' ]] && [[ "${1#*:}" != /* ]]; then
        log "Target '$1' is not an absolute local/remote path"
        return 1
    fi
    targets+=("$1")
    target_id=$(( "${target_id}" + 1 ))
    if (( "${source_target_start}" < 0 )); then
        source_target_start="${target_id}"
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
            add_target "$2"
            shift
            ;;
        '--help')
            echo "$0 --source [source] (--prefix [prefix]) --target [target] (--target [target] (--target [target])) ..."
            echo
            printf '  --%-37s%s\n' \
                'source [source]' 'either the mountpoint containing .snapshots mountpoint, or .snapshots mountpoint itself, this begins the declaration of a single syncing operation, multiple [source] could be defined and each needs their corresponding [target]s (see below), e.g. "/.snapshots", "/home"' \
                'prefix [prefix]' 'the sycned subvols prefix for the current source, by default this is [source] with all path-seperators swapped to _ and then all leading _ removed, e.g. for source "/home" the default would be _home' \
                'target [target]' 'either absolute path starting with / to put snapshots in, or a scp-style remote prefix to remotely send snapshots to, for current source, e.g. "/srv/backup/warm/snapshots", "nas.lan:/srv/snapshots", etc' \
                'wrapper-local [wrapper]' 'a "wrapper" for local permission-sensitive operations, default: sudo, it could also be a script' \
                'wrappper-remote:[remote] [wrapper]' 'a "wrapper" for remote permisison-sensitive operations for the specific remote, default: sudo'
            echo
            echo 'Note: if you want to sync multiple sources, it is recommended to do them in a single snasync invocation, e.g. snasync --source / --prefix pc_root --target /srv/backup/warm/snapshots --target nas.lan:/srv/backup/snapshots --source /home --prefix pc_home --target /srv/backup/warm/snapshots --target nas.lan:/srv/backup/snapshots'
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

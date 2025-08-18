#!/bin/bash
#
# Name: ragnar
# Auth: Gavin Lloyd <gavinhungry@gmail.com>
# Desc: Mount an existing remote LUKS device with NBD over SSH
#
# Released under the terms of the MIT license
# https://github.com/gavinhungry/ragnar
#
#

if [[ ! -z ${DEBUG} ]]; then
  set -x
  set -e
fi

[ ${_ABASH:-0} -ne 0 ] || source $(dirname "${BASH_SOURCE}")/abash/abash.sh

SERVER=${RAGNAR_SERVER:-zigloo}
echo "SERVER $SERVER"
NBDEXPORT=${RAGNAR_NBDEXPORT:-$SERVER}
ZPOOL=${ZPOOL:-$SERVER}
KEYFILE=${RAGNAR_KEYFILE:-/etc/luks/${NBDEXPORT}.key}
echo "keyfile $KEYFILE"
HEADER=${RAGNAR_HEADER:-/etc/luks/${NBDEXPORT}.header}
NUM_DRIVES=${RAGNAR_NUM_DRIVES:-"5"}

TMP=$(tmpdirp "${SERVER}-${NBDEXPORT}")
mkdir -p ${TMP}
SERVER_IP=$(ssh -G ${SERVER} | grep -i "^hostname " | cut -d " " -f 2)

# use TMP dir for ctl_path
ssh_is_open() {
  ssh -qO check -S "${TMP}/ssh" ${SERVER_IP} &> /dev/null
}

open_ssh() {
  ssh -fNn -MS "${TMP}/ssh" -L 10809:127.0.0.1:10809 ${SERVER_IP}
}

close_ssh() {
  if ssh_is_open; then
    ssh -qO exit -S "${TMP}/ssh" ${SERVER_IP}
  fi
}

nbd_device() {
  IDX=$1
  cat "${TMP}/nbd${IDX}" 2> /dev/null
}

nbd_is_open() {
  [ -f "/sys/block/${1}/pid" ] && nbd-client -c "/dev/${1}" &>/dev/null && [ "$(sudo blockdev --getsize64 "/dev/${1}" 2>/dev/null)" -gt 0 ]
}

# TODO this isn't actually working :(
wait_for_nbd() {
    local device=$(nbd_device $1)
    local timeout=${2:-10}  # Default 2 seconds
    local max_iterations=$((timeout * 2))  # Convert to 0.1s iterations
    local iterations=0
    echo "waiting for nbd device: ${device}"

    while ! nbd_is_open "$device"; do
        if (( iterations >= max_iterations )); then
            return 1  # Timeout reached
        fi
        sleep 0.1
        ((iterations++))
    done

    # nbd_is_open is now properly returning 0 when the device is actually up and capable
    # of being decrypted by LUKS, however, before blockdev was being used there was a race
    # condition that made the LUKS decrypt fail because /dev/nbd# wasn't "quite ready" even
    # though /sys/block/nbd#/pid and nbd-client -c "/dev/nbd#" returned success. So out
    # of an abundance of caution and mistrust of the system... putting a tiny sleep here
    # because it's way more important ragnar not fail then be 0.5s faster.

    sleep 0.1

    return 0  # Device is open
}

nbd_next_open() {
  IDX=$1
  checksu modprobe nbd

  echo "nbd${IDX}"
  return

  for DEV in /dev/nbd*; do
    NBD=$(echo ${DEV} | cut -d'/' -f3)
    if ! nbd_is_open ${NBD}; then
      echo ${NBD}
      return
    fi
  done
}

export_is_open() {
  IDX=$1
  [ -f "${TMP}/nbd${IDX}" ] || return 1
  nbd_is_open $(nbd_device ${IDX})
}

open_export() {
  checksu modprobe nbd
  NBD=$1
  IDX=$2

  if quietly checksu nbd-client 127.0.0.1 /dev/${NBD} -connections 2 -name ${NBDEXPORT}${IDX}; then
    echo ${NBD} > ${TMP}/nbd${IDX}
  else
    close_ssh
    rm -rf ${TMP}/nbd${IDX}
    return 1
  fi
}

close_export() {
  IDX=$1
  if [[ -n "$(export_is_open ${IDX})" ]]; then
    checksu
    checksu modprobe nbd
    quietly checksu nbd-client -d /dev/$(nbd_device ${IDX}) && quietly rm -f "${TMP}/nbd${IDX}"
  fi
}

luks_is_open() {
  IDX=$1
  [ -b "/dev/mapper/${NBDEXPORT}${IDX}" ]
}

luks_open() {
  NBD=$1
  IDX=$2
  #checksu [ -f ${HEADER} ] || HEADER=${NBD}
  checksu cryptsetup open /dev/${NBD} ${NBDEXPORT}${IDX} --key-file ${KEYFILE} # --header ${HEADER}
}

luks_close() {
  IDX=$1
  checksu cryptsetup close /dev/mapper/${NBDEXPORT}${IDX}
}

open() {
  if sudo zpool list -H -o name ${ZPOOL} 2>&1; then
      inform "Already mounted zpool ${ZPOOL}."
      return 0;
  fi

  for i in $(seq 0 $((NUM_DRIVES - 1))); do
    checksu [ -f "${KEYFILE}" ] || die "Keyfile not found"
    for j in $(seq 0 10); do
        if [[ ${j} = 10 ]]; then
            CMD=die
        else
            CMD=warn
        fi

        if ssh_is_open; then
          inform "SSH connection already open to ${SERVER}"
        else
          open_ssh
          inform "Opening SSH connection to ${SERVER}" || ${CMD} "Could not open SSH connection to ${SERVER}"
        fi

        NBD=$(nbd_next_open ${i})
        NBD_DEVICE=$(nbd_device ${i})
        if [[ "$(nbd_is_open ${NBD_DEVICE})" ]]; then
          inform "**${NBDEXPORT}${i} already open on $(nbd_device ${i})**"
        else
          inform "Opening network block device on /dev/${NBD}"
          open_export ${NBD} ${i} || ${CMD} "Could not open network block device on /dev/${NBD}"
        fi

        wait_for_nbd ${i} 10 || ${CMD} "Nbd device on /dev/${NBD} never came up!"

        if luks_is_open ${i}; then
          warn "HICCUP"
          warn "HICCUP"
          inform "Decrypted **${NBDEXPORT}${i} previously to /dev/mapper/${NBDEXPORT}${i}"
          break
        else
          inform "Opening LUKS device from /dev/${NBD}"
          if luks_open ${NBD} ${i}; then
              inform "Decrypted filesystem from /dev/mapper/${NBDEXPORT}${i}"
              break
          else
              ${CMD} "Could not open LUKS device from /dev/${NBD}"
              echo "Retry after iteration: ${j}"
              continue
          fi
        fi
    done
  done

  if sudo zpool list -H -o name ${ZPOOL} 2>&1; then
      inform "Already mounted zpool ${ZPOOL}."
  else
    inform "${NBDEXPORT} is not imported, importing now..."
    if sudo zpool import -f ${ZPOOL}; then
      inform "Mounted zpool ${ZPOOL}"
    else
      die "Failed to mount zpool ${ZPOOL}"
    fi
  fi
}

close() {
  eval checksu zpool export -f ${ZPOOL}
  for i in $(seq 0 $((NUM_DRIVES - 1))); do
    if [[ -n "$(export_is_open ${i})" ]]; then
      inform "${NBDEXPORT}${i} is not open"
      continue # skip
    fi
    NBD=$(nbd_device ${i})

    checksu

    luks_is_open ${i} && inform "Closing LUKS device from /dev/${NBD}"
    luks_close ${i} || inform "Could not close LUKS device from /dev/${NBD}"

    export_is_open ${i} && inform "Closing network block device on /dev/${NBD}"
    close_export ${i} || inform "Could not close network block device on /dev/${NBD}"
  done
  ssh_is_open && inform "Closing SSH connection to ${SERVER}"
  close_ssh || die "Could not close existing SSH connection to ${SERVER}"

  rm -rf ${TMP}
}

ssh_host_exists() {
    local host=$1
    # Check if the hostname differs from the input (meaning it was configured)
    local found_hostname=$(cat ~/.ssh/config | grep -i "^host " | tr -s " " | cut -d " " -f 2 | grep -wE "^${host}$")
    [[ "$found_hostname" == "$host" ]]
}

# Usage
if ssh_host_exists "${RAGNAR_SERVER}"; then
    case $1 in
      'open') open ;;
      'close') close ;;
      'restart') close && open ;;
      *) usage '[open|close]' ;;
    esac
else
    die "Can't find value for RAGNAR_SERVER (Currently: ${RAGNAR_SERVER}) in .ssh/config. Remember this should also be the name of your zpool!"
fi

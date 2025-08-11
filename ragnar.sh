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

set -x

[ ${_ABASH:-0} -ne 0 ] || source $(dirname "${BASH_SOURCE}")/abash/abash.sh

SERVER=${RAGNAR_SERVER:-localhost}
echo "SERVE $SERVER"
NBDEXPORT=${RAGNAR_NBDEXPORT:-ztar}
KEYFILE=${RAGNAR_KEYFILE:-/etc/luks/${NBDEXPORT}.key}
echo "keyfile $KEYFILE"
HEADER=${RAGNAR_HEADER:-/etc/luks/${NBDEXPORT}.header}

TMP=$(tmpdirp "${SERVER}-${NBDEXPORT}")
mkdir -p ${TMP}
# TODO HARDCODED
mkdir -p ${TMP}/0/
mkdir -p ${TMP}/1/
mkdir -p ${TMP}/2/
mkdir -p ${TMP}/3/
mkdir -p ${TMP}/4/

# use TMP dir for ctl_path
ssh_is_open() {
  ssh -qO check -S "${TMP}/ssh" ${SERVER} &> /dev/null
}

open_ssh() {
  ssh -fNn -MS "${TMP}/ssh" -L 10809:127.0.0.1:10809 ${SERVER}
}

close_ssh() {
  if ssh_is_open; then
    ssh -qO exit -S "${TMP}/ssh" ${SERVER}
  fi
}

nbd_device() {
  IDX=$1
  cat "${TMP}/${IDX}/nbd" 2> /dev/null
}

nbd_is_open() {
  [ -f "/sys/block/${1}/pid" ]
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
  [ -f "${TMP}/${IDX}/nbd" ] || return 1
  nbd_is_open $(nbd_device ${IDX})
}

open_export() {
  checksu modprobe nbd
  NBD=$1
  IDX=$2

  if quietly checksu nbd-client 127.0.0.1 /dev/${NBD} -name ${NBDEXPORT}${IDX}; then
    echo ${NBD} > ${TMP}/${IDX}/nbd
  else
    close_ssh
    rm -fr ${TMP}/${IDX}/
    return 1
  fi
}

close_export() {
  IDX=$1
  if export_is_open; then
    checksu
    checksu modprobe nbd
    quietly checksu nbd-client -d /dev/$(nbd_device ${IDX}) && quietly rm -f "${TMP}/${IDX}/nbd"
  fi
}

luks_is_open() {
  IDX=$1
  [ -b /dev/mapper/${NBDEXPORT}${IDX} ]
}

luks_open() {
  NBD=$1
  IDX=$2
  #checksu [ -f ${HEADER} ] || HEADER=${NBD}
  checksu cryptsetup open /dev/${NBD} ${NBDEXPORT}${IDX} --key-file /tmp/keyfile # ${KEYFILE} # --header ${HEADER}
}

luks_close() {
  IDX=$1
  checksu cryptsetup close /dev/mapper/${NBDEXPORT}${IDX}
}

filesystem_mountpoint() {
  IDX=$1
  udisksctl info -b /dev/mapper/${NBDEXPORT}${IDX} 2> /dev/null | grep MountPoints | cut -d':' -f2 | sed 's/^\s*//'
}

filesystem_is_mounted() {
  IDX=$1
  [ -n "$(filesystem_mountpoint ${IDX})" ]
}

mount_filesystem() {
  IDX=$1
  quietly checksu udisksctl mount -b /dev/mapper/${NBDEXPORT}${IDX}
}

unmount_filesystem() {
  IDX=$1
  quietly checksu udisksctl unmount -b /dev/mapper/${NBDEXPORT}${IDX}
}

open() {
  # TODO HARDCODED
  for i in {0..4}; do
    if [[ -n "$(nbd_device ${i})" ]]; then
      inform "**${NBDEXPORT}${i} already open on $(nbd_device ${i})**"
      continue  # Skip to next iteration
    fi
    checksu [ -f "${KEYFILE}" ] || die "Keyfile not found"

    inform "Opening SSH connection to ${SERVER}"
    ssh_is_open || open_ssh || die "Could not open SSH connection to ${SERVER}"
    sleep 1

    NBD=$(nbd_next_open ${i})
    inform "Opening network block device on /dev/${NBD}"
    open_export ${NBD} ${i} || die "Could not open network block device on /dev/${NBD}"
    sleep 1

    inform "Opening LUKS device from /dev/${NBD}"
    luks_open ${NBD} ${i} || die "Could not open LUKS device from /dev/${NBD}"
    sleep 1

    inform "Decrypted filesystem from /dev/mapper/${NBDEXPORT}${i}"
    #mount_filesystem ${i} || die "Could not mount filesystem from /dev/mapper/${NBDEXPORT}${i}"

    msg "Filesystem is mounted on $(filesystem_mountpoint)"
    sleep 1
  done
  checksu zpool import -f ${NBDEXPORT}
  inform "Mounted zpool ${NBDEXPORT}"
}

close() {
  # TODO HARDCODED
  for i in {0..4}; do
    checksu zpool export ${NBDEXPORT}
    if [[ -n "$(export_is_open ${i})" ]]; then
      inform "${NBDEXPORT}${i} is not open"
      continue # skip
    fi
    NBD=$(nbd_device ${i})

    checksu

    MOUNTPOINT=$(filesystem_mountpoint ${i})

    #filesystem_is_mounted ${i} && inform "Closing filesystem on ${MOUNTPOINT}"
    #unmount_filesystem ${i} || die "Could not close filesystem on ${MOUNTPOINT}"

    luks_is_open ${i} && inform "Closing LUKS device from /dev/${NBD}"
    luks_close ${i} || die "Could not close LUKS device from /dev/${NBD}"

    export_is_open ${i} && inform "Closing network block device on /dev/${NBD}"
    close_export ${i} || die "Could not close network block device on /dev/${NBD}"
    sleep 1
  done
  ssh_is_open && inform "Closing SSH connection to ${SERVER}"
  close_ssh || die "Could not close existing SSH connection to ${SERVER}"

  tmpdirclean
}

case $1 in
  'open') open ;;
  'close') close ;;
  *) usage '[open|close]' ;;
esac

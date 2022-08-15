#!/usr/bin/env bash
# ESXi backup script.
#
# MIT License
# Copyright (c) 2022 Adam Bernstein. All Rights Reserved.
# See LICENSE file for full licensing terms.
#
# This script uses a raw TCP connection using nc (netcat) for backup speed.
#
# DO NOT USE in environmnts where you must have security between the ESXi system
# being backed up and the backup NAS disk. Everything is transferred In-The-Clear.
#
# General strategy:
#    1. Make snapshot of VM to backup
#    2. Copy down all files from ESXi system using nc. Local dd maintains
#       "sparceness" of copied VMDK files.
#    3. Delete previously created snapshot
#

ESXI_TARGET_IP="192.168.100.119"
ESXI_SSH_USER="root"
SSHKEY="/mnt/8TB/esxi-backups/etc/esxibackup2"
SSH="ssh -i $SSHKEY -A $ESXI_SSH_USER@${ESXI_TARGET_IP}"
LOCAL_BACKUP_BASE=/mnt/8TB/esxi-backups
ESXI_VOLUME_BASE=/vmfs/volumes
SNAP_TAG="Backing_up_snapshot_$(date +%s)"

VMIDS_FILE="/tmp/esxvmids.txt"
NCPID_FILE="/tmp/ncpidfile.txt"
ESXBACKUP_VMX_LIST="/tmp/esxvm-vmx.txt"
ESXBACKUP_DIRS="/tmp/esxvmdirs.txt"

MY_IP=$(ip a | grep 'inet ' | grep -v ' lo$' | sed -e 's|.*inet ||' -e 's|\/.*||')

trap 'cleanup_snapshots; exit' 1  1 2 3 15

function nccp_file()
{
  src_file="$1"
  dst_file="$2"
  dst_dir="$3"

  # Create small scriptlet that runs on the ESXi system
  cat<< NNNN>remote-nccp.sh
dd bs=2M if=$src_file | nc $MY_IP 80
NNNN
chmod +x remote-nccp.sh

  # Start local netcat listener job
  # Make sparse file backups using "dd conv=sparse" option
  (echo starting nc && nc -l -p 80 | pv | dd bs=4M conv=sparse of="$dst_file") &
  echo $! > "$NCPID_FILE"

  # scp the scriptlet up to the ESXi system
  scp -p remote-nccp.sh $ESXI_SSH_USER@$ESXI_TARGET_IP:$dst_dir

  # Execute the scriptlet on the ESXi system
  ssh $ESXI_SSH_USER@192.168.100.119 $dst_dir/remote-nccp.sh
}

function cleanup_snapshots()
{
  # This trap disables further signals from interrupting the trap function
  trap '' 1 2 3 15

  for id in `cat $VMIDS_FILE`; do
    echo "deleting snapshot of vmid=$id"

    # Get snapshot ID
    snapshots=`$SSH  vim-cmd vmsvc/snapshot.get $id`

    # Backup snapshot id may be buried in a list of other snapshots
    # making extraction of the snapshot for backups somewhat painful.
    # "Desciption" is correct. this is a typo in vim-cmd (oops)
    #
    snapshot_id=`echo "$snapshots" | \
        sed -n -e  "\#^--*Snapshot Name  *: $SNAP_TAG#{:a;N;\#Snapshot Desciption#!ba; \#Snapshot Id#p}" | \
          grep 'Snapshot Id' | sed 's/.*  *//'`

    # Remove snapshot
    echo "Removing snapshot $snapshot_id"
    echo "$SSH vim-cmd vmsvc/snapshot.remove $id $snapshot_id"
    $SSH vim-cmd vmsvc/snapshot.remove $id $snapshot_id
  done
  ncpid=$(cat "$NCPID_FILE")
  kill -0 $ncpid > /dev/null 2>&1
  if [ $? -eq 0 ]; then
    kill -9 $ncpid
  fi
  rm "$NCPID_FILE"
}


function test_is_root()
{
  if [ $(id -u) -ne 0 ]; then
    echo "You must run this backup as root."
    exit 1
  fi
}

function verify_ssh_connectivity()
{
  echo "Testing ssh to $ESXI_TARGET_IP (should see no password prompt)"
  echo "  Did you sudo -E su before running screen?"
  ${SSH} true
  if [ $? -ne 0 ]; then
    echo "ERROR: ssh test to $ESXI_TARGET_IP failed"
    exit 1
  fi
}

function main()
{
  local backup_only_list=""
  while [ -n "$1" ]; do
    backup_only_list="$backup_only_list $1"
    shift
  done
  backup_only_list=$(echo "$backup_only_list" | sed 's|^ ||')

  test_is_root

  verify_ssh_connectivity

  rm -f "$ESXBACKUP_DIRS"
  rm -f "$VMIDS_FILE"

  # TODO: Need a mechanism to backup a subset of all possible VMs to backup
  # Get full list of all directories with virtual disks and virtual machines
  #
  $SSH find -L "$ESXI_VOLUME_BASE/datastore*/" -name '*-flat.vmdk' -o -name '*.vmx' > "$ESXBACKUP_VMX_LIST"
  for remote_dir in `cat "$ESXBACKUP_VMX_LIST"`; do
    if [ -n "$backup_only_list" ]; then
      if [ $(echo "$backup_only_list" | grep -c $(basename $(dirname "$remote_dir")))  -gt 0 ]; then
        dirname $remote_dir >> "$ESXBACKUP_DIRS"
      fi
    else
      dirname $remote_dir >> "$ESXBACKUP_DIRS"
    fi
  done
  if [ ! -s "$ESXBACKUP_DIRS" ]; then
    echo "ERROR: No system to backup found. Tried '$backup_only_list'"
    exit 1
  fi

  # sort -o will create a tmp file when in/out are the same file
  sort -u -o "$ESXBACKUP_DIRS" "$ESXBACKUP_DIRS" 

  for remote_dir in `cat "$ESXBACKUP_DIRS"`; do
    dir=`basename $remote_dir`
  #  echo debug1 $dir
    id=`$SSH vim-cmd vmsvc/getallvms |  awk '{print ":" $1 ":" $4 ":"}' | grep ":$dir/.*:$" | sed 's/^:\(.*\):\(.*\):$/\1/'`
    if [ -n "$id" ]; then
      echo "Making snapshot of dir=$dir vmid=$id"
      # take snapshot of VM
      echo $id >> "$VMIDS_FILE"
      echo $SSH vim-cmd vmsvc/snapshot.create $id $SNAP_TAG
      $SSH vim-cmd vmsvc/snapshot.create $id $SNAP_TAG
    fi
  done

  echo "Starting VM backup. Will take a long time..."
  for remote_dir in `cat "$ESXBACKUP_DIRS"`; do
    local_dir=`echo "$remote_dir" | sed "s|${ESXI_VOLUME_BASE}/||"`
    mkdir -p "$LOCAL_BACKUP_BASE/$local_dir"
    for backup_file in `$SSH ls -1 "$remote_dir"`; do
       # Clean up any previous file present for this VM backup
       rm -f "$LOCAL_BACKUP_BASE/$local_dir/$backup_file"

       # Run the netcat copy to backup this file
       echo nccp_file "${remote_dir}/${backup_file}" "$LOCAL_BACKUP_BASE/$local_dir/$backup_file" "$remote_dir"
       nccp_file "${remote_dir}/${backup_file}" "$LOCAL_BACKUP_BASE/$local_dir/$backup_file" "$remote_dir"
    done
  done

  cleanup_snapshots

  echo "VM backup complete."
}

main "$@"

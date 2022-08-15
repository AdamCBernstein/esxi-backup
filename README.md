# esxi-backup
ESXi backup script

Backup ESXi configuration and VMDK virtual disks from a running virtual
machine to a remote NAS file server.

usage:
  ./esxi-backup.sh [ VMname1 VMName2 ... ]

Features:
  * Highly performant, at the expense of security (warning below)
  * Sparse VMDK file structure is preserved during backup

Configuration requirements:
  * ssh private / public key pair
  * Ability to ssh as root into ESXi system using this keypair
  * NAS with sufficient disk space to backup ESXi virtual machines

WARNING: This implementation uses nc (netcat) to bulk copy the ESXi data to the
backup storage device. This strategy is highly performant, but is totally insecure.
All data copied between the ESXi system and NAS storage device is copied over a raw
TCP connection in-the-clear.

This can be easily modified to use SSH to copy the data. However, this is 5x-10x slower
due to encryption overhead on both sides of the SSH connetion.

Backup strategy:
  * Backup is run locally on the NAS storage device
  * SSH connectivity is verified between backup device and ESXi system
  * By default, all VMs present on ESXi system on all data stores are backed up
  * A snapshot for every VM being backed up is taken. This is done, because any
    virtual machine file in-use is locked and not readable by the backup script
  * All files in every datastoreN/virtual_machine/* directory are copied to a
    corresponding local directory on the backup NAS, called datastoreN/virtual_machine/*
  * When provided, only the VMname1 list provided will be backed up. This can be
    used for testing, or spot backups of a VM, perhaps it is new and has not yet
    been backed up.
  * Once backup is complete, all backup snapshots created are deleted.

# Motivation
Need debian setup with network block devices working!

NBD & luks = remote encrypted backups... e.g. we each have a luks encrypted setup at the other's house, and then we use this linux Network Block Device technology (https://packages.debian.org/stable/nbd-server) to mount the luks volumes, but then we use cryptsetup open on the locally block device which is then decrypted... locally. Therefore the “host” of the nbd server couldn’t ever access any of the files on it, zero-trust!

Poc from: https://github.com/gavinhungry/ragnar + some zfs

# Parts
Sd card for pi - https://www.amazon.com/dp/B09X7DQJQL?ref=ppx_yo2ov_dt_b_fed_asin_title
Usb adapter for fans - https://www.amazon.com/dp/B081K8LBH3?ref=ppx_yo2ov_dt_b_fed_asin_title
Two fans - https://www.amazon.com/dp/B0CJDTGRJZ?ref=ppx_yo2ov_dt_b_fed_asin_title
Sata (different lengths?) data and power cables
https://www.amazon.com/dp/B095YFRL92?ref=ppx_yo2ov_dt_b_fed_asin_title
https://www.amazon.com/dp/B0925XMFY3?ref=ppx_yo2ov_dt_b_fed_asin_title
Spinning disks  - https://www.amazon.com/dp/B07H289S7C?ref=ppx_yo2ov_dt_b_fed_asin_title
Beefy power adapter to power all the 3.5” hdd
https://www.amazon.com/dp/B0BHWMP8H5?ref=ppx_yo2ov_dt_b_fed_asin_title
Case
https://www.amazon.com/dp/B0BV5JZZVB?ref=ppx_yo2ov_dt_b_fed_asin_title
Sky is the limit here but something that holds hdd
The pi
https://www.amazon.com/dp/B0F1CT9SQ6?ref=ppx_yo2ov_dt_b_fed_asin_title
Sata hat for the pi
 https://www.amazon.com/dp/B0DX1HQWB2?ref=ppx_yo2ov_dt_b_fed_asin_title
Cooler for pi
https://www.amazon.com/dp/B0CRR97QGL?ref=ppx_yo2ov_dt_b_fed_asin_title


# Monitoring = tbd
https://www.openstatus.dev/
https://www.reddit.com/r/devops/comments/14ygcmo/seeking_opinions_on_better_stack_alternatives/
Super Monitoring, Hetrix Tools, OffAlerts, and Pingdom
https://github.com/louislam/uptime-kuma


## Steps manually performed in the physical world.
### Assembly!
- you're on your own here!
- 3D print pi tray to so it can be screwed in to the tower?


## Prereqs
!!! Need some sort of VPN running so the computer your friend plugs into their network will be routeable from your network


### Overview:
- we are going to be doing all of these operations on a computer and zpool we will call `ztar`
- What we are going to do:
Create a linux filesystem on each disk (for  each drive (you basically just hit g, n, enter to accept default start, enter t to accept default end, p (to check over), then w to write to disk)
Then we do the luks thing
Then we write zeros to the unencrypted drive (so the data on the encrypted drive starts fresh and random)
Then we create our zfs pool
Then we set up nbd server and connect to it with ragnar
Then we remotely mount our zpool

### INSTALL
Notes: https://bitbucket.org/price_clark/secrets/src/main/.config/secrets/terel.tail6aab7.ts.net/wiki/

```
# sudo apt update
# apt install vim nbd-server nbd-client cryptsetup pv linux-headers-arm64 lz4
```
### ZFS tools install
https://wiki.debian.org/ZFS
https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/Debian%20Bookworm%20Root%20on%20ZFS.html
Add backports and install modules:
```
$ codename=$(lsb_release -cs);echo "deb http://deb.debian.org/debian $codename-backports main contrib non-free" | sudo tee -a /etc/apt/sources.list && sudo apt update
# apt install -t stable-backports zfsutils-linux
```

### FORMATTING the drives
`sudo fdisk /dev/sdX` where X = drive letter
```
Created a new DOS (MBR) disklabel with disk identifier 0x9c65695b.
Command (m for help): g
Created a new GPT disklabel (GUID: E857799E-A207-7F4D-8FE0-2CB60507F137).

Command (m for help): n
Partition number (1-128, default 1):
First sector (2048-15628053134, default 2048):
Last sector, +/-sectors or +/-size{K,M,G,T,P} (2048-15628053134, default 15628052479):
Created a new partition 1 of type 'Linux filesystem' and of size 7.3 TiB.
```
** by default it should Linux filesystem but if it does not hit `t` to get types and L to see list but it’s `20`
```
Command (m for help): p
Disk /dev/sda: 7.28 TiB, 8001563222016 bytes, 15628053168 sectors
Disk model: ST8000DM004-2U91
Units: sectors of 1 * 512 = 512 bytes
Sector size (logical/physical): 512 bytes / 4096 bytes
I/O size (minimum/optimal): 4096 bytes / 4096 bytes
Disklabel type: gpt
Disk identifier: E857799E-A207-7F4D-8FE0-2CB60507F137
Device     Start         End     Sectors  Size Type
/dev/sda1   2048 15628052479 15628050432  7.3T Linux filesystem

Command (m for help): w
The partition table has been altered.
Calling ioctl() to re-read partition table.
Syncing disks.
```


### LUKS

helpful command to get the partuuid used in our luks encryption
```
lsblk -o name,partuuid
```

Helpful guide part 1: https://www.lisenet.com/2013/install-luks-and-create-an-encrypted-luks-partition-on-debian/
Helpful guide part 2: https://www.lisenet.com/2013/luks-add-keys-backup-and-restore-volume-header/
LUKS FAQ: https://gitlab.com/cryptsetup/cryptsetup/-/blob/main/FAQ.md#frequently-asked-questions-cryptsetupluks
Header backups are in 1pass and gdrive: luks_header_backups
Create LUKS partition:
```
# cryptsetup -c aes-xts-plain64 -s 512 luksFormat /dev/disk/by-partuuid/1fcf3a8e-d12b-f74f-af94-8cabd5233d9c
```
Pick a good passphrase and do not forget it, ever!
Verify you can decrypt it:
```
# cryptsetup open /dev/disk/by-partuuid/1fcf3a8e-d12b-f74f-af94-8cabd5233d9c luks-1fcf3a8e-d12b-f74f-af94-8cabd5233d9c
```
Enter passphrase for /dev/disk/by-partuuid/1fcf3a8e-d12b-f74f-af94-8cabd5233d9c:
```
$ ls /dev/mapper/
control  luks-1fcf3a8e-d12b-f74f-af94-8cabd5233d9c
```
Note that the name i chose for the decrypted drive appears in /dev/mapper, this is how i know to verify the decryption process worked.
Add another passphrase (this is very important in case the luks header gets corrupted which can happen):
```
cryptsetup luksAddKey --key-slot 1 /dev/disk/by-partuuid/1fcf3a8e-d12b-f74f-af94-8cabd5233d9c
cryptsetup luksHeaderBackup /dev/disk/by-partuuid/1fcf3a8e-d12b-f74f-af94-8cabd5233d9c --header-backup-file /root/1fcf3a8e-d12b-f74f-af94-8cabd5233d9c-header.backup
```
For ultra-security (see section 2.19 of the faq or the related guides) but this takes awhile!
```
# for each drive!
#sudo dd if=/dev/zero of=/dev/mapper/luks-d0b3ffb6-bb6f-e249-9904-30105104634c bs=1M status=progress
** After zeroing out the drives i had to reboot to run the zfs commands.

```

### INSTALL ZFS FS
https://forum.level1techs.com/t/zfs-guide-for-starters-and-advanced-users-concepts-pool-config-tuning-troubleshooting/196035
At this point you should have 5 unencrypted hdd’s on /dev/mapper/ if you do not use `cryptsetup open` on the encrypted drives. It’s time to create a zpool at raidz2:
```
mkdir ~/backups
zpool create -o ashift=12 -o autotrim=on ztar raidz2 /dev/mapper/luks-*



# create a root dataset, because of the permission hierarchy of zfs i like to have all datasets come off of a root dataset
so I am going to create `ztar/root` and `ztar/root/backups`
sudo zfs create -o canmount=on ztar/root
# an initial snapshot simplifies things
sudo zfs snapshot ztar/root@empty

# optional
# create the backups dataset that is mounted at ~/backups when the zpool is imported.
sudo zfs create -o mountpoint=~/backups -o canmount=on ztar/root/backups/
```

#### Host Nbd Server of Encrypted Hard Drives
	NOTE on ordering: it really matters the order the drives appear to zpool when it is created must be the order seen when it is mounted. So are cryptsetups create /dev/mapper/ztar0-ztar4 and our nbd client takes great care to make sure ztar0=nbd0, ztar1=nbd1, etc.


```
price@tartaros:~ $ sudo cryptsetup open /dev/disk/by-partuuid/f0827759-bca7-5645-a409-db6454f4ae93 ztar0 --key-file /tmp/keyfile
price@tartaros:~ $ sudo cryptsetup open /dev/disk/by-partuuid/03013f1b-ae51-5c43-a0fb-80aac5ef7089 ztar1 --key-file /tmp/keyfile
price@tartaros:~ $ sudo cryptsetup open /dev/disk/by-partuuid/5846622e-4c50-854a-a0db-c42f8aa77b1b ztar2 --key-file /tmp/keyfile
price@tartaros:~ $ sudo cryptsetup open /dev/disk/by-partuuid/d1dc2a41-55a7-3b4e-bc87-f64fa01b1627 ztar3 --key-file /tmp/keyfile

price@tartaros:~ $ sudo cryptsetup open /dev/disk/by-partuuid/468b72fc-7433-6041-9f17-72f61c914f9f ztar4 --key-file /tmp/keyfile
```
Using nbd-server
If not installed, `sudo apt install nbd-server`
`sudo modprobe nbd`
/etc/nbd-server/config
```
[generic]
allowlist = 1
authfile = /etc/nbd-server/allow
# default port is 10809

[ztar0]
exportname = /dev/disk/by-partuuid/f0827759-bca7-5645-a409-db6454f4ae93
[ztar1]
exportname = /dev/disk/by-partuuid/03013f1b-ae51-5c43-a0fb-80aac5ef7089
[ztar2]
exportname = /dev/disk/by-partuuid/5846622e-4c50-854a-a0db-c42f8aa77b1b
[ztar3]
exportname = /dev/disk/by-partuuid/d1dc2a41-55a7-3b4e-bc87-f64fa01b1627
[ztar4]
exportname = /dev/disk/by-partuuid/468b72fc-7433-6041-9f17-72f61c914f9f
```

- Create this file that is referred to in the above config /etc/nbd-server/allow
```
127.0.0.1
192.168.1.1
192.168.0.0/16
```
- Now get the nbd-server daemon running!
```
sudo systemctl enable nbd-server
Sudo systemctl start nbd-server
Sudo systemctl status nbd-server
List with nbd-client (on the host for now)
 sudo nbd-client localhost -l
Negotiation: ..
ztar0
ztar1
ztar2
ztar3
ztar4

### RAGNAR Now get the ragnar script running

```
cd ragnar
```
Follow ragnar README (set RAGNAR_SERVER=ztar  in env and put the keyfile at /etc/luks/ztar.key)

NOTE: You must be able to successfully run `./ragnar.sh open` and `./ragnar.sh close`

save the direct path to the ragnar script, e.g. `~/development/pi-nas/ragnar/ragnar.sh`

### having a host machine "always" mount the zpool

1. Add the RAGNAR_SERVER env var to some host in your ~/.ssh/config
Set RAGNAR_NBDEXPORT=”ztar” or whatever your zpool name is
Set the RAGNAR_KEYFILE /etc/luks/${RAGNAR_NBDEXPORT}.key
To write the keyfile properly before you type the binary type
	:set binary <hit enter>
	:set noeol <hit enter>
This will allow you to write exactly what you typed with no newline saved at the end of the file
Having a service that allows mounts your devices
Verify that there is a zfs-import of some kind on your system:
```
> systemctl list-unit-files | grep zfs-import
zfs-import-cache.service                    enabled         enabled
zfs-import-scan.service                     disabled        disabled
zfs-import.service                          masked          disabled
zfs-import.target                           enabled         enabled
```
My system has the zfs-import target enabled (don’t worry about the service being masked).


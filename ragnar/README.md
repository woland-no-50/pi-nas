#hard forked from 
https://github.com/gavinhungry/rangar
and
https://github.com/gavinhungry/abash

[ragnar](http://en.battlestarwiki.org/wiki/Ragnar_Anchorage)
========
Mount an existing remote [LUKS](https://gitlab.com/cryptsetup/cryptsetup) device
with [NBD](http://nbd.sourceforge.net/) over SSH. This has the advantage of
never exposing your LUKS keyfile to the server, as all encryption/decryption
takes place on your local machine.

You must have an existing LUKS device with a keyfile being exported by NBD on
some remote server. Your NBD server should be behind a firewall, and only listen
on `localhost`.

REQUIREMENTS:
    - The name of your zpool and the name of the alias (in .ssh/config) to your remote server that is
    hosting your encrypted drives must be the same.
    - set that value = RAGNAR_SERVER
    e.g. export RAGNAR_SERVER=zigloo or RAGNAR_SERVER=ztar
    - set RAGNAR_KEYFILE if it is not equal to /etc/luks/${RAGNAR_SERVER}.key
    - set RAGNAR_NUM_DRIVES if it not equal to 5

    *NOTE
    	The observant reader following along from the pi-nas root
    README.md will note that the zpool, ztar, and the hosted nas drives
    with nbd-server, ztar0-ztar4, have a ztar# style naming pattern,
    this is relied on in the ragnar script to mount each individual luks
    drive before mounting the zpool. It is only because /dev/maapper/ztar0-4
    exist in the correct order (the same as when they are encrypted) that allows
    the zpool import command to work.

Environment Variables
---------------------
  - `RAGNAR_SERVER`: Server to connect to (can be a host alias from
    `~/.ssh/config`). Defaults to `ztar`.
  - `RAGNAR_KEYFILE`: Path to LUKS keyfile. Defaults to
    `/etc/luks/${RAGNAR_NBDEXPORT}.key`
  - RAGNAR_NUM_DRIVES: number of drives to mount, defaults to 5.jk:w

Usage
-----

### Open

    $ ragnar open
    [sudo] password:

    ragnar: Opening SSH connection to localhost ...
    ragnar: Opening network block device on /dev/nbd0 ...
    ragnar: Opening LUKS device from /dev/nbd0 ...
    ragnar: Mounting filesystem from /dev/mapper/ragnar ...
    ragnar: Filesystem is mounted on /media/ragnar

### Close

    $ ragnar close
    [sudo] password:

    ragnar: Closing filesystem on /media/ragnar ...
    ragnar: Closing LUKS device from /dev/nbd0 ...
    ragnar: Closing network block device on /dev/nbd0 ...
    ragnar: Closing SSH connection to localhost ...

License
-------
This software is released under the terms of the **MIT license**. See `LICENSE`.

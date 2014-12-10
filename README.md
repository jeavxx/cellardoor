CellarDoor
==========

CellarDoor is a SUID root wrapper for scripts. CellarDoor allows you to set
up select scripts that can be run as root, without using a password. It adds
convenience by allowing for shorthand names, and remains (in theory) secure
by enforcing strict permissions on all files involved.


### Why?
When I'm running bare bones type linux setups, I tend to do a lot of things
with scripts (connecting to wifi, adjusting screen brightness). Scripts can't
SUID root (for good reason), and I got tired of typing my password for these
trivialities. Writing a little wrapper for this also presented a simple,
practical problem to tackle as my first independently written Haskell program.


### Safety:
I AM NOT A SECURITY EXPERT. Nor has this code been audited in any way. Use at
your own risk. That being said, cellardoor is rather picky about whether to
run things. Any script to be run must be found in a database of preapproved
scripts. Once a script is found in the database, it will only be run if both
the database file and the script are a) owned by root, and b) writable only
by owner (root). This seemed sufficient for use on my personal computers. If
I end up needing more security, I may require scripts to match a checksum
before being run.


### Installation:
Start off with the usual cabal stuff

    $ cabal build
    $ cabal install

To do any good, you'll need to set permissions on the cellardoor binary

    $ sudo chown root <path-to-cellardoor>
    $ sudo chmod 4755 <path-to-cellardoor>

Finally, create a simple sqlite database containing the scripts you'd like to
run: (using wifi-menu as an example)

    $ sudo sqlite3 /etc/cellar
    sqlite> CREATE TABLE scripts (name text PRIMARY KEY, path text);
    sqlite> INSERT INTO scripts VALUES ('wifi-menu', '/usr/bin/wifi-menu');
    sqlite> .quit


### Usage:

    $ cellardoor -e SCRIPTNAME [-d DATABASE] [ARGUMENTS...]

So, if you had followed the above example, you could now run wifi-menu with

    $ cellardoor -e wifi-menu

If you get a message like "ERROR: lax permissions on ...", then you need to
adjust the permissions on either your script or your cellar database.

    $ sudo chown root <script-or-db-path> && sudo chmod 755 <script-or-db-path>

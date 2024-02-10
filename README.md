# Simple Mass Data Transfer
## What is SMD_Transfer?
The Problem this command line tool is trying to solve is essentially a gap in my file sharing tool belt. 
That is, just wanting to quickly transfer multiple, maybe large, files to a friend as a one-of. And, if needed, even encrypted.

With all of that in a simple, no unneeded nonsense, lightweight manner.

## What is it not?
Like most other (big) file sharing tools, handling many users with complicated caching and sending many different files depending on some conditions.
SMD_Transfer is simple and (at least supposed to be) capable, but only for a specific use case.

## Install
Just install it with cargo:

``cargo install --git https://github.com/Vescusia/simple_mass_data_transfer.git``


## Usage
Host a file (make sure to configure your firewall and router!)

``smd_transfer host /path/to/some/file.example -b 0.0.0.0:4444``

And then tell your friend to download it:

``smd_transfer dl my-friends-domain.com:4444 -p /path/to/install/folder/``

You can also host whole directories

``smd_transfer host /path/to/some/directory/ -b 0.0.0.0:4444``

And use encryption with a configurable key
(if no key is specified, no encryption will be used)

``smd_transfer -k my_cool_passkey host /path/to/some/directory/ -b 0.0.0.0:4444``

Your friend will also need to specify the same key in the same way.

For any more information:
``smd_transfer --help``

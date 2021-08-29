# ![rehex logo](res/icon64.png) Reverse Engineers' Hex Editor

A cross-platform (Windows, Linux, Mac) hex editor for reverse engineering, and everything else.

## Features

* Large (1TB+) file support
* Decoding of integer/floating point value types
* Inline disassembly of machine code
* Highlighting and annotation of ranges of bytes
* Side by side comparision of selections
* Lua scripting support ([API reference here](http://www.solemnwarning.net/rehex-luadoc/))
* Virtual address mapping support

![inline comments + data types demo](doc/comments-types.gif)

![file diff demo](doc/file-diff.gif)

## Installation

The [Releases](https://github.com/solemnwarning/rehex/releases) page has standalone packages for Windows and Mac, as well as installable packages for popular Linux distributions, or you can install them from a distribution package repository as described below.

The same packages are also produced for Git commits (look for the tick), if you want to try the development/unreleased versions.

### Debian

First, you will need to add my APT signing key to your system:

    wget -qO - https://repos.solemnwarning.net/debian-key.gpg | sudo apt-key add -

Add the following lines to your `/etc/apt/sources.list` file:

    deb http://repos.solemnwarning.net/debian/ CODENAME main
    deb-src http://repos.solemnwarning.net/debian/ CODENAME main

**NOTE:** Replace `CODENAME` with the version you're running (e.g. `bullseye` or `buster`).

Finally, you can install the package:

    $ sudo apt-get update
    $ sudo apt-get install rehex

### Ubuntu

First, you will need to add my APT signing key to your system:

    wget -qO - https://repos.solemnwarning.net/ubuntu-key.gpg | sudo apt-key add -

Add the following lines to your `/etc/apt/sources.list` file:

If running Ubuntu 20.04 (Focal Fossa) or later:

    deb  [arch=amd64] http://repos.solemnwarning.net/ubuntu/ CODENAME main
    deb-src  [arch=amd64] http://repos.solemnwarning.net/ubuntu/ CODENAME main

**NOTE:** Replace `CODENAME` with the version you're running (e.g. `focal` for 20.04 or `hirsute` for 21.04).

If running Ubuntu 18.04 (Bionic Beaver):

    deb http://repos.solemnwarning.net/ubuntu/ bionic main
    deb-src http://repos.solemnwarning.net/ubuntu/ bionic main

Finally, you can install the package:

    $ sudo apt-get update
    $ sudo apt-get install rehex

**NOTE:** Ubuntu users must have the "Universe" package repository enabled to install some of the dependencies.

### Fedora

    $ sudo dnf copr enable solemnwarning/rehex
    $ sudo dnf install rehex

### CentOS

    $ sudo dnf install epel-release
    $ sudo dnf copr enable solemnwarning/rehex
    $ sudo dnf install rehex

### openSUSE
    $ sudo zypper ar obs://editors editors
    $ sudo zypper ref
    $ sudo zypper in rehex

## Building

If you want to compile on Linux, just check out the source and run `make`. You will need Jansson, wxWidgets, Capstone and Lua installed, along with their development packages (Install `build-essential`, `git`, `libwxgtk3.0-dev`, `libjansson-dev`, `libcapstone-dev`, `liblua5.3-dev` and `lua5.3` on Ubuntu).

The resulting build can be installed using `make install`, which accepts all the standard environment variables.

For Windows or Mac build instructions, see the relevant README: [README.Windows.md](README.Windows.md) [README.OSX.md](README.OSX.md)

## Feedback

If you find any bugs or have suggestions for improvements or new features, please open an issue on Github, or join the `#rehex` IRC channel on `irc.libera.chat`.

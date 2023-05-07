# USB/IP Wrapper

A nice nushell-based wrapper around the [USB/IP tool](https://usbip.sourceforge.net/) with some special [✨ for NixOS users](#nixos-module).

<div align="center">
  <img
    src="./assets/usbip_wrapper_logo.png"
    alt="usbip-wrapper logo">
</div>

<!--toc:start-->
- [USB/IP Wrapper](#usbip-wrapper)
  - [USB/IP: TL;DR](#usbip-tldr)
    - [Why do I need USB/IP?](#why-do-i-need-usbip)
    - [Why should I look at this repository?](#why-should-i-look-at-this-repository)
  - [Usage](#usage)
    - [USB-IDs](#usb-ids)
  - [NixOS Module](#nixos-module)
  - [Testing](#testing)
<!--toc:end-->

## USB/IP: TL;DR

From the [USB/IP Project page](https://usbip.sourceforge.net/):
> USB/IP Project aims to develop a general USB device sharing system over IP network.
To share USB devices between computers with their full functionality,
USB/IP encapsulates "USB I/O messages" into TCP/IP payloads and transmits them between computers.

<!-- It has been upstreamed into the [Linux kernel](https://www.kernel.org/doc/readme/tools-usb-usbip-README) for quite some time -->

### Why do I need USB/IP?

My current use case is that this allows me to remotely mount my [USB key with a key file](https://tqdev.com/2022-luks-with-usb-unlock) or my
_real_ [YubiKey 5 series hardware key](https://www.yubico.com/de/store/#yubikey-5-series) from my laptop to my server to decrypt my storage pools after a reboot.

Others use it to remotely mount old Linux-supported printers.

If you have a different interesting use case, let me know!

### Why should I look at this repository?

Good question! This repository contains two helpful components:
- The actual `usbip-wrapper` tool
- A [NixOS](https://nixos.org/) module that provides a simple entry point to set up the USB/IP host/client on a NixOS system with a secure auto-mount procedure.
If you are a NixOS user, check out the [NixOS Module section](#nixos-module)!

The `usbip-wrapper` tool provides a more user- and scripting-friendly interface to the
`usbip` program:
- Supports remotely mounting multiple USB devices from the same manufacturer.
  - This is a limitation of the [binding tutorial from Arch Linux](https://wiki.archlinux.org/title/USB/IP#Tips_and_tricks)
  - May mount _all available_ devices from a host without having to explicitly list all USB IDs
  - May unmount _all locally_ mounted USB devices from USB/IP
- Acts _idempotent_ and only returns non-zero status codes for _true_ errors
- Gives more helpful error messages to make it easier to debug
- Provides a unified interface with identical environment variables for the host and client application

<!-- Idempotent: - If all desired remote USB devices have already been mounted then re-calling mount won't provide an error. -->

If you only want to use USB/IP directly check out the [Arch-Linux USB/IP wiki entry](https://wiki.archlinux.org/title/USB/IP).

## Usage

Note: You still have to install the `usbip` package and the required kernel modules for
the host/client. See the [Arch Linux USB/IP documentation](https://wiki.archlinux.org/title/USB/IP)
for some pointers. If you are using NixOS, see the [NixOS Module](#nixos-module) section!

For a _manual_ installation, one needs to add/`use` the [nushell script](src/usbip_wrapper.nu)
path to `config.nu` (update via `config nu`) and add `use <PATH>/usbip_wrapper.nu *`.
Then the following command will auto-complete and show all available commands with
help message: `usbip-wrapper <TAB><TAB>`

### USB-IDs

To find the USB ID of the device you would like to mount, call `lsusb` and copy the hex code after `ID` `XXXX:XXXX`.

Or, the _official_ list of known USB IDs can be found at [linux-usb.org/usb.ids](http://www.linux-usb.org/usb.ids).

For example, the hardware key manufacturer of the [YubiKey 5 Series](https://www.yubico.com/de/store/#yubikey-5-series),
[yubico](https://www.yubico.com/), is listed as *Yubico.com* with the _vendor_ id 1050.
For each of the registered products, there are different unique _product_ ids, which look (at the time of writing) like this:

```
1050  Yubico.com
	0010  Yubikey (v1 or v2)
	0110  Yubikey NEO(-N) OTP
    [...]
	0406  Yubikey 4/5 U2F+CCID
	0407  Yubikey 4/5 OTP+U2F+CCID
	0410  Yubikey plus OTP+U2F
```

## NixOS Module

The project also provides a NixOS module.
NixOS is treated as a first-class citizen and makes it trivial to
deploy a USB/IP host/client infrastructure securely with minimal
footprint and auto-mount capabilities.

In short, importing the module this flake provides:
- `services.usbip_wrapper_client`
  - Creates a `systemd` Unit file that connects to a specified host and
  mounts the listed USB devices.
  - The basis for further `systemd` customization/logic to load the unit file
  as a dependency of a different one or chain multiple together with different
  possible hosts.
- `services.usbip_wrapper_host`
  - Creates a few `systemd` Unit files that automatically start and manage
  the `usbip` server for a specific amount of time and automatically
  hosts the listed USB devices if available.
  - Usually does not require any further configuration

The NixOS Module also ensures that the _correct_ `usbip` version is used, i.e., from the kernel version of the host, and loads the required kernel
_modules_ depending on which unit is activated.

This means that from the viewpoint of a NixOS user, all of the complexity
associated with installing the `usbip` package, required _kernel modules_, and
configuring a secure auto-mount pipeline is done automatically and one only
needs to configure the desired behavior, showing the _real strength_ of NixOS :heart: .

For more information about the different configuration options, please see the
source module file at [./nix/usbip_wrapper.nix](./nix/usbip_wrapper.nix).
A nicer auto-generated documentation is planned.
For a detailed overview of the inner workings of the auto-mount `systemd` pipeline,
please take a look at the [./docs/systemd_doc.md](./docs/systemd_doc.md).

## Testing

The project contains _unit tests_ that are directly embedded inside
the Rust code.
Simply run `cargo test` to execute them.

The project also contains a very complex _integration test suite_.
This test suite ensures that the NixOS Module and all of the provided
configuration options work as expected, but it also ensures that the
USB/IP package behaves as expected under different scenarios.

The integration test suite contains one set-up where a cluster of 4
virtual machines, 2 clients and 2 hosts (one with the current stable
and one with the latest Linux kernel version), are spun up and each
client/host pair connects to each other and mounts a virtual/emulated
USB device.
See the [./nix/tests.nix](./nix/test.nix) file for more details.

These tests can be run via:

```nix build -L .#<test-name>```

## Nushell?

The previous version was implemented in Rust but I rewrote the application
as a [`nushell`](https://www.nushell.sh/) script.
At the time of writing (v0.79), nushell is mature enough to write some
medium sized scripts but there are a few hurdles when it is used as an _application_.
In the NixOS related code, there are quite a few work-arounds to hide the limitation
but all-in-all nushell seems to be a perfect fit scripts!

I am keeping both implementations in the repository, to also provide a comparison between
both languages for medium-sized scripts.


# USB/IP Wrapper Automation Documentation

<!--toc:start-->
- [USB/IP Wrapper Automation Documentation](#usbip-wrapper-automation-documentation)
  - [TL;DR](#tldr)
  - [Details](#details)
  - [Security](#security)
    - [The secure channel](#the-secure-channel)
  - [Final notes](#final-notes)
<!--toc:end-->

## TL;DR

The TL;DR for NixOS users is:
- _Client_ requests a USB device
- _Hoster_ only starts up the server and uses resources if a request is made over a secure channel
- _Hoster_ will shut down after a pre-configured time and free up the resources, guaranteeing
that the USB device will become locally available again.

## Details
In the following, we have two devices that communicate with each other, an USB/IP _client_ and a _host_.
The _host_ makes a locally attached USB device available for a USB/IP _client_ to remotely mount.
These terms may conflict with other definitions when we are trying to unlock an encrypted device on a _server_.
Here, a Laptop or other PC is usually used to _host_ a USB device and the _server_ wants to mount the USB device remotely.
So in this scenario, the Laptop becomes the USB/IP _host_ (as it is _hosting_ a USB device) and the server becomes the USB/IP _client_ as it wants to
mount a remote USB device.
I know it is confusing, but just try to keep track of who hosts the USB stick :)

These two devices share a few variables:
- `port`: The port over which the client communicates with the hoster
- `usb-ids`: A list of USB IDs that a hoster may provide and a client may want to mount
  - The lists may only contain a single entry and may be asymmetric as one host may provide different devices for various clients.

Finally, the auto-mount process that is provided for NixOS users looks as follows:

- The USB/IP _client_ requests to mount a remote USB device with a given USB ID over a [secure channel](#the-secure-channel)
- The USB/IP _host_ has an active [systemd-socket](https://www.freedesktop.org/software/systemd/man/systemd.socket.html#) that listens for an incoming TCP connection
on the pre-defined `port`. If data is received over this port:
  - The actual USB/IP server application is started on the _hoster_ with a _safe-loader_
  - The _safe-loader_ ensures that the next steps are delayed until the server application completely finished its start-up process[^1]
    - For the interested: This is done via a hacky `systemd` unit that is spawned before the server application starts and
    watches the `journalctl` output from this point in time and waits until the server application _announces_ that it finished initializing
    and is ready for incoming connections.
  - Start the _global_ time-to-live for the server application to guarantee the USB device is unmounted from the remote _client_
  and becomes available again for the _hoster_
- Reply to the request of the USB/IP _client_ and mount the requested USB device if available
- If the time-to-live timer runs up, stop the USB/IP server application and free up all resources

[^1]: If this is skipped, the USB/IP server application will respond during the start-up phase that it isn't ready for incoming connections and will fail to
process the request of the _client_.

## Security
As one can imagine, this setup does raise some security concerns, especially
if a USB stick is shared that contains a key file or is a USB hardware key
that doesn't require any interaction.
There are quite a few uncommon parts one has to be aware of when thinking about
sharing USB devices over a network.

For one, the communication is *not* done via HTTP(s), which means that the
service _cannot_ be routed through a classic HTTP(s) reverse proxy like Caddy/NGINX/Traefik.
Also, the USB _hoster_ is usually a Laptop that is also connected to public Wi-Fi
or any other untrusted network.
This means that opening the firewall/ports shouldn't be done without thinking[^2].
Finally, if this should be done in an automated and transparent fashion
one has to be very sure that one doesn't accidentally allow any random client
to _mount_ your hardware key without you noticing!

The solution I came up with, is one of my favorite solutions when it comes to
security. Acknowledging that this is too risky and that I should build on work
from other specialists that know what they are doing.
So instead of trying to come up with custom firewall rules, complicated authentication schemes, or encryption strategies, I simply _require_ that a
_secure channel_ has to be used from the start.

[^2]: Yes, I know, you should never open ports without thinking. Just saying you should
maybe think thrice not twice before doing so :p

### The secure channel
Here, we define a secure channel as an interface that only allows devices to communicate with each other that have been authenticated.
Practically speaking, this should be a network interface that is managed via [WireGuard](https://www.wireguard.com/), [tailscale](https://tailscale.com/), or similar.
This may seem like a _trivial_ solution but it does allow the project to stay simple
and keep the _sensitive_ part configurable.

I use tailscale and only have to open up the port on the tailscale interface.
As tailscale already takes care of the authentication, I can be sure that only
_authenticated_ devices can communicate with each other.
With the [ACL tags](https://tailscale.com/kb/1068/acl-tags/) one can even configure
which _exact_ machines are allowed to communicate over the pre-defined `port`.

## Final notes

Yeah, I know this was a lot...
Sorry for that.
I wanted to write a blog post about it, but creating a blog is too much work...
And this document will help me remember what past me was thinking.
But hey, maybe you also learned something along the way.
Feel free to create an issue if something was unclear or, if you are as obsessive as I am,
ask for more details

Either way, farewell traveler 👋.

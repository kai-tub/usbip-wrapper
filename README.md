# USB-IP Wrapper (WIP!)

A nice wrapper around the usbip tool.

## USB-IDs

The _official_ list of known USB ID's can be found at [linux-usb.org/usb.ids](http://www.linux-usb.org/usb.ids).

For example, the hardware key manufacturer of the [YubiKey 5 Series](https://www.yubico.com/de/store/#yubikey-5-series),
[yubico](https://www.yubico.com/), is listed as *Yubico.com* with the _vendor_ id 1050.
For each of the registered products, there is a different unique _product_ ids, which look (at the time of writing) like:

```
1050  Yubico.com
	0010  Yubikey (v1 or v2)
	0110  Yubikey NEO(-N) OTP
	0111  Yubikey NEO(-N) OTP+CCID
	0112  Yubikey NEO(-N) CCID
	0113  Yubikey NEO(-N) U2F
	0114  Yubikey NEO(-N) OTP+U2F
	0115  Yubikey NEO(-N) U2F+CCID
	0116  Yubikey NEO(-N) OTP+U2F+CCID
	0120  Yubikey Touch U2F Security Key
	0200  Gnubby U2F
	0211  Gnubby
	0401  Yubikey 4/5 OTP
	0402  Yubikey 4/5 U2F
	0403  Yubikey 4/5 OTP+U2F
	0404  Yubikey 4/5 CCID
	0405  Yubikey 4/5 OTP+CCID
	0406  Yubikey 4/5 U2F+CCID
	0407  Yubikey 4/5 OTP+U2F+CCID
	0410  Yubikey plus OTP+U2F
```

## (Possible) Roadmap

Things I might work on if I am bored or if somebody would like to have the feature implemented:

- Allow wild-carding of the device ID like `1050:*` 
  - Use-case: Would allow to easily add multiple different devices from the same vendor
  - Draw-back: Feels kinda cryptic to me and I am more leaning towards the next idea below
- Integrate a copy (probably in a parsed HashMap) of the [USB ID list](http://www.linux-usb.org/usb.ids) at build time into the final binary
  - Use-case: Allow quick validation of given USB ID's raise warning if unknown id is given to make it easier to spot typo's; though it shouldn't error out as it might be valid
  - Use-case: Allow vendor-specific *wild-carding* to only say mount _Yubico.com_ to try to match all possible plugged in hardware keys from that vendor (with known product id!)
    - Extra: Allow fuzzy matching to only provide _yubico_ as a name to match _Yubico.com_
    - Draw-back: Wild-carding can lead to unexpected behavior and a user _should_ probably look up what they are making _mountable_ on their side...
  
### Rejected ideas

Things that I thought about adding to the roadmap but rejected because ...:

- Allow fuzzy-matching of product name
  - Bad idea because similar name can appear across many different vendors with potentially unexpected matches if product name is too generic; for example, _Card Reader_ would
  match 326 times.
- Use a configuration file to have custom _names_ for USB ID's
  - Bad idea for multiple reasons. For one, this requires additional configuration for the user and, secondly, with the (in the near future published) strict,
  supported systemd service units, the program won't be allowed to read from the user's home directory.
  Ideally, it shouldn't have access to any local files to further minimize the required capabilities.
  Thirdly, this would lead to cases where a reviewer of the CLI calls cannot be sure which USB devices are included and which aren't, especially if USB devices have
  similar names, or if only the vendor name is used but not the product name. For example, if the custom name is _yubikey_, it isn't clear which key is meant.
  This is a bad user experience and there already is a _unique_ way to describe USB devices by using the _official_ USB ID list!
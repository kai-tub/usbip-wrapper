# Roadmap

Things I might work on if I am bored or if somebody would like to have the feature implemented:

- Allow wild-carding of the device ID like `1050:*`
  - Use-case: Would allow to easily add multiple different devices from the same vendor
  - Draw-back: Feels kinda cryptic to me and I am more leaning towards the next idea below
- Integrate a copy (probably in a parsed HashMap) of the [USB ID list](http://www.linux-usb.org/usb.ids) at build time into the final binary
  - Use-case: Allow quick validation of given USB ID's raise warning if unknown id is given to make it easier to spot typo's; though it shouldn't error out as it might be valid
  - Use-case: Allow vendor-specific *wild-carding* to only say mount _Yubico.com_ to try to match all possible plugged in hardware keys from that vendor (with known product id!)
    - Extra: Allow fuzzy matching to only provide _yubico_ as a name to match _Yubico.com_
    - Draw-back: Wild-carding can lead to unexpected behavior and a user _should_ probably look up what they are making _mountable_ on their side...

But does this really provide the user any real benefits?
If the installation is as complex as it already is, then running `lsusb` once for
every different device/vendor is just as complex as looking up the official list
and thinking about globbing...

- Apply systemd hardening to ensure that the script can only modify strictly defined parts of the system

## Rejected ideas

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


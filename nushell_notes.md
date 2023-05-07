# Nushell Notes

`nushell` seems to do some complex job-control
and causes issues when the _NixOS VM_ tests run `execute`.
It can be reproduced by calling wrapping the line inside a `pkgs.writeShellScriptBin`

```
pkgs.writeShellScriptBin "fails-in-vm" ''
	${pkgs-unstable.nushell}/bin/nu -c "^ls"
''
```

To still allow full integration tests of the code itself,
I try to avoid the issue by creating custom `systemd` modules that
simply call the script however I need.
And then I can access the output of `journalctl` to see if it worked
as expected.

It is by no means a nice solution but it works :shrug:.




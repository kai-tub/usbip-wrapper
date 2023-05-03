#!/usr/bin/env nu
use std "assert"
use std "log error"
use std "log info"
use std "log warning"

# FUTURE: Add additional code that checks whether or not `usbip` is available and provide
# some nice error message to describe where and how to install it.
# FUTURE: Add tests that force 'unhappy' paths of the code to be taken. The unhappy path might be
# emulated via QEMU.

def USBID_REGEX [] { '(?P<usbid>[0-9a-fA-F]{4}:[0-9a-fA-F]{4})' }
def BUSID_REGEX [] { '(?P<busid>[0-9]+-[0-9]+)' }

# DISCUSS: Inheritence of parameters, or shared documentation would be a very nice quality of live improvement

export def "parse usbid" [] {
	parse --regex (USBID_REGEX)
}

# parse output of usbip list --remote
export def "parse usbip-list-remote" [] {
	parse --regex ( (BUSID_REGEX) + ':.+?:.+\(' + (USBID_REGEX) + '\)' )
}

# parse output of usbip port
export def "parse usbip-port" [] {
	parse --regex ( 'Port\s+(?P<port>\d+).*\n\s*(?P<description>.*)\(' + (USBID_REGEX) + '\)' )
}

# parse output of usbip list --local
export def "parse usbip-list-local" [] {
	parse --regex ( 'busid ' + (BUSID_REGEX) + '\s+\(' + (USBID_REGEX) + '\)\s*\n\s*(?P<description>.*)' )
}

# List all local USB devices that can be hosted via usbip
export def "usbip-wrapper list hostable" [] {
	# how should I check for installed command?
	^usbip list --local | parse usbip-list-local
}

# List all hosted USB devices from localhost
# may _require_ client kernel modules!
export def "usbip-wrapper list unhostable" [
	--tcp-port: int = 8324	# The tcp-port over which to communicate
] {
	usbip-wrapper list mountable --tcp-port $tcp_port localhost
}

# List all remote USB devices that can be mounted
export def "usbip-wrapper list mountable" [
	host: string,		# The path to the host to connect to
	--tcp-port: int = 8324	# The tcp-port over which to communicate
] {
	do { ^usbip --tcp-port $tcp_port list --remote $host }
	| complete
	| match $in.exit_code { 
		0 => { 
			$in.stdout | parse usbip-list-remote
		},
		_ => { 
			log error $"Is the usbip daemon/server running and is it running via port ($tcp_port) on ($host)?"
			$in.stderr
			exit -1
		}
	}
}

# List all remote USB devices that were locally mounted via usbip
export def "usbip-wrapper list unmountable" [] {
	^usbip port | parse usbip-port
}

# Bind a USB device via it's busid and make it accessible for remote connections
export def "usbip-wrapper bind" [
	--tcp-port: int = 8324
	busid: string
] {
	do { ^usbip --tcp-port $tcp_port bind --busid $busid }
	| complete
	| match $in.exit_code {
		0 => {
			log info $"bound ($busid)"
		},
		_ => {
			match ($in.stderr | str contains "already bound to usbip-host") {
				true => {
					log info "already bound to usbip-host; not re-binding"
				}
				false => {
					log error $"($in.stderr)"
					error make { msg: $"($in.stderr)" }
					exit -1
				},
			}
		}
	}
	null
}

# Unbind a USB device via it's busid and make it unaccessible for remote connections
export def "usbip-wrapper unbind" [
	--tcp-port: int = 8324
	busid: string
] {
	do { ^usbip --tcp-port $tcp_port unbind --busid $busid }
	| complete
	| match $in.exit_code {
		0 => { log info $"unbound ($busid)" },
		_ => {
			 # The following error may re-occure when the listing of bound devices is buggy
			match ($in.stderr | str contains "device is not bound") {
				true => { log info $"($busid) wasn't bound to host; ignoring" },
				false => {
					log error $"($in.stderr)"
					error make { msg: $"($in.stderr)" }
					exit -1
				}
			}
		}
	}
	null
}

# Host local USB devices and make them accessible for remote usbip clients
# by providing the desired usbids. If multiple USB devices with the same
# usbid are connected, then all of them will be hosted.
export def "usbip-wrapper host" [
	--tcp-port: int = 8324		# The tcp-port to host
	...usbids: string	# The USB devices to host, given their respective usbid
] {
	let usbids_span = (metadata $usbids).span
	let hostable = (usbip-wrapper list hostable)

	let to_host =	($hostable | join ($usbids | parse usbid) 'usbid')

	if ($to_host.usbid | is-empty) {
		log error $"Zero matching usbid\(s\) found for ($usbids)"
    error make {
        msg: 'No matching usbid(s) found!',
        label: {
            text: $"None of these matched ($to_host.usbid)",
            start: $usbids_span.start,
            end: $usbids_span.end
        }
    }
		exit -1
	}
	# DISCUSS: Would it make sense to define a is-not-empty?
	let missed_usbids = ($usbids | filter {|usbid| $usbid not-in $to_host.usbid})
	if ($missed_usbids | length) > 0 {
		# only warn for partial matches for now. Could also throw an error in the future
		# then with additional information "underlining" of which input was incorrect
		# or add a flag that enables/disables partial matching
		log warning $"The following usbids were NOT found: ($missed_usbids)"
	}
	
	$to_host.busid | each { |busid| usbip-wrapper bind --tcp-port $tcp_port $busid}
	null
}

# Unbind a hosted USB device from the usb/ip server
# If no specific USB ID(s) is/are given, then all will be removed
export def "usbip-wrapper unhost" [
	--tcp-port: int = 8324		# The tcp-port
	...usbids: string	# The USB devices to unhost, given their respective usbid. If none is given, all will be unhosted
] {
	let unhostable = (usbip-wrapper list unhostable);

	let to_unhost = match ($usbids | is-empty ) {
		true => { ($unhostable) },
		false => { ($unhostable | join ($usbids | parse usbid) 'usbid') },
	}
	# FUTURE: Could also provide errors/warning if only partial match exists!
	$to_unhost.busid | each {|busid| usbip-wrapper unbind --tcp-port $tcp_port $busid }
	null
}

# start-usb-hoster
# Known issue that it hangs whenever it is run without root rights without
# failing, although it isn't working
export def "usbip-wrapper start-usb-hoster" [
	--pid-path: path = /tmp/usbipd.pid # Path to which the server will try to write the pid file
	--tcp-port: int = 8324 # The tcp-port over which to communicate
	--debug # debug flag
] {
	# DISCUSS: Flag to string
	let debug_flag = (match $debug { false => "", true => "--debug" })
	# ASK: Figure out how I can iteratively process the stderr output and generate
	# an early exit if specific condition is reached
	# run-external --redirect-stderr --redirect-stdout "usbipd" | lines | each {|l| print 'a'; sleep 1sec }
	do { ^usbipd --tcp-port $tcp_port --pid $pid_path $debug_flag }
	null
}

# Unmount a remote-usb from the local server
export def "usbip-wrapper unmount-remote" [
	...usbids: string
] {
	let unmountable = (usbip-wrapper list unmountable);
	let usbids_span = (metadata $usbids).span

	let to_unmount = match ($usbids | is-empty) {
		true => { $unmountable },
		false => {
			($unmountable | join ($usbids | parse usbid) 'usbid')
		}
	}

	if ($to_unmount.usbid | is-empty) {
		log error $"Zero matching usbid\(s\) found for ($usbids)"
    error make {
        msg: 'No matching usbid(s) found!',
        label: {
						# check if unmountable is empty and if it is trigger text that
						# first mounting is required!
            text: $"None of these matched ($to_unmount.usbid)",
            start: $usbids_span.start,
            end: $usbids_span.end
        }
    }
		exit -1
	}
	let missed_usbids = ($usbids | filter {|usbid| $usbid not-in $to_unmount.usbid})
	if ($missed_usbids | length) > 0 {
		# only warn for partial matches for now. Could also throw an error in the future
		# then with additional information "underlining" of which input was incorrect
		# or add a flag that enables/disables partial matching
		log warning $"The following usbids were NOT found on remote and were NOT mounted: ($missed_usbids)"
	}

	$to_unmount
	| each { |row|
		do { ^usbip detach --port $row.port }
		| complete
		| match $in.exit_code {
			0 => { log info $"Unmounted ($row.usbid)" },
			_ => {
				print $in.stderr
				exit 1
			}
		}
	}
	null
}


# Mount remote USB devices via usbip by providing the usbids of the target devices
# If none are given, mount all available devices
export def "usbip-wrapper mount-remote" [
	--tcp-port: int = 8324
	host: string
	...usbids: string
] {
	let mountable = (usbip-wrapper list mountable $host);
	let usbids_span = (metadata $usbids).span

	let to_mount = match ($usbids | is-empty) {
		true => { $mountable },
		false => {
			($mountable | join ($usbids | parse usbid) 'usbid')
		}
	}

	if ($to_mount.usbid | is-empty) {
		log error $"Zero matching usbid\(s\) found for ($usbids)"
    error make {
        msg: 'No matching usbid(s) found!',
        label: {
            text: $"None of these matched ($to_mount.usbid)",
            start: $usbids_span.start,
            end: $usbids_span.end
        }
    }
		exit -1
	}
	let missed_usbids = ($usbids | filter {|usbid| $usbid not-in $to_mount.usbid})
	if ($missed_usbids | length) > 0 {
		# only warn for partial matches for now. Could also throw an error in the future
		# then with additional information "underlining" of which input was incorrect
		# or add a flag that enables/disables partial matching
		log warning $"The following usbids were NOT found on remote and were NOT mounted: ($missed_usbids)"
	}

	$to_mount.busid
	| each { |busid|
		do { ^usbip --tcp-port $tcp_port attach --busid $busid --remote $host }
		| complete
		| match $in.exit_code {
			0 => { log info $"Mounted ($busid)" },
			_ => {
				print $in.stderr

				if ($in.stderr | str contains 'vhci_driver') {
					print "\nPlease enable the `vhci-hcd` kernel module!"
				}
				exit 1
			}
		}
	}
	null
}

export def main [] {
	echo "Calling main!"
}

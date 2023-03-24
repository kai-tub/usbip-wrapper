use core::fmt;
use std::path::PathBuf;

use anyhow::{anyhow, Context};
use clap::{Parser, Subcommand};
use env_logger;
use log::{debug, error, warn};
use regex::Regex;
use std::collections::{HashMap, HashSet};
use std::string::String;
use xshell::{cmd, Shell};

#[derive(Parser, Debug)]
#[command(author, version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Bind USB device
    Host {
        #[arg(long, default_value_t = 3240, env = "USBIP_TCP_PORT")]
        tcp_port: u32,
        #[arg(last = true, required = true)]
        usb_ids: Vec<String>,
    },
    /// Unbind USB device
    /// If unhosted while remote is still connected, it seems like
    /// it will also be disconnected from the client without any issues.
    Unhost {
        #[arg(long, default_value_t = 3240, env = "USBIP_TCP_PORT")]
        tcp_port: u32,
        /// Not specifying a value will unbind all hosted USB devices!
        #[arg(last = true)]
        usb_ids: Vec<String>,
    },
    /// Start usbip daemon via `usbipd`
    StartUsbHoster {
        /// Start daemon with debug option enabled
        #[arg(long, env = "USBIP_DAEMON_DEBUG")]
        debug: bool,

        /// Change path to PID file
        #[arg(
            long,
            default_value = "/var/run/usbipd.pid",
            env = "USBIP_DAEMON_PID_PATH"
        )]
        pid: PathBuf,

        /// Select which TCP port to use
        /// Please note that the environment variable does NOT contain DAEMON
        /// to highlight that the environment variable is shared between the
        /// usbip interface and the daemon.
        #[arg(long, default_value_t = 3240, env = "USBIP_TCP_PORT")]
        tcp_port: u32,
    },
    /// List all devices that can be hosted, i.e. all USB devices that are connected locally
    ListHostable {},
    /// List all devices that can be mounted from an usbip host.
    /// Defaults to `localhost` which allows to quickly debug if previous mounted usb devices
    /// were attached correctly. For _real_ use, please overwrite the `host` value to the external
    /// usbip host/server.
    ListMountable {
        #[arg(long, default_value_t = 3240, env = "USBIP_TCP_PORT")]
        tcp_port: u32,
        #[arg(long, default_value = "localhost", env = "USBIP_REMOTE_HOST")]
        host: String,
    },
    /// Mount devices from an usbip host.
    MountRemote {
        #[arg(long, default_value_t = 3240, env = "USBIP_TCP_PORT")]
        tcp_port: u32,
        #[arg(long, required = true, env = "USBIP_REMOTE_HOST")]
        host: String,
        /// UsbIds to mount; if none are given it will default to mounting
        /// _all_ remotely available USB devices!
        #[arg(last = true)]
        usb_ids: Vec<String>,
    },
    /// Unmount remote device
    /// Required (!) to be able to re-mount the USB device again
    /// and might cause problems if not done. Especially during restarts for example
    /// If usbip port is not executed with `root` priveliges, it will still work,
    /// but the host will be called `unknown host, remote port and remote busid`
    /// but it will still list the used port and the usbid
    UnmountRemote {
        #[arg(last = true)]
        usb_ids: Vec<String>,
    },
}

/// A simple enum that indicates whether to bind or
/// unbind a local USB device
enum BindType {
    Bind,
    Unbind,
}

impl BindType {
    // TODO: Read up if this can be split into two parts!
    fn execute(&self, busid: &BusId, tcp_port: u32) -> anyhow::Result<()> {
        let port = tcp_port.to_string();
        let b = busid.to_string();
        let sh = Shell::new()?;
        match &self {
            BindType::Bind => {
                let bind_type_s = self.to_string();
                let stderr = cmd!(sh, "usbip --tcp-port {port} {bind_type_s} --busid={b}")
                    .ignore_status()
                    .read_stderr()
                    .expect("Error during reading StdErr!");
                if stderr.contains("error: ") && !stderr.contains("already bound to usbip-host") {
                    Err(anyhow!("Unknown error message: {stderr}"))?;
                }
                Ok(())
            }
            BindType::Unbind => {
                let bind_type_s = self.to_string();
                let stderr = cmd!(sh, "usbip --tcp-port {port} {bind_type_s} --busid={b}")
                    .ignore_status()
                    .read_stderr()
                    .expect("Error during reading StdErr!");
                if stderr.contains("error: ")
                    && !stderr.contains("device is not bound to usbip-host")
                {
                    Err(anyhow!("Unknown error message: {stderr}"))?;
                }
                Ok(())
            }
        }
    }
}

impl fmt::Display for BindType {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            BindType::Bind => write!(f, "bind"),
            BindType::Unbind => write!(f, "unbind"),
        }
    }
}

/// Simple struct string-variant that contains
/// a unique BusId (which may change between reboots!)
#[derive(Debug, Eq, PartialEq, Hash, Clone)]
struct BusId(String);

/// Internal USB port that the "virtual"/remote USB
/// was locally attached to.
/// Has NOTHING to do with the TCP port!
#[derive(Debug, Eq, PartialEq, Hash, Clone)]
struct Port(String);

/// Simple struct string-variant that contains
/// a UsbId/VendorId that might be shared across multiple USB
/// devices from the same vendor, for example, when having multiple
/// hardware keys, like the Yubikey plugged in
#[derive(Debug, Eq, PartialEq, Hash, Clone)]
struct UsbId(String);

/// Simple Pair wrapper for convenience around `BusId` and `UsbId`
struct IdPair {
    bus_id: BusId,
    usb_id: UsbId,
}

struct UsbPortPair {
    usb_id: UsbId,
    port: Port,
}

impl fmt::Display for BusId {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Display for UsbId {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl fmt::Display for Port {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// A simple struct string-variant that contains
/// all locally hostable USB devices in a detailed/pretty format
#[derive(Debug)]
struct ListHostable(String);

/// A simple struct string-variant that contains
/// all locally hostable USB devices in a compressed/parsable format
#[derive(Debug)]
struct ListHostableParsable(String);

/// A simple struct string-variant that contains
/// all remotely mountable USB devices
#[derive(Debug)]
struct ListMountable(String);

/// A simple struct string-variant that contains
/// all, from a remote usbip-hosted, mounted devices
/// that can be unmounted
#[derive(Debug)]
struct ListUnmountable(String);

// Sharing life-time mostly as practice, should actually clone for better UX
// TODO: Think about if this is not simply a set operation and all values
/// Given the set of usb_ids and a map of usb_ids and a value set, return
/// all values that match.
fn collect_matching<'a, T>(
    m: &'a HashMap<UsbId, HashSet<T>>,
    usb_ids: &HashSet<UsbId>,
) -> Vec<&'a T> {
    m.iter()
        .filter(|(usbid, _set)| usb_ids.contains(usbid))
        .flat_map(|(_usbid, set)| set)
        .collect()
}

fn all_values<'a, T>(m: &'a HashMap<UsbId, HashSet<T>>) -> Vec<&'a T> {
    m.iter().flat_map(|(_usbid, set)| set).collect()
}

impl ListHostable {
    fn new() -> anyhow::Result<Self> {
        let sh = Shell::new()?;
        let stdout = cmd!(sh, "usbip list --local").read()?;
        Ok(ListHostable(stdout))
    }
}

/// Small helper that parses the source to a usbid-{busid} map given a regular expression.
/// The regular expression must contain the capture groups `busid` and `usbid`, otherwise
/// the function will return an error.
/// I wish there was a way to enforce this at compile time...
fn build_usbid_map_helper(
    source: &str,
    regex: &Regex,
) -> anyhow::Result<HashMap<UsbId, HashSet<BusId>>> {
    if regex
        .capture_names()
        .filter_map(|cap| cap)
        .collect::<HashSet<_>>()
        != vec!["busid", "usbid"].into_iter().collect::<HashSet<_>>()
    {
        return Err(anyhow!("Provided invalid regular expression!\nMust have capture groups that contain `usbid` and `busid`!"));
    }
    let res = regex
        .captures_iter(source)
        .filter_map(|cap| match (cap.name("busid"), cap.name("usbid")) {
            // defining a pair guarantees that there is no difference due to ordering
            (Some(busid), Some(usbid)) => Some(IdPair {
                bus_id: BusId(busid.as_str().to_string()),
                usb_id: UsbId(usbid.as_str().to_string()),
            }),
            _ => None,
        })
        .fold(HashMap::new(), |mut acc, p| {
            acc.entry(p.usb_id)
                .or_insert(HashSet::new())
                .insert(p.bus_id);
            acc
        });
    Ok(res)
}

impl ListHostableParsable {
    fn new() -> anyhow::Result<Self> {
        let sh = Shell::new()?;
        let stdout = cmd!(sh, "usbip list --parsable --local").read()?;
        Ok(ListHostableParsable(stdout))
    }

    fn build_usbid_map(&self) -> HashMap<UsbId, HashSet<BusId>> {
        build_usbid_map_helper(
            &self.0,
            &Regex::new(r"busid=(?P<busid>.*?)#usbid=(?P<usbid>.*?)#").unwrap(),
        )
        .unwrap()
    }
}

impl ListMountable {
    /// Call `usbip` and get a list of all mountable USB devices
    fn new(host: &str, port: u32) -> anyhow::Result<Self> {
        let sh = Shell::new()?;
        let port = port.to_string();
        let stdout = cmd!(sh, "usbip --tcp-port={port} list --remote={host}").read();
        match stdout {
            Ok(s) => Ok(ListMountable(s)),
            Err(s) => {
                let err_s = s.to_string();
                if err_s.contains("command not found") {
                    Err(anyhow!(
                        "Cannot find the command `usbip`.\n  \
                         Please install the usbip package or add it to your PATH"
                    ))
                } else {
                    Err(anyhow!(
                        "Is the usbip daemon/server running and is it runnig via port {port}?"
                    ))
                }
            }
        }
    }

    fn build_usbid_map(&self) -> HashMap<UsbId, HashSet<BusId>> {
        build_usbid_map_helper(
            &self.0,
            &Regex::new(r"\s+(?P<busid>[0-9\-]+):.+?:.+\((?P<usbid>[0-9a-fA-F]+:[0-9a-fA-F]+)\)")
                .unwrap(),
        )
        .unwrap()
    }
}

impl ListUnmountable {
    /// Call `usbip` and get a list of all mountable USB devices
    fn new() -> anyhow::Result<Self> {
        let sh = Shell::new()?;
        let stdout = cmd!(sh, "usbip port").read();
        match stdout {
            Ok(s) => Ok(ListUnmountable(s)),
            Err(s) => {
                let err_s = s.to_string();
                if err_s.contains("command not found") {
                    Err(anyhow!(
                        "Cannot find the command `usbip`.\n  \
                         Please install the usbip package or add it to your PATH"
                    ))
                } else {
                    Err(anyhow!(s))
                }
            }
        }
    }

    // TODO: Think about how to refactor this code!
    fn build_usbid_map(&self) -> HashMap<UsbId, HashSet<Port>> {
        Regex::new(r"Port\s+(?P<port>\d+).*\n.*\((?P<usbid>[0-9a-fA-F]+:[0-9a-fA-F]+)\)")
            .unwrap()
            .captures_iter(&self.0)
            .filter_map(|cap| match (cap.name("port"), cap.name("usbid")) {
                // defining a pair guarantees that there is no difference due to ordering
                (Some(port), Some(usbid)) => Some(UsbPortPair {
                    port: Port(port.as_str().to_string()),
                    usb_id: UsbId(usbid.as_str().to_string()),
                }),
                _ => None,
            })
            .fold(HashMap::new(), |mut acc, p| {
                acc.entry(p.usb_id).or_insert(HashSet::new()).insert(p.port);
                acc
            })
    }
}

/// Quickly check the `usbip` version and provide additional information
/// if the executable cannot be found.
fn check_usbip_version(sh: &Shell) -> anyhow::Result<()> {
    let version = cmd!(sh, "usbip version").read().with_context(|| {
        "Could not determine installed usbip version. Is usbip installed/added to PATH?"
    })?;
    debug!("usbip version is: {version}");
    Ok(())
}

/// Bind/Unbind all UsbIds from the given HashSet over the given TCP port
/// TODO: Does it actually require the correct TCP port?
// fn bind_usb_ids(bind_type: BindType, usb_ids: &HashSet<UsbId>, port: u32) -> anyhow::Result<()> {
//     let hs = ListHostableParsable::new()?.build_usbid_map();
//     let matched_busids = collect_matching(&hs, &usb_ids);
//     debug!("Matched Busids: {matched_busids:?}");
//     if matched_busids.len() == 0 {
//         warn!("Found no matching USB IDs!");
//         println!("Found no matching USB IDs!");
//         return Ok(());
//     }
//     for b in matched_busids {
//         debug!("{bind_type}ing {b}");
//         bind_type.execute(b, port)?;
//     }
//     Ok(())
// }

// Some weird notes for readme:
// You can bind before you start the daemon/server and it will work!
fn main() -> anyhow::Result<()> {
    env_logger::init();
    let cli = Cli::parse();
    let sh = Shell::new()?;

    let command = cli.command;
    check_usbip_version(&sh)?;

    match command {
        Commands::Host { usb_ids, tcp_port } => {
            // TODO: Implement FromString for this type
            let usb_ids_set = usb_ids
                .into_iter()
                .map(|u| UsbId(u))
                .collect::<HashSet<UsbId>>();
            let hs = ListHostableParsable::new()?.build_usbid_map();
            let matched_busids = collect_matching(&hs, &usb_ids_set);
            debug!("Matched Busids: {matched_busids:?}");
            if matched_busids.len() == 0 {
                return Err(anyhow!("Found no matching USB IDs!"));
            }
            for b in matched_busids {
                debug!("hosting {b}");
                BindType::Bind.execute(b, tcp_port)?;
            }
            Ok(())
        }
        Commands::Unhost { usb_ids, tcp_port } => {
            // TODO: Implement FromString for this type
            // bind_usb_ids(BindType::Unbind, &usb_ids_set, tcp_port)
            let usbid_map = ListHostableParsable::new()?.build_usbid_map();
            let matched_busids = match usb_ids.len() {
                // TODO: Figure out how to auto-unhost all available usb sticks!
                // => Just brute-force through all possible values!
                0 => all_values(&usbid_map),
                _ => {
                    let usb_ids_set = usb_ids
                        .into_iter()
                        .map(|u| UsbId(u))
                        .collect::<HashSet<UsbId>>();
                    collect_matching(&usbid_map, &usb_ids_set)
                }
            };
            debug!("Matched Busids: {matched_busids:?}");
            if matched_busids.len() == 0 {
                return Err(anyhow!("Found no matching USB IDs!"));
            }
            for b in matched_busids {
                debug!("unbinding {b}");
                BindType::Unbind.execute(b, tcp_port)?;
            }
            Ok(())
        }
        Commands::ListMountable { tcp_port, host } => {
            let list_output = ListMountable::new(&host, tcp_port)?;
            if list_output.build_usbid_map().len() == 0 {
                println!("No mountable devices found. Use the `host` sub-command on the USB host to add USB devices.")
            } else {
                println!("{}", list_output.0);
            }
            Ok(())
        }
        Commands::ListHostable {} => {
            let list_output = ListHostable::new()?;
            println!("{}", list_output.0);
            Ok(())
        }
        Commands::MountRemote {
            tcp_port,
            host,
            usb_ids,
        } => {
            let usbid_map = ListMountable::new(&host, tcp_port)?.build_usbid_map();
            let matched_busids = match usb_ids.len() {
                0 => all_values(&usbid_map),
                _ => {
                    let usb_ids_set = usb_ids
                        .into_iter()
                        .map(|u| UsbId(u))
                        .collect::<HashSet<UsbId>>();
                    collect_matching(&usbid_map, &usb_ids_set)
                }
            };
            debug!("Matched Busids: {matched_busids:?}");
            if matched_busids.len() == 0 {
                return Err(anyhow!("Found no matching USB IDs!"));
            }
            let port = tcp_port.to_string();
            let host_s = host.to_string();

            // TODO: Potentially export as separat functionality
            for b in matched_busids {
                let b_s = b.to_string();
                // What happens if the call is execute multiple times?
                // Since every call has a unique busid it won't be called multiple times
                // each follow-up call will again check for matching ids and won't find anything
                let stderr = cmd!(
                    sh,
                    "usbip --tcp-port {port} attach --busid={b_s} --remote={host_s}"
                )
                .ignore_status()
                .read_stderr()
                .expect("Error while reading from stderr");
                if stderr.contains("open vhci_driver") {
                    error!("Missing vhci-hcd driver module");
                    Err(anyhow!("Please enable the `vhci-hcd` kernel module."))?
                }
            }

            Ok(())
        }
        Commands::StartUsbHoster {
            debug,
            pid,
            tcp_port,
        } => {
            let tcp_port_s = tcp_port.to_string();
            let version = cmd!(
                sh,
                "usbipd --version"
            )
            .read()
            .with_context(|| {
                "Could not determine installed usbipd version. Is the daemon usbipd installed/added to PATH?"
            })?;
            let debug_option = match debug {
                true => ["--debug"],
                false => [""],
            };
            debug!("usbipd version is: {version}");
            cmd!(
                sh,
                "usbipd --tcp-port {tcp_port_s} --pid {pid} {debug_option...}"
            )
            .run()
            .with_context(|| "Could not successfully start usbipd")?;
            println!("Shutting down");
            Ok(())
        }
        Commands::UnmountRemote { usb_ids } => {
            let usbid_map = ListUnmountable::new()?.build_usbid_map();
            let matched_ports = match usb_ids.len() {
                0 => all_values(&usbid_map),
                _ => {
                    let usb_ids_set = usb_ids
                        .into_iter()
                        .map(|u| UsbId(u))
                        .collect::<HashSet<UsbId>>();
                    collect_matching(&usbid_map, &usb_ids_set)
                }
            };
            debug!("Matched Ports: {matched_ports:?}");
            if matched_ports.len() == 0 {
                return Err(anyhow!("Found no matching ports!"));
            }
            // TODO: Potentially export as separat functionality
            for p in matched_ports {
                let p_s = p.to_string();
                // What happens if the call is execute multiple times?
                // Since every call has a unique busid it won't be called multiple times
                // each follow-up call will again check for matching ids and won't find anything
                let stderr = cmd!(sh, "usbip detach --port={p_s}")
                    .ignore_status()
                    .read_stderr()
                    .expect("Error while reading from stderr");
                println!("{stderr}");
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use rstest::*;

    use super::*;

    #[fixture]
    pub fn parsable_list_output() -> String {
        "busid=1-11#usbid=058f:9540#
        busid=1-1#usbid=04f2:b67c#
        busid=1-14#usbid=8087:0029#
        busid=1-8#usbid=04f2:b67c#
        busid=1-9#usbid=06cb:00bd#"
            .to_string()
    }

    // #[rstest]
    // #[case("8087:0029", vec!["1-14".to_string()])]
    // #[case("8087:002", Vec::new())]
    // #[case("04f2:b67c", vec!["1-1".to_string(), "1-8".to_string()])]
    // fn test_find_matching_busid_given_usbid(
    //     parsable_list_output: String,
    //     #[case] usbid: String,
    //     #[case] expected: Vec<String>,
    // ) {
    //     UsbIpOutput::ListLocalParsable::assert_eq!(
    //         expected,
    //         matching_busids(&parsable_list_output, &vec![usbid]) // test_match(&parsable_list_output, &usbid)
    //     )
    // }

    // TODO: make these actual tests!

    #[test]
    fn test_find_matching_pairs() {
        let s = "
         1-11: Alcor Micro Corp. : AU9540 Smartcard Reader (058f:9540)
         1-12: Alcor Micro Corp. with : colon in name : AU9540 Smartcard Reader (058f:9540)
         12-1: Alcor Micro Corp. : AU9540 Smartcard Reader (0000:0000) with trick name (058f:9540)
        "
        .to_string();
        // let pairs = [
        //     ("1-11", "058f:9540"),
        //     ("1-12", "058f:9540"),
        //     ("12-1", "058f:9540"),
        // ]
        // .into_iter()
        // .map(|(bus_id, usb_id)| IdPair {
        //     bus_id: BusId(bus_id.to_string()),
        //     usb_id: UsbId(usb_id.to_string()),
        // })
        // .collect::<Vec<IdPair>>();

        println!("{:?}", ListMountable(s).build_usbid_map())
    }

    #[test]
    fn test_port() {
        let s = "
            Port 00: <Port in Use> at Full Speed(12Mbps)
               Yubico.com : Yubikey 4/5 OTP+U2F+CCID (1050:0407)
               3-1 -> unknown host, remote port and remote busid
                   -> remote bus/dev 001/011

            Port 01: <Port in Use> at Full Speed(12Mbps)
               Yubico.com : Yubikey 4/5 OTP+U2F+CCID (1050:0407)
               3-1 -> usbip://nixos-laptop:5000/1-7
                   -> remote bus/dev 001/011
        "
        .to_string();
        println!("{:?}", ListUnmountable(s).build_usbid_map())
    }
    // TODO: Add these as they are valid busids when connected via usb-multi
    //    - busid 1-4.3.4 (0bda:402e)
    //   Realtek Semiconductor Corp. : unknown product (0bda:402e)

    // - busid 1-4.3.5 (413c:b06f)
    //   Dell Computer Corp. : unknown product (413c:b06f)

    // - busid 1-4.5 (413c:b06e
}

# Home network for Omarchy

An [Omarchy](https://omarchy.org) bar widget for a MikroTik router (RouterOS 7). Every device on the network sits in a lane (address range); drag a card to another lane to give it a fixed IP and a name. Click a card for per-device controls.

- **Lanes**: configurable address ranges, e.g. New / Lights & smart / Others / Mine. New devices land in the DHCP pool lane, and you get a notification the first time one joins.
- **Move**: the lease becomes static with the next free IP in that lane (editable). WiFi devices get kicked once so they pick it up; wired ones switch at their next renewal. iPhones often keep the old IP until renewal.
- **What is this?**: a guess from the host name (model codes like `M2101K6G`), the DHCP vendor class (`android-dhcp-13`), the MAC vendor (`/usr/share/hwdata/oui.txt`) and the domains it looks up.
- **Pause internet** and a nightly **bedtime**, through RouterOS kid-control.
- **Through the VPN**: per-device toggle that adds the device to a firewall address list your router routes through a VPN tunnel.
- **Live traffic** per device (kid-control rates) with a sparkline.
- **Who's home**: mark a phone and get a notification when it joins or leaves the WiFi (leaving counts after `awayMinutes` off the WiFi, so a napping phone doesn't trigger it).
- **Quarantine**: one toggle that keeps devices in the pool range off the rest of the LAN (bridge filter rules on every router).
- **Recent lookups** per device from the router's DNS log.
- **Health**: internet/WAN status, public IP, latency, CPU/temperature, outage log, RouterOS update check.

Device names come from the devices themselves, so everything is rendered as plain text.

## Install

```bash
git clone https://github.com/osszoi/omarchy-network ~/Work/personal/omarchy-network
~/Work/personal/omarchy-network/install.sh
```

`install.sh` copies `config.example.json` to `~/.config/omarchy-network/config.json`, asks for the router login and writes it to `~/.config/omarchy-network/netrc` (mode 600, passed to curl with `--netrc-file`, never on a command line), links the plugin and enables it. Run `omarchy restart shell` after code changes.

## Router user

Give the plugin its own user, limited to your PC's address:

```
/user group add name=omarchy-network policy=read,write,api,rest-api
/user add name=omarchy-network group=omarchy-network address=<your PC>/32 password=<long random>
```

`www` must be enabled (REST API at `http://router/rest`). RouterOS policies aren't per menu, so this user can change any setting: that's why it only works from one address. Checking for updates also needs `reboot` in the group policy; leave it out if you'd rather not.

Access points listed under `aps` need the same user (it uses one netrc entry per host).

## Router-side rules

The plugin only toggles things; these have to exist once. Adapt the addresses:

```
# per-device VPN: devices in the list route via table vpn-us (create the table, the wireguard route and the srcnat yourself)
/ip firewall address-list add list=omarchy-local address=192.168.88.0/24
/ip firewall mangle add chain=prerouting action=mark-routing new-routing-mark=vpn-us passthrough=no src-address-list=omarchy-vpn-us dst-address-list=!omarchy-local
/ip firewall filter add chain=forward action=drop src-address-list=omarchy-vpn-us out-interface-list=WAN out-interface=!wg-us place-before=0
/ip firewall filter add chain=forward action=accept connection-state=established,related src-address-list=omarchy-vpn-us place-before=[find comment="defconf: fasttrack"]
/ip firewall filter add chain=forward action=accept connection-state=established,related dst-address-list=omarchy-vpn-us place-before=[find comment="defconf: fasttrack"]

# traffic stats + pause/bedtime
/ip kid-control add name=omarchy-all mon=0s-1d tue=0s-1d wed=0s-1d thu=0s-1d fri=0s-1d sat=0s-1d sun=0s-1d

# recent lookups
/system logging action add name=omarchydns target=memory memory-lines=4000
/system logging add topics=dns action=omarchydns regex="got query from|question: "

# quarantine (pool = 192.168.88.0/27 here), on every router, disabled
/interface bridge filter add chain=forward action=accept mac-protocol=ip src-address=192.168.88.1/32 disabled=yes comment="omarchy-network: quarantine"
/interface bridge filter add chain=forward action=accept mac-protocol=ip dst-address=192.168.88.1/32 disabled=yes comment="omarchy-network: quarantine"
/interface bridge filter add chain=forward action=drop mac-protocol=ip src-address=192.168.88.0/27 dst-address=192.168.88.0/24 disabled=yes comment="omarchy-network: quarantine"
/interface bridge filter add chain=forward action=drop mac-protocol=ip src-address=192.168.88.0/24 dst-address=192.168.88.0/27 disabled=yes comment="omarchy-network: quarantine"
```

Quarantine only sees traffic that passes through a MikroTik bridge in software (WiFi). Two wired devices on the same plain switch still talk to each other.

The health line reads netwatch entries with comments `internet` (and the outage log from a disk log file `outages.0.txt`, lines tagged `OUTAGE-LOG`), if you have them.

## Config

See `config.example.json`. `notes` maps a MAC to a reminder shown when you move a device that something else reaches by IP.

## Tests

```bash
node test/logic.test.js
```

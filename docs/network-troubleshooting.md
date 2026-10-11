# Container Internet connectivity

If release discovery fails with a DNS error, check routing before changing DNS:

```sh
ip route
ip -4 route get 8.8.8.8
ip -4 route show default
ip -6 route show default
getent hosts api.github.com
curl -I --connect-timeout 10 https://api.github.com
```

A static IPv4 container normally needs a default gateway. A route added with
`ip route add default` is temporary. Save the correct gateway in the Proxmox
container's **Network → eth0 → Edit → IPv4 gateway** configuration, preserving
its address, bridge, VLAN and other existing options. Apply the network change
or restart the container when suitable, then verify the route again.

For a new installation, pass both `--ip <address/CIDR>` and `--gateway <router>`
to `ct/herdr.sh`. The installer rejects static addresses without a gateway and
persists the gateway in the Proxmox `net0` configuration. DHCP installations
depend on the DHCP server supplying a router. The application cannot safely
infer your router from the container's IP address.

The dashboard diagnoses failed connectivity using read-only IPv4 and IPv6
route queries and default-route configuration. The configured gateway and
interface appear in the diagnosis when available. These read-only queries send
no packets: an existing route does not establish whether its next hop is
reachable. If the `ip` command is unavailable or probes time out, the diagnosis
reports that limitation without claiming that a route is missing. It never
changes routing. The dashboard also explains that manually added routes are
temporary.
After repairing connectivity, **Check for updates** retries immediately.
Background checks back off for one minute after failures.

Release discovery failures are recorded in the gateway's systemd journal.
The first failure and changes in its error or diagnosis emit WARNING messages;
identical retries emit DEBUG messages. Recovery emits an INFO summary with the
number of failed attempts and the outage's start time. The dashboard always
shows the current failure count and start time, so repeated warnings are not
needed to expose a persistent outage. Cached reads do not increase the count.
These counters are in memory and reset on successful discovery or gateway
restart. Discovery is driven by dashboard requests, not an independent
background loop; leaving the page stops its requests.
Find the installed unit with `systemctl list-units --all '*herdr*'`, then run
`journalctl -u <gateway-unit> --since '30 minutes ago' --no-pager`.
Installation status and release discovery are separate: a completed previous
installation can coexist with a failed current release check.

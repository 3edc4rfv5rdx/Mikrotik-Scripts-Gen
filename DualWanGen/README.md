# DualWanGen

`DualWanB.sh` builds failover between two uplinks on one MikroTik router: a
primary and a backup default route, each checked by pinging its own probe
address through its own uplink.

```sh
./DualWanB.sh --example   # writes a commented DualWanB.conf (an old one goes to .bak)
$EDITOR DualWanB.conf     # uplinks, gateways, probes, distances
./DualWanB.sh             # writes out-dualwan-<ROUTER>/
```

Upload `dualwan-<ROUTER>.rsc` to the router and run `/import file=<name>.rsc`;
`remove-dualwan-<ROUTER>.rsc` undoes it.

Notes:

- `GATEWAY=dhcp` takes over the DHCP client on that uplink: it stops adding its
  own default route, and a lease script keeps the probe route on the current
  gateway;
- any other DHCP, PPPoE or LTE client on the WANs needs `add-default-route=no`,
  and the import warns about default routes it did not add;
- masquerade rules are created disabled.

How it works, in Russian: [dual-wan-failover.md](dual-wan-failover.md).

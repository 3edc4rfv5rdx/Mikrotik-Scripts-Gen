# Two uplinks and one WireGuard tunnel

**English** · [Русский](dual-wan-failover.ru.md)

The automation lives in WAN failover, not in the tunnel: WireGuard follows the
ordinary routing table and moves to the other uplink by itself when the
default route changes.

## Recipe

```
/ip/route add dst-address=8.8.4.4/32 gateway=<fibre-gw> scope=10
/ip/route add dst-address=1.0.0.1/32 gateway=<lte-gw>   scope=10
/ip/route add dst-address=0.0.0.0/0 gateway=8.8.4.4 target-scope=11 distance=1 check-gateway=ping
/ip/route add dst-address=0.0.0.0/0 gateway=1.0.0.1 target-scope=11 distance=2 check-gateway=ping
```

The probes must differ: with a single address the check goes over the route
that is already active, and the second uplink is never checked.

## What does the switching

RouterOS itself; no scripts or netwatch are needed. `check-gateway=ping` sends
ICMP to its route's gateway every 10 seconds with a 10-second timeout; after two
timeouts in a row the route turns inactive and the next one by distance takes
over. The check keeps running on the inactive route too: the first reply brings
it back, and traffic returns to the primary uplink on its own.

The default route's gateway is the probe, not the provider's router: pinging the
neighbouring provider router checks only that router, not the internet behind
it. Going through the probe checks the uplink's real connectivity.

Connections established through masquerade break on a switch, since the source
address changes. New ones go through the backup right away.

## Path of a packet

A packet from the LAN to 1.2.3.4, both uplinks up:

1. Both `0.0.0.0/0` routes in `main` match; the one with the lower distance
   (fibre) is active, and its gateway is `8.8.4.4`.
2. `8.8.4.4` is not a neighbour, so the router looks up a route to it and finds
   the `/32` via the provider's gateway: that is the real next hop.
3. The packet leaves through the fibre interface to the provider gateway's MAC.
   The destination stays 1.2.3.4: the packet does not go to 8.8.4.4, which only
   picks the next hop.
4. Masquerade on that interface, if enabled, rewrites the source address.

The `check-gateway` ping to 8.8.4.4 takes the same `/32`. Two misses in a row,
and the default via fibre goes down; the same packet then leaves via `1.0.0.1`,
that is through LTE.

## scope and target-scope

A route whose `scope` is greater than the searching route's `target-scope` is
not used to resolve a next hop. Defaults: connected 10, static 30, dynamic 40,
and `target-scope=10` (connected only). Hence the probe `/32` gets `scope=10`
and the default route `target-scope=11`; otherwise 8.8.4.4 does not resolve as a
gateway.

In plain words: by default the router looks for a gateway only among its
neighbours, the addresses in directly connected networks. 8.8.4.4 is not a
neighbour, so `gateway=8.8.4.4` alone is unreachable. `scope=10` on the `/32`
makes that route "almost a neighbour", and `target-scope=11` lets the default
route resolve its gateway through such routes. The result: the internet goes
via 8.8.4.4, 8.8.4.4 via fibre, and `check-gateway=ping` pings the real
internet.

## The tunnel

Nothing to set up: the side with two uplinks changes its source address, the
other side learns the new endpoint from the authenticated handshake (roaming),
and `persistent-keepalive=25s` keeps the switch to about half a minute.

## Conditions

- The side with two uplinks must be the one that dials; otherwise the other side
  has a static `endpoint-address` that is wrong after the move to LTE (DDNS
  fixes that).
- Masquerade is needed on both WAN interfaces.
- The backup works only with different `distance` values; equal ones give ECMP.

Sources: [IP Routing](https://help.mikrotik.com/docs/spaces/ROS/pages/328084/IP+Routing),
[Using scope and target-scope attributes](https://wiki.mikrotik.com/Manual:Using_scope_and_target-scope_attributes),
[forum thread on check-gateway](https://forum.mikrotik.com/t/check-gateway-more-than-each-10s/44969).

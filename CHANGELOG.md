# Changelog

## [Unreleased]

- WireGuard peers get a `name` of `peer-<other side>`.
- The generated `.rsc` removes itself by name pattern, so it also works when the file sits in `flash/`.
- Per-side routing: `A_ROUTE_TO_B` / `B_ROUTE_TO_A` list the networks routed into the tunnel.
- Firewall rules are emitted `disabled=yes`, and the input rule is placed before the defconf LAN drop found by its properties instead of `move`.
- Output files are named `sideA-<A_NAME>.rsc` / `sideB-<B_NAME>.rsc`.
- Renamed to `wg-gen.sh` / `wg-gen.conf`; RouterOS objects are tagged `wg-gen: <A>-<B>`.
- Output goes to `out-<A_NAME>-<B_NAME>` and the input config is copied next to it.
- Generated `.rsc` removes itself from the router after import, since it carries the private key.
- The firewall cleanup line is emitted only on a side that manages firewall rules.
- Generator `wg-gen.sh`: builds a pair of RouterOS `.rsc` files for a WireGuard site-to-site tunnel from one config file, with optional per-side firewall rules.

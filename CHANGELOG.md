# Changelog

## [Unreleased]

- The emitters take the side letters and read their settings through namerefs instead of 13 positional arguments.
- Keys are generated through openssl only; the `wg` branch is gone.
- Dropped the forward accept rules; `*_FIREWALL` now emits only the input rule for the listen port.
- Removed `A_CHECK_GATEWAY`/`B_CHECK_GATEWAY`: without a backup path to the same networks they only leak traffic to the default route.
- The sample config puts a blank line after every parameter.
- Each side tags its objects with its own name first: `wg-gen: <own>-<peer>`.
- Shared `PORT` for both sides, with `A_PORT`/`B_PORT` as per-side overrides; every sample parameter is commented.
- `--example` writes the sample to the config file, moving an existing one to `.bak`.
- Generated `out-*/` directories are git-ignored, since they hold private keys.
- Added `DualWanB.sh`: generates the dual-WAN failover `.rsc` (recursive probes, two defaults with `check-gateway=ping`, optional masquerade) plus its undo file.
- Probe addresses are 8.8.4.4 and 1.0.0.1, in the script and in the note.
- Separate `removeA-`/`removeB-` files undo an import: they drop every tagged object, whatever the side was generated with.
- Added `dual-wan-failover.md`: recursive-route failover between two uplinks under one tunnel.
- Routes use the peer's tunnel IP as gateway, with optional `check-gateway=ping` via `*_CHECK_GATEWAY`.
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

# Changelog

## [Unreleased]

- Renamed to `wg-gen.sh` / `wg-gen.conf`; RouterOS objects are tagged `wg-gen: <A>-<B>`.
- Output goes to `out-<A_NAME>-<B_NAME>` and the input config is copied next to it.
- Generated `.rsc` removes itself from the router after import, since it carries the private key.
- The firewall cleanup line is emitted only on a side that manages firewall rules.
- Generator `wg-gen.sh`: builds a pair of RouterOS `.rsc` files for a WireGuard site-to-site tunnel from one config file, with optional per-side firewall rules.

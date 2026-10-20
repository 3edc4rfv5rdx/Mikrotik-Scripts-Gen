# Mikrotik-Scripts-Gen

Bash generators that turn one small config file into RouterOS v7 `.rsc` files,
ready for `/import` on a MikroTik router.

| Folder | What it builds |
|---|---|
| [WireGuardGen](WireGuardGen/) | A WireGuard site-to-site tunnel: one file per side, with fresh keys |
| [DualWanGen](DualWanGen/) | Failover between two uplinks with recursive routes and `check-gateway=ping` |

Common to both:

- every object a file creates is tagged in its comment, and a re-import replaces
  only those objects;
- each generator also writes a `remove…` file that undoes the import;
- firewall and NAT rules are created disabled, to be reviewed and enabled by hand;
- a generated file deletes itself from the router once imported.

Requires bash 4.3+; `wg-gen.sh` also needs OpenSSL 1.1.1+ for the keys.

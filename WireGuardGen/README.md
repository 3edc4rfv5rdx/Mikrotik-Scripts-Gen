# WireGuardGen

`wg-gen.sh` builds a WireGuard site-to-site tunnel between two MikroTik
routers, A and B.

```sh
./wg-gen.sh --example     # writes a commented wg-gen.conf (an old one goes to .bak)
$EDITOR wg-gen.conf       # names, tunnel addresses, endpoints, routes
./wg-gen.sh               # writes out-<A>-<B>/
```

The output folder holds:

- `sideA-<A>-<B>.rsc` and `sideB-<B>-<A>.rsc`: interface, peer, tunnel address,
  routes and, if asked, a disabled input rule for the listen port;
- `removeA-…` / `removeB-…`: undo files;
- a copy of the config.

Upload each `side` file to its router and run `/import file=<name>.rsc`.

Notes:

- keys are generated anew on every run, so import both sides from the same run;
- the `.rsc` files carry private keys; `out-*/` is git-ignored;
- at least one side needs a public `ENDPOINT`, and the other side dials it.

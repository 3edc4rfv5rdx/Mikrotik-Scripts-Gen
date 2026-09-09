#!/usr/bin/env bash
# RouterOS .rsc pair for a WireGuard site-to-site tunnel.
set -euo pipefail

OUT_DIR=
DEFAULT_CONF=./wg-gen.conf
CONF=

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
    cat <<'EOF'
Usage: wg-gen.sh [-o OUTDIR] [CONFIG]
       wg-gen.sh --example > wg-gen.conf

CONFIG defaults to ./wg-gen.conf.

Generates OUTDIR/sideA-<A_NAME>.rsc and OUTDIR/sideB-<B_NAME>.rsc, ready for
/import on the matching MikroTik router.

Options:
  -o, --out DIR   output directory (default: ./out-<A_NAME>-<B_NAME>)
      --example   print a commented sample config and exit
  -h, --help      this help
EOF
}

print_example() {
    cat <<'EOF'
# Generator input, sourced by wg-gen.sh: shell quoting applies.

# Keepalive for the dialing side. Empty disables.
KEEPALIVE=25s

# Tunnel MTU. Empty keeps the RouterOS default (1420).
MTU=

# Empty private key means generate; fill in to keep an existing tunnel.
A_PRIVATE_KEY=
B_PRIVATE_KEY=

# Empty: no PSK. "auto": generate. Otherwise a key, format-checked.
PRESHARED_KEY=

# ---- side A ----
A_NAME=office
A_IFACE=wg-home
A_PORT=13231
# Tunnel address with prefix.
A_IPADDR=10.255.0.1/30
# Public address. Empty if behind NAT.
A_ENDPOINT=office.example.com
# Networks routed into the tunnel, comma-separated (quote if spaced). Empty for none.
A_ROUTE_TO_B=192.168.20.0/24
# Emit input/forward rules.
A_FIREWALL=no

# ---- side B ----
B_NAME=home
B_IFACE=wg-office
B_PORT=13231
B_IPADDR=10.255.0.2/30
# Public address. Empty if behind NAT.
B_ENDPOINT=my.home-prov.net
B_ROUTE_TO_A=192.168.10.0/24
B_FIREWALL=yes
EOF
}

# ---------- IPv4 helpers ----------

is_ipv4() {
    local IFS=. o
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    for o in $1; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

# "a.b.c.d/pp", both halves checked.
is_cidr() {
    local prefix=${1#*/}
    [[ $1 == */* ]] || return 1
    is_ipv4 "${1%/*}" || return 1
    [[ $prefix =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 0 && prefix <= 32 ))
}

# Network address as an integer.
cidr_net_int() {
    local IFS=. a b c d prefix=${1#*/} mask
    read -r a b c d <<<"${1%/*}"
    mask=$(( 0xFFFFFFFF ^ ((1 << (32 - prefix)) - 1) ))
    echo $(( ((a << 24) | (b << 16) | (c << 8) | d) & mask & 0xFFFFFFFF ))
}

validate_name() {
    [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
        || die "$1 must match [A-Za-z0-9][A-Za-z0-9_-]*, got '$2'"
}

is_yes() { [[ ${1,,} == y* || ${1,,} == true || $1 == 1 ]]; }

# ---------- key material ----------

# base64 of exactly 32 bytes
is_wgkey() { [[ $1 =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]; }

hex_to_bin() {
    local hex=$1 i
    for (( i = 0; i < ${#hex}; i += 2 )); do
        printf "\\x${hex:i:2}"
    done
}

wg_genkey() {
    if have wg; then
        wg genkey
    else
        openssl genpkey -algorithm X25519 \
            | openssl pkey -inform PEM -outform DER \
            | tail -c 32 | base64 | tr -d '\n'
    fi
}

wg_genpsk() {
    if have wg; then
        wg genpsk
    else
        openssl rand -base64 32 | tr -d '\n'
    fi
}

# PKCS#8 DER header for a raw 32-byte X25519 scalar.
X25519_PKCS8_HEADER=302e020100300506032b656e04220420

wg_pubkey() {
    local priv=$1 hex
    if have wg; then
        printf '%s' "$priv" | wg pubkey
    else
        hex=$(printf '%s' "$priv" | base64 -d | od -An -v -tx1 | tr -d ' \n')
        hex_to_bin "${X25519_PKCS8_HEADER}${hex}" \
            | openssl pkey -inform DER -pubout -outform DER \
            | tail -c 32 | base64 | tr -d '\n'
    fi
}

# ---------- arguments ----------

while (( $# )); do
    case $1 in
        -o|--out) [[ ${2-} ]] || die "--out needs a directory"; OUT_DIR=$2; shift 2 ;;
        --example) print_example; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)
            if [[ $CONF ]]; then die "only one config file expected"; fi
            CONF=$1; shift ;;
    esac
done

: "${CONF:=$DEFAULT_CONF}"
[[ -f $CONF ]] || die "no such config file: $CONF"

KEEPALIVE=25s MTU=
A_PRIVATE_KEY= B_PRIVATE_KEY= PRESHARED_KEY=
A_NAME= A_IFACE= A_PORT=13231 A_IPADDR= A_ENDPOINT= A_ROUTE_TO_B= A_FIREWALL=no
B_NAME= B_IFACE= B_PORT=13231 B_IPADDR= B_ENDPOINT= B_ROUTE_TO_A= B_FIREWALL=no
# shellcheck source=/dev/null
. "$CONF"

# ---------- validation ----------

for var in A_NAME B_NAME A_IPADDR B_IPADDR; do
    [[ ${!var} ]] || die "$var is not set in $CONF"
done

validate_name A_NAME "$A_NAME"
validate_name B_NAME "$B_NAME"
[[ $A_NAME != "$B_NAME" ]] || die "A_NAME and B_NAME must differ"

: "${A_IFACE:=wg-$B_NAME}"
: "${B_IFACE:=wg-$A_NAME}"
validate_name A_IFACE "$A_IFACE"
validate_name B_IFACE "$B_IFACE"

for var in A_IPADDR B_IPADDR; do
    is_cidr "${!var}" || die "$var must be an address with a prefix, got '${!var}'"
done
A_TUNNEL_IP=${A_IPADDR%/*}
B_TUNNEL_IP=${B_IPADDR%/*}
[[ $A_TUNNEL_IP != "$B_TUNNEL_IP" ]] || die "A_IPADDR and B_IPADDR must differ"
[[ ${A_IPADDR#*/} == "${B_IPADDR#*/}" && \
   $(cidr_net_int "$A_IPADDR") == "$(cidr_net_int "$B_IPADDR")" ]] \
    || die "A_IPADDR and B_IPADDR must sit in the same subnet"

for var in A_ROUTE_TO_B B_ROUTE_TO_A; do
    IFS=, read -ra nets <<<"${!var}"
    for net in "${nets[@]}"; do
        net=${net// /}
        [[ $net ]] || continue
        is_cidr "$net" || die "$var contains a bad network: $net"
    done
done

for var in A_PORT B_PORT; do
    [[ ${!var} =~ ^[0-9]+$ ]] && (( ${!var} >= 1 && ${!var} <= 65535 )) \
        || die "$var must be a UDP port, got '${!var}'"
done

[[ $A_ENDPOINT || $B_ENDPOINT ]] \
    || die "at least one of A_ENDPOINT / B_ENDPOINT must be set, otherwise neither side can dial"

# ---------- key material ----------

for var in A_PRIVATE_KEY B_PRIVATE_KEY; do
    if [[ ${!var} ]]; then
        is_wgkey "${!var}" || die "$var is not a base64-encoded 32-byte key"
    else
        printf -v "$var" '%s' "$(wg_genkey)"
    fi
done
case ${PRESHARED_KEY,,} in
    '') ;;  # no preshared key
    auto) PRESHARED_KEY=$(wg_genpsk) ;;
    *) is_wgkey "$PRESHARED_KEY" \
        || die "PRESHARED_KEY must be empty, 'auto', or a base64-encoded 32-byte key" ;;
esac

A_PUBLIC_KEY=$(wg_pubkey "$A_PRIVATE_KEY")
B_PUBLIC_KEY=$(wg_pubkey "$B_PRIVATE_KEY")
[[ $A_PUBLIC_KEY != "$B_PUBLIC_KEY" ]] || die "both sides ended up with the same key pair"

TAG="wg-gen: $A_NAME-$B_NAME"

# ---------- emitter ----------

# emit_side <name> <iface> <privkey> <port> <address> <firewall> \
#           <peer name> <peer pubkey> <peer ip> <peer endpoint> <peer port> \
#           <file> <routes>
emit_side() {
    local name=$1 iface=$2 priv=$3 port=$4 address=$5 firewall=$6
    local peer_name=$7 peer_pub=$8 peer_ip=$9 peer_endpoint=${10} peer_port=${11}
    local file=${12} net
    local -a routes
    IFS=, read -ra routes <<<"${13}"

    echo "# WireGuard site-to-site, $name side (peer: $peer_name)."
    echo "# wg-gen.sh, $(date '+%Y-%m-%d %H:%M:%S %z'). Re-import replaces only"
    printf '# objects tagged "%s".\n' "$TAG"
    echo
    printf ':log info "%s: importing %s configuration";\n' "$TAG" "$name"
    echo
    if is_yes "$firewall"; then
        printf '/ip/firewall/filter remove [find comment~"%s"]\n' "$TAG"
    fi
    if [[ ${13} ]]; then
        printf '/ip/route remove [find comment~"%s"]\n' "$TAG"
    fi
    printf '/ip/address remove [find comment~"%s"]\n' "$TAG"
    printf '/interface/wireguard/peers remove [find comment~"%s"]\n' "$TAG"
    printf '/interface/wireguard remove [find comment~"%s"]\n' "$TAG"
    echo

    echo "/interface/wireguard"
    printf 'add name="%s" listen-port=%s private-key="%s"%s \\\n' \
        "$iface" "$port" "$priv" "${MTU:+ mtu=$MTU}"
    printf '    comment="%s tunnel to %s"\n' "$TAG" "$peer_name"
    echo

    echo "/interface/wireguard/peers"
    printf 'add interface="%s" name="peer-%s" public-key="%s" \\\n' \
        "$iface" "$peer_name" "$peer_pub"
    if [[ $PRESHARED_KEY ]]; then
        printf '    preshared-key="%s" \\\n' "$PRESHARED_KEY"
    fi
    printf '    allowed-address=0.0.0.0/0'
    if [[ $peer_endpoint ]]; then
        printf ' \\\n    endpoint-address=%s endpoint-port=%s' "$peer_endpoint" "$peer_port"
        if [[ $KEEPALIVE ]]; then
            printf ' persistent-keepalive=%s' "$KEEPALIVE"
        fi
    fi
    printf ' \\\n    comment="%s peer %s"\n' "$TAG" "$peer_name"
    echo

    echo "/ip/address"
    printf 'add interface="%s" address=%s comment="%s tunnel address"\n' \
        "$iface" "$address" "$TAG"

    if [[ ${13} ]]; then
        echo
        echo "/ip/route"
        for net in "${routes[@]}"; do
            net=${net// /}
            [[ $net ]] || continue
            printf 'add dst-address=%s gateway="%s" comment="%s to %s"\n' \
                "$net" "$iface" "$TAG" "$peer_name"
        done
    fi

    if is_yes "$firewall"; then
        echo
        echo "# Forward rules come in disabled, at the end of the chain."
        echo "/ip/firewall/filter"
        printf 'add chain=forward action=accept in-interface="%s" disabled=yes \\\n' "$iface"
        printf '    comment="%s forward from %s"\n' "$TAG" "$peer_name"
        printf 'add chain=forward action=accept out-interface="%s" disabled=yes \\\n' "$iface"
        printf '    comment="%s forward to %s"\n' "$TAG" "$peer_name"
        echo
        echo "# The input rule goes in front of the defconf drop; if that rule is not"
        echo "# there, it lands at the end of the chain and has to be moved by hand."
        echo ':local anchor [/ip/firewall/filter find chain=input action=drop in-interface-list="!LAN"]'
        echo ':if ([:len $anchor] > 0) do={'
        printf '    /ip/firewall/filter add chain=input action=accept protocol=udp dst-port=%s disabled=yes \\\n' "$port"
        printf '        comment="%s accept wireguard" place-before=[:pick $anchor 0]\n' "$TAG"
        echo '} else={'
        printf '    /ip/firewall/filter add chain=input action=accept protocol=udp dst-port=%s disabled=yes \\\n' "$port"
        printf '        comment="%s accept wireguard"\n' "$TAG"
        echo '}'
    fi

    echo
    echo "# The file holds the private key, drop it once imported. Matched by"
    echo "# pattern: on a flash-backed router the name is flash/<file>."
    printf '/file remove [find name~"%s"]\n' "$file"
}

: "${OUT_DIR:=./out-$A_NAME-$B_NAME}"
mkdir -p "$OUT_DIR"
A_FILE="$OUT_DIR/sideA-$A_NAME.rsc"
B_FILE="$OUT_DIR/sideB-$B_NAME.rsc"

umask 077
emit_side "$A_NAME" "$A_IFACE" "$A_PRIVATE_KEY" "$A_PORT" "$A_IPADDR" "$A_FIREWALL" \
    "$B_NAME" "$B_PUBLIC_KEY" "$B_TUNNEL_IP" "$B_ENDPOINT" "$B_PORT" "${A_FILE##*/}" "$A_ROUTE_TO_B" > "$A_FILE"
emit_side "$B_NAME" "$B_IFACE" "$B_PRIVATE_KEY" "$B_PORT" "$B_IPADDR" "$B_FIREWALL" \
    "$A_NAME" "$A_PUBLIC_KEY" "$A_TUNNEL_IP" "$A_ENDPOINT" "$A_PORT" "${B_FILE##*/}" "$B_ROUTE_TO_A" > "$B_FILE"

# Keep the input next to what it produced.
if [[ $(readlink -f "$CONF") != $(readlink -f "$OUT_DIR/${CONF##*/}") ]]; then
    cp -- "$CONF" "$OUT_DIR/"
fi

cat >&2 <<EOF
A  $A_NAME  $A_IPADDR  pub $A_PUBLIC_KEY  -> $A_FILE
B  $B_NAME  $B_IPADDR  pub $B_PUBLIC_KEY  -> $B_FILE

Upload each file to its router and run: /import file=<name>.rsc
EOF

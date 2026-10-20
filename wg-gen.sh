#!/usr/bin/env bash
# RouterOS .rsc pair for a WireGuard site-to-site tunnel.
set -euo pipefail

OUT_DIR=
DEFAULT_CONF=./wg-gen.conf
CONF=
EXAMPLE=

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: wg-gen.sh [-o OUTDIR] [CONFIG]
       wg-gen.sh --example [CONFIG]

CONFIG defaults to ./wg-gen.conf.

Generates OUTDIR/sideA-<A_NAME>.rsc and OUTDIR/sideB-<B_NAME>.rsc, ready for
/import on the matching MikroTik router, plus removeA-/removeB- files that
undo the import.

Options:
  -o, --out DIR   output directory (default: ./out-<A_NAME>-<B_NAME>)
      --example   write a commented sample to CONFIG and exit; an existing
                  CONFIG is moved to CONFIG.bak
  -h, --help      this help
EOF
}

print_example() {
    cat <<'EOF'
# Generator input, sourced by wg-gen.sh: shell quoting applies.

# Keepalive for the dialing side. If empty = no keepalive.
KEEPALIVE=25s

# Tunnel MTU. If empty = RouterOS default (1420).
MTU=

# UDP port for both sides; A_PORT / B_PORT override it per side.
PORT=13231

# Generate a preshared key for the pair: yes or no.
PSK=no

# ---- side A ----
# Router name: goes into the tag, the file names and the peer name.
# Letters, digits, "_" and "-".
A_NAME=office

# WireGuard interface on this router. If empty = wg-$B_NAME.
A_IFACE=wg-home

# Listen port. If empty = $PORT.
A_PORT=

# Tunnel address with prefix, same subnet as B_IPADDR.
A_IPADDR=10.255.0.1/30

# Public address B dials. Leave empty if behind NAT.
A_ENDPOINT=office.example.com

# Networks behind B, comma-separated (quote if spaced); each becomes a route
# into the tunnel. If empty = no routes.
A_ROUTE_TO_B=192.168.20.0/24

# Emit an input accept rule for the listen port (always disabled).
A_FIREWALL=no

# ---- side B ----
# Router name: goes into the tag, the file names and the peer name.
# Letters, digits, "_" and "-".
B_NAME=home

# WireGuard interface on this router. If empty = wg-$A_NAME.
B_IFACE=wg-office

# Listen port. If empty = $PORT.
B_PORT=

# Tunnel address with prefix, same subnet as A_IPADDR.
B_IPADDR=10.255.0.2/30

# Public address A dials. Leave empty if behind NAT.
B_ENDPOINT=my.home-prov.net

# Networks behind A, comma-separated (quote if spaced); each becomes a route
# into the tunnel. If empty = no routes.
B_ROUTE_TO_A=192.168.10.0/24

# Emit an input accept rule for the listen port (always disabled).
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

hex_to_bin() {
    local hex=$1 i
    for (( i = 0; i < ${#hex}; i += 2 )); do
        printf "\\x${hex:i:2}"
    done
}

wg_genkey() {
    openssl genpkey -algorithm X25519 \
        | openssl pkey -inform PEM -outform DER \
        | tail -c 32 | base64 | tr -d '\n'
}

wg_genpsk() { openssl rand -base64 32 | tr -d '\n'; }

# PKCS#8 DER header for a raw 32-byte X25519 scalar.
X25519_PKCS8_HEADER=302e020100300506032b656e04220420

wg_pubkey() {
    local hex
    hex=$(printf '%s' "$1" | base64 -d | od -An -v -tx1 | tr -d ' \n')
    hex_to_bin "${X25519_PKCS8_HEADER}${hex}" \
        | openssl pkey -inform DER -pubout -outform DER \
        | tail -c 32 | base64 | tr -d '\n'
}

# ---------- arguments ----------

while (( $# )); do
    case $1 in
        -o|--out) [[ ${2-} ]] || die "--out needs a directory"; OUT_DIR=$2; shift 2 ;;
        --example) EXAMPLE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *)
            if [[ $CONF ]]; then die "only one config file expected"; fi
            CONF=$1; shift ;;
    esac
done

: "${CONF:=$DEFAULT_CONF}"

if [[ $EXAMPLE ]]; then
    if [[ -e $CONF ]]; then
        mv -- "$CONF" "$CONF.bak"
        printf 'moved %s to %s.bak\n' "$CONF" "$CONF" >&2
    fi
    print_example > "$CONF"
    printf 'sample written to %s\n' "$CONF" >&2
    exit 0
fi

[[ -f $CONF ]] || die "no such config file: $CONF"

KEEPALIVE=25s MTU= PORT=13231
PSK=no
A_NAME= A_IFACE= A_PORT= A_IPADDR= A_ENDPOINT= A_ROUTE_TO_B=
A_FIREWALL=no
B_NAME= B_IFACE= B_PORT= B_IPADDR= B_ENDPOINT= B_ROUTE_TO_A=
B_FIREWALL=no
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

: "${A_PORT:=$PORT}"
: "${B_PORT:=$PORT}"
for var in A_PORT B_PORT; do
    [[ ${!var} =~ ^[0-9]+$ ]] && (( ${!var} >= 1 && ${!var} <= 65535 )) \
        || die "$var must be a UDP port, got '${!var}'"
done

[[ $A_ENDPOINT || $B_ENDPOINT ]] \
    || die "at least one of A_ENDPOINT / B_ENDPOINT must be set, otherwise neither side can dial"

# ---------- key material ----------

A_PRIVATE_KEY=$(wg_genkey)
B_PRIVATE_KEY=$(wg_genkey)
PRESHARED_KEY=
if is_yes "$PSK"; then
    PRESHARED_KEY=$(wg_genpsk)
fi

A_PUBLIC_KEY=$(wg_pubkey "$A_PRIVATE_KEY")
B_PUBLIC_KEY=$(wg_pubkey "$B_PRIVATE_KEY")

# ---------- emitter ----------

# Each side tags its objects "wg-gen: <own name>-<peer name>".
tag_of() { printf 'wg-gen: %s-%s' "$1" "$2"; }

# emit_cleanup <tag>: drops everything carrying the tag; a remove on an empty
# find is a no-op.
emit_cleanup() {
    local tag=$1
    printf '/ip/firewall/filter remove [find comment~"%s"]\n' "$tag"
    printf '/ip/route remove [find comment~"%s"]\n' "$tag"
    printf '/ip/address remove [find comment~"%s"]\n' "$tag"
    printf '/interface/wireguard/peers remove [find comment~"%s"]\n' "$tag"
    printf '/interface/wireguard remove [find comment~"%s"]\n' "$tag"
}

# emit_self_remove <file>: the name is matched by pattern, since on a
# flash-backed router the file is called flash/<file>.
emit_self_remove() {
    printf '/file remove [find name~"%s"]\n' "$1"
}

# The emitters take the side letters, own first (A B or B A), and read that
# side's settings through namerefs.

# emit_remove <side> <peer side>
emit_remove() {
    local -n name=$1_NAME peer_name=$2_NAME undo=$1_UNDO
    local tag
    tag=$(tag_of "$name" "$peer_name")
    echo "# WireGuard site-to-site, $name side: undo of the $peer_name tunnel."
    echo "# wg-gen.sh, $(date '+%Y-%m-%d %H:%M:%S %z')."
    printf '# Removes every object tagged "%s" and nothing else.\n' "$tag"
    echo
    printf ':log info "%s: removing %s configuration";\n' "$tag" "$name"
    echo
    emit_cleanup "$tag"
    echo
    echo "# Drop this file once imported."
    emit_self_remove "${undo##*/}"
}

# emit_side <side> <peer side>
emit_side() {
    local -n name=$1_NAME iface=$1_IFACE priv=$1_PRIVATE_KEY port=$1_PORT
    local -n address=$1_IPADDR firewall=$1_FIREWALL file=$1_FILE
    local -n route_list=$1_ROUTE_TO_$2
    local -n peer_name=$2_NAME peer_pub=$2_PUBLIC_KEY peer_ip=$2_TUNNEL_IP
    local -n peer_endpoint=$2_ENDPOINT peer_port=$2_PORT
    local net tag
    tag=$(tag_of "$name" "$peer_name")
    local -a routes
    IFS=, read -ra routes <<<"$route_list"

    echo "# WireGuard site-to-site, $name side (peer: $peer_name)."
    echo "# wg-gen.sh, $(date '+%Y-%m-%d %H:%M:%S %z'). Re-import replaces only"
    printf '# objects tagged "%s".\n' "$tag"
    echo
    printf ':log info "%s: importing %s configuration";\n' "$tag" "$name"
    echo
    emit_cleanup "$tag"
    echo

    echo "/interface/wireguard"
    printf 'add name="%s" listen-port=%s private-key="%s"%s \\\n' \
        "$iface" "$port" "$priv" "${MTU:+ mtu=$MTU}"
    printf '    comment="%s tunnel to %s"\n' "$tag" "$peer_name"
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
    printf ' \\\n    comment="%s peer %s"\n' "$tag" "$peer_name"
    echo

    echo "/ip/address"
    printf 'add interface="%s" address=%s comment="%s tunnel address"\n' \
        "$iface" "$address" "$tag"

    if [[ $route_list ]]; then
        echo
        echo "/ip/route"
        for net in "${routes[@]}"; do
            net=${net// /}
            [[ $net ]] || continue
            printf 'add dst-address=%s gateway=%s comment="%s to %s"\n' \
                "$net" "$peer_ip" "$tag" "$peer_name"
        done
    fi

    if is_yes "$firewall"; then
        echo
        echo "# The input rule comes in disabled, in front of the defconf drop; if that"
        echo "# rule is not there, it lands at the end of the chain and has to be moved"
        echo "# by hand."
        echo ':local anchor [/ip/firewall/filter find chain=input action=drop in-interface-list="!LAN"]'
        echo ':if ([:len $anchor] > 0) do={'
        printf '    /ip/firewall/filter add chain=input action=accept protocol=udp dst-port=%s disabled=yes \\\n' "$port"
        printf '        comment="%s accept wireguard" place-before=[:pick $anchor 0]\n' "$tag"
        echo '} else={'
        printf '    /ip/firewall/filter add chain=input action=accept protocol=udp dst-port=%s disabled=yes \\\n' "$port"
        printf '        comment="%s accept wireguard"\n' "$tag"
        echo '}'
    fi

    echo
    echo "# The file holds the private key, drop it once imported."
    emit_self_remove "${file##*/}"
}

: "${OUT_DIR:=./out-$A_NAME-$B_NAME}"
mkdir -p "$OUT_DIR"
A_FILE="$OUT_DIR/sideA-$A_NAME.rsc"
B_FILE="$OUT_DIR/sideB-$B_NAME.rsc"
A_UNDO="$OUT_DIR/removeA-$A_NAME.rsc"
B_UNDO="$OUT_DIR/removeB-$B_NAME.rsc"

umask 077
emit_side A B > "$A_FILE"
emit_side B A > "$B_FILE"
emit_remove A B > "$A_UNDO"
emit_remove B A > "$B_UNDO"

# Keep the input next to what it produced.
if [[ $(readlink -f "$CONF") != $(readlink -f "$OUT_DIR/${CONF##*/}") ]]; then
    cp -- "$CONF" "$OUT_DIR/"
fi

cat >&2 <<EOF
A  $A_NAME  $A_IPADDR  pub $A_PUBLIC_KEY  -> $A_FILE
B  $B_NAME  $B_IPADDR  pub $B_PUBLIC_KEY  -> $B_FILE
undo                                        -> $A_UNDO, $B_UNDO

Upload each file to its router and run: /import file=<name>.rsc
EOF

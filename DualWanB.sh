#!/usr/bin/env bash
# RouterOS .rsc for dual-WAN failover: recursive routes with check-gateway=ping.
set -euo pipefail

OUT_DIR=
DEFAULT_CONF=./DualWanB.conf
CONF=
EXAMPLE=

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: DualWanB.sh [-o OUTDIR] [CONFIG]
       DualWanB.sh --example [CONFIG]

CONFIG defaults to ./DualWanB.conf.

Generates OUTDIR/dualwan-<ROUTER>.rsc for /import on the router with two
uplinks, plus a remove- file that undoes it.

Options:
  -o, --out DIR   output directory (default: ./out-dualwan-<ROUTER>)
      --example   write a commented sample to CONFIG and exit; an existing
                  CONFIG is moved to CONFIG.bak
  -h, --help      this help
EOF
}

print_example() {
    cat <<'EOF'
# Generator input, sourced by DualWanB.sh: shell quoting applies.

# Router this belongs to; only names the tag and the files.
# DHCP, PPPoE and LTE clients on both WANs need add-default-route=no, or their
# own default route breaks the failover.
ROUTER=home

# ---- WAN 1, primary ----
WAN1_NAME=fiber
# Next hop. Ethernet/fibre: the provider's gateway IP. Point-to-point links
# (LTE, PPPoE, L2TP): the interface name. Pin one to the other as IP%iface.
WAN1_GATEWAY=192.0.2.1
# Probe address pinned to this uplink. Must differ from the other one.
WAN1_PROBE=8.8.4.4
WAN1_DISTANCE=1
# Interface for masquerade. Empty skips NAT for this uplink.
WAN1_IFACE=ether1

# ---- WAN 2, backup ----
WAN2_NAME=lte
WAN2_GATEWAY=lte1
WAN2_PROBE=1.0.0.1
WAN2_DISTANCE=2
WAN2_IFACE=lte1

# Emit masquerade rules; they come in disabled.
MASQUERADE=yes
EOF
}

is_ipv4() {
    local IFS=. o
    [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    for o in $1; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

validate_name() {
    [[ $2 =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
        || die "$1 must match [A-Za-z0-9][A-Za-z0-9_-]*, got '$2'"
}

is_yes() { [[ ${1,,} == y* || ${1,,} == true || $1 == 1 ]]; }

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

ROUTER= MASQUERADE=no
WAN1_NAME= WAN1_GATEWAY= WAN1_PROBE= WAN1_DISTANCE=1 WAN1_IFACE=
WAN2_NAME= WAN2_GATEWAY= WAN2_PROBE= WAN2_DISTANCE=2 WAN2_IFACE=
# shellcheck source=/dev/null
. "$CONF"

for var in ROUTER WAN1_NAME WAN2_NAME WAN1_GATEWAY WAN2_GATEWAY WAN1_PROBE WAN2_PROBE; do
    [[ ${!var} ]] || die "$var is not set in $CONF"
done

validate_name ROUTER "$ROUTER"
validate_name WAN1_NAME "$WAN1_NAME"
validate_name WAN2_NAME "$WAN2_NAME"
[[ $WAN1_NAME != "$WAN2_NAME" ]] || die "WAN1_NAME and WAN2_NAME must differ"

for var in WAN1_PROBE WAN2_PROBE; do
    is_ipv4 "${!var}" || die "$var must be an IPv4 address, got '${!var}'"
done
[[ $WAN1_PROBE != "$WAN2_PROBE" ]] \
    || die "the probes must differ, otherwise only the active uplink is ever checked"

for var in WAN1_DISTANCE WAN2_DISTANCE; do
    [[ ${!var} =~ ^[0-9]+$ ]] && (( ${!var} >= 1 && ${!var} <= 255 )) \
        || die "$var must be 1..255, got '${!var}'"
done
(( 10#$WAN1_DISTANCE < 10#$WAN2_DISTANCE )) \
    || die "WAN1_DISTANCE must be below WAN2_DISTANCE: equal ones load-balance, a higher one makes WAN1 the backup"

# IP, interface, or IP%interface; a typo would only surface at /import.
for var in WAN1_GATEWAY WAN2_GATEWAY; do
    gw=${!var}
    if [[ $gw == *%* ]]; then
        is_ipv4 "${gw%%%*}" && [[ ${gw#*%} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
            || die "$var must be IP%interface, got '$gw'"
    elif [[ $gw =~ ^[0-9.]+$ ]]; then
        is_ipv4 "$gw" || die "$var is not a valid IPv4 address: '$gw'"
    else
        [[ $gw =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
            || die "$var must be an IP, an interface or IP%interface, got '$gw'"
    fi
done

TAG="dualwan: $ROUTER"

# emit_cleanup: drops everything carrying the tag. Every comment is
# "<tag> <what>", so the match is anchored on both ends of the tag: "home"
# must not catch "home2".
emit_cleanup() {
    printf '/ip/firewall/nat remove [find comment~"^%s "]\n' "$TAG"
    printf '/ip/route remove [find comment~"^%s "]\n' "$TAG"
}

# emit_self_remove <file>: the name is matched by pattern, since on a
# flash-backed router the file is called flash/<file>.
emit_self_remove() {
    printf '/file remove [find name~"%s"]\n' "$1"
}

emit_config() {
    local file=$1

    echo "# Dual-WAN failover on $ROUTER: $WAN1_NAME primary, $WAN2_NAME backup."
    echo "# DualWanB.sh, $(date '+%Y-%m-%d %H:%M:%S %z'). Re-import replaces only"
    printf '# objects tagged "%s".\n' "$TAG"
    echo "# Any other default route is left alone, but it breaks the failover: one"
    echo "# with the same distance turns it into ECMP, one with a lower distance wins"
    echo "# outright. A DHCP, PPPoE or LTE client on a WAN adds one unless it has"
    echo "# add-default-route=no; the end of this file warns if one is found."
    echo
    printf ':log info "%s: importing";\n' "$TAG"
    echo
    emit_cleanup
    echo

    echo "/ip/route"
    echo "# Probes, each pinned to its own uplink."
    printf 'add dst-address=%s/32 gateway=%s scope=10 comment="%s probe via %s"\n' \
        "$WAN1_PROBE" "$WAN1_GATEWAY" "$TAG" "$WAN1_NAME"
    printf 'add dst-address=%s/32 gateway=%s scope=10 comment="%s probe via %s"\n' \
        "$WAN2_PROBE" "$WAN2_GATEWAY" "$TAG" "$WAN2_NAME"
    echo "# Defaults, resolved recursively through the probes above."
    printf 'add dst-address=0.0.0.0/0 gateway=%s target-scope=11 distance=%s \\\n' \
        "$WAN1_PROBE" "$WAN1_DISTANCE"
    printf '    check-gateway=ping comment="%s via %s"\n' "$TAG" "$WAN1_NAME"
    printf 'add dst-address=0.0.0.0/0 gateway=%s target-scope=11 distance=%s \\\n' \
        "$WAN2_PROBE" "$WAN2_DISTANCE"
    printf '    check-gateway=ping comment="%s via %s"\n' "$TAG" "$WAN2_NAME"

    if is_yes "$MASQUERADE" && [[ $WAN1_IFACE || $WAN2_IFACE ]]; then
        echo
        echo "# Masquerade comes in disabled, at the end of the chain."
        echo "/ip/firewall/nat"
        local name iface
        for name in "$WAN1_NAME:$WAN1_IFACE" "$WAN2_NAME:$WAN2_IFACE"; do
            iface=${name#*:}
            [[ $iface ]] || continue
            printf 'add chain=srcnat action=masquerade out-interface="%s" disabled=yes \\\n' "$iface"
            printf '    comment="%s nat %s"\n' "$TAG" "${name%%:*}"
        done
    fi

    echo
    echo "# Warn about default routes this file did not add."
    printf ':local foreign [/ip/route find where dst-address=0.0.0.0/0 and !(comment~"^%s ")]\n' "$TAG"
    echo ':if ([:len $foreign] > 0) do={'
    printf '    :log warning "%s: other default routes present, failover will not work"\n' "$TAG"
    printf '    :put "%s: other default routes present, failover will not work"\n' "$TAG"
    echo '}'

    echo
    echo "# Drop this file once imported."
    emit_self_remove "$file"
}

emit_remove() {
    local file=$1

    echo "# Dual-WAN failover on $ROUTER: undo."
    echo "# DualWanB.sh, $(date '+%Y-%m-%d %H:%M:%S %z')."
    printf '# Removes every object tagged "%s" and nothing else.\n' "$TAG"
    echo
    printf ':log info "%s: removing";\n' "$TAG"
    echo
    emit_cleanup
    echo
    echo "# Drop this file once imported."
    emit_self_remove "$file"
}

: "${OUT_DIR:=./out-dualwan-$ROUTER}"
mkdir -p "$OUT_DIR"
FILE="$OUT_DIR/dualwan-$ROUTER.rsc"
UNDO="$OUT_DIR/remove-dualwan-$ROUTER.rsc"

umask 077
emit_config "${FILE##*/}" > "$FILE"
emit_remove "${UNDO##*/}" > "$UNDO"

# Keep the input next to what it produced.
if [[ $(readlink -f "$CONF") != $(readlink -f "$OUT_DIR/${CONF##*/}") ]]; then
    cp -- "$CONF" "$OUT_DIR/"
fi

cat >&2 <<EOF
$WAN1_NAME  distance $WAN1_DISTANCE  probe $WAN1_PROBE  via $WAN1_GATEWAY
$WAN2_NAME  distance $WAN2_DISTANCE  probe $WAN2_PROBE  via $WAN2_GATEWAY

$FILE
$UNDO

Upload to the router and run: /import file=<name>.rsc
EOF

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
ROUTER=home

# Emit masquerade rules for both uplinks: yes or no (always disabled).
MASQUERADE=yes

# DHCP, PPPoE and LTE clients on both WANs need add-default-route=no, or their
# own default route breaks the failover. With GATEWAY=dhcp the generated file
# sets it itself; any other client needs it by hand.

##############################
# WAN 1, primary
##############################

# Uplink name: goes into the comments of its routes and NAT rule.
WAN1_NAME=fiber

# Next hop. Ethernet/fibre: the provider's gateway IP. Point-to-point links
# (LTE, PPPoE, L2TP): the interface name. Pin one to the other as IP%iface.
# "dhcp": follow the gateway the DHCP client on WAN1_IFACE gets; its script
# keeps the probe route up to date.
WAN1_GATEWAY=192.0.2.1

# Probe address pinned to this uplink, must differ from WAN2_PROBE. All
# traffic to it goes only through this uplink, so do not use it as a DNS server.
WAN1_PROBE=8.8.4.4

# Route distance, must be below WAN2_DISTANCE.
WAN1_DISTANCE=1

# Uplink interface: masquerade goes out of it, and with GATEWAY=dhcp its DHCP
# client is the one taken over. If empty = no NAT for this uplink; not allowed
# with dhcp.
WAN1_IFACE=ether1

##############################
# WAN 2, backup
##############################

# Uplink name: goes into the comments of its routes and NAT rule.
WAN2_NAME=lte

# Next hop. Ethernet/fibre: the provider's gateway IP. Point-to-point links
# (LTE, PPPoE, L2TP): the interface name. Pin one to the other as IP%iface.
# "dhcp": follow the gateway the DHCP client on WAN2_IFACE gets; its script
# keeps the probe route up to date.
WAN2_GATEWAY=lte1

# Probe address pinned to this uplink, must differ from WAN1_PROBE. All
# traffic to it goes only through this uplink, so do not use it as a DNS server.
WAN2_PROBE=1.0.0.1

# Route distance, must be above WAN1_DISTANCE.
WAN2_DISTANCE=2

# Uplink interface: masquerade goes out of it, and with GATEWAY=dhcp its DHCP
# client is the one taken over. If empty = no NAT for this uplink; not allowed
# with dhcp.
WAN2_IFACE=lte1
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

[[ -z $WAN1_IFACE || $WAN1_IFACE != "$WAN2_IFACE" ]] \
    || die "WAN1_IFACE and WAN2_IFACE must differ, got '$WAN1_IFACE' for both"

# IP, interface, IP%interface or dhcp; a typo would only surface at /import.
for n in 1 2; do
    var=WAN${n}_GATEWAY iface_var=WAN${n}_IFACE
    gw=${!var}
    if [[ $gw == dhcp ]]; then
        [[ ${!iface_var} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
            || die "$var=dhcp needs $iface_var, the interface its DHCP client runs on"
    elif [[ $gw == *%* ]]; then
        is_ipv4 "${gw%%%*}" && [[ ${gw#*%} =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
            || die "$var must be IP%interface, got '$gw'"
    elif [[ $gw =~ ^[0-9.]+$ ]]; then
        is_ipv4 "$gw" || die "$var is not a valid IPv4 address: '$gw'"
    else
        [[ $gw =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
            || die "$var must be an IP, an interface, IP%interface or dhcp, got '$gw'"
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

is_dhcp() { local -n gw=WAN$1_GATEWAY; [[ $gw == dhcp ]]; }

# The script a taken-over DHCP client runs on every lease: it points the probe
# route at the gateway just handed out, and puts the route back with scope=10
# if someone removed it. Escaped for a RouterOS string.
dhcp_script() {
    local -n name=WAN$1_NAME probe=WAN$1_PROBE
    local comment="$TAG probe via $name" raw bs='\' q='"' d='$'
    printf -v raw ':if ($bound=1) do={:local r [/ip/route find comment="%s"]; :if ([:len $r]=0) do={/ip/route add dst-address=%s/32 gateway=$"gateway-address" scope=10 comment="%s"} else={/ip/route set $r gateway=$"gateway-address"}}' \
        "$comment" "$probe" "$comment"
    raw=${raw//"$bs"/"$bs$bs"}
    raw=${raw//"$q"/"$bs$q"}
    raw=${raw//"$d"/"$bs$d"}
    printf '%s' "$raw"
}

# Locals are kept inside { } blocks: whether /import carries a top-level
# :local over to the next line is not something to rely on.

# emit_dhcp_check <n>: aborts the import before anything is touched when the
# DHCP client is missing or already runs a script of its own.
emit_dhcp_check() {
    local -n iface=WAN$1_IFACE
    echo '{'
    printf '    :local dc [/ip/dhcp-client find interface="%s"]\n' "$iface"
    printf '    :if ([:len $dc] != 1) do={ :error "%s: expected one DHCP client on %s" }\n' \
        "$TAG" "$iface"
    echo '    :local old [/ip/dhcp-client get $dc script]'
    printf '    :if ($old != "" && !($old ~ "%s ")) do={ :error "%s: the DHCP client on %s already has a script, merge it by hand" }\n' \
        "$TAG" "$TAG" "$iface"
    echo '}'
}

# emit_probe <n>: the /32 that pins the probe to its uplink. With dhcp the
# gateway comes from the current lease; until there is one the interface
# stands in, and the client script fixes it on bound.
emit_probe() {
    local -n name=WAN$1_NAME gw=WAN$1_GATEWAY probe=WAN$1_PROBE iface=WAN$1_IFACE
    if is_dhcp "$1"; then
        echo '{'
        printf '    :local gw [:tostr [/ip/dhcp-client get [find interface="%s"] gateway]]\n' "$iface"
        printf '    :if ([:len $gw] = 0) do={ :set gw "%s" }\n' "$iface"
        printf '    /ip/route add dst-address=%s/32 gateway=$gw scope=10 comment="%s probe via %s"\n' \
            "$probe" "$TAG" "$name"
        echo '}'
    else
        printf '/ip/route add dst-address=%s/32 gateway=%s scope=10 comment="%s probe via %s"\n' \
            "$probe" "$gw" "$TAG" "$name"
    fi
}

emit_config() {
    local file=$1 n iface_var

    echo "# Dual-WAN failover on $ROUTER: $WAN1_NAME primary, $WAN2_NAME backup."
    echo "# DualWanB.sh, $(date '+%Y-%m-%d %H:%M:%S %z'). Re-import replaces only"
    printf '# objects tagged "%s"; for the few seconds it takes the router has no\n' "$TAG"
    echo "# default route, so run it from a console that survives that."
    echo "# Any other default route is left alone, but it breaks the failover: one"
    echo "# with the same distance turns it into ECMP, one with a lower distance wins"
    echo "# outright. A DHCP, PPPoE or LTE client on a WAN adds one unless it has"
    echo "# add-default-route=no; the end of this file warns if one is found."
    echo
    printf ':log info "%s: importing";\n' "$TAG"
    echo
    if is_dhcp 1 || is_dhcp 2; then
        echo "# DHCP clients taken over below."
        for n in 1 2; do
            is_dhcp "$n" && emit_dhcp_check "$n"
        done
        echo
    fi
    emit_cleanup
    echo

    echo "# Probes, each pinned to its own uplink."
    for n in 1 2; do
        emit_probe "$n"
    done
    echo
    echo "/ip/route"
    echo "# Defaults, resolved recursively through the probes above."
    printf 'add dst-address=0.0.0.0/0 gateway=%s target-scope=11 distance=%s \\\n' \
        "$WAN1_PROBE" "$WAN1_DISTANCE"
    printf '    check-gateway=ping comment="%s via %s"\n' "$TAG" "$WAN1_NAME"
    printf 'add dst-address=0.0.0.0/0 gateway=%s target-scope=11 distance=%s \\\n' \
        "$WAN2_PROBE" "$WAN2_DISTANCE"
    printf '    check-gateway=ping comment="%s via %s"\n' "$TAG" "$WAN2_NAME"

    for n in 1 2; do
        is_dhcp "$n" || continue
        echo
        echo "# The client stops adding its own default route and keeps the probe"
        echo "# route on the current gateway."
        iface_var=WAN${n}_IFACE
        printf '/ip/dhcp-client set [find interface="%s"] add-default-route=no script="%s"\n' \
            "${!iface_var}" "$(dhcp_script "$n")"
    done

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
    echo "# Warn about enabled default routes in main this file did not add; other"
    echo "# tables belong to policy routing and do not compete."
    if is_dhcp 1 || is_dhcp 2; then
        echo "# A client just switched to add-default-route=no may take a moment to"
        echo "# drop its dynamic route; without the pause it would be reported."
        echo ':delay 2s'
    fi
    echo '{'
    printf '    :local foreign [/ip/route find where dst-address=0.0.0.0/0 and routing-table=main and disabled=no and !(comment~"^%s ")]\n' "$TAG"
    echo '    :if ([:len $foreign] > 0) do={'
    printf '        :log warning "%s: other default routes present, failover will not work"\n' "$TAG"
    printf '        :put "%s: other default routes present, failover will not work"\n' "$TAG"
    echo '    }'
    echo '}'

    echo
    echo "# Drop this file once imported."
    emit_self_remove "$file"
}

emit_remove() {
    local file=$1

    echo "# Dual-WAN failover on $ROUTER: undo."
    echo "# DualWanB.sh, $(date '+%Y-%m-%d %H:%M:%S %z')."
    printf '# Removes every object tagged "%s", gives any DHCP client it took over\n' "$TAG"
    echo "# its default route back, and touches nothing else."
    echo
    printf ':log info "%s: removing";\n' "$TAG"
    echo
    echo "# Give the DHCP clients their default route back before ours go. Found by"
    echo "# the tag in their script, so a client taken over by an earlier config is"
    echo "# handed back too."
    printf '/ip/dhcp-client set [find script~"%s "] script="" add-default-route=yes\n' "$TAG"
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

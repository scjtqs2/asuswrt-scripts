#!/bin/sh
# Made by Jack'lul <jacklul.github.io>
#
# Runs Tailscale service
#
# Note that automatic download of Tailscale binaries stores them in /tmp directory - make sure you have enough free RAM!
# You will want to start this manually first to login.
#

#shellcheck disable=SC2155

readonly SCRIPT_PATH="$(readlink -f "$0")"
readonly SCRIPT_NAME="$(basename "$SCRIPT_PATH" .sh)"
readonly SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
readonly SCRIPT_CONFIG="$SCRIPT_DIR/$SCRIPT_NAME.conf"

STATE_FILE="/jffs/tailscaled.state" # where to store state file, preferably persistent between reboots
INTERFACE="tailscale0" # interface to use, if you change TAILSCALED_ARGUMENTS make sure correct interface is being used
TAILSCALED_ARGUMENTS="-no-logs-no-support -tun $INTERFACE" # 'tailscaled' arguments
TAILSCALE_ARGUMENTS="--accept-dns=false --advertise-exit-node" # 'tailscale up' arguments, refer to https://tailscale.com/kb/1080/cli/#command-reference
TAILSCALED_PATH="" # path to tailscaled binary, fill TAILSCALE_DOWNLOAD_URL to automatically download 下载到指定位置，这里配置上
TAILSCALE_PATH="" # path to tailscale binary, fill TAILSCALE_DOWNLOAD_URL to automatically download 下载到指定位置，这里配置上
TAILSCALE_DOWNLOAD_URL="" # Tailscale tgz download URL, "https://pkgs.tailscale.com/stable/tailscale_latest_arm.tgz" should work

# This means that this is a Merlin firmware
if [ -f "/usr/sbin/helper.sh" ]; then
    #shellcheck disable=SC1091
    . /usr/sbin/helper.sh

    TAILSCALED_ARGUMENTS_=$(am_settings_get jl_tailscale_td_args)
    TAILSCALE_ARGUMENTS_=$(am_settings_get jl_tailscale_t_args)
    TAILSCALED_PATH_=$(am_settings_get jl_tailscale_td_path)
    TAILSCALE_PATH_=$(am_settings_get jl_tailscale_t_path)

    [ -n "$TAILSCALED_ARGUMENTS_" ] && TAILSCALED_ARGUMENTS=$TAILSCALED_ARGUMENTS_
    [ -n "$TAILSCALE_ARGUMENTS_" ] && TAILSCALE_ARGUMENTS=$TAILSCALE_ARGUMENTS_
    [ -n "$TAILSCALED_PATH_" ] && TAILSCALED_PATH=$TAILSCALED_PATH_
    [ -n "$TAILSCALE_PATH_" ] && TAILSCALE_PATH=$TAILSCALE_PATH_
fi

if [ -f "$SCRIPT_CONFIG" ]; then
    #shellcheck disable=SC1090
    . "$SCRIPT_CONFIG"
fi

CHAIN="TAILSCALE"
FOR_IPTABLES="iptables"

[ "$(nvram get ipv6_service)" != "disabled" ] && FOR_IPTABLES="$FOR_IPTABLES ip6tables"

download_tailscale() {
    if [ -n "$TAILSCALE_DOWNLOAD_URL" ]; then
        logger -s -t "$SCRIPT_NAME" "Downloading Tailscale binaries from '$TAILSCALE_DOWNLOAD_URL'..."

        set -e
        mkdir -p /tmp/download
        cd /tmp/download
        curl -fsSL "$TAILSCALE_DOWNLOAD_URL" -o "tailscale.tgz"
        tar zxf "tailscale.tgz"
        mv ./*/tailscaled /tmp/tailscaled
        mv ./*/tailscale /tmp/tailscale
        rm -fr /tmp/download/*
        chmod +x /tmp/tailscaled /tmp/tailscale
        set +e

        TAILSCALED_PATH="/tmp/tailscaled"
        TAILSCALE_PATH="/tmp/tailscale"
    fi
}

firewall_rules() {
    [ -z "$INTERFACE" ] && { logger -s -t "$SCRIPT_NAME" "Tailscale interface is not set"; exit 1; }

    for _IPTABLES in $FOR_IPTABLES; do
        case "$1" in
            "add")
                if ! $_IPTABLES -n -L "$CHAIN" >/dev/null 2>&1; then
                    _INPUT_END="$($_IPTABLES -L INPUT --line-numbers | sed '/^num\|^$\|^Chain/d' | wc -l)"

                    $_IPTABLES -N "$CHAIN"
                    $_IPTABLES -I INPUT "$_INPUT_END" -i "$INTERFACE" -j "$CHAIN"
                    $_IPTABLES -A $CHAIN -j "ACCEPT"
                fi
            ;;
            "remove")
                if $_IPTABLES -n -L "$CHAIN" >/dev/null 2>&1; then
                    $_IPTABLES -D INPUT -i "$INTERFACE" -j "$CHAIN"
                    $_IPTABLES -F "$CHAIN"
                    $_IPTABLES -X "$CHAIN"
                fi
            ;;
        esac
    done

    [ "$1" = "add" ] && logger -s -t "$SCRIPT_NAME" "Added firewall rules for Tailscale interface ($INTERFACE)"
}

#shellcheck disable=SC2009
TAILSCALED_PID="$(ps w | grep "tailscaled" | grep -v grep | awk '{print $1}' | tr '\n' ' ' | awk '{$1=$1};1')"

case "$1" in
    "run")
        [ ! -f "$TAILSCALED_PATH" ] && [ -f "/tmp/tailscaled" ] && TAILSCALED_PATH="/tmp/tailscaled"
        [ ! -f "$TAILSCALE_PATH" ] && [ -f "/tmp/tailscale" ] && TAILSCALE_PATH="/tmp/tailscale"

        if [ ! -f "$TAILSCALED_PATH" ] || [ ! -f "$TAILSCALE_PATH" ]; then
            download_tailscale

            [ ! -f "$TAILSCALED_PATH" ] && { logger -s -t "$SCRIPT_NAME" "Could not find tailscaled binary: $TAILSCALED_PATH"; exit 1; }
            [ ! -f "$TAILSCALE_PATH" ] && { logger -s -t "$SCRIPT_NAME" "Could not find tailscale binary: $TAILSCALE_PATH"; exit 1; }
        fi

        if [ -z "$TAILSCALED_PID" ]; then
            logger -s -t "$SCRIPT_NAME" "Starting Tailscale daemon..."

            ! lsmod | grep -q tun && modprobe tun && sleep 1

            #shellcheck disable=SC2086
            $TAILSCALED_PATH --state="$STATE_FILE" $TAILSCALED_ARGUMENTS >/dev/null 2>&1 &
            sleep 5
        fi

        #shellcheck disable=SC2086
        $TAILSCALE_PATH up $TAILSCALE_ARGUMENTS

        sh "$SCRIPT_PATH" firewall
    ;;
    "init-run")
        if [ -z "$TAILSCALED_PID" ]; then
            nohup "$SCRIPT_PATH" run >/dev/null 2>&1 &
        else
            sh "$SCRIPT_PATH" firewall
        fi
    ;;
    "firewall")
        if [ -n "$TAILSCALED_PID" ]; then
            firewall_rules add
        else
            firewall_rules remove
        fi
    ;;
    "start")
        cru a "$SCRIPT_NAME" "*/1 * * * * $SCRIPT_PATH init-run"
    ;;
    "stop")
        cru d "$SCRIPT_NAME"

        firewall_rules remove

        [ -n "$TAILSCALED_PID" ] && kill "$TAILSCALED_PID"
    ;;
    "restart")
        sh "$SCRIPT_PATH" stop
        sh "$SCRIPT_PATH" start
    ;;
    *)
        echo "Usage: $0 run|start|stop|restart|firewall"
        exit 1
    ;;
esac

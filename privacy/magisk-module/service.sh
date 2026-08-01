#!/system/bin/sh
# BOOX Privacy Firewall. Magisk executes this script after Android services start.

MODDIR=${0%/*}
LOG=/data/local/tmp/boox-privacy-firewall.log
CHAIN=BOOX_PRIVACY
WAN_UIDS_V4=''
WAN_UIDS_V6=''

log() {
    printf '%s %s\n' "$(date -Iseconds 2>/dev/null || date)" "$*" >> "$LOG"
}

uid_for() {
    dumpsys package "$1" 2>/dev/null |
        sed -n -e 's/^[[:space:]]*userId=//p' -e 's/^[[:space:]]*appId=//p' |
        head -1 | cut -d' ' -f1
}

reset_chain() {
    tool=$1
    while "$tool" -w 5 -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
    "$tool" -w 5 -F "$CHAIN" 2>/dev/null || true
    "$tool" -w 5 -X "$CHAIN" 2>/dev/null || true
}

prepare_chain() {
    tool=$1
    "$tool" -w 5 -N "$CHAIN" 2>/dev/null || true
    "$tool" -w 5 -F "$CHAIN"
    "$tool" -w 5 -C OUTPUT -j "$CHAIN" 2>/dev/null || "$tool" -w 5 -I OUTPUT 1 -j "$CHAIN"
}

deny_package() {
    tool=$1
    package=$2
    uid=$(uid_for "$package")
    if [ -z "$uid" ]; then return; fi
    # Never firewall Android shared/system UIDs. BOOX core services use UID 1000.
    if [ "$uid" -lt 10000 ]; then
        log "refused unsafe UID rule: $package uid=$uid"
        return
    fi
    "$tool" -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -j REJECT
    log "denied network: $package uid=$uid via $tool"
}

# Lockdown deliberately includes Android's shared UID 1000 because the BOOX
# launcher and cloud-sync service run under it. Local/LAN destinations remain
# reachable; every other destination is rejected in the kernel.
deny_wan_uid() {
    tool=$1
    uid=$2
    case "$uid" in ''|*[!0-9]*) return ;; esac
    if [ "$tool" = iptables ]; then
        case " $WAN_UIDS_V4 " in *" $uid "*) return ;; esac
        WAN_UIDS_V4="$WAN_UIDS_V4 $uid"
        for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 224.0.0.0/4 255.255.255.255/32
        do
            iptables -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -d "$cidr" -j RETURN
        done
        iptables -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -j REJECT
    else
        case " $WAN_UIDS_V6 " in *" $uid "*) return ;; esac
        WAN_UIDS_V6="$WAN_UIDS_V6 $uid"
        for cidr in ::1/128 fe80::/10 fc00::/7 ff00::/8
        do
            ip6tables -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -d "$cidr" -j RETURN
        done
        ip6tables -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -j REJECT
    fi
    log "vendor WAN denied: uid=$uid via $tool"
}

deny_wan_package() {
    tool=$1
    package=$2
    uid=$(uid_for "$package")
    [ -n "$uid" ] && deny_wan_uid "$tool" "$uid"
}

apply_lockdown_uid_file() {
    tool=$1
    [ -f "$MODDIR/lockdown-uids.conf" ] || return
    while read -r uid
    do
        deny_wan_uid "$tool" "$uid"
    done < "$MODDIR/lockdown-uids.conf"
}

discover_lockdown_packages() {
    tool=$1
    for package in $(pm list packages 2>/dev/null | sed -n 's/^package:\(com\.onyx\([.][A-Za-z0-9_.]*\)\{0,1\}\)$/\1/p')
    do
        deny_wan_package "$tool" "$package"
    done
}

lan_only_v4() {
    package=$1
    uid=$(uid_for "$package")
    if [ -z "$uid" ] || [ "$uid" -lt 10000 ]; then return; fi
    for cidr in 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16
    do
        iptables -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -d "$cidr" -j RETURN
    done
    iptables -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -j REJECT
    log "LAN-only IPv4: $package uid=$uid"
}

lan_only_v6() {
    package=$1
    uid=$(uid_for "$package")
    if [ -z "$uid" ] || [ "$uid" -lt 10000 ]; then return; fi
    for cidr in ::1/128 fe80::/10 fc00::/7
    do
        ip6tables -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -d "$cidr" -j RETURN
    done
    ip6tables -w 5 -A "$CHAIN" -m owner --uid-owner "$uid" -j REJECT
    log "LAN-only IPv6: $package uid=$uid"
}

apply_profile_packages() {
    profile=$(tr '[:upper:]' '[:lower:]' < "$MODDIR/profile" 2>/dev/null)
    config="$MODDIR/${profile}-packages.conf"
    if [ ! -f "$config" ]; then
        log "missing or invalid package profile: $profile"
        return
    fi
    while read -r action package
    do
        case "$action" in
            uninstall-user) pm uninstall --user 0 "$package" >/dev/null 2>&1 || true ;;
            disable-user) pm disable-user --user 0 "$package" >/dev/null 2>&1 || true ;;
        esac
    done < "$config"
    log "package profile enforced: $profile"
}

apply_privacy_settings() {
    settings put global ntp_server time.cloudflare.com
    settings put global captive_portal_http_url 'http://connectivitycheck.gstatic.com/generate_204'
    settings put global captive_portal_https_url 'https://connectivitycheck.gstatic.com/generate_204'
    settings put global captive_portal_http_url_config '{"captivePortalHttpUrls":["http://connectivitycheck.gstatic.com/generate_204"],"captivePortalHttpsUrls":["https://connectivitycheck.gstatic.com/generate_204"],"defaultCaptivePortalFallbackUrls":["http://connectivitycheck.android.com/generate_204"]}'
}

# Install the hardcoded-IP block immediately. The hostname overlay is already
# active, while application UID rules wait for Package Manager below.
reset_chain iptables
reset_chain ip6tables
prepare_chain iptables
prepare_chain ip6tables
iptables -w 5 -A "$CHAIN" -d 119.23.143.188/32 -j REJECT

profile=$(tr '[:upper:]' '[:lower:]' < "$MODDIR/profile" 2>/dev/null)
if [ "$profile" = lockdown ]; then
    apply_lockdown_uid_file iptables
    apply_lockdown_uid_file ip6tables
fi

# Magisk late_start can run before Package Manager exposes application IDs.
# Wait at most five minutes; never hold Android's boot indefinitely.
attempt=0
while [ "$(getprop sys.boot_completed)" != "1" ] || [ -z "$(uid_for com.onyx.easytransfer)" ]
do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 150 ]; then
        log 'timed out waiting for Android boot / Package Manager'
        break
    fi
    sleep 2
done

# BOOX finishes some package/settings maintenance after boot_completed=1.
sleep 30

# BOOX rewrites these values during startup, so apply the recorded privacy
# alternatives only after its boot services have finished.
apply_privacy_settings
apply_profile_packages

reset_chain iptables
reset_chain ip6tables
prepare_chain iptables
prepare_chain ip6tables
WAN_UIDS_V4=''
WAN_UIDS_V6=''

# Known cleartext BOOX bootstrap address found in application analysis.
iptables -w 5 -A "$CHAIN" -d 119.23.143.188/32 -j REJECT

if [ "$profile" = lockdown ]; then
    apply_lockdown_uid_file iptables
    apply_lockdown_uid_file ip6tables
    discover_lockdown_packages iptables
    discover_lockdown_packages ip6tables
    # Catch any com.onyx package added later in the same boot session.
    (
        while sleep 60
        do
            apply_privacy_settings
            discover_lockdown_packages iptables
            discover_lockdown_packages ip6tables
        done
    ) >/dev/null 2>&1 &
else
    for package in com.onyx.igetshop com.onyx.aiassistant com.onyx.appmarket org.chromium.chrome
    do
        deny_package iptables "$package"
        deny_package ip6tables "$package"
    done

    # Preserve EasyTransfer on the local network while blocking its optional WAN/WeChat path.
    lan_only_v4 com.onyx.easytransfer
    lan_only_v6 com.onyx.easytransfer
fi

log 'firewall loaded'

#!/system/bin/sh
CHAIN=BOOX_PRIVACY
for tool in iptables ip6tables
do
    while "$tool" -w 5 -D OUTPUT -j "$CHAIN" 2>/dev/null; do :; done
    "$tool" -w 5 -F "$CHAIN" 2>/dev/null || true
    "$tool" -w 5 -X "$CHAIN" 2>/dev/null || true
done
rm -f /data/local/tmp/boox-privacy-firewall.log

#!/bin/sh

set -o errexit
set -o nounset
if [ "${TRACE-0}" -eq 1 ]; then set -o xtrace; fi

cd "$(dirname "$0")" || exit 1

dir=$(pwd)

IPT=$(which iptables)

interface=$(ip route | grep default | sed -e "s/^.*dev.//" -e "s/.proto.*//")

readonly backup_dir_firwall_rules="/tmp/backup/firewall/"

#### util functions

beginswith() { case $2 in "$1"*) true;; *) false;; esac; }

skip_docker_ifaces() {
  
  ## Skip all the interfaces created by docker:
  ##    vethXXXXXX
  ##    docker0
  ##    docker_gwbridge
  ##    br-XXXXXXXXXXX

  ifaces=$(ip -o link show | awk -F': ' '{print $2}')

  for i in $ifaces
  do
      if beginswith vet "$i"; then
          vet_value=${i%%@*}
          echo "Allow traffic on vet iface: $vet_value"
          $IPT -A INPUT -i "$vet_value" -j ACCEPT
          $IPT -A OUTPUT -o "$vet_value" -j ACCEPT
      fi
      if beginswith br- "$i"; then
          echo "Allow traffic on br- iface: $i"
          $IPT -A INPUT -i "$i" -j ACCEPT
          $IPT -A OUTPUT -o "$i" -j ACCEPT
      fi
      if beginswith docker "$i"; then
          echo "Allow traffic on docker iface: $i"
          $IPT -A INPUT -i "$i" -j ACCEPT
          $IPT -A OUTPUT -o "$i" -j ACCEPT
      fi
  done
}

#### end util functions

start() {
    echo "############ <START> ##############"

    mkdir -p "$backup_dir_firwall_rules"
    IPTABLES_SAVE_FILE="$backup_dir_firwall_rules/rules_$(date +%Y%m%d%H%M%S%N)"

    touch "$IPTABLES_SAVE_FILE"
    chmod 600 "$IPTABLES_SAVE_FILE"
    iptables-save -c >"$IPTABLES_SAVE_FILE"

    # flush all rules
    $IPT -F
    $IPT -X
    $IPT -Z
    $IPT -t filter --flush
    $IPT -t nat    --flush
    $IPT -t mangle --flush

    # Preserve docker rules
    docker_restore

    # Skip filter on docker ifaces
    skip_docker_ifaces

    ### BLOCK INPUT BY DEFAULT ALLOW OUTPUT ###
    $IPT -P INPUT DROP
    $IPT -P OUTPUT ACCEPT

    # Enable free use of loopback interfaces
    $IPT -A INPUT -i lo -j ACCEPT
    $IPT -A OUTPUT -o lo -j ACCEPT

    ###############
    ###  INPUT  ###
    ###############

    # === anti scan ===
    $IPT -N SCANS
    $IPT -A SCANS -p tcp --tcp-flags FIN,URG,PSH FIN,URG,PSH -j DROP
    $IPT -A SCANS -p tcp --tcp-flags ALL ALL -j DROP
    $IPT -A SCANS -p tcp --tcp-flags ALL NONE -j DROP
    $IPT -A SCANS -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
    ####################
    echo "[Anti-scan is ready]"

    #No spoofing
    if [ -e /proc/sys/net/ipv4/conf/all/ip_filter ]; then
        for filtre in /proc/sys/net/ipv4/conf/*/rp_filter
        do
            echo > 1 "$filtre"
        done
    fi
    echo "[Anti-spoofing is ready]"

    #No synflood
    if [ -e /proc/sys/net/ipv4/tcp_syncookies ]; then
        echo 1 > /proc/sys/net/ipv4/tcp_syncookies
    fi
    echo "[Anti-synflood is ready]"

    ####################
    # === Clean particulars packets ===
    #Make sure NEW incoming tcp connections are SYN packets
    $IPT -A INPUT -p tcp ! --syn -m state --state NEW -j DROP
    # Packets with incoming fragments
    $IPT -A INPUT -f -j DROP
    # incoming malformed XMAS packets
    $IPT -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
    # Incoming malformed NULL packets
    $IPT -A INPUT -p tcp --tcp-flags ALL NONE -j DROP

    #Drop broadcast
    $IPT -A INPUT -m pkttype --pkt-type broadcast -j DROP

    # Accept inbound TCP packets
    $IPT -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    $IPT -A INPUT -p tcp --dport 22 -m state --state NEW -s 0.0.0.0/0 -j ACCEPT
    
    # Other firewall rules
    # insert here your firewall rules

    # Swarm mode - uncomment to enable swarm access (adjust source lan)
    # $IPT -A INPUT -p tcp --dport 2377 -m state --state NEW -s 192.168.1.0/24 -j ACCEPT
    # $IPT -A INPUT -p tcp --dport 7946 -m state --state NEW -s 192.168.1.0/24 -j ACCEPT
    # $IPT -A INPUT -p udp --dport 7946 -m state --state NEW -s 192.168.1.0/24 -j ACCEPT
    # $IPT -A INPUT -p udp --dport 4789 -m state --state NEW -s 192.168.1.0/24 -j ACCEPT

    # Accept inbound ICMP messages
    $IPT -A INPUT -p ICMP --icmp-type 8 -s 0.0.0.0/0 -j ACCEPT
    $IPT -A INPUT -p ICMP --icmp-type 11 -s 0.0.0.0/0 -j ACCEPT

    ###############
    ###   LOG   ###
    ###############

    $IPT -N LOGGING
    $IPT -A INPUT -j LOGGING
    $IPT -A LOGGING -m limit --limit 2/min -j LOG --log-prefix "IPTables-Dropped: " --log-level 4
    $IPT -A LOGGING -j DROP
}

docker_restore() {
  awk -f "$dir/awk.firewall" <"$IPTABLES_SAVE_FILE" | iptables-restore
}

stop() {
    ### OPEN ALL !!! ###
    echo "############ <STOP> ##############"

    mkdir -p "$backup_dir_firwall_rules"
    IPTABLES_SAVE_FILE="$backup_dir_firwall_rules/rules_$(date +%Y%m%d%H%M%S%N)"

    touch "$IPTABLES_SAVE_FILE"
    chmod 600 "$IPTABLES_SAVE_FILE"
    iptables-save -c >"$IPTABLES_SAVE_FILE"

    # set the default policy to ACCEPT
    $IPT --policy INPUT   ACCEPT
    $IPT --policy OUTPUT  ACCEPT
    $IPT --policy FORWARD ACCEPT

    $IPT           --flush
    $IPT -t nat    --flush
    $IPT -t mangle --flush

    # Preserve docker rules
    docker_restore
 }

case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    start
    ;;
  *)
    echo "systemctl {start|stop} iptables-docker.service" >&2
    echo "or" >&2
    echo "iptables-docker.sh {start|stop}" >&2
    exit 1
    ;;
esac

exit 0

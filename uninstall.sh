#!/bin/sh

echo "Disable iptables-docker"

systemctl stop iptables-docker
systemctl disable iptables-docker

echo "remove iptables-docker.sh"

rm -rf /usr/local/sbin/iptables-docker.sh
rm -rf /usr/local/sbin/awk.firewall

echo "remove systemd unit"

rm -rf /etc/systemd/system/iptables-docker.service

echo "Reload systemd"

systemctl daemon-reload
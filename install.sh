#!/bin/sh

echo "Set iptables to iptables-legacy"

iptables --version | grep legacy > /dev/null
iptables_rc=$?
if [ $iptables_rc -ne 0 ]; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
    echo "You need to reboot your machine"
fi

echo "Disable ufw,firewalld"

systemctl stop ufw
systemctl disable ufw

systemctl stop firewalld
systemctl disable firewalld

echo "Install iptables-docker.sh"

cp src/iptables-docker.sh /usr/local/sbin/
cp src/awk.firewall /usr/local/sbin/

chmod 700 /usr/local/sbin/iptables-docker.sh
chmod 600 /usr/local/sbin/awk.firewall

echo "Create systemd unit"

cp src/iptables-docker.service /etc/systemd/system/

echo "Enable iptables-docker.service"

systemctl daemon-reload
systemctl enable iptables-docker

echo "start iptables-docker.service"

systemctl start iptables-docker

if [ $iptables_rc -ne 0 ]; then
    echo "Reboot your machine"
fi
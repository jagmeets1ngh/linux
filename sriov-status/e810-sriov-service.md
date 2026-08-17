```bash
sudo nano /etc/systemd/system/e810-sriov.service
```

# PASTE THE BELOW INTO THE FILE AND EDIT VF MAC, VLAN, SPOOFCHECK, TRUST values as per your requirements:
```
[Unit]
Description=Intel E810 SR-IOV VF Setup (ice1 + ice2)
Documentation=https://github.com/intel/ethernet-linux-ice
After=network.target
Before=pve-guests.target

[Service]
Type=oneshot
RemainAfterExit=yes

ExecStart=/usr/bin/ip link set ice2 up

ExecStart=/usr/bin/bash -c 'echo 24 > /sys/class/net/ice2/device/sriov_numvfs'

1a:PVE#:NIC#:VLAN_ID:VM_HH:VM_LL     1a = SR-IOV VF
2a:PVE#:NIC#:VLAN_ID:VM_HH:VM_LL     2a = virtio

#Jump Server:
# VFs - Services, Internal, Storage, Trusted
ExecStart=/usr/bin/ip link set ice2 vf 0 mac 1a:01:02:71:01:00
ExecStart=/usr/bin/ip link set ice2 vf 1 mac 1a:01:02:72:01:00
ExecStart=/usr/bin/ip link set ice2 vf 2 mac 1a:01:02:74:01:00
ExecStart=/usr/bin/ip link set ice2 vf 3 mac 1a:01:02:75:01:00

# VM 1011 - External, Storage
ExecStart=/usr/bin/ip link set ice2 vf 4 mac 1a:01:02:71:10:11
ExecStart=/usr/bin/ip link set ice2 vf 5 mac 1a:01:02:74:10:11

# VM 1012 - External, Storage
ExecStart=/usr/bin/ip link set ice2 vf 6 mac 1a:01:02:71:10:12
ExecStart=/usr/bin/ip link set ice2 vf 7 mac 1a:01:02:74:10:12

# VM 1013 - External, Storage
ExecStart=/usr/bin/ip link set ice2 vf 8 mac 1a:01:02:71:10:13



#VLAN ASSIGNMENTS
ExecStart=/usr/bin/ip link set ice2 vf 0 vlan 71
ExecStart=/usr/bin/ip link set ice2 vf 1 vlan 72
ExecStart=/usr/bin/ip link set ice2 vf 2 vlan 74
ExecStart=/usr/bin/ip link set ice2 vf 3 vlan 75
ExecStart=/usr/bin/ip link set ice2 vf 4 vlan 71
ExecStart=/usr/bin/ip link set ice2 vf 5 vlan 74
ExecStart=/usr/bin/ip link set ice2 vf 6 vlan 71
ExecStart=/usr/bin/ip link set ice2 vf 7 vlan 74
ExecStart=/usr/bin/ip link set ice2 vf 8 vlan 71


#SPOOFCHECK
ExecStart=/usr/bin/ip link set ice2 vf 0 spoofchk on
ExecStart=/usr/bin/ip link set ice2 vf 1 spoofchk on
ExecStart=/usr/bin/ip link set ice2 vf 2 spoofchk on
ExecStart=/usr/bin/ip link set ice2 vf 3 spoofchk on
ExecStart=/usr/bin/ip link set ice2 vf 4 spoofchk on
ExecStart=/usr/bin/ip link set ice2 vf 5 spoofchk on
ExecStart=/usr/bin/ip link set ice2 vf 6 spoofchk on
ExecStart=/usr/bin/ip link set ice2 vf 7 spoofchk on
ExecStart=/usr/bin/ip link set ice2 vf 8 spoofchk on

#TRUST
ExecStart=/usr/bin/ip link set ice2 vf 0 trust off
ExecStart=/usr/bin/ip link set ice2 vf 1 trust off
ExecStart=/usr/bin/ip link set ice2 vf 2 trust off
ExecStart=/usr/bin/ip link set ice2 vf 3 trust off
ExecStart=/usr/bin/ip link set ice2 vf 4 trust off
ExecStart=/usr/bin/ip link set ice2 vf 5 trust off
ExecStart=/usr/bin/ip link set ice2 vf 6 trust off
ExecStart=/usr/bin/ip link set ice2 vf 7 trust off
ExecStart=/usr/bin/ip link set ice2 vf 8 trust off

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```
## ***Activate the Service***
```bash
sudo systemctl enable --now e810-sriov.service
```

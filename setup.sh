#!/bin/bash

# Node building vars
image_dir="/var/lib/libvirt/images"
#base_os_img="/var/lib/libvirt/images/iso/CentOS-7-x86_64-GenericCloud.qcow2"
base_os_img="/var/lib/libvirt/images/iso/CentOS-Stream-GenericCloud-8-20201217.0.x86_64.qcow2"
ssh_pub_key="/root/.ssh/id_ed25519.pub"

# Network Vars
dns_domain="ceph.lab"

# Extra Vars
root_password="password"
os_drive_size="40G"
tmp_dir="/tmp"

# Ceph Extra nodes 
rgw=yes
mds=no
iscsi=no


##### Start #####

# Exit on any failure

set -e

# Create Network files

echo "Creating ceph-presentation xml file"

cat <<EOF > $tmp_dir/ceph-presentation.xml
<network>
  <name>ceph-presentation</name>
  <bridge name="virbr3300"/>
  <forward mode="nat"/>
  <domain name="ceph.lab"/>
  <ip address="10.44.20.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.44.20.200" end="10.44.20.210"/>
    </dhcp>
  </ip>
</network>
EOF

echo "Creating ceph-replicaton xml file"
cat <<EOF >$tmp_dir/ceph-replication.xml
<network>
  <name>ceph-replication</name>
  <bridge name="virbr3301"/>
  <ip address="172.16.20.1" netmask="255.255.255.0">
    <dhcp>
      <range start="172.16.20.200" end="172.16.20.210"/>
    </dhcp>
  </ip>
</network>
EOF

echo "Creating ceph networks in libvirt"

check_rep=$(virsh net-list --all | grep ceph-replication >/dev/null && echo "0" || echo "1")
check_pres=$(virsh net-list --all | grep ceph-presentation >/dev/null && echo "0" || echo "1")

networks=()

if [[ $check_rep == "1" ]]; then
  networks+=("ceph-replication")
fi

if [[ $check_pres == "1" ]]; then
  networks+=("ceph-presentation")
fi

net_len=$(echo "${#networks[@]}")

if [ "$net_len" -ge 1 ]; then
  for network in ${networks[@]}; do 
    virsh net-define $tmp_dir/$network.xml
    virsh net-start $network
    virsh net-autostart $network
  done
else
  echo "Both networks already created"
fi

# Check OS image exists

if [ -f "$base_os_img" ]; then
  echo "Base OS image exists"
else
  echo "Base image doesn't exist ($base_os_img). Exiting"
  exit 1
fi

# Build OS drives for machines

echo "Starting build of VMs"

echo "Building Bastion & Grafana drives"

for node in bastion grafana; do 
  check=$(virsh list --all | grep $node.$dns_domain > /dev/null && echo "0" || echo "1" )
  if [[ $check == "0" ]]; then
    echo "$node.$dns_domain exists"
  else
    echo "Starting $node"
    echo "Creating $image_dir/$node.$dns_domain.qcow2 at $os_drive_size"
    qemu-img create -f qcow2 $image_dir/$node.$dns_domain.qcow2 $os_drive_size
    echo "Resizing base OS image"
    virt-resize --expand /dev/sda1 $base_os_img $image_dir/$node.$dns_domain.qcow2
    echo "Customising OS for $node"
    virt-customize -a $image_dir/$node.$dns_domain.qcow2 \
      --root-password password:$root_password \
      --uninstall cloud-init \
      --hostname $node.$dns_domain \
      --ssh-inject root:file:$ssh_pub_key \
      --selinux-relabel
  fi
done

check=$(virsh list --all | grep bastion.$dns_domain > /dev/null && echo "0" || echo "1" )
if [[ $check == "1" ]]; then
  echo "Defining Bastion VM"
  virt-install --name bastion.$dns_domain \
    --virt-type kvm \
    --memory 2048 \
    --vcpus 2 \
    --boot hd,menu=on \
    --disk path=$image_dir/bastion.$dns_domain.qcow2,device=disk \
    --os-type Linux \
    --os-variant centos7 \
    --network network:ceph-presentation \
    --graphics spice \
    --noautoconsole
fi

check=$(virsh list --all | grep grafana.$dns_domain > /dev/null && echo "0" || echo "1" )
if [[ $check == "1" ]]; then
  echo "Defining Grafana VM"
  virt-install --name grafana.$dns_domain \
    --virt-type kvm \
    --memory 4096 \
    --vcpus 2 \
    --boot hd,menu=on \
    --disk path=$image_dir/grafana.$dns_domain.qcow2,device=disk \
    --os-type Linux \
    --os-variant centos7 \
    --network network:ceph-presentation \
    --graphics spice \
    --noautoconsole
fi

echo "Building Monitor VMs"

count=1

for mon in `seq -w 01 03`; do 
  check=$(virsh list --all | grep ceph-mon$mon.$dns_domain > /dev/null && echo "0" || echo "1" )
  if [[ $check == "0" ]]; then
    echo "ceph-mon$mon.$dns_domain already exists"
    count=$(( $count + 1 ))
  else
    echo "Creating eth0 ifcfg file"
    mkdir -p $tmp_dir/ceph-mon$mon
    cat <<EOF > $tmp_dir/ceph-mon$mon/ifcfg-eth0
TYPE=Ethernet
NAME=eth0
DEVICE=eth0
BOOTPROTO=static
IPADDR=10.44.20.2$count
NETMASK=255.255.255.0
GATEWAY=10.44.20.1
DNS1=10.44.20.1
ONBOOT=yes
DEFROUTE=yes
EOF
    echo "Creating eth1 ifcfg file"
    cat <<EOF > $tmp_dir/ceph-mon$mon/ifcfg-eth1
TYPE=Ethernet
NAME=eth1
DEVICE=eth1
BOOTPROTO=static
IPADDR=172.16.20.2$count
NETMASK=255.255.255.0
EOF
    echo "Starting ceph-mon$mon"
    echo "Creating $image_dir/ceph-mon$mon.$dns_domain.qcow2 at $os_drive_size"
    qemu-img create -f qcow2 $image_dir/ceph-mon$mon.$dns_domain.qcow2 $os_drive_size
    echo "Resizing base OS image"
    virt-resize --expand /dev/sda1 $base_os_img $image_dir/ceph-mon$mon.$dns_domain.qcow2
    echo "Customising OS for ceph-mon$mon"
    virt-customize -a $image_dir/ceph-mon$mon.$dns_domain.qcow2 \
      --root-password password:$root_password \
      --uninstall cloud-init \
      --hostname ceph-mon$mon \
      --ssh-inject root:file:$ssh_pub_key \
      --copy-in $tmp_dir/ceph-mon$mon/ifcfg-eth0:/etc/sysconfig/network-scripts/ \
      --copy-in $tmp_dir/ceph-mon$mon/ifcfg-eth1:/etc/sysconfig/network-scripts/ \
      --selinux-relabel
    echo "Defining ceph-mon$mon.$dns_domain"
    virt-install --name ceph-mon$mon.$dns_domain \
      --virt-type kvm \
      --memory 4096 \
      --vcpus 4 \
      --boot hd,menu=on \
      --disk path=$image_dir/ceph-mon$mon.$dns_domain.qcow2,device=disk \
      --os-type Linux \
      --os-variant centos7 \
      --network network:ceph-presentation \
      --network network:ceph-replication \
      --graphics spice \
      --noautoconsole
    count=$(( $count + 1 ))
  fi
done

echo "Building OSD T1 drives"

count=1

for i in `seq -w 01 04`; do 
  check=$(virsh list --all | grep ceph-t1-osd$i.$dns_domain > /dev/null && echo "0" || echo "1" )
  if [[ $check == "0" ]]; then
    echo "ceph-t1-osd$i.$dns_domain already exists"
    count=$(( $count + 1 ))
  else
    echo "Creating eth0 ifcfg file"
    mkdir -p $tmp_dir/ceph-t1-osd$i
    cat <<EOF > $tmp_dir/ceph-t1-osd$i/ifcfg-eth0
TYPE=Ethernet
NAME=eth0
DEVICE=eth0
BOOTPROTO=static
IPADDR=10.44.20.3$count
NETMASK=255.255.255.0
GATEWAY=10.44.20.1
DNS1=10.44.20.1
ONBOOT=yes
DEFROUTE=yes
EOF
    echo "Creating eth1 ifcfg file"
    cat <<EOF > $tmp_dir/ceph-t1-osd$i/ifcfg-eth1
TYPE=Ethernet
NAME=eth1
DEVICE=eth1
BOOTPROTO=static
IPADDR=172.16.20.3$count
NETMASK=255.255.255.0
EOF
    echo "Starting ceph-t1-osd$i"
    echo "Creating $image_dir/ceph-t1-osd$i.$dns_domain.qcow2 at $os_drive_size"
    qemu-img create -f qcow2 $image_dir/ceph-t1-osd$i.$dns_domain.qcow2 $os_drive_size
    for c in {1..4}; do 
      qemu-img create -f qcow2 $image_dir/ceph-t1-osd$i-disk$c.$dns_domain.qcow2 5G
    done
    echo "Resizing base OS image"
    virt-resize --expand /dev/sda1 $base_os_img $image_dir/ceph-t1-osd$i.$dns_domain.qcow2
    echo "Customising OS for ceph-t1-osd$i"
    virt-customize -a $image_dir/ceph-t1-osd$i.$dns_domain.qcow2 \
      --root-password password:$root_password \
      --uninstall cloud-init \
      --hostname ceph-t1-osd$i \
      --ssh-inject root:file:$ssh_pub_key \
      --copy-in $tmp_dir/ceph-t1-osd$i/ifcfg-eth0:/etc/sysconfig/network-scripts/ \
      --copy-in $tmp_dir/ceph-t1-osd$i/ifcfg-eth1:/etc/sysconfig/network-scripts/ \
      --selinux-relabel
    echo "Defining ceph-t1-osd$i"
    virt-install --name ceph-t1-osd$i.$dns_domain \
      --virt-type kvm \
      --memory 8192 \
      --vcpus 4 \
      --boot hd,menu=on \
      --disk path=$image_dir/ceph-t1-osd$i.$dns_domain.qcow2,device=disk \
      --disk path=$image_dir/ceph-t1-osd$i-disk1.$dns_domain.qcow2,device=disk \
      --disk path=$image_dir/ceph-t1-osd$i-disk2.$dns_domain.qcow2,device=disk \
      --disk path=$image_dir/ceph-t1-osd$i-disk3.$dns_domain.qcow2,device=disk \
      --disk path=$image_dir/ceph-t1-osd$i-disk4.$dns_domain.qcow2,device=disk \
      --os-type Linux \
      --os-variant centos7 \
      --network network:ceph-presentation \
      --network network:ceph-replication \
      --graphics spice \
      --noautoconsole
    
    count=$(( $count + 1 ))
  fi
done

echo "Building OSD T2 drives"

count=1

for i in `seq -w 01 04`; do 
  check=$(virsh list --all | grep ceph-t2-osd$i.$dns_domain > /dev/null && echo "0" || echo "1" )
  if [[ $check == "0" ]]; then
    echo "ceph-t2-osd$i.$dns_domain already exists"
    count=$(( $count + 1 ))
  else
    echo "Creating eth0 ifcfg file"
    mkdir -p $tmp_dir/ceph-t2-osd$i
    cat <<EOF > $tmp_dir/ceph-t2-osd$i/ifcfg-eth0
TYPE=Ethernet
NAME=eth0
DEVICE=eth0
BOOTPROTO=static
IPADDR=10.44.20.4$count
NETMASK=255.255.255.0
GATEWAY=10.44.20.1
DNS1=10.44.20.1
ONBOOT=yes
DEFROUTE=yes
EOF
    echo "Creating eth1 ifcfg file"
    cat <<EOF > $tmp_dir/ceph-t2-osd$i/ifcfg-eth1
TYPE=Ethernet
NAME=eth1
DEVICE=eth1
BOOTPROTO=static
IPADDR=172.16.20.4$count
NETMASK=255.255.255.0
EOF
    echo "Starting ceph-t2-osd$i"
    echo "Creating $image_dir/ceph-t2-osd$i.$dns_domain.qcow2 at $os_drive_size"
    qemu-img create -f qcow2 $image_dir/ceph-t2-osd$i.$dns_domain.qcow2 $os_drive_size
    for c in {1..4}; do
      qemu-img create -f qcow2 $image_dir/ceph-t2-osd$i-disk$c.$dns_domain.qcow2 10G
    done
    echo "Resizing base OS image"
    virt-resize --expand /dev/sda1 $base_os_img $image_dir/ceph-t2-osd$i.$dns_domain.qcow2
    echo "Customising OS for ceph-t2-osd$i"
    virt-customize -a $image_dir/ceph-t2-osd$i.$dns_domain.qcow2 \
      --root-password password:$root_password \
      --uninstall cloud-init \
      --hostname ceph-t2-osd$i \
      --ssh-inject root:file:$ssh_pub_key \
      --copy-in $tmp_dir/ceph-t2-osd$i/ifcfg-eth0:/etc/sysconfig/network-scripts/ \
      --copy-in $tmp_dir/ceph-t2-osd$i/ifcfg-eth1:/etc/sysconfig/network-scripts/ \
      --selinux-relabel
  
    echo "Defining ceph-t2-osd$i"
    virt-install --name ceph-t2-osd$i.$dns_domain \
      --virt-type kvm \
      --memory 8192 \
      --vcpus 4 \
      --boot hd,menu=on \
      --disk path=$image_dir/ceph-t2-osd$i.$dns_domain.qcow2,device=disk \
      --disk path=$image_dir/ceph-t2-osd$i-disk1.$dns_domain.qcow2,device=disk \
      --disk path=$image_dir/ceph-t2-osd$i-disk2.$dns_domain.qcow2,device=disk \
      --disk path=$image_dir/ceph-t2-osd$i-disk3.$dns_domain.qcow2,device=disk \
      --disk path=$image_dir/ceph-t2-osd$i-disk4.$dns_domain.qcow2,device=disk \
      --os-type Linux \
      --os-variant centos7 \
      --network network:ceph-presentation \
      --network network:ceph-replication \
      --graphics spice \
      --noautoconsole
    count=$(( $count + 1 ))
  fi
done

## Build extra ceph nodes if defines

# If rgw is "yes"

if [[ $rgw == "yes" ]]; then
  count=1
  for rgw in `seq -w 01 02`; do 
    check=$(virsh list --all | grep ceph-rgw$rgw.$dns_domain > /dev/null && echo "0" || echo "1" )
    if [[ $check == "0" ]]; then
      echo "ceph-rgw$rgw.$dns_domain already exists"
      count=$(( $count + 1 ))
    else
      echo "Creating eth0 ifcfg file"
      mkdir -p $tmp_dir/ceph-rgw$rgw
      cat <<EOF > $tmp_dir/ceph-rgw$rgw/ifcfg-eth0
TYPE=Ethernet
NAME=eth0
DEVICE=eth0
BOOTPROTO=static
IPADDR=10.44.20.11$count
NETMASK=255.255.255.0
GATEWAY=10.44.20.1
DNS1=10.44.20.1
ONBOOT=yes
DEFROUTE=yes
EOF
      echo "Starting ceph-rgw$rgw"
      echo "Creating $image_dir/ceph-rgw$rgw.$dns_domain.qcow2 at $os_drive_size"
      qemu-img create -f qcow2 $image_dir/ceph-rgw$rgw.$dns_domain.qcow2 $os_drive_size
      echo "Resizing base OS image"
      virt-resize --expand /dev/sda1 $base_os_img $image_dir/ceph-rgw$rgw.$dns_domain.qcow2
      echo "Customising OS for ceph-rgw$rgw"
      virt-customize -a $image_dir/ceph-rgw$rgw.$dns_domain.qcow2 \
        --root-password password:$root_password \
        --uninstall cloud-init \
        --hostname ceph-rgw$rgw \
        --ssh-inject root:file:$ssh_pub_key \
        --copy-in $tmp_dir/ceph-rgw$rgw/ifcfg-eth0:/etc/sysconfig/network-scripts/ \
        --selinux-relabel
      echo "Defining ceph-rgw$rgw.$dns_domain"
      virt-install --name ceph-rgw$rgw.$dns_domain \
        --virt-type kvm \
        --memory 4096 \
        --vcpus 2 \
        --boot hd,menu=on \
        --disk path=$image_dir/ceph-rgw$rgw.$dns_domain.qcow2,device=disk \
        --os-type Linux \
        --os-variant centos7 \
        --network network:ceph-presentation \
        --graphics spice \
        --noautoconsole
      count=$(( $count + 1 ))
    fi
  done
fi

# If mds set to "yes"

if [[ $mds == "yes" ]]; then
  count=1
  for mds in `seq -w 01 02`; do
    check=$(virsh list --all | grep ceph-mds$mds.$dns_domain > /dev/null && echo "0" || echo "1" )
    if [[ $check == "0" ]]; then
      echo "ceph-mds$mds.$dns_domain already exists"
      count=$(( $count + 1 ))
    else
      echo "Creating eth0 ifcfg file"
      mkdir -p $tmp_dir/ceph-mds$mds
      cat <<EOF > $tmp_dir/ceph-mds$mds/ifcfg-eth0
TYPE=Ethernet
NAME=eth0
DEVICE=eth0
BOOTPROTO=static
IPADDR=10.44.20.12$count
NETMASK=255.255.255.0
GATEWAY=10.44.20.1
DNS1=10.44.20.1
ONBOOT=yes
DEFROUTE=yes
EOF
      echo "Starting ceph-mds$mds"
      echo "Creating $image_dir/ceph-mds$mds.$dns_domain.qcow2 at $os_drive_size"
      qemu-img create -f qcow2 $image_dir/ceph-mds$mds.$dns_domain.qcow2 $os_drive_size
      echo "Resizing base OS image"
      virt-resize --expand /dev/sda1 $base_os_img $image_dir/ceph-mds$mds.$dns_domain.qcow2
      echo "Customising OS for ceph-mds$mds"
      virt-customize -a $image_dir/ceph-mds$mds.$dns_domain.qcow2 \
        --root-password password:$root_password \
        --uninstall cloud-init \
        --hostname ceph-mds$mds \
        --ssh-inject root:file:$ssh_pub_key \
        --copy-in $tmp_dir/ceph-mds$mds/ifcfg-eth0:/etc/sysconfig/network-scripts/ \
        --selinux-relabel
      echo "Defining ceph-mds$mds.$dns_domain"
      virt-install --name ceph-mds$mds.$dns_domain \
        --virt-type kvm \
        --memory 8192 \
        --vcpus 4 \
        --boot hd,menu=on \
        --disk path=$image_dir/ceph-mds$mds.$dns_domain.qcow2,device=disk \
        --os-type Linux \
        --os-variant centos7 \
        --network network:ceph-presentation \
        --graphics spice \
        --noautoconsole
      count=$(( $count + 1 ))
    fi
  done
fi

# If iscsi set to "yes"

if [[ $iscsi == "yes" ]]; then
  count=1
  for iscsi in `seq -w 01 02`; do
    check=$(virsh list --all | grep ceph-iscsi$iscsi.$dns_domain > /dev/null && echo "0" || echo "1" )
    if [[ $check == "0" ]]; then
      echo "ceph-iscsi$iscsi.$dns_domain already exists"
      count=$(( $count + 1 ))
    else
      echo "Creating eth0 ifcfg file"
      mkdir -p $tmp_dir/ceph-iscsi$iscsi
      cat <<EOF > $tmp_dir/ceph-iscsi$iscsi/ifcfg-eth0
TYPE=Ethernet
NAME=eth0
DEVICE=eth0
BOOTPROTO=static
IPADDR=10.44.20.13$count
NETMASK=255.255.255.0
GATEWAY=10.44.20.1
DNS1=10.44.20.1
ONBOOT=yes
DEFROUTE=yes
EOF
      echo "Starting ceph-iscsi$iscsi"
      echo "Creating $image_dir/ceph-iscsi$iscsi.$dns_domain.qcow2 at $os_drive_size"
      qemu-img create -f qcow2 $image_dir/ceph-iscsi$iscsi.$dns_domain.qcow2 $os_drive_size
      echo "Resizing base OS image"
      virt-resize --expand /dev/sda1 $base_os_img $image_dir/ceph-iscsi$iscsi.$dns_domain.qcow2
      echo "Customising OS for ceph-iscsi$iscsi"
      virt-customize -a $image_dir/ceph-iscsi$iscsi.$dns_domain.qcow2 \
        --root-password password:$root_password \
        --uninstall cloud-init \
        --hostname ceph-iscsi$iscsi \
        --ssh-inject root:file:$ssh_pub_key \
        --copy-in $tmp_dir/ceph-iscsi$iscsi/ifcfg-eth0:/etc/sysconfig/network-scripts/ \
        --selinux-relabel
      echo "Defining ceph-iscsi$iscsi.$dns_domain"
      virt-install --name ceph-iscsi$iscsi.$dns_domain \
        --virt-type kvm \
        --memory 8192 \
        --vcpus 4 \
        --boot hd,menu=on \
        --disk path=$image_dir/ceph-iscsi$iscsi.$dns_domain.qcow2,device=disk \
        --os-type Linux \
        --os-variant centos7 \
        --network network:ceph-presentation \
        --graphics spice \
        --noautoconsole
      count=$(( $count + 1 ))
    fi
  done
fi

# Print running VMs

virsh list

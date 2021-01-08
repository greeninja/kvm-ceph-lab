#!/bin/bash

# Node building vars
image_dir="/var/lib/libvirt/images"
base_os_img="/var/lib/libvirt/images/iso/CentOS-7-x86_64-GenericCloud.qcow2"
ssh_pub_key="/root/.ssh/id_ed25519.pub"

# Network Vars
dns_domain="ceph.lab"

# Extra Vars
root_password="d0ddl3"
os_drive_size="40G"
tmp_dir="/tmp"


##### Start #####

# Destroy & Undefine all nodes

echo "Destroy & Undefine all nodes"
virsh destroy bastion.$dns_domain
virsh destroy grafana.$dns_domain
virsh undefine bastion.$dns_domain --remove-all-storage
virsh undefine grafana.$dns_domain --remove-all-storage

echo "Removing Monitor nodes"
for mon in `seq -w 01 03`; do
  virsh destroy ceph-mon$mon.$dns_domain
  virsh undefine ceph-mon$mon.$dns_domain --remove-all-storage
done

echo "Removing OSD nodes"
for i in `seq -w 01 04`; do
  virsh destroy ceph-t1-osd$i.$dns_domain
  virsh destroy ceph-t2-osd$i.$dns_domain
  virsh undefine ceph-t1-osd$i.$dns_domain --remove-all-storage
  virsh undefine ceph-t2-osd$i.$dns_domain --remove-all-storage
done

echo "Removing other nodes"
for i in `seq -w 01 02`; do
  virsh destroy ceph-rgw$i.$dns_domain
  virsh destroy ceph-mds$i.$dns_domain
  virsh destroy ceph-iscsi$i.$dns_domain
  virsh undefine ceph-rgw$i.$dns_domain --remove-all-storage
  virsh undefine ceph-mds$i.$dns_domain --remove-all-storage
  virsh undefine ceph-iscsi$i.$dns_domain --remove-all-storage
done

# Remove ifcfg files

echo "Removing monitor ifcfg files"
for mon in `seq -w 01 03`; do
  rm $tmp_dir/ceph-mon$mon -rf
  rm $tmp_dir/ceph-mds$mon -rf
  rm $tmp_dir/ceph-iscsi$mon -rf
  rm $tmp_dir/ceph-rgw$mon -rf
done

echo "Removing OSD ifcfg files"
for t in 1 2; do
  for i in `seq -w 01 04`; do
    rm $tmp_dir/ceph-t$t-osd$i -rf
  done
done

# Remove Network files

echo "Removing ceph-presentation xml file"

rm $tmp_dir/ceph-presentation.xml -rf

echo "Removing ceph-replicaton xml file"

echo "Removing ceph networks in libvirt"

for network in ceph-presentation ceph-replication; do 
  virsh net-destroy $network
  virsh net-undefine $network
done



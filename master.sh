#!/bin/bash
log_msg() {
    message=$1
    echo "[DEBUG] $(date +'%Y-%m-%d %H:%M:%S,%3N') ${message}" >> "/tmp/deploy.log"
}

function retry {
  local retries=10
  local count=0
  until "$@"; do
    exit=$?
    wait=$((2 ** $count))
    count=$(($count + 1))
    if [ $count -lt $retries ]; then
      log_msg "Retry $count/$retries exited $exit, retrying in $wait seconds..."
      sleep $wait
    else
      log_msg "Retry $count/$retries exited $exit, no more retries left."
      return $exit
    fi
  done
  return 0
}


function deploy_compute_addons {
  IFS=','
  for i in $1; do
    log_msg "deploying ${i} compute addon"
    vinfra service compute set --enable-${i} --wait --timeout 3600
    log_msg "deployed ${i} compute addon"
  done
}

echo $password |passwd --stdin root

log_msg "changed password to $password"

echo `/usr/bin/openssl rand -hex 8` > /etc/vstorage/host_id
echo `/usr/bin/openssl rand -hex 16` > /etc/machine-id

log_msg "fixing up iscsi initiatorname"
hostid=$(cat /etc/vstorage/host_id | cut -c -12)
echo "InitiatorName=iqn.1994-05.com.redhat:$hostid" > /etc/iscsi/initiatorname.iscsi

systemctl restart systemd-journald  # restart journald after machine-id was changed
sed -i '/NODE_ID =/d' /etc/vstorage/vstorage-ui-agent.conf
echo "NODE_ID = '`/usr/bin/openssl rand -hex 16`'" >> /etc/vstorage/vstorage-ui-agent.conf

log_msg "generated new uuids for machine"


cat > /etc/sysconfig/network-scripts/ifcfg-eth0 <<EOF
BOOTPROTO="dhcp"
DEVICE="eth0"
ONBOOT="yes"
IPV6INIT="no"
TYPE="Ethernet"
EOF

log_msg "configured public interface"

cat > /etc/sysconfig/network-scripts/ifcfg-eth1 <<EOF
BOOTPROTO="dhcp"
DEVICE="eth1"
IPV6INIT="no"
NAME="eth1"
ONBOOT="yes"
TYPE="Ethernet"
EOF

log_msg "configured private interface"

# restart interfaces manually to avoid error with
# dhclient is already running - exiting.
systemctl stop vstorage-ui-agent
log_msg "stopped vstorage-ui-agent service"
sleep 3

log_msg "restart eth0 interface"
ifdown eth0
ifup eth0
log_msg "restart eth1 interface"
ifdown eth1
ifup eth1
log_msg "interfaces eth0 and eth1 restarted"

# let network init
sleep 10

systemctl start vstorage-ui-agent
log_msg "started vstorage-ui-agent service"

systemctl start vstorage-ui-backend
log_msg "started vstorage-ui-backend service"

echo $password | bash /usr/libexec/vstorage-ui-backend/bin/configure-backend.sh -x eth0 -i eth1
log_msg "configured backend"

/usr/libexec/vstorage-ui-backend/libexec/init-backend.sh
log_msg "backend initialized"

systemctl restart vstorage-ui-backend
log_msg "backend restarted"

retry /usr/libexec/vstorage-ui-agent/bin/register-storage-node.sh -m $private_ip -x eth0
log_msg "backend node registered"


if [ "$type" == "none" ]; then
    log_msg "Clean installation was requested, no clusters will be deployed."
    exit 0
fi

# let backend initialize completely
# don't edit this delays without coordinated changes in slave.sh
sleep 10

# deploying storage cluster
node_id=`vinfra --vinfra-password $password node list -f value -c id -c is_primary | sort -k 2 | tail -n 1 | cut -c1-36`

log_msg "deploying storage cluster..."
retry vinfra --vinfra-password $password cluster create --node "${node_id}" $cluster_name --wait
log_msg "deploying storage cluster...done"

no_ip_interfaces=$(vinfra node iface list --all | grep \\[\\] | wc -l)
while [ "0" != "$no_ip_interfaces" ]; do
    log_msg "there are $no_ip_interfaces with no IP addresses. waiting..."
    sleep 10
    no_ip_interfaces=$(vinfra node iface list --all | grep \\[\\] | wc -l)
done


log_msg "configuring traffic types..."
retry vinfra --vinfra-password $password cluster network set --add-traffic-types 'VM private' Private --wait
retry vinfra --vinfra-password $password cluster network set --add-traffic-types 'Compute API' Public --wait
retry vinfra --vinfra-password $password cluster network set --add-traffic-types 'Self-service panel' Public --wait
retry vinfra --vinfra-password $password cluster network set --add-traffic-types 'VM public' Public --wait
retry vinfra --vinfra-password $password cluster network set --add-traffic-types 'VM backups' Private --wait
log_msg "configuring traffic types...done"


unassigned_nodes_count=$(retry vinfra --vinfra-password $password node list -f value -c host -c is_assigned | grep False | wc -l)
log_msg "waiting for other nodes to register..."
sleep 30
log_msg "waiting for other nodes to register...done"

while [ "0" != "$unassigned_nodes_count" ]; do
    log_msg "there are $unassigned_nodes_count unassigned nodes left. waiting..."
    sleep 10
    unassigned_nodes_count=$(retry vinfra --vinfra-password $password node list -f value -c host -c is_assigned | grep False | wc -l)
done

compute_nodes=$(retry vinfra --vinfra-password $password node list -f value -c host -c id | sort -k2 | awk '{print $1}' | tr '\n' ' ' | sed 's/.$//' | sed -e 's: :,:g')
ha_nodes=$(echo $compute_nodes | cut -d ',' -f 1,2,3)

log_msg "the list of nodes: $compute_nodes"
log_msg "the list of HA nodes: $ha_nodes"
retry vinfra --vinfra-password $password cluster settings dns set --nameservers 8.8.8.8
sleep 2

case $type in
     storage)
          # by default, storage cluster already deployed
          exit 0
          ;;
     compute)
          # deploying compute cluster
          log_msg "creating compute cluster..."
          retry vinfra --vinfra-password $password service compute cluster create --wait --public-network=Public --node $compute_nodes --force --timeout 3600
          log_msg "creating compute cluster...done"

          log_msg "deploying compute addons..."
          deploy_compute_addons $compute_addons
          log_msg "deploying compute addons...done"
          ;;
     ha)
          # deploying ha
          log_msg "setting up HA..."
          retry vinfra --vinfra-password $password cluster ha create --virtual-ip Public:$vip_public --virtual-ip Private:$vip_private --node $ha_nodes --force --timeout 3600
          log_msg "setting up HA...done"
          ;;
     hacompute)
          # deploying ha with compute
          log_msg "setting up HA..."
          retry vinfra --vinfra-password $password cluster ha create --virtual-ip Public:$vip_public --virtual-ip Private:$vip_private --node $ha_nodes --force --timeout 3600
          log_msg "setting up HA...done"

          log_msg "creating compute cluster..."
          retry vinfra --vinfra-password $password service compute cluster create --wait --public-network=Public --node $compute_nodes --force  --timeout 3600
          log_msg "creating compute cluster...done"

          log_msg "deploying compute addons..."
          deploy_compute_addons $compute_addons
          log_msg "deploying compute addons...done"
          ;;
esac

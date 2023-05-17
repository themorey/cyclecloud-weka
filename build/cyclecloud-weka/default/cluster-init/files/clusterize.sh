#!/bin/bash
set -ex

# setup CycleCloud variables to find cluster IPs
cluster_name=$(jetpack config cyclecloud.cluster.name)
ccuser=$(jetpack config cyclecloud.config.username)
ccpass=$(jetpack config cyclecloud.config.password)
ccurl=$(jetpack config cyclecloud.config.web_server)
#cctype=$(jetpack config cyclecloud.node.template)

# Weka variables
VMS=$(curl -s -k --user ${ccuser}:${ccpass} "${ccurl}/clusters/${cluster_name}/nodes" | jq -r '.nodes[]  | .Hostname' | xargs)
IPS=$(curl -s -k --user ${ccuser}:${ccpass} "${ccurl}/clusters/${cluster_name}/nodes" | jq -r '.nodes[] |  .PrivateIp' | xargs | sed -e 's/ /,/g')
weka_status_ready="Containers: 1/1 running (1 weka)"
ssh_command="ssh -o StrictHostKeyChecking=no"

# Check cluster node status
#for vm in ${VMS}; do
#    while [ ! -f /tmp/${vm}.ready ]; do
#        while [ "$(${ssh_command} ${vm} 'weka local status' | grep ${weka_status_ready})" != "${weka_status_ready}" ]; do
#            sleep 10
#        done
#        touch /tmp/${vm}.ready
#    done
#done

# Get and map Core IDs
#if [ ! -f /tmp/core_ids ]; then
core_ids=$(cat /sys/devices/system/cpu/cpu*/topology/thread_siblings_list | cut -d "-" -f 1 | sort -u | tr '\n' ' ')
core_ids="${core_ids[@]/0}"
IFS=', ' read -r -a core_ids <<< "$core_ids"
core_idx_begin=0
core_idx_end=$(($core_idx_begin + $num_drive_containers))
get_core_ids() {
    core_idx_end=$(($core_idx_begin + $1))
    res=${core_ids[i]}
    for (( i=$(($core_idx_begin + 1)); i<$core_idx_end; i++ ))
    do
	    res=$res,${core_ids[i]}
    done
    core_idx_begin=$core_idx_end
    eval "$2=$res"
}
get_core_ids $num_drive_containers drive_core_ids
get_core_ids $num_compute_containers compute_core_ids
get_core_ids $num_frontend_containers frontend_core_ids
#    touch /tmp/core_ids
#fi

# Add the cluster drives
for vm in ${VMS}; do
    if [ "${vm}" != "$(hostname)" ]; then
        while [ "$(curl -s -k --user ${ccuser}:${ccpass} "${ccurl}/clusters/${cluster_name}/nodes" | jq -r --arg jq_vm ${vm} '.nodes[] | select(.Hostname == $jq_vm) |  .Status')" != "Ready" ]; do
            sleep 2
        done
    fi
    ${ssh_command} ${vm} "weka local setup container --name drives0 --base-port 14000 --cores ${num_drive_containers} --no-frontends --drives-dedicated-cores ${num_drive_containers} --core-ids $drive_core_ids --dedicate || true"
done


# create the cluster and login
weka cluster create ${VMS} --host-ips ${IPS} 1> /dev/null 2>& 1 || true

sleep 30s

# add drives to the cluster then update the cluster
if [ ! -f /tmp/weka.nvme_added ]; then
    for (( i=0; i<${hosts_num}; i++ )); do
	    for (( d=0; d<${num_drive_containers}; d++ )); do
		    weka cluster drive add ${i} "/dev/nvme${d}"n1
            sleep 5
	    done
    done
    touch /tmp/weka.nvme_added
fi    

weka cluster update --cluster-name="${cluster_name}"

# create compute containers
for vm in ${VMS}; do
    ${ssh_command} ${vm} "if [ ! -f /tmp/compute0.built ]; then \
      weka local setup container --name compute0 --base-port 15000 --cores ${num_compute_containers} \
      --no-frontends --compute-dedicated-cores ${num_compute_containers}  --memory ${compute_memory} --join-ips ${IPS} --core-ids $compute_core_ids; \
      fi; touch /tmp/compute0.built"
done

weka cloud enable
if [ ! -f /tmp/weka.protection ]; then
    weka cluster update --data-drives ${stripe_width} --parity-drives ${protection_level}
    weka cluster hot-spare ${hotspare}
    touch /tmp/weka.protection
fi
weka cluster drive
weka cluster start-io


# verify all the drives are VALID and remove/add drives that are not
#if [ ! -f drives.csv ]; then
#    weka cluster drive --no-header -f csv > drives.csv
#fi
#while IFS="," read -r diskid uuid host nodeid size status lifetime attachment drivestatus; do 
#    if [ "${drivestatus}" != "OK" ]; then
#        weka cluster drive deactivate ${uuid} --force && weka cluster drive remove ${uuid} --force 
#        ${ssh_command} ${host} "reboot"
#        while true; do 
#           command ssh "$@"; [ $? -eq 0 ] && break || sleep 0.5
#        done
#        ${ssh_command} ${host} "nvme=$(ls /dev/nvme*n1); weka cluster drive add ${diskid} ${nvme}"
#    fi
#done < <(tail -n +2 drives.csv)


# create frontend containers
for vm in ${VMS}; do
    ${ssh_command} ${vm} "if [ ! -f /tmp/frontend0.built ]; then \
      sudo weka local setup container --name frontend0 --base-port 16000 --cores ${num_frontend_containers} \
      --frontend-dedicated-cores ${num_frontend_containers} --allow-protocols true --join-ips ${IPS} --core-ids $frontend_core_ids; \ 
      fi; touch /tmp/frontend0.built"
done

sleep 15s

weka cluster process
weka cluster drive
weka cluster container


if [ ! -f /tmp/weka.full_capacity ]; then
    full_capacity=$(weka status -J | jq .capacity.unprovisioned_bytes)
    weka fs group create default
    weka fs create default default "${full_capacity}"B
    touch /tmp/weka.full_capacity
fi

if [ "${set_obs}" == "True" ]; then
    if [ !-f /tmp/weka.set_obs ]; then
        weka fs tier s3 add azure-obs --site local --obs-name default-local --obs-type AZURE --hostname ${obs_name}.blob.core.windows.net \
          --port 443 --bucket ${obs_container_name} --access-key-id ${obs_name} --secret-key ${obs_blob_key} --protocol https --auth-method AWSSignature4
        weka fs tier s3 attach default azure-obs
        tiering_percent=$(echo "${full_capacity} * 100 / ${tiering_ssd_percent}" | bc)
        weka fs update default --total-capacity "${tiering_percent}"B
        touch /tmp/weka.set_obs
    fi
fi

weka alerts mute JumboConnectivity 365d
weka alerts mute UdpModePerformanceWarning 365d

# Check DRIVES are UP
expected_drives=$(( $num_drive_containers * $hosts_num ))
active_drives=$(weka status --json | jq -r '.drives.active')
while [ "${active_drives}" != "${expected_drives}" ]; do
    weka cluster stop-io --force
    weka cluster drive scan
    weka cluster drive activate
    weka cluster start-io
done


# Update status in CycleCloud GUI
jetpack log "Weka cluster is running."
jetpack log "Access cluster at https://$(jetpack config cyclecloud.instance.ipv4):14000"

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

#if [ ! -f /tmp/weka.cluster_created ]; then
#    weka cluster create ${VMS} --host-ips ${IPS} 1> /dev/null 2>& 1 || true
#    touch /tmp/weka.cluster_created
#fi
weka cluster create ${VMS} --host-ips ${IPS} 1> /dev/null 2>& 1 || true


sleep 30s

if [ ! -f /tmp/weka.nvme_added ]; then
    for (( i=0; i<${hosts_num}; i++ )); do
	    for (( d=0; d<${num_drive_containers}; d++ )); do
		    weka cluster drive add ${i} "/dev/nvme${d}"n1
	    done
    done
    touch /tmp/weka.nvme_added
fi    

weka cluster update --cluster-name="${cluster_name}"

# create compute containers
for vm in ${VMS}; do
    ${ssh_command} ${vm} "if [ ! -f /tmp/compute0.built ]; then \
      sudo weka local setup container --name compute0 --base-port 15000 --cores ${num_compute_containers} \
      --no-frontends --compute-dedicated-cores ${num_compute_containers}  --memory ${compute_memory} --join-ips ${IPS}; fi; touch /tmp/compute0.built"
done

weka cloud enable
if [ ! -f /tmp/weka.protection ]; then
    weka cluster update --data-drives ${stripe_width} --parity-drives ${protection_level}
    weka cluster hot-spare ${hotspare}
    touch /tmp/weka.protection
fi
weka cluster start-io

# create frontend containers
for vm in ${VMS}; do
    ${ssh_command} ${vm} "if [ ! -f /tmp/frontend0.built ]; then \
      sudo weka local setup container --name frontend0 --base-port 16000 --cores ${num_frontend_containers} \
      --frontend-dedicated-cores ${num_frontend_containers} --allow-protocols true --join-ips ${IPS}; fi; touch /tmp/frontend0.built"
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
    weka fs tier s3 add azure-obs --site local --obs-name default-local --obs-type AZURE --hostname ${obs_name}.blob.core.windows.net \
      --port 443 --bucket ${obs_container_name} --access-key-id ${obs_name} --secret-key ${obs_blob_key} --protocol https --auth-method AWSSignature4
    weka fs tier s3 attach default azure-obs
    tiering_percent=$(echo "${full_capacity} * 100 / ${tiering_ssd_percent}" | bc)
    weka fs update default --total-capacity "${tiering_percent}"B
fi

weka alerts mute JumboConnectivity 365d
weka alerts mute UdpModePerformanceWarning 365d
echo "completed successfully" > /tmp/weka_clusterization_completion_validation

jetpack log "Weka cluster is running."
jetpack log "Access cluster at https://$(jetpack config cyclecloud.instance.ipv4):14000"

#!/bin/bash
set -ex

# setup CycleCloud variables to find cluster IPs
ccuser=$(jetpack config cyclecloud.config.username)
ccpass=$(jetpack config cyclecloud.config.password)
ccurl=$(jetpack config cyclecloud.config.web_server)
mount_point=$(jetpack config weka.mount_point)
fs=$(jetpack config weka.fs)


# Pick a package manager
if [ "$(which yum)" ]; then
    pkg_cmd=yum
    yum install -y epel-release
else
    pkg_cmd=apt
fi
${pkg_cmd} install -y jq


# Find the mount addresses if deployed by CycleCloud...otherwise use manual entries
if [ "$(jetpack config weka.cycle)" == "True" ]; then
    cluster_name=$(jetpack config weka.cluster_name)
    # Get the list of Weka cluster IPs from CycleCloud
    IPS=$(curl -s -k --user ${ccuser}:${ccpass} "${ccurl}/clusters/${cluster_name}/nodes" \
      | jq -r '.nodes[] |  .PrivateIp' | xargs | sed -e 's/ /,/g')
else
    IPS=$(jetpack config weka.cluster_address)
fi

# Pick a random Weka node from the list of IPs
num_commas=$(echo $IPS | tr -cd , | wc -c )
num_nodes=$(echo "$((num_commas + 1))")
weka_address=$(echo $IPS | cut -d ',' -f $(( ( RANDOM % ${num_nodes} )  + 1 )))


# Create a mount point
mkdir -p ${mount_point}

# Install the WEKA agent on the client machine:
# curl <backend server http address>:14000/dist/v1/install | sh
curl http://${weka_address}:14000/dist/v1/install | sh

# You can mount a stateless or stateful client on the filesystem using UDP. The following is an example of mounting a stateless client: 
# mount -t wekafs -o net=udp <Load balancer DNS name or IP address>/<filesystem name> /mnt/weka

# support for multiple NICs for DPDK mode was added to CC ver 8.7.0 and Slurm project version 3.0.10
version=$(jetpack config slurm.autoscale_version)
if [[ $(echo -e "$version\n3.0.10" | sort -V | head -n1) == "3.0.10" ]] || [[ "$version" == "3.0.10" ]]; then
    echo "Version $version supports DPDK"
    mount -t wekafs -o num_cores=1 ${weka_address}/${fs} ${mount_point}
else
    echo "Version $version does not support DPDK...using UDP mode"
    mount -t wekafs -o net=udp,num_cores=1 ${weka_address}/${fs} ${mount_point}
fi


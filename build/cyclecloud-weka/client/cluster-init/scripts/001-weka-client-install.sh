#!/bin/bash
set -ex

# setup CycleCloud variables to find cluster IPs
ccuser=$(jetpack config cyclecloud.config.username)
ccpass=$(jetpack config cyclecloud.config.password)
ccurl=$(jetpack config cyclecloud.config.web_server)
weka_name=$(jetpack config weka.cluster_name)
mount_point=$(jetpack config weka.mount_point)
fs=$(jetpack config weka.fs)

if [ "$(which yum)" ]; then
    pkg_cmd=yum
else
    pkg_cmd=apt
fi
${pkg_cmd} install -y jq


# Find a Weka frontend to mount
weka=$(curl -s -k --user ${ccuser}:${ccpass} "${ccurl}/clusters/${weka_name}/nodes" | jq -r '.nodes[] | select(.Name=="weka-1") | .PrivateIp')

# Create a mount point
mkdir -p ${mount_point}

# Install the WEKA agent on the client machine:
# curl <backend server http address>:14000/dist/v1/install | sh
curl http://${weka}:14000/dist/v1/install | sh

# You can mount a stateless or stateful client on the filesystem using UDP. The following is an example of mounting a stateless client: 
# mount -t wekafs -o net=udp <Load balancer DNS name or IP address>/<filesystem name> /mnt/weka
mount -t wekafs -o net=udp,num_cores=1 ${weka}/${fs} ${mount_point}
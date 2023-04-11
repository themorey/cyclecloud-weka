#!/usr/bin/bash
set -ex
## Map CC Jetpack variables to Weka Terraform variables
export ofed_version=$(jetpack config weka.ofed_version)
export hosts_num=$(jetpack config weka.num_hosts)
export weka_version=$(jetpack config weka.version)
#export apt_private_repo=$(jetpack config weka.)
export apt_repo_url=$(jetpack config weka.apt_repo_url)
export weka_token=$(jetpack config weka.weka_io_token)
export hotspare=$(jetpack config weka.hotspare)
export install_ofed_url=$(jetpack config weka.install_ofed_url)
export ofed_version=$(jetpack config weka.ofed_version)
export install_weka_url=$(jetpack config weka.install_weka_url)
export protection_level=$(jetpack config weka.protection_level)
export stripe_width=$(jetpack config weka.stripe_width)
export traces_per_ionode=$(jetpack config weka.traces_per_ionode)
export prefix=$(jetpack config weka.prefix)
export cluster_name=$(jetpack config cyclecloud.cluster.name)
export user=$(jetpack config cyclecloud.cluster.user.name)
export set_obs=$(jetpack config weka.set_obs_integration)
export obs_name=$(jetpack config weka.storage_account)
export obs_container_name=$(jetpack config weka.obs_name)
export obs_blob_key=$(jetpack config weka.storage_key)
export tiering_ssd_percent=$(jetpack config weka.tiering_percent)
export private_key=$(jetpack config weka.private_key  | \
  sed 's/-----BEGIN RSA PRIVATE KEY----- /-----BEGIN RSA PRIVATE KEY----- \n/g' | \
  sed 's/ -----END RSA PRIVATE KEY-----/\n-----END RSA PRIVATE KEY-----/g')
if [ "$(jetpack config azure.metadata.compute.vmSize)"=="Standard_L8s_v3" ]; then
  export num_drive_containers=1
  export num_compute_containers=1
  export num_frontend_containers=1
  export compute_memory="31GB"
else
  export num_drive_containers=2
  export num_compute_containers=4
  export num_frontend_containers=1
  export compute_memory="72GB"
fi


if [ ! -f /tmp/clusterinit.runonce ]; then
  # add private key to ssh config
  if [ ! -f /root/.ssh/weka.pem ]; then
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/g' /etc/ssh/sshd_config
    systemctl restart sshd.service
    echo "${private_key}" > /root/.ssh/weka.pem
    chmod 600 /root/.ssh/weka.pem

    cat > /root/.ssh/config <<EOL
Host *
  User root
  IdentityFile /root/.ssh/weka.pem
EOL
    # Create public key and add to authorized_keys file
    ssh-keygen -f /root/.ssh/weka.pem -y > /root/.ssh/weka.pub
    cat /root/.ssh/weka.pub >> /root/.ssh/authorized_keys
  fi

  apt install net-tools -y

  # set apt private repo
  #if [ ! -z "${apt_repo_url}" ]; then
  #  echo "adding ${apt_repo_url} to /etc/apt/sources.list"
  #  mv /etc/apt/sources.list /etc/apt/sources.list.bak
  #  echo "deb ${apt_repo_url} focal main restricted universe" > /etc/apt/sources.list
  #fi

  INSTALLATION_PATH="/tmp/weka"
  mkdir -p $INSTALLATION_PATH

  # install OFED if needed (Azure HPC images have OFED included)
  if [ ! "$(which ofed_info)" ]; then
    if [ "${ofed_version}" ]; then
      OFED_NAME=ofed-${ofed_version}
      if [ "${install_ofed_url}" ]; then
        wget ${install_ofed_url} -O $INSTALLATION_PATH/$OFED_NAME.tgz
      else
        wget http://content.mellanox.com/ofed/MLNX_OFED-${ofed_version}/MLNX_OFED_LINUX-${ofed_version}-ubuntu20.04-x86_64.tgz -O $INSTALLATION_PATH/$OFED_NAME.tgz
      fi
      tar xf $INSTALLATION_PATH/$OFED_NAME.tgz --directory $INSTALLATION_PATH --one-top-level=$OFED_NAME
      cd $INSTALLATION_PATH/$OFED_NAME/*/
      ./mlnxofedinstall --without-fw-update --add-kernel-support --force
      /etc/init.d/openibd restart
    fi
  fi


  apt update -y
  apt install -y jq

  # Format and mount data disk for logs and traces (Not the NVMe)
  if [ ! "$( df -h | grep -i "/opt/weka" )" ]; then
    device=$(lsblk --fs --json | jq -r '.blockdevices[] | select(.children == null and .fstype == null) | .name' | grep -i sd)
    echo $device
    wekaiosw_device=/dev/${device}
    mkfs.ext4 -L wekaiosw $wekaiosw_device || exit 1
    mkdir -p /opt/weka || exit 1
    mount $wekaiosw_device /opt/weka || exit 1
    echo "LABEL=wekaiosw /opt/weka ext4 defaults 0 2" >>/etc/fstab
  fi


  # install weka
  WEKA_NAME=${weka_version}
  if [ "${weka_token}" ]; then
    curl https://${weka_token}@get.prod.weka.io/dist/v1/install/${weka_version}/${weka_version} | sh
  elif [ "${install_weka_url}" ]; then
    wget --auth-no-challenge ${install_weka_url} -O $INSTALLATION_PATH/$WEKA_NAME.tar
    tar -xvf $INSTALLATION_PATH/$WEKA_NAME.tar --directory $INSTALLATION_PATH --one-top-level=$WEKA_NAME
    cd $INSTALLATION_PATH/$WEKA_NAME/weka-$WEKA_NAME
    ./install.sh
  else
    exit 1
  fi

  rm -rf $INSTALLATION_PATH

  weka local stop
  weka local rm default --force
  weka local setup container --name drives0 --base-port 14000 --cores ${num_drive_containers} --no-frontends --drives-dedicated-cores ${num_drive_containers}

  #curl ${clusterization_url}?code="${function_app_default_key}" -H "Content-Type:application/json"  -d "{\"name\": \"$HOSTNAME\"}" > /tmp/clusterize.sh
  #chmod +x /tmp/clusterize.sh
  #/tmp/clusterize.sh > /tmp/cluster_creation.log 2>&1
  touch /tmp/clusterinit.runonce
  chmod +x $CYCLECLOUD_SPEC_PATH/files/clusterize.sh
fi

if [ "$(jetpack config cyclecloud.node.name)" == "weka-1" ]; then
  /bin/bash $CYCLECLOUD_SPEC_PATH/files/clusterize.sh
fi
# call the script to build the cluster
#/bin/bash $CYCLECLOUD_SPEC_PATH/files/clusterize.sh

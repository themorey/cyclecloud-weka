
Weka
========

This project configures a Weka storage cluster in Azure using CycleCloud.  This project was adapted from a Weka produced Terraform project hosted here:  [Weka Terraform Project](https://github.com/weka/terraform-azure-weka)

Weka is a highly performant and scalable storage solution that is supported in Azure on LsV3 VMs using local NVMe disks.  It also supports tiering data to Blob to optimize costs. See the [Weka documentation site](https://docs.weka.io/overview/about) for an overview.

## Pre-requisites

#### 1.  PPG
You will need to manually configure an Azure [Promixity Placement Group](https://learn.microsoft.com/en-us/azure/virtual-machines/linux/proximity-placement-groups).  A PPG is "a logical grouping used to make sure that Azure compute resources are physically located close to each other. Proximity placement groups are useful for workloads where low latency is a requirement."   Following is an example Azure CLI command to create a PPG (substitute your own values for `--name` and `--resource-group`):

```
      az ppg create \
        --name wekaPPG \
        --resource-group myPPGGroup \
        --location eastus \
        --intent-vm-sizes Standard_L8s_v3 Standard_L16s_v3 Standard_L32s_v3 Standard_L48s_v3 Standard_L64s_v3 \
          Standard_L8as_v3 Standard_L16as_v3 Standard_L32as_v3 Standard_L48as_v3 Standard_L64as_v3
```

You will need to use the `Resource_ID` of the PPG in the CycleCloud configuration.  You can get that from the Azure CLI as follows:

```
      az ppg show --name wekaPPG --resource-group myPPGGroup --query "id"
```


#### 2. SSH PRIVATE KEY:  
You will also need to provide a Private SSH key for Weka nodes to authenticate to each other during the initial configuration.  The following steps should be followed to create the Private Key:

```
    ssh-keygen -m PEM -f $HOME/.ssh/weka.pem
    cat $HOME/.ssh/weka.pem
    -----BEGIN RSA PRIVATE KEY-----
    <content>
    -----END RSA PRIVATE KEY-----
```
You will need to copy all the output of the `cat $HOME/.ssh/weka.pem` including the `-----BEGIN RSA PRIVATE KEY-----` and `-----END RSA PRIVATE KEY-----` and paste it into the CycleCloud settings (Weka Settings > General Settings > SSH Private Key).


# INSTALLATION
Below are instructions to clone the project from github and add the Weka project and template:

```
git clone https://github.com/themorey/cyclecloud-weka.git
cd cyclecloud-weka
cyclecloud project upload <cyclecloud_locker_name>
cyclecloud import_template -f templates/cyclecloud=weka.txt
```

An explanation of the [Weka config options](https://github.com/weka/terraform-azure-weka#inputs) can be found on their Github page for the Terraform project.

During installation all but 1 node will turn GREEN in CycleCloud UI and move to _READY_ state.  The "clusterization" via the `clusterize.sh` script is happening on the remaining VM (named `weka-1` in the UI) that will be in _PREPARING_ state.  You can SSH to this VM and tail the log file with command `tail -f /opt/cycle/jetpack/logs/cluster-init/cyclecloud-weka/default/scripts/001-user-data.sh.out` to follow its progress.

---
**NOTE**

Cluster startup time is ~15 minutes and some recoverable errors may display in CycleCloud UI during that time.  Review the `001-user-data.sh.out` log file on `weka-1` to determine the cause of the error.

---

### Client install and mount
An extended Slurm template is included in this repository with the option for choose a CycleCloud deployed Weka filesystem to configure and mount on the nodes:
```
cyclecloud import_template -f templates/slurm-weka.txt
```
Note: The Slurm template is a modified version of the official one [here](https://github.com/Azure/cyclecloud-slurm/blob/2.7.0/templates/slurm.txt)


You should be able to create a new "Weka" cluster in the Azure CycleCloud User Interface. Once this has been created you can create start the Slurm-Weka cluster and, in the configuration, select the new file system to be used.

### Extending a template to use a Weka filesystem
Additional cluster templates (ie. PBSPro, GridEngine, LSF) can be updated to install and mount a Weka filesystem with the additions below.

The node default section will need the following additions:

```
[[[configuration]]]
# Weka mount options 
weka.cluster_name = ${ifThenElse(CycleWeka, WekaClusterName, undefined)} 
weka.cluster_address = ${ifThenElse(CycleWeka, undefined, WekaClusterAddress)} 
weka.mount_point = $WekaMountPoint 
weka.fs = $WekaFileSystem 
weka.cycle = $CycleWeka
[[[cluster-init cyclecloud-weka:client]]]
```

These variables (WekaClusterName, WekaMountPoint and WekaFileSystem) are parameterized, meaning they are configurable via the CycleCloud GUI, and given an additional Weka Setttings configuration section by appending the following to the template:

```
[parameters Weka Cluster Info]
Order = 17
Description = "Add Weka cluster information for mounting"

     [[parameter CycleWeka]] 
     HideLabel = true 
     DefaultValue = false 
     Widget.Plugin = pico.form.BooleanCheckBox 
     Widget.Label = CycleCloud deployed Weka? 
   
     [[parameter WekaClusterName]] 
     Label = Weka Cluster 
     Description = Name of the Weka cluster to connect to. This cluster should be orchestrated by the same CycleCloud Server 
     Required = True 
     Config.Plugin = pico.form.QueryDropdown 
     Config.Query = select ClusterName as Name from Cloud.Node where Cluster().IsTemplate =!= True && ClusterInitSpecs["cyclecloud-weka:default"] isnt undefined 
     Config.SetDefault = false 
     Conditions.Excluded := CycleWeka isnt true 
  
     [[parameter WekaClusterAddress]] 
     Label = Weka Addresses 
     Description = Enter the Load Balancer IP or a list of comma separated Weka Node IPs (ie. 10.0.0.4, 10.0.0.5, 10.0.0.6, 10.0.0.7, 10.0.0.8, 10.0.0.9 ) 
     Required = True 
     Config.ParameterType = String 
     Config.SetDefault = false 
     Conditions.Excluded := CycleWeka is true 
      
     [[parameter WekaMountPoint]] 
     Label = Weka Mount Point 
     Description = The local mount point to mount the Weka cluster. 
     DefaultValue = /mnt/weka 
     Required = True 
      
     [[parameter WekaFileSystem]] 
     Label = Weka FS Name 
     Description = The Weka FileSystem name to mount 
     DefaultValue = "default" 
     Required = True
```
---
**NOTE**

The default FileSystem created by Weka is name `default`.

---
# Contributing

This project welcomes contributions and suggestions.  Most contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit https://cla.microsoft.com.

When you submit a pull request, a CLA-bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., label, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.


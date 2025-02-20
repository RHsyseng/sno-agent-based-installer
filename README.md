# SNO with OpenShift Agent Based Installer

## Overview

Note: This repo only works for OpenShift 4.12+.
Sister repo for [Multiple Nodes OpenShift](https://github.com/borball/mno-with-abi):

This repo provides set of helper scripts:

- sno-iso: Used to generate bootable ISO image based on agent based installer, some operators and node tunings for 
  [Telco RAN](https://docs.openshift.com/container-platform/4.16/scalability_and_performance/telco_ref_design_specs/telco-ref-design-specs-overview.html) 
  are enabled as day 1 operations.
- sno-install: Used to mount the ISO image generated by sno-iso to BMC console as virtual media with Redfish API, and boot 
  the node from the image to trigger the SNO installation. Tested on HPE, ZT, Dell and KVM with Sushy tools, 
  other servers may/not work depending on the Redfish version, please create issues if you see any issue.
- sno-day2: Most of the operators and tunings required by vDU applications are enabled as day1, but some of them can 
  only be done as [day2 configurations](templates/day2).
- sno-ready: Used to validate if the SNO cluster has all required configuration and tunings defined in the configuration.

## Dependencies
Some software and tools are required to be installed before running the scripts:

- nmstatectl: sudo dnf install /usr/bin/nmstatectl -y
- yq: https://github.com/mikefarah/yq#install
- jinja2: pip3 install jinja2-cli, pip3 install jinja2-cli[yaml]

## Configuration

Prepare config.yaml to fit your lab situation, here is an example:

```yaml
cluster:
  domain: outbound.vz.bos2.lab
  name: sno148
  #optional: set ntps servers 
  #ntps:
    #- 0.rhel.pool.ntp.org
    #- 1.rhel.pool.ntp.org
host:
  hostname: sno148.outbound.vz.bos2.lab
  interface: ens1f0
  mac: b4:96:91:b4:9d:f0
  ipv4:
    enabled: true
    dhcp: false
    ip: 192.168.58.48
    dns: 
      - 192.168.58.15
    gateway: 192.168.58.1
    prefix: 25
    machine_network_cidr: 192.168.58.0/25
    #optional, default 10.128.0.0/14
    #cluster_network_cidr: 10.128.0.0/14
    #optional, default 23
    #cluster_network_host_prefix: 23
  ipv6:
    enabled: false
    dhcp: false
    ip: 2600:52:7:58::48
    dns: 
      - 2600:52:7:58::15
    gateway: 2600:52:7:58::1
    prefix: 64
    machine_network_cidr: 2600:52:7:58::/64
    #optional, default fd01::/48
    #cluster_network_cidr: fd01::/48
    #optional, default 64
    #cluster_network_host_prefix: 64
  vlan:
    enabled: false
    name: ens1f0.58
    id: 58
  disk: /dev/nvme0n1

cpu:
  isolated: 2-31,34-63
  reserved: 0-1,32-33

proxy:
  enabled: false
  http:
  https:
  noproxy:

pull_secret: ./pull-secret.json
ssh_key: /root/.ssh/id_rsa.pub

bmc:
  address: 192.168.13.148
  username: Administrator
  password: dummy

iso:
  address: http://192.168.58.15/iso/agent-148.iso

```

By default, following tunings or operators will be enabled during day1(installation phase):

- Workload partitioning
- SNO boot accelerate
- Kdump service/config
- crun(4.13+)
- rcu_normal(4.14+)
- sriov_kernel: (4.14+)
- sync_time_once (4.14+)
- Local Storage Operator
- PTP Operator
- SR-IOV Network Operator

You can turn on/off the day1 operations and specify the desired versions in the config file under section 
[day1](samples/usage.md#day1).

In some case you may want to include more custom resources during the installation, you can put those custom resources 
in any folder and set the path in day1.extra_manifests in the config.yaml, the sno-iso script will copy 
and include those inside the ISO image. The paths of the day1.extra_manifests can support environment variables like 
${HOME}, ${OCP_Y_VERSION}, ${OCP_Z_VERSION} etc, an example:

```yaml
day1:
  extra_manifests:
    - ${HOME}/1
    - ${HOME}/2
    - $OCP_Y_VERSION
```

Get other sample [configurations](samples/usage.md).

## Generate ISO image

You can run sno-iso.sh [config file] to generate a bootable ISO image so that you can boot from BMC console to install SNO. By default stable-4.14 will be downloaded and installed if not specified.

```
# ./sno-iso.sh -h
Usage: ./sno-iso.sh [config file] [ocp version]
config file and ocp version are optional, examples:
- ./sno-iso.sh sno130.yaml              equals: ./sno-iso.sh sno130.yaml stable-4.14
- ./sno-iso.sh sno130.yaml 4.14.33

Prepare a configuration file by following the example in config.yaml.sample           
-----------------------------------
# content of config.yaml.sample
...
-----------------------------------
Example to run it: ./sno-iso.sh config-sno130.yaml   

```

## Boot node from ISO image

Once you generate the ISO image, you can boot the node from the image with your preferred way, OCP will be installed automatically.

A helper script sno-install.sh is available in this repo to boot the node from ISO and trigger the installation automatically, assume you have an HTTP server (http://192.168.58.15/iso in our case) to host the ISO image.

Define your BMC info and ISO location in the configuration file first:

```yaml
bmc:
  address: 192.168.14.130
  username: Administrator
  password: Redhat123!
  kvm_uuid:

iso:
  address: http://192.168.58.15/iso/agent-130.iso

```

Then run it:

```
# ./sno-install.sh 
Usage: ./sno-install.sh <cluster-name>
If <cluster-name> is not present, it will install the newest cluster created by sno-iso
Example: ./sno-install.sh
Example: ./sno-install.sh sno130

```

## Day2 operations

Some CRs are not supported in installation phase as day1 operations, those can/shall be done as day 2 operations
once SNO is deployed.

```
# ./sno-day2.sh -h
Usage: ./sno-day2.sh <cluster-name>
If <cluster-name> is not present, it will run day2 ops towards the newest cluster installed by sno-install
Example: ./sno-day2.sh
Example: ./sno-day2.sh sno130

```

You can turn on/off day2 operation with configuration in section [day2](samples/usage.md#day2).

## Validation

After applying all day2 operations, node may be rebooted once, check if all required tunings and operators are in placed:

```
# ./sno-ready.sh sno130
Will run cluster config validation towards the cluster sno130 with config: /root/sno-4.14/instances/sno130/config-resolved.yaml
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.14.26   True        False         89d     Cluster version is 4.14.26

NAME                          STATUS   ROLES                         AGE   VERSION
sno130.outbound.vz.bos2.lab   Ready    control-plane,master,worker   97d   v1.27.13+e709aa5

NAME                                                      AGE
cluster-logging.openshift-logging                         97d
intel-device-plugins-operator.openshift-operators         49d
intel-device-plugins-operator.openshiftoperators          49d
local-storage-operator.openshift-local-storage            97d
ptp-operator.openshift-ptp                                97d
sriov-fec.vran-acceleration-operators                     97d
sriov-network-operator.openshift-sriov-network-operator   97d

Checking node:
[+]Node                                                        ready

Checking cluster operators:
[+]cluster operator authentication                             healthy
[+]cluster operator cloud-controller-manager                   healthy
[+]cluster operator cloud-credential                           healthy
[+]cluster operator config-operator                            healthy
[+]cluster operator dns                                        healthy
[+]cluster operator etcd                                       healthy
[+]cluster operator ingress                                    healthy
[+]cluster operator kube-apiserver                             healthy
[+]cluster operator kube-controller-manager                    healthy
[+]cluster operator kube-scheduler                             healthy
[+]cluster operator kube-storage-version-migrator              healthy
[+]cluster operator machine-approver                           healthy
[+]cluster operator machine-config                             healthy
[+]cluster operator marketplace                                healthy
[+]cluster operator monitoring                                 healthy
[+]cluster operator network                                    healthy
[+]cluster operator node-tuning                                healthy
[+]cluster operator openshift-apiserver                        healthy
[+]cluster operator openshift-controller-manager               healthy
[+]cluster operator operator-lifecycle-manager                 healthy
[+]cluster operator operator-lifecycle-manager-catalog         healthy
[+]cluster operator operator-lifecycle-manager-packageserver   healthy
[+]cluster operator service-ca                                 healthy

Checking all pods:
[-]Some pods are failing or creating.
NAMESPACE                                          NAME                                                              READY   STATUS      RESTARTS         AGE
openshift-kube-apiserver                           installer-11-sno130.outbound.vz.bos2.lab                          0/1     Error       0                90d
openshift-kube-apiserver                           installer-12-sno130.outbound.vz.bos2.lab                          0/1     Error       0                90d
openshift-kube-controller-manager                  installer-4-sno130.outbound.vz.bos2.lab                           0/1     Error       0                97d
openshift-kube-scheduler                           installer-4-sno130.outbound.vz.bos2.lab                           0/1     Error       0                97d
openshift-kube-scheduler                           installer-6-sno130.outbound.vz.bos2.lab                           0/1     Error       0                97d

Checking required machine configs:
[+]mc 01-master-cpu-partitioning                               exists
[+]mc 06-kdump-enable-master                                   exists
[+]mc container-mount-namespace-and-kubelet-conf-master        exists
[+]mc 04-accelerated-container-startup-master                  not exist
[+]mc 99-crio-disable-wipe-master                              exists
[+]mc 08-set-rcu-normal-master                                 exists
[+]mc 07-sriov-related-kernel-args-master                      exists
[+]mc 99-sync-time-once-master                                 exists

Checking machine config pool:
[+]mcp master                                                  updated and not degraded

Checking required performance profile:
[+]PerformanceProfile sno-perfprofile exists.
[+]topologyPolicy is restricted
[+]realTimeKernel is enabled

Checking required tuned:
[+]Tuned performance-patch                                     exists

Checking SRIOV operator status:
[+]sriovnetworknodestate sync status                           succeeded

Checking PTP operator status:
[+]Ptp linuxptp-daemon                                         ready
[-]PtpConfig                                                   not exist

Checking chronyd.service:
[+]chronyd service                                             inactive
[+]chronyd service                                             not enabled

Checking openshift monitoring:
[+]AlertManager                                                not enabled
[+]PrometheusK8s retention                                     24h
[+]Telemeter Client                                            not enabled

Checking openshift capabilities:
[+](cluster capability)operator node-tuning                    enabled
[+](cluster capability)operator console                        disabled
[+](cluster capability)operator marketplace                    enabled

Checking network diagnostics:
[+]Network diagnostics                                         disabled

Checking Operator hub:
[-]Catalog community-operators                                 not disabled
[-]Catalog redhat-marketplace                                  not disabled

Checking /proc/cmdline:
[+]systemd.cpu_affinity presents: systemd.cpu_affinity=0,1,32,33
[+]isolcpus presents: isolcpus=managed_irq,2-31,34-63
[+]Isolated cpu in cmdline: 2-31,34-63 matches with the ones in performance profile: 2-31,34-63
[+]Reserved cpu in cmdline: 0,1,32,33 matches with the ones in performance profile: 0-1,32-33

Checking RHCOS kernel:
[+]Node kernel                                                 realtime

Checking kdump.service:
[+]kdump service                                               active
[+]kdump service                                               enabled
[+]olm collect-profiles-config: disabled                       true

Checking InstallPlans:
[-]InstallPlans below are not approved yet.
openshift-local-storage            install-lltr9   local-storage-operator.v4.14.0-202405070741   Manual      false
openshift-logging                  install-j2d4v   cluster-logging.v5.9.2                        Manual      false
openshift-ptp                      install-7swbx   ptp-operator.v4.14.0-202405070741             Manual      false
openshift-sriov-network-operator   install-dnfp4   sriov-network-operator.v4.14.0-202405070741   Manual      false
vran-acceleration-operators        install-swxr4   sriov-fec.v2.8.0                              Manual      false

Checking container runtime:
[+]Container runtime                                           crun
[-]cgroup                                                      not v2

Completed the checking.
```


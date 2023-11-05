#!/bin/bash
# 
# Helper script to validate if the SNO node contains all the necessary tunings
# usage: ./sno-ready.sh
#

if ! type "yq" > /dev/null; then
  echo "Cannot find yq in the path, please install yq on the node first. ref: https://github.com/mikefarah/yq#install"
fi

if ! type "jinja2" > /dev/null; then
  echo "Cannot find jinja2 in the path, will install it with pip3 install jinja2-cli and pip3 install jinja2-cli[yaml]"
  pip3 install --user jinja2-cli
  pip3 install --user jinja2-cli[yaml]
fi

usage(){
	echo "Usage: $0 [config.yaml]"
  echo "Example: $0 config-sno130.yaml"
}

if [ $# -lt 1 ]
then
  usage
  exit
fi

if [[ ( $@ == "--help") ||  $@ == "-h" ]]
then 
  usage
  exit
fi

config_file=$1;

cluster_name=$(yq '.cluster.name' $config_file)
cluster_workspace=$cluster_name
export KUBECONFIG=$cluster_workspace/auth/kubeconfig

ocp_release=$(oc version -o json|jq -r '.openshiftVersion')
ocp_y_version=$(echo $ocp_release | cut -d. -f 1-2)

NC='\033[0m' # No Color

info(){
  printf  $(tput setaf 2)"%-62s %-10s"$(tput sgr0)"\n" "[+]""$@"
}

warn(){
  printf  $(tput setaf 3)"%-62s %-10s"$(tput sgr0)"\n" "[-]""$@"
}

check_node(){
  echo -e "\n${NC}Checking node:"
  if [ $(oc get node -o jsonpath='{..conditions[?(@.type=="Ready")].status}') = "True" ]; then
    info "Node" "ready"
  else
    warn "Node" "not ready"
  fi
}

export_address(){
  export address=$(oc get node -o jsonpath='{..addresses[?(@.type=="InternalIP")].address}')
}

check_pods(){
  echo -e "\n${NC}Checking all pods:"
  if [ $(oc get pods -A |grep -vE "Running|Completed" |wc -l) -gt 1 ]; then
    warn "Some pods are failing or creating."
    oc get pods -A |grep -vE "Running|Completed"
  else
    info "No failing pods."
  fi
}

check_co(){
  echo -e "\n${NC}Checking cluster operators:"
  for name in $(oc get co -o jsonpath={..metadata.name}); do
    local progressing=$(oc get co $name -o jsonpath='{..conditions[?(@.type=="Progressing")].status}')
    local available=$(oc get co $name -o jsonpath='{..conditions[?(@.type=="Available")].status}')
    local degraded=$(oc get co $name -o jsonpath='{..conditions[?(@.type=="Degraded")].status}')
    if [ "$available" = "True" -a "$progressing" = "False" -a "$degraded" = "False" ]; then
      info "cluster operator $name " "healthy"
    else
      warn "cluster operator $name " "unhealthy"
    fi
  done
}

check_mc(){
  echo -e "\n${NC}Checking required machine configs:"
  
  if [ "false" = "$(yq '.day1.workload_partition' $config_file)" ]; then
    warn "workload_partition is not enabled in $config_file"
  else
    if [ $(oc get mc |grep 02-master-workload-partitioning | wc -l) -eq 1 ]; then
      info "mc 02-master-workload-partitioning" "exists"
    else
      warn "mc 02-master-workload-partitioning" "not exist"
    fi
  fi

  if [ "false" = "$(yq '.day1.kdump.enabled' $config_file)" ]; then
    warn "kdump service is not enabled in $config_file"
  else
    if [ $(oc get mc |grep 06-kdump-enable-master | wc -l) -eq 1 ]; then
      info "mc 06-kdump-enable-master" "exists"
    else
      warn "mc 06-kdump-enable-master" "not exist"
    fi
  fi

  if [ "true" = "$(yq '.day1.kdump.blacklist_ice' $config_file)" ]; then
    if [ $(oc get mc |grep 05-kdump-config-master | wc -l) -eq 1 ]; then
      info "mc 05-kdump-config-master" "exists"
    else
      warn "mc 05-kdump-config-master" "not exist"
    fi
  else
    warn "kdump blacklist_ice is not enabled in $config_file"
  fi

  if [ "false" = "$(yq '.day1.boot_accelerate' $config_file)" ]; then
    warn "boot_accelerate is not enabled in $config_file"
  else
    if [ $(oc get mc |grep container-mount-namespace-and-kubelet-conf-master | wc -l) -eq 1 ]; then
      info "mc container-mount-namespace-and-kubelet-conf-master" "exists"
    else
      warn "mc container-mount-namespace-and-kubelet-conf-master" "not exist"
    fi

    if [ "4.12" = "$ocp_y_version" ] || [ "4.13" = "$ocp_y_version" ]; then
      if [ $(oc get mc |grep 04-accelerated-container-startup-master | wc -l) -eq 1 ]; then
        info "mc 04-accelerated-container-startup-master" "exists"
      else
        warn "mc 04-accelerated-container-startup-master" "not exist"
      fi
    else
      if [ $(oc get mc |grep 04-accelerated-container-startup-master | wc -l) -eq 1 ]; then
        warn "mc 04-accelerated-container-startup-master" "exists"
      else
        info "mc 04-accelerated-container-startup-master" "not exist"
      fi
    fi

    if [ $(oc get mc |grep 99-crio-disable-wipe-master | wc -l) -eq 1 ]; then
      info "MachineConfig 99-crio-disable-wipe-master" "exists"
    else
      warn "MachineConfig 99-crio-disable-wipe-master" "not exist"
    fi
  fi

}

check_mcp(){
  echo -e "\n${NC}Checking machine config pool:"
  updated=$(oc get mcp master -o jsonpath='{..conditions[?(@.type=="Updated")].status}')
  updating=$(oc get mcp master -o jsonpath='{..conditions[?(@.type=="Updating")].status}')
  degraded=$(oc get mcp master -o jsonpath='{..conditions[?(@.type=="Degraded")].status}')
  if [ $updated = "True" -a $updating = "False" -a $degraded = "False" ]; then
    info "mcp master" "updated and not degraded"
  else
    warn "mcp master" "updating or degraded"
  fi
}

check_pp(){
  echo -e "\n${NC}Checking required performance profile:"

  if [ "false" = "$(yq '.day2.performance_profile.enabled' $config_file)" ]; then
    warn "performance profile:" "disabled"
  else
    pp=$(yq '.day2.performance_profile.name //"openshift-node-performance-profile"' $config_file)
    
    if [ $(oc get performanceprofiles |grep $pp | wc -l) -eq 1 ]; then
      info "PerformanceProfile $pp exists."
      check_pp_detail
    else
      warn "PerformanceProfile $pp is not existing."
    fi
  fi
}

check_pp_detail(){
  if [ $(oc get performanceprofile -o jsonpath={..topologyPolicy}) = "single-numa-node" ]; then
    info "topologyPolicy is single-numa-node"
  else
    warn "topologyPolicy is not single-numa-node"
  fi
  if [ $(oc get performanceprofile -o jsonpath={..realTimeKernel.enabled}) = "true" ]; then
    info "realTimeKernel is enabled"
  else
    warn "realTimeKernel is not enabled"
  fi
}


check_tuned(){
  echo -e "\n${NC}Checking required tuned:"

  if [ "false" = "$(yq '.day2.tuned_profile.enabled' $config_file)" ]; then
    warn "Tuned performance patch:" "disabled"
  else   
    if [ $(oc get tuned -n  openshift-cluster-node-tuning-operator performance-patch|grep performance-patch | wc -l) -eq 1 ]; then
      info "Tuned performance-patch" "exists"
    else
      warn "Tuned performance-patch" "not exist"
    fi
  fi

  if [ "true" = "$(yq '.day2.tuned_profile.kdump' $config_file)" ]; then
    if [ $(oc get tuned -n  openshift-cluster-node-tuning-operator performance-patch-kdump-setting|grep performance-patch-kdump-setting | wc -l) -eq 1 ]; then
      info "Tuned performance-patch-kdump-setting" "exists"
    else
      warn "Tuned performance-patch-kdump-setting" "not exist"
    fi
  fi

}

check_sriov(){
  echo -e "\n${NC}Checking SRIOV operator status:"

  if [ "false" = "$(yq '.day1.operators.sriov' $config_file)" ]; then
    warn "SR-IOV operator" "disabled"
  else   
    if [ $(oc get sriovnetworknodestate -n openshift-sriov-network-operator -o jsonpath={..syncStatus}) = "Succeeded" ]; then
      info "sriovnetworknodestate sync status" "succeeded"
    else
      warn "sriovnetworknodestate sync status" "not succeeded"
    fi
  fi
}

check_ptp(){
  echo -e "\n${NC}Checking PTP operator status:"
  if [ "false" = "$(yq '.day1.operators.ptp' $config_file)" ]; then
    warn "PTP operator" "disabled"
  else   
    if [ $(oc get daemonset -n openshift-ptp linuxptp-daemon -o jsonpath={.status.numberReady}) -eq 1 ]; then
      info "Ptp linuxptp-daemon" "ready"
      check_ptpconfig
    else
      warn "Ptp linuxptp-daemon" "not ready"
    fi
  fi
}

check_ptpconfig(){
  if [ "ordinary" = "$(yq '.day2.ptp.ptpconfig' $config_file )" ] || [ "boundary" = "$(yq '.day2.ptp.ptpconfig' $config_file )" ]; then
    if [ $(oc get ptpconfig -n openshift-ptp |grep -v NAME |wc -l) -eq 1 ]; then
      info "PtpConfig" "exists"
      if [ $(oc get ptpconfig -n openshift-ptp -o jsonpath={..ptpSchedulingPolicy}) = "SCHED_FIFO" ]; then
        info "PtpConfig SchedulingPolicy" "SCHED_FIFO"
      else
        warn "PtpConfig SchedulingPolicy" "not SCHED_FIFO"
      fi
      if [ $(oc get ptpconfig -n openshift-ptp -o jsonpath={..ptpSchedulingPriority}) = "10" ]; then
        info "PtpConfig ptpSchedulingPriority" "10"
      else
        warn "PtpConfig SchedulingPolicy" "not 10"
      fi
    else
      warn "PtpConfig" "not exist"
    fi
  fi

}

check_monitoring(){
  echo -e "\n${NC}Checking openshift monitoring:"
  if [ "false" = "$(yq '.day2.cluster_monitor_tuning' $config_file)" ]; then
    warn "cluster_monitor_tuning is not enabled in $config_file"
  else
    if [ $(oc get configmap -n openshift-monitoring cluster-monitoring-config -o jsonpath={.data.config\\.yaml} |yq e '.grafana.enabled' -) = "false" ]; then
      info "Grafana" "not enabled"
    else
      warn "Grafana" "enabled"
    fi
    if [ $(oc get configmap -n openshift-monitoring cluster-monitoring-config -o jsonpath={.data.config\\.yaml} |yq e '.alertmanagerMain.enabled' -) = "false" ]; then
      info "AlertManager" "enabled"
    else
      warn "AlertManager" "enabled"
    fi
    if [ $(oc get configmap -n openshift-monitoring cluster-monitoring-config -o jsonpath={.data.config\\.yaml} |yq e '.prometheusK8s.retention' -) = "24h" ]; then
      info "PrometheusK8s retention" "24h"
    else
      warn "PrometheusK8s retention" "not 24h"
    fi
  fi
}

check_capabilities(){
  echo -e "\n${NC}Checking openshift capabilities:"

  #only check when capabilities are not specified in the config file
  #for others we assume it is not vDU case, and will skip the check
  if [ -z "$(yq '.cluster.capabilities // ""' $config_file)" ]; then
    check_co_enabled "marketplace"
    check_co_enabled "node-tuning"
    check_co_disabled "console"
  fi
}

check_co_enabled(){
  local name=$1
  oc get co $name 1>/dev/null 2>/dev/null

  if [ $? == 0 ]; then
    info "(cluster capability)operator $name " "enabled"
  else
    warn "(cluster capability)operator $name " "disabled"
  fi
}

check_co_disabled(){
  local name=$1
  oc get co $name 1>/dev/null 2>/dev/null
  if [ $? == 1 ]; then
    info "(cluster capability)operator $name " "disabled"
  else
    warn "(cluster capability)operator $name " "disabled"
  fi
}


check_network_diagnostics(){
  echo -e "\n${NC}Checking network diagnostics:"
  if [ "false" = "$(yq '.day2.disable_network_diagnostics' $config_file)" ]; then
    warn "disable_network_diagnostics is not enabled in $config_file"
  else  
    if [ $(oc get network.operator.openshift.io cluster -o jsonpath={..disableNetworkDiagnostics}) = "true" ]; then
      info "Network diagnostics" "disabled"
    else
      warn "Network diagnostics" "not disabled"
    fi
  fi
}

check_operator_hub(){
  echo -e "\n${NC}Checking Operator hub:"
  if [ "false" = "$(yq '.day2.operator_hub_tuning' $config_file)" ]; then
    warn "operator_hub_tuning is not enabled in $config_file"
  else  
    if [ $(oc get catalogsource -n openshift-marketplace |grep community-operators|wc -l) -eq "0" ]; then
      info "Catalog community-operators" "disabled"
    else
      warn "Catalog community-operators" "not disabled"
    fi
    if [ $(oc get catalogsource -n openshift-marketplace |grep redhat-marketplace|wc -l) -eq "0" ]; then
      info "Catalog redhat-marketplace" "disabled"
    else
      warn "Catalog redhat-marketplace" "not disabled"
    fi
  fi  
}

check_cmdline(){
  echo -e "\n${NC}Checking /proc/cmdline:"
  export cmdline_arguments=$(ssh core@$address cat /proc/cmdline)

  check_cpuset
}

check_kernel(){
  echo -e "\n${NC}Checking RHCOS kernel:"
  kernel_version=$(ssh core@$address uname -r)
  if [ $(echo $kernel_version |grep rt | wc -l ) -eq 1 ]; then
    info "Node kernel" "realtime"
  else
    warn "Node kernel" "not realtime"
  fi
}

check_cpuset(){
  for argument in $cmdline_arguments; do
    if [[ "$argument" == *"cpu_affinity"* ]]; then
      cpu_affinity=$argument
    fi
    if [[ "$argument" == *"isolcpus"* ]]; then
      isolcpus=$argument
    fi
  done

  if [ -z $cpu_affinity ]; then
    warn "systemd.cpu_affinity not present."
  else
    info "systemd.cpu_affinity presents: $cpu_affinity"
  fi
  if [ -z $isolcpus ]; then
    warn "isolcpus not present."
  else
    info "isolcpus presents: $isolcpus"
  fi

  cpu_affinity="${cpu_affinity/systemd.cpu_affinity=/}"
  isolcpus="${isolcpus/isolcpus=/}"
  isolcpus="${isolcpus/managed_irq,/}"

  isolcpus_pp=$(oc get performanceprofiles.performance.openshift.io -o jsonpath={..spec.cpu.isolated})
  reservedcpus_pp=$(oc get performanceprofiles.performance.openshift.io -o jsonpath={..spec.cpu.reserved})

  cmd_cpu_affinity=()
  cmd_isolated_cpus=()

  pp_isolated_cpus=()
  pp_reserved_cpus=()

  for n1 in $(echo $cpu_affinity | awk '/-/{for (i=$1; i<=$2; i++)printf "%s%s",i,ORS;next} 1' RS=, FS=-)
  do
    cmd_cpu_affinity+=($n1)
  done

  for n2 in $(echo $isolcpus | awk '/-/{for (i=$1; i<=$2; i++)printf "%s%s",i,ORS;next} 1' RS=, FS=-)
  do
    cmd_isolated_cpus+=("$n2")
  done

  for n3 in $(echo $isolcpus_pp | awk '/-/{for (i=$1; i<=$2; i++)printf "%s%s",i,ORS;next} 1' RS=, FS=-)
  do
    pp_isolated_cpus+=("$n3")
  done

  for n4 in $(echo $reservedcpus_pp | awk '/-/{for (i=$1; i<=$2; i++)printf "%s%s",i,ORS;next} 1' RS=, FS=-)
  do
    pp_reserved_cpus+=("$n4")
  done

  isolated_cpu_match1=1
  isolated_cpu_match2=1
  reserved_cpu_match1=1
  reserved_cpu_match2=1

  for v1 in "${cmd_cpu_affinity[@]}"
  do
    if [[ ! " ${pp_reserved_cpus[*]} " =~ " ${v1} " ]]; then
      reserved_cpu_match1=0
      break
    fi
  done

  for v2 in "${cmd_isolated_cpus[@]}"
  do
    if [[ ! " ${pp_isolated_cpus[*]} " =~ " ${v2} " ]]; then
      isolated_cpu_match1=0
      break
    fi
  done

  for v1 in "${pp_reserved_cpus[@]}"
  do
    if [[ ! " ${cmd_cpu_affinity[*]} " =~ " ${v1} " ]]; then
      reserved_cpu_match2=0
      break
    fi
  done

  for v2 in "${pp_isolated_cpus[@]}"
  do
    if [[ ! " ${cmd_isolated_cpus[*]} " =~ " ${v2} " ]]; then
      isolated_cpu_match2=0
      break
    fi
  done

  if [[ $isolated_cpu_match1 == 1 && $isolated_cpu_match2 == 1 ]]; then
    info "Isolated cpu in cmdline: $isolcpus matches with the ones in performance profile: $isolcpus_pp"
  else
    warn "Isolated cpu in cmdline: $isolcpus not match with the ones in performance profile: $isolcpus_pp"
  fi

  if [[ $reserved_cpu_match1 == 1 && $reserved_cpu_match2 == 1 ]]; then
    info "Reserved cpu in cmdline: $cpu_affinity matches with the ones in performance profile: $reservedcpus_pp"
  else
    warn "Reserved cpu in cmdline: $cpu_affinity not match with the ones in performance profile: $reservedcpus_pp"
  fi

}

check_kdump(){
  echo -e "\n${NC}Checking kdump.service:"
  if [ "false" = "$(yq '.day1.kdump.enabled' $config_file)" ]; then
    warn "kdump is not enabled in $config_file"
  else
    if [[ $(ssh core@$address systemctl is-active kdump) = 'active' ]]; then
      info "kdump service" "active"
    else
      warn "kdump service" "not active"
    fi

    if [[ $(ssh core@$address systemctl is-enabled kdump) = 'enabled' ]]; then
      info "kdump service" "enabled"
    else
      warn "kdump service" "not enabled"
    fi
  fi  
}

check_chronyd(){
  echo -e "\n${NC}Checking chronyd.service:"
  if [ "ordinary" = "$(yq '.day2.ptp.ptpconfig' $config_file )" ] || [ "boundary" = "$(yq '.day2.ptp.ptpconfig' $config_file )" ]; then
    if [[ $(ssh core@$address systemctl is-active chronyd) = 'inactive' ]]; then
      info "chronyd service" "inactive"
    else
      warn "chronyd service" "active"
    fi

    if [[ $(ssh core@$address systemctl is-enabled chronyd) = 'enabled' ]]; then
      warn "chronyd service" "enabled"
    else
      info "chronyd service" "not enabled"
    fi
  else
    warn "ptpconfig is not enabled in $config_file."
    if [[ $(ssh core@$address systemctl is-active chronyd) = 'inactive' ]]; then
      warn "chronyd service" "inactive"
    else
      info "chronyd service" "active"
    fi

    if [[ $(ssh core@$address systemctl is-enabled chronyd) = 'enabled' ]]; then
      info "chronyd service" "enabled"
    else
      warn "chronyd service" "not enabled"
    fi
  fi
}

check_ip(){
  echo -e "\n${NC}Checking InstallPlans:"
  if [ $(oc get installplans.operators.coreos.com -A |grep false |wc -l) -gt 0 ]; then
    warn "InstallPlans below are not approved yet."
    oc get installplans.operators.coreos.com -A |grep false
  else
    info "All InstallPlans have been approved or auto-approved."
  fi
}

check_container_runtime(){
  echo -e "\n${NC}Checking container runtime:"
  local search=$(ssh core@$address grep -rv "^#" /etc/crio |grep 'default_runtime = "crun"'|wc -l)
  local container_runtime="runc"
  if [ $search = 1 ]; then
    container_runtime="crun"
  fi

  if [ "4.12" = "$ocp_y_version" ] || [ "false" = "$(yq '.day1.crun' $config_file )" ] ; then
    if [ "runc" = "$container_runtime" ]; then
      info "Container runtime" "runc"
    else
      warn "Container runtime" "crun"
    fi
  else
    if [ "runc" = "$container_runtime" ]; then
      warn "Container runtime" "runc"
    else
      info "Container runtime" "crun"
    fi
  fi
}

oc get clusterversion
echo
oc get node
echo
oc get operator


if [ $? -eq 0 ]; then
  check_node
  check_co
  export_address
  check_pods
  check_mc
  check_mcp
  check_pp
  check_tuned
  check_sriov
  check_ptp
  check_chronyd
  check_monitoring
  check_capabilities
  check_network_diagnostics
  check_operator_hub
  check_cmdline
  check_kernel
  check_kdump
  check_ip
  check_container_runtime

  echo -e "\n${NC}Completed the checking."
else
  echo -e "\n${NC}Please export the KUBECONFIG environment variable before running the check."
fi
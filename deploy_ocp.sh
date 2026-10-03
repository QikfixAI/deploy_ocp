#!/bin/bash

# Loading all the Variables
if [ -f deploy_ocp.conf ]; then
  source deploy_ocp.conf
fi

cleanup()
{
  rm -vf /tmp/wally.sh
  rm -vf /tmp/*.iso
  rm -vf new*
  ssh root@$KVM_SRV "rm -rf /var/lib/libvirt/images/*.iso"

  ssh root@$LNX_SRV "rm -rf /tmp/install-c*"
  ssh root@$LNX_SRV "rm -rf /tmp/download_b*"
  ssh root@$LNX_SRV "rm -rf /tmp/monitor*"
}

check_requirements_ssh()
{
  timeout --foreground -k 1 5 ssh root@$LNX_SRV hostname >/dev/null
  if [ $? -ne 0 ]; then
    echo "There is a problem accessing $LNX_SRV via ssh."
    echo "Please, fix it. Exiting ...."
    exit
  fi

  timeout --foreground -k 1 5 ssh root@$KVM_SRV hostname >/dev/null
  if [ $? -ne 0 ]; then
    echo "There is a problem accessing $KVM_SRV via ssh."
    echo "Please, fix it. Exiting ...."
    exit
  fi

  ssh root@$LNX_SRV "ls -ld /data"
  if [ $? -ne 0 ]; then
    echo "Creating /data directory remotely"
    ssh root@$LNX_SRV "mkdir -v /data"
  fi

  echo "You are able to access $LNX_SRV and $KVM_SRV with no issues."
}

check_dns()
{
  nslookup $API_ADDR $DNS_SERVER >/dev/null
  if [ $? -eq 0 ]; then
    API_STATUS="already in use"
  else
    API_STATUS="available"
  fi
}

setup_dns()
{

  resp=$(ssh root@$KVM_SRV "virsh domifaddr $CLUSTER_NAME --source agent | grep 192")
  count=$(echo $resp | wc -c)
  if [ $count -ne 1 ]; then
    IP=$(echo $resp | awk '{print $NF}' | cut -d/ -f1)
    LAST_IP_FIELD=$(echo $IP | cut -d. -f4)
    echo "----"
    echo "Adding 'ocpsrv.$CLUSTER_NAME.$DOMAIN 86400 A $IP' to the DNS"
    echo "Adding 'api.$CLUSTER_NAME.$DOMAIN 86400 A $IP' to the DNS"
    echo "Adding 'api-int.$CLUSTER_NAME.$DOMAIN 86400 A $IP' to the DNS"
    echo "Adding '*.apps.$CLUSTER_NAME.$DOMAIN 86400 A $IP' to the DNS"
    echo "Adding '$LAST_IP_FIELD.$DNS_REVERSE_ZONE 86400 IN PTR ocpsrv.${CLUSTER_NAME}.${DOMAIN}.' to the DNS"
    echo "----"
    echo "Removing Previous Entries"
    nsupdate -k $DNS_KEY_FILE << EOF
;server storage.king.lab
server $DNS_SERVER
;zone king.lab
zone $DOMAIN
update delete ocpsrv.$CLUSTER_NAME.$DOMAIN
update delete api.$CLUSTER_NAME.$DOMAIN
update delete api-int.$CLUSTER_NAME.$DOMAIN
update delete *.apps.$CLUSTER_NAME.$DOMAIN
send
;zone 86.168.192.in-addr.arpa
;zone $DNS_REVERSE_ZONE
;update add $LAST_IP_FIELD.$DNS_REVERSE_ZONE 86400 IN PTR ocpsrv.${CLUSTER_NAME}.${DOMAIN}.
;send
EOF

    echo "Adding New Entries"
    nsupdate -k $DNS_KEY_FILE << EOF
;server storage.king.lab
server $DNS_SERVER
;zone king.lab
zone $DOMAIN
update add ocpsrv.$CLUSTER_NAME.$DOMAIN 86400 A $IP
update add api.$CLUSTER_NAME.$DOMAIN 86400 A $IP
update add api-int.$CLUSTER_NAME.$DOMAIN 86400 A $IP
update add *.apps.$CLUSTER_NAME.$DOMAIN 86400 A $IP
send
;zone 86.168.192.in-addr.arpa
zone $DNS_REVERSE_ZONE
update add $LAST_IP_FIELD.$DNS_REVERSE_ZONE 86400 IN PTR ocpsrv.${CLUSTER_NAME}.${DOMAIN}.
send
EOF
    #echo "Waiting to refresh from Main DNS to PiHole"
    #sleep 120
    nslookup $API_ADDR $DNS_SERVER
  else
    echo "Not adding a thing"
  fi
  

}


# Let's ask some questions here
cluster_info()
{
  while :
  do
    # Checking the DNS entry
    check_dns

    echo "DNS Entry '$API_ADDR' is $API_STATUS"
    echo "#######"
    echo "1. Set the domain, default/current is '$DOMAIN'"
    echo "2. Set the cluster name, default/current is '$CLUSTER_NAME'"
    echo "3. Set the local subnet CIDR, default/current is '$NET_CIDR'"
    echo "4. List ALL the OpenShift Version available"
    echo "5. Set the OpenShift Version, default is '$OCP_VERSION'"
    echo "6. Set the VM Description, default is '$VM_DESC'"
    echo ""
    echo "8. Proceed with the Deployment!"
    echo ""
    echo "9. Exit"
    echo -n "Type the number: "
    read opc
    echo "#######"
    case $opc in
      '1') echo "Setting the Domain"
           echo "Current value: $DOMAIN"
           echo -n "Please, type the domain name: "
           read DOMAIN
           API_ADDR="api.${CLUSTER_NAME}.${DOMAIN}"
           echo "New value: $DOMAIN"
           ;;
      '2') echo "Setting the Cluster"
           echo "Current value: $CLUSTER_NAME"
           echo -n "Please, type the cluster name: "
           read CLUSTER_NAME
           API_ADDR="api.${CLUSTER_NAME}.${DOMAIN}"
           echo "New value: $CLUSTER_NAME"
           ;;
      '3') echo "Setting the Network CIDR"
           echo "Current value: $NET_CIDR"
           echo -n "Please, type the cluster name: "
           read NET_CIDR
           echo "New value: $NET_CIDR"
           ;;
      '4') echo "List all OCP Versions"
           curl -s https://mirror.openshift.com/pub/openshift-v4/clients/ocp/ | grep -o "a href.*" | cut -d\" -f2 | sed 's#/##' 
           ;;
      '5') echo "Setting the OCP Version"
           echo "Current value: $OCP_VERSION"
           echo -n "Please, type the OCP Version: "
           read OCP_VERSION
           echo "New value: $OCP_VERSION"
           ;;
      '6') echo "Setting the VM Description"
           echo "Current value: $VM_DESC"
           echo -n "Please, type the VM Description: "
           read VM_DESC
           echo "New value: $VM_DESC"
           ;;
      '8') echo "Go Rockets!!"
           steps_podman_srv
           ;;
      '9') echo "exiting ..."
         exit
    esac
  done
}


# Execute all the steps to create the image
steps_podman_srv()
{
#echo "AUDIT: beginning of steps_podman_srv: $CLUSTER_NAME"

TEMPLATE_INST_FILE="template_install-config.yaml"
TEMPLATE_DOWN_FILE="template_download_binaries.sh"
INST_FILE_FINAL="install-config.yaml"
DOWN_FILE_FINAL="download_binaries.sh"

  # Intaller Template Section
  TEMPLATE_INST_FILE_NEW="new_install-config.yaml"

  # copy from the templates 
  cp $TEMPLATE_INST_FILE $TEMPLATE_INST_FILE_NEW

  # do all the changes here
  sed -i "" "s/<domain>/$DOMAIN/" $TEMPLATE_INST_FILE_NEW
  sed -i "" "s/<name>/$CLUSTER_NAME/" $TEMPLATE_INST_FILE_NEW
  sed -i "" "s#10.0.0.0/16#$NET_CIDR#" $TEMPLATE_INST_FILE_NEW
  sed -i "" "s#<pull_secret>#$PULL_SECRET#" $TEMPLATE_INST_FILE_NEW
  sed -i "" "s#<ssh_key>#$SSH_KEY#" $TEMPLATE_INST_FILE_NEW
  sed -i "" "s#/dev/disk/by-id/<disk_id>#/dev/vda#" $TEMPLATE_INST_FILE_NEW

  # Download Template Section
  TEMPLATE_DOWN_FILE_NEW="new_download_binaries.sh"
  
  # copy from the templates 
  cp $TEMPLATE_DOWN_FILE $TEMPLATE_DOWN_FILE_NEW

  # do all the changes here
  sed -i "" "s/<domain>/$DOMAIN/" $TEMPLATE_DOWN_FILE_NEW
  sed -i "" "s/<name>/$CLUSTER_NAME/" $TEMPLATE_DOWN_FILE_NEW
  sed -i "" "s/<ocp_version>/$OCP_VERSION/" $TEMPLATE_DOWN_FILE_NEW
  sed -i "" "s/<arch>/$ARCH/" $TEMPLATE_DOWN_FILE_NEW

  # copy via ssh the final/modified files
  scp $TEMPLATE_INST_FILE_NEW root@$LNX_SRV:$REMOTE_DATA_DIR/$INST_FILE_FINAL
  scp $TEMPLATE_DOWN_FILE_NEW root@$LNX_SRV:$REMOTE_DATA_DIR/$DOWN_FILE_FINAL

  # Script Execution on the remote Podman Server 
  ssh root@$LNX_SRV "bash $REMOTE_DATA_DIR/$DOWN_FILE_FINAL"

  #echo "AUDIT: Above download_image: $CLUSTER_NAME"
  download_image
  upload_image
}

# Download the image locally
download_image()
{
  #echo "AUDIT: inside download_image: $CLUSTER_NAME"
  IMAGE_NAME="${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}.iso"
  LOCAL_PATH="$REMOTE_DATA_DIR/${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}"
  # Downloading the image to the local filesystem (under /tmp)
  scp root@$LNX_SRV:$LOCAL_PATH/rhcos-live.iso /tmp/${IMAGE_NAME}
  #echo "pause here"
  #read x
}


# Upload the new image
upload_image()
{
  #echo "AUDIT: inside upload_image: $CLUSTER_NAME"
  IMAGE_NAME="${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}.iso"
  scp /tmp/$IMAGE_NAME root@$KVM_SRV:/var/lib/libvirt/images/$IMAGE_NAME

  deploy_monitor_template
  deploy_fix_certs_template
  deploy_new_user_template
  new_vm
}

deploy_new_user_template()
{
  echo "Creating the New User Script"
  echo "Don't forget to access the folder with the installation files"
  echo "and execute the 'create_admin_user.sh' to add your '$USER_ID' user"
  echo "and '$PASSWORD' as password."

  TEMPLATE_USER="template_new_user.sh"
  TEMPLATE_USER_NEW="new_monitor.sh"
  LOCAL_PATH="$REMOTE_DATA_DIR/${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}"
  USER_FINAL="$LOCAL_PATH/create_admin_user.sh"

  cp $TEMPLATE_USER $TEMPLATE_USER_NEW
  sed -i "" "s#<dir_here>#$LOCAL_PATH#" $TEMPLATE_USER_NEW
  sed -i "" "s#<user_id>#$USER_ID#" $TEMPLATE_USER_NEW
  sed -i "" "s#<password>#$PASSWORD#" $TEMPLATE_USER_NEW
  chmod -v 755 $TEMPLATE_USER_NEW
  scp $TEMPLATE_USER_NEW root@$LNX_SRV:$USER_FINAL
}

deploy_monitor_template()
{
  echo "Creating the Monitor Script"

  TEMPLATE_MONITOR="template_monitor.sh"
  TEMPLATE_MONITOR_NEW="new_monitor.sh"
  LOCAL_PATH="$REMOTE_DATA_DIR/${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}"
  MONITOR_FINAL="monitor_${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}.sh"
  #CONSOLE_URL="console-openshift-console.apps.ocp1.king.lab"
  CONSOLE_URL="console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}"

  cp $TEMPLATE_MONITOR $TEMPLATE_MONITOR_NEW
  sed -i "" "s#<remote_dir>#$LOCAL_PATH#" $TEMPLATE_MONITOR_NEW
  sed -i "" "s#<console_url>#$CONSOLE_URL#" $TEMPLATE_MONITOR_NEW
  chmod -v 755 $TEMPLATE_MONITOR_NEW
  scp $TEMPLATE_MONITOR_NEW root@$LNX_SRV:$REMOTE_DATA_DIR/$MONITOR_FINAL
}

deploy_fix_certs_template()
{
  echo "Creating the Cert Fix Script"

  TEMPLATE_MONITOR="template_fix_certs.sh"
  TEMPLATE_MONITOR_NEW="fix_certs_new.sh"
  LOCAL_PATH="$REMOTE_DATA_DIR/${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}"
  MONITOR_FINAL="fix_certs_${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}.sh"
  #CONSOLE_URL="console-openshift-console.apps.ocp1.king.lab"
  CONSOLE_URL="console-openshift-console.apps.${CLUSTER_NAME}.${DOMAIN}"

  cp $TEMPLATE_MONITOR $TEMPLATE_MONITOR_NEW
  sed -i "" "s#<remote_dir>#$LOCAL_PATH#" $TEMPLATE_MONITOR_NEW
  chmod -v 755 $TEMPLATE_MONITOR_NEW
  scp $TEMPLATE_MONITOR_NEW root@$LNX_SRV:$REMOTE_DATA_DIR/$MONITOR_FINAL
}


new_vm()
{
  echo "Creating the VM"

  NAME="$CLUSTER_NAME"
  IMAGE_NAME="${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}.iso"

  # --noautoconsole is the option to release the terminal, but this option
  # will allaw the machine to shutdown in the next restart, instead of restarting
  # The terminal will get stuck up to the first restart
  echo "virt-install --name $NAME \
                     --metadata description=\"$VM_DESC\" \
                     --memory $MEMORY \
                     --vcpu $VCPU \
                     --os-variant fedora-coreos-stable \
                     --graphics vnc \
                     --cdrom /var/lib/libvirt/images/$IMAGE_NAME \
                     --disk size=$DISK \
                     --network type=direct,source=eno1,source.mode=bridge \
                     --check all=off" >/tmp/wally.sh
                     #--network type=direct,source=eno1,source.mode=bridge,mac=$MAC" >/tmp/wally.sh
 
 # We can't add the cards on all the VMs
 #                    --host-device 02:00.0 --host-device 02:00.1 \
 #                    --host-device 03:00.0 --host-device 03:00.1" >/tmp/wally.sh
  chmod 755 /tmp/wally.sh
  scp /tmp/wally.sh root@$KVM_SRV:/tmp/wally.sh
  ssh root@$KVM_SRV "nohup /tmp/wally.sh >/tmp/vm_output.log 2>&1 &"
  
  echo "let's wait for 120 seconds to prepare a new VM and retrieve"
  echo "the ip address, then setup the DNS entries"
  sleep 120

  # Let's call and setup DNS
  setup_dns
}

## Main
check_requirements_ssh
cluster_info

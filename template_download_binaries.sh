#!/bin/bash

# Setting some variables
DOMAIN="<domain>"
CLUSTER_NAME="<name>"
OCP_VERSION="<ocp_version>"
ARCH="<arch>"
REMOTE_FOLDER="<remote_folder>"

DEST_PATH="$REMOTE_FOLDER/${CLUSTER_NAME}.${DOMAIN}-${OCP_VERSION}"

if [ -d $DEST_PATH ]; then
  echo "Removing some old stuff"
  rm -rfv $DEST_PATH
fi
mkdir -v $DEST_PATH
cd $DEST_PATH


# Downloading the OC
echo "Downloading the OC"
echo "Value of OCP_VERSION: $OCP_VERSION"
curl -s -k https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-client-linux.tar.gz -o oc.tar.gz
tar zxf oc.tar.gz
chmod +x oc

# Downloading the openshift-install-linux
echo "Downloading the openshift-install-linux"
curl -s -k https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-install-linux.tar.gz -o openshift-install-linux.tar.gz
tar zxf openshift-install-linux.tar.gz
chmod +x openshift-install

# Downloading the CoreOS image
echo "Downloading the CoreOS image"
export ISO_URL=$(./openshift-install coreos print-stream-json | python -m json.tool | grep location | grep $ARCH | grep iso | cut -d\" -f4)
#curl -s -L $ISO_URL -o rhcos-live-original.iso
curl -s -L $ISO_URL -o rhcos-live.iso


mkdir $DEST_PATH/ocp
cp $REMOTE_FOLDER/install-config.yaml $DEST_PATH/ocp
cd $DEST_PATH
$DEST_PATH/openshift-install --dir=ocp create single-node-ignition-config

podman run --privileged --pull always --rm \
      -v /dev:/dev -v /run/udev:/run/udev -v $PWD:/data \
      -w /data quay.io/coreos/coreos-installer:release \
      iso ignition embed -fi ocp/bootstrap-in-place-for-live-iso.ign rhcos-live.iso

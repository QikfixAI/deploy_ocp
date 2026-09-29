#!/bin/bash

export FULL_PATH="<remote_dir>"
export KUBECONFIG="$FULL_PATH/ocp/auth/kubeconfig"
export OC="$FULL_PATH/oc"

count=0

while (( $count < 5 ))
do
  echo "Let's do this ... $count of 5, for 30 seconds"
  echo "---"
  $OC get csr | grep -i pending
  echo "---"
  $OC get csr -o name | xargs $OC adm certificate approve
  sleep 30
  (( count = count + 1))
done

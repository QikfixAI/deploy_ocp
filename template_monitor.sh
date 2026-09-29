#!/bin/bash

export FULL_PATH="<remote_dir>"
export CONSOLE_URL="<console_url>"
export KUBECONFIG="$FULL_PATH/ocp/auth/kubeconfig"

watch -n1 '
  aux=$(curl -s -k $CONSOLE_URL -LI | grep HTTP | grep 200 | wc -c)
  if [ $aux -ne 0 ]; then
    echo "WebUI: You can Connect"
  else
    echo "WebUI: Connection Not Ready Yet"
  fi
  echo
  echo "$FULL_PATH/oc get co"
  $FULL_PATH/oc get co
  echo
  echo "$FULL_PATH/oc get clusterversion"
  $FULL_PATH/oc get clusterversion
  echo
  echo "$FULL_PATH/oc get nodes"
  $FULL_PATH/oc get nodes
  echo
  $FULL_PATH/oc get pods --no-headers -A | grep -v -E "( Completed | Running )" | wc -l
  echo "$FULL_PATH/oc get pods -A | grep -v -E \"( Completed | Running )\""
  $FULL_PATH/oc get pods -A | grep -v -E "( Completed | Running )"
'

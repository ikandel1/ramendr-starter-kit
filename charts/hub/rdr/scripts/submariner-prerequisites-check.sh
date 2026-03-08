#!/bin/bash
set -euo pipefail

echo "Starting Submariner prerequisites check..."

# Configuration (PRIMARY_CLUSTER and SECONDARY_CLUSTER from values.yaml via env)
PRIMARY_CLUSTER="${PRIMARY_CLUSTER:-ocp-primary}"
SECONDARY_CLUSTER="${SECONDARY_CLUSTER:-ocp-secondary}"
KUBECONFIG_DIR="/tmp/kubeconfigs"
MAX_ATTEMPTS=120  # 2 hours with 1 minute intervals
SLEEP_INTERVAL=60  # 1 minute between checks

# Create kubeconfig directory
mkdir -p "$KUBECONFIG_DIR"

# Function to check Submariner health and connectivity
check_submariner_health() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "Checking Submariner health on $cluster..."
  
  # Check if Submariner is installed (check for the correct CRDs)
  if ! oc --kubeconfig="$kubeconfig" get crd clusters.submariner.io &>/dev/null; then
    echo "Submariner clusters CRD not found on $cluster"
    return 1
  fi
  
  # Check if Submariner operator is running
  local submariner_operator_pods=$(oc --kubeconfig="$kubeconfig" get pods -n submariner-operator --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  submariner_operator_pods=$(echo "$submariner_operator_pods" | tr -d ' \n')
  if [[ $submariner_operator_pods -eq 0 ]]; then
    echo "Submariner operator not running on $cluster"
    return 1
  fi
  
  # Check Submariner gateway nodes
  local gateway_nodes=$(oc --kubeconfig="$kubeconfig" get nodes -l submariner.io/gateway=true --no-headers 2>/dev/null | wc -l)
  if [[ $gateway_nodes -eq 0 ]]; then
    echo "No Submariner gateway nodes found on $cluster"
    return 1
  fi
  
  echo "Submariner is healthy on $cluster"
  return 0
}

# Function to check Submariner connectivity between clusters
check_submariner_connectivity() {
  echo "Checking Submariner connectivity between $PRIMARY_CLUSTER and $SECONDARY_CLUSTER..."
  
  # Check Submariner clusters on hub cluster
  local primary_cluster_id=$(oc get clusters.submariner.io "$PRIMARY_CLUSTER" -n resilient-broker -o jsonpath='{.spec.cluster_id}' 2>/dev/null || echo "")
  local secondary_cluster_id=$(oc get clusters.submariner.io "$SECONDARY_CLUSTER" -n resilient-broker -o jsonpath='{.spec.cluster_id}' 2>/dev/null || echo "")
  
  if [[ -z "$primary_cluster_id" || -z "$secondary_cluster_id" ]]; then
    echo "Could not retrieve cluster IDs from Submariner"
    return 1
  fi
  
  echo "Primary cluster ID: $primary_cluster_id"
  echo "Secondary cluster ID: $secondary_cluster_id"
  
  # Check if both clusters are registered in Submariner
  if [[ "$primary_cluster_id" == "$PRIMARY_CLUSTER" && "$secondary_cluster_id" == "$SECONDARY_CLUSTER" ]]; then
    echo "✅ Both clusters are registered in Submariner"
    return 0
  else
    echo "❌ Cluster IDs do not match expected values"
    return 1
  fi
  
  echo "✅ Submariner connectivity verified between $PRIMARY_CLUSTER and $SECONDARY_CLUSTER"
  return 0
}

# Function to download kubeconfig for a cluster
download_kubeconfig() {
  local cluster="$1"
  local kubeconfig_path="$KUBECONFIG_DIR/${cluster}-kubeconfig.yaml"
  
  echo "Downloading kubeconfig for $cluster..."
  
  # Get the kubeconfig secret name (same approach as download-kubeconfigs.sh)
  local kubeconfig_secret=$(oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1)
  
  if [[ -z "$kubeconfig_secret" ]]; then
    echo "No kubeconfig secret found for cluster $cluster"
    return 1
  fi
  
  echo "Found kubeconfig secret: $kubeconfig_secret"
  
  # Try to get the kubeconfig data (same approach as download-kubeconfigs.sh)
  local kubeconfig_data=""
  
  # First try to get the 'kubeconfig' field
  kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  # If that fails, try the 'raw-kubeconfig' field
  if [[ -z "$kubeconfig_data" ]]; then
    kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" -o jsonpath='{.data.raw-kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi
  
  if [[ -z "$kubeconfig_data" ]]; then
    echo "Could not extract kubeconfig data for cluster $cluster"
    return 1
  fi
  
  # Write the kubeconfig to file
  echo "$kubeconfig_data" > "$kubeconfig_path"
  
  # Validate kubeconfig
  if oc --kubeconfig="$kubeconfig_path" get nodes --request-timeout=5s &>/dev/null; then
    echo "Kubeconfig downloaded and validated for $cluster"
    return 0
  else
    echo "Kubeconfig for $cluster is invalid or cluster is unreachable"
    return 1
  fi
}

# Main check loop - keep retrying until all prerequisites are met
while true; do
  attempt=1
  echo "=== Starting new Submariner prerequisites check cycle ==="
  
  while [[ $attempt -le $MAX_ATTEMPTS ]]; do
    echo "=== Submariner Prerequisites Check Attempt $attempt/$MAX_ATTEMPTS ==="
    
    all_checks_passed=true
    
    # Download kubeconfigs
    if ! download_kubeconfig "$PRIMARY_CLUSTER"; then
      echo "Failed to download kubeconfig for $PRIMARY_CLUSTER"
      all_checks_passed=false
    fi
    
    if ! download_kubeconfig "$SECONDARY_CLUSTER"; then
      echo "Failed to download kubeconfig for $SECONDARY_CLUSTER"
      all_checks_passed=false
    fi
    
    if [[ "$all_checks_passed" == "true" ]]; then
      # Check Submariner health on individual clusters
      if ! check_submariner_health "$PRIMARY_CLUSTER" "$KUBECONFIG_DIR/${PRIMARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      if ! check_submariner_health "$SECONDARY_CLUSTER" "$KUBECONFIG_DIR/${SECONDARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      # Check Submariner connectivity between clusters
      if ! check_submariner_connectivity; then
        all_checks_passed=false
      fi
    fi
    
    if [[ "$all_checks_passed" == "true" ]]; then
      echo "🎉 All Submariner prerequisites are met! Proceeding with DR policy deployment..."
      exit 0
    else
      echo "❌ Some Submariner prerequisites are not met. Waiting $SLEEP_INTERVAL seconds before retry..."
      sleep $SLEEP_INTERVAL
      ((attempt++))
    fi
  done
  
  echo "❌ Submariner prerequisites check failed after $MAX_ATTEMPTS attempts"
  echo "🔄 Continuing to retry until all prerequisites are met..."
  echo "Please ensure:"
  echo "1. Submariner is installed and connected between $PRIMARY_CLUSTER and $SECONDARY_CLUSTER"
  echo "2. Submariner operator is running on both managed clusters"
  echo "3. Submariner gateway nodes are configured on both managed clusters"
  echo "4. Both clusters are registered in the Submariner broker"
  echo ""
  echo "🔄 Restarting Submariner prerequisites check..."
  # Reset attempt counter and continue
  attempt=1
  sleep $SLEEP_INTERVAL
done  # End of infinite retry loop


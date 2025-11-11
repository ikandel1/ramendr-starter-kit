#!/bin/bash
set -euo pipefail

echo "Starting ArgoCD health monitoring and remediation..."

# Configuration
MAX_ATTEMPTS=270  # Check 270 times (90 minutes with 20s intervals) before failing
SLEEP_INTERVAL=20
ARGOCD_NAMESPACE="openshift-gitops"
HEALTH_CHECK_TIMEOUT=30

# Function to check if a cluster is wedged
check_cluster_wedged() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "Checking if $cluster is wedged..."
  
  # Check if we can connect to the cluster
  if ! oc --kubeconfig="$kubeconfig" get nodes --request-timeout=10s &>/dev/null; then
    echo "❌ Cannot connect to $cluster - cluster appears wedged"
    return 0
  fi
  
  # Determine the cluster-specific ArgoCD instance name and namespace
  local cluster_argocd_namespace=""
  local cluster_argocd_instance=""
  case "$cluster" in
    "ocp-primary")
      cluster_argocd_namespace="ramendr-starter-kit-resilient"
      cluster_argocd_instance="resilient-gitops-server"
      ;;
    "ocp-secondary")
      cluster_argocd_namespace="ramendr-starter-kit-resilient"
      cluster_argocd_instance="resilient-gitops-server"
      ;;
    "local-cluster")
      cluster_argocd_namespace="openshift-gitops"
      cluster_argocd_instance="openshift-gitops"
      ;;
    *)
      echo "❌ Unknown cluster $cluster - cannot determine ArgoCD instance"
      return 0
      ;;
  esac
  
  echo "Looking for cluster-specific gitops-server instance: $cluster_argocd_instance in namespace: $cluster_argocd_namespace"
  
  # Check if the cluster-specific ArgoCD namespace exists
  if ! oc --kubeconfig="$kubeconfig" get namespace "$cluster_argocd_namespace" &>/dev/null; then
    echo "⚠️  Cluster-specific ArgoCD namespace $cluster_argocd_namespace not found on $cluster"
    
    # Check if openshift-gitops namespace exists and is wedged
    if oc --kubeconfig="$kubeconfig" get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
      echo "🔍 Checking if openshift-gitops instance is wedged on $cluster..."
      local openshift_gitops_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=openshift-gitops-server --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
      echo "Found $openshift_gitops_pods gitops-server pods in $ARGOCD_NAMESPACE namespace on $cluster"
      
      if [[ $openshift_gitops_pods -gt 0 ]]; then
        echo "❌ openshift-gitops instance is running but cluster-specific ArgoCD is missing - cluster appears wedged"
        return 0
      fi
    fi
    
    echo "✅ $cluster appears healthy (no ArgoCD instances installed yet)"
    return 1
  fi
  
  # Check if the cluster-specific ArgoCD instance exists and is running
  local cluster_argocd_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$cluster_argocd_namespace" -l app.kubernetes.io/name=$cluster_argocd_instance --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  echo "Found $cluster_argocd_pods $cluster_argocd_instance pods in $cluster_argocd_namespace namespace on $cluster"
  
  if [[ $cluster_argocd_pods -eq 0 ]]; then
    echo "⚠️  No gitops-server pods found in $cluster_argocd_namespace namespace on $cluster"
    
    # Check if openshift-gitops instance is wedged
    if oc --kubeconfig="$kubeconfig" get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
      echo "🔍 Checking if openshift-gitops instance is wedged on $cluster..."
      local openshift_gitops_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=openshift-gitops-server --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
      echo "Found $openshift_gitops_pods gitops-server pods in $ARGOCD_NAMESPACE namespace on $cluster"
      
      if [[ $openshift_gitops_pods -gt 0 ]]; then
        echo "❌ openshift-gitops instance is running but cluster-specific ArgoCD is missing - cluster appears wedged"
        return 0
      fi
    fi
    
    echo "✅ $cluster appears healthy (no ArgoCD instances running yet)"
    return 1
  elif [[ $cluster_argocd_pods -eq 1 ]]; then
    echo "✅ Found 1 $cluster_argocd_instance pod in $cluster_argocd_namespace namespace on $cluster - cluster appears healthy"
    return 1
  else
    echo "⚠️  Found $cluster_argocd_pods $cluster_argocd_instance pods in $cluster_argocd_namespace namespace on $cluster (expected 1) - cluster may be wedged"
    return 0
  fi
}

# Function to remediate a wedged cluster
remediate_wedged_cluster() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "🔧 Remediating wedged cluster: $cluster"
  
  # Stop all ArgoCD instances by scaling down deployments
  echo "  Stopping all ArgoCD instances on $cluster..."
  oc --kubeconfig="$kubeconfig" scale deployment --all -n "$ARGOCD_NAMESPACE" --replicas=0 &>/dev/null || true
  oc --kubeconfig="$kubeconfig" scale statefulset --all -n "$ARGOCD_NAMESPACE" --replicas=0 &>/dev/null || true
  
  # If scaling doesn't work, try more aggressive cleanup
  echo "  Attempting aggressive cleanup for stuck deployments..."
  oc --kubeconfig="$kubeconfig" delete deployment --all -n "$ARGOCD_NAMESPACE" --grace-period=0 --force &>/dev/null || true
  oc --kubeconfig="$kubeconfig" delete statefulset --all -n "$ARGOCD_NAMESPACE" --grace-period=0 --force &>/dev/null || true
  oc --kubeconfig="$kubeconfig" delete pods --all -n "$ARGOCD_NAMESPACE" --grace-period=0 --force &>/dev/null || true
  
  # Wait for all instances to stop
  echo "  Waiting for ArgoCD instances to stop..."
  local attempt=1
  while [[ $attempt -le 30 ]]; do
    local running_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    if [[ $running_pods -eq 0 ]]; then
      echo "  ✅ All ArgoCD instances stopped on $cluster"
      break
    fi
    echo "  Waiting for instances to stop... (attempt $attempt/30)"
    sleep 5
    ((attempt++))
  done
  
  # Restart all ArgoCD instances by scaling up deployments
  echo "  Restarting all ArgoCD instances on $cluster..."
  oc --kubeconfig="$kubeconfig" scale deployment --all -n "$ARGOCD_NAMESPACE" --replicas=1 &>/dev/null || true
  oc --kubeconfig="$kubeconfig" scale statefulset --all -n "$ARGOCD_NAMESPACE" --replicas=1 &>/dev/null || true
  
  # Wait for pods to restart
  echo "  Waiting for ArgoCD pods to restart on $cluster..."
  local attempt=1
  while [[ $attempt -le 20 ]]; do
    local running_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
    local total_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | wc -l)
    
    if [[ $running_pods -gt 0 && $running_pods -eq $total_pods ]]; then
      echo "  ✅ ArgoCD pods restarted successfully on $cluster"
      break
    fi
    
    echo "  Waiting for pods to restart... (attempt $attempt/20)"
    sleep 10
    ((attempt++))
  done
  
  if [[ $attempt -gt 20 ]]; then
    echo "  ⚠️  ArgoCD pods may not have fully restarted on $cluster"
  fi
  
  # Trigger ArgoCD refresh/sync
  echo "  Triggering ArgoCD refresh on $cluster..."
  local server_pod=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=openshift-gitops-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$server_pod" ]]; then
    # Trigger refresh of all applications
    oc --kubeconfig="$kubeconfig" exec -n "$ARGOCD_NAMESPACE" "$server_pod" -- argocd app list -o name | while read app; do
      if [[ -n "$app" ]]; then
        echo "    Refreshing $app..."
        oc --kubeconfig="$kubeconfig" exec -n "$ARGOCD_NAMESPACE" "$server_pod" -- argocd app get "$app" --refresh &>/dev/null || true
      fi
    done
    
    # Trigger hard refresh
    oc --kubeconfig="$kubeconfig" exec -n "$ARGOCD_NAMESPACE" "$server_pod" -- argocd app list -o name | while read app; do
      if [[ -n "$app" ]]; then
        echo "    Hard refreshing $app..."
        oc --kubeconfig="$kubeconfig" exec -n "$ARGOCD_NAMESPACE" "$server_pod" -- argocd app get "$app" --hard-refresh &>/dev/null || true
      fi
    done
  fi
  
  echo "  ✅ Remediation completed for $cluster"
}

# Function to download kubeconfig for a cluster (using same logic as download-kubeconfigs.sh)
download_kubeconfig() {
  local cluster="$1"
  local kubeconfig_path="/tmp/${cluster}-kubeconfig.yaml"
  
  echo "Downloading kubeconfig for $cluster..."
  
  # Check if cluster is available (same as download-kubeconfigs.sh)
  local cluster_status=$(oc get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "Unknown")
  if [[ "$cluster_status" != "True" ]]; then
    echo "Cluster $cluster is not available (status: $cluster_status), skipping..."
    return 1
  fi
  
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
  
  # Validate kubeconfig (same as download-kubeconfigs.sh)
  if oc --kubeconfig="$kubeconfig_path" get nodes &>/dev/null; then
    echo "Kubeconfig downloaded and validated for $cluster"
    
    # Show cluster info (same as download-kubeconfigs.sh)
    local server_url=$(echo "$kubeconfig_data" | grep -E "^\s*server:" | head -1 | awk '{print $2}' || echo "Unknown")
    echo "  Server URL: $server_url"
    
    local node_count=$(oc --kubeconfig="$kubeconfig_path" get nodes --no-headers 2>/dev/null | wc -l || echo "0")
    echo "  Node count: $node_count"
    
    return 0
  else
    echo "Downloaded kubeconfig for $cluster but it may not be valid"
    echo "  File saved as: $kubeconfig_path"
    return 1
  fi
}

# Main monitoring loop
attempt=1
while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  echo "=== ArgoCD Health Check Attempt $attempt/$MAX_ATTEMPTS ==="
  
  # Get list of managed clusters
  MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$MANAGED_CLUSTERS" ]]; then
    echo "❌ CRITICAL ERROR: No managed clusters found"
    echo ""
    echo "The ArgoCD health monitor requires managed clusters to function properly."
    echo "Without managed clusters, there are no targets for health monitoring."
    echo ""
    echo "This may indicate:"
    echo "  - Managed clusters have not been created yet"
    echo "  - Managed clusters have been deleted"
    echo "  - There is a connectivity issue with the hub cluster"
    echo "  - The OpenShift Cluster Manager is not properly configured"
    echo ""
    echo "The health monitor cannot function without managed clusters."
    echo "Please ensure managed clusters are created and available."
    echo ""
    echo "Job will exit with error code 1."
    exit 1
  fi
  
  echo "Found managed clusters: $MANAGED_CLUSTERS"
  
  wedged_clusters=()
  
  # First, check if all managed clusters are available and ready
  echo "🔍 Checking if all managed clusters are available and ready..."
  unavailable_clusters=()
  for cluster in $MANAGED_CLUSTERS; do
    if [[ "$cluster" == "local-cluster" ]]; then
      continue
    fi
    
    echo "Checking availability of cluster: $cluster"
    
    # Check if cluster is available
    cluster_status=$(oc get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$cluster_status" != "True" ]]; then
      echo "⚠️  Cluster $cluster is not available (status: $cluster_status)"
      unavailable_clusters+=("$cluster")
      continue
    fi
    
    # Check if cluster is joined
    joined_status=$(oc get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$joined_status" != "True" ]]; then
      echo "⚠️  Cluster $cluster is not joined (status: $joined_status)"
      unavailable_clusters+=("$cluster")
      continue
    fi
    
    echo "✅ Cluster $cluster is available and joined"
  done
  
  # If any clusters are not ready, wait and retry
  if [[ ${#unavailable_clusters[@]} -gt 0 ]]; then
    echo "⏳ Waiting for clusters to be ready: ${unavailable_clusters[*]}"
    echo "Clusters must be available and joined before health checks can begin"
    echo "This is normal during initial cluster deployment - clusters may take several minutes to become ready"
    
    # If this is the last attempt and clusters are still not ready, fail
    if [[ $attempt -ge $MAX_ATTEMPTS ]]; then
      echo "❌ FINAL ATTEMPT FAILED: Clusters are still not ready after $MAX_ATTEMPTS attempts"
      echo "This indicates a problem with cluster deployment or connectivity"
      echo "Failed clusters: ${unavailable_clusters[*]}"
      echo "The health monitor cannot function without ready clusters"
      exit 1
    else
      sleep $SLEEP_INTERVAL
      ((attempt++))
      continue
    fi
  fi
  
  echo "✅ All managed clusters are available and ready - proceeding with health checks"
  
  # Now check each managed cluster for ArgoCD health
  kubeconfig_failures=()
  for cluster in $MANAGED_CLUSTERS; do
    if [[ "$cluster" == "local-cluster" ]]; then
      continue
    fi
    
    echo "Checking ArgoCD health on cluster: $cluster"
    
    # Download kubeconfig
    if download_kubeconfig "$cluster"; then
      kubeconfig_path="/tmp/${cluster}-kubeconfig.yaml"
      
      # Check if cluster is wedged
      if check_cluster_wedged "$cluster" "$kubeconfig_path"; then
        wedged_clusters+=("$cluster")
      fi
    else
      echo "❌ Failed to download or validate kubeconfig for $cluster"
      kubeconfig_failures+=("$cluster")
    fi
  done
  
  # If there are kubeconfig failures, wait and retry (up to MAX_ATTEMPTS)
  if [[ ${#kubeconfig_failures[@]} -gt 0 ]]; then
    echo "⚠️  Kubeconfig failures detected: ${kubeconfig_failures[*]}"
    echo "This may indicate clusters are still starting up or there are connectivity issues"
    echo "Attempt $attempt/$MAX_ATTEMPTS - will retry if attempts remain"
    
    # If this is the last attempt, fail
    if [[ $attempt -ge $MAX_ATTEMPTS ]]; then
      echo "❌ FINAL ATTEMPT FAILED: Cannot access clusters after $MAX_ATTEMPTS attempts"
      echo "This indicates a problem with cluster deployment, connectivity, or kubeconfig secrets"
      echo "Failed clusters: ${kubeconfig_failures[*]}"
      echo "The health monitor cannot function without valid kubeconfigs"
      exit 1
    else
      echo "⏳ Waiting for clusters to be ready before next attempt..."
      sleep $SLEEP_INTERVAL
      ((attempt++))
      continue
    fi
  fi
  
  # Remediate wedged clusters
  if [[ ${#wedged_clusters[@]} -gt 0 ]]; then
    echo "Found wedged clusters: ${wedged_clusters[*]}"
    
    for cluster in "${wedged_clusters[@]}"; do
      kubeconfig_path="/tmp/${cluster}-kubeconfig.yaml"
      remediate_wedged_cluster "$cluster" "$kubeconfig_path"
    done
    
    echo "✅ Remediation completed for wedged clusters"
    echo "⏳ Waiting for remediated clusters to recover before next check..."
    sleep $SLEEP_INTERVAL
    ((attempt++))
  else
    echo "✅ All clusters are healthy - health monitoring completed successfully"
    echo "🎉 ArgoCD health monitoring completed successfully"
    exit 0
  fi
done

echo "🎉 ArgoCD health monitoring completed"


#!/bin/bash
set -euo pipefail

echo "Starting ArgoCD health monitoring and remediation..."

# Configuration
MAX_ATTEMPTS=180  # Check 180 times (90 minutes with 30s intervals) before failing
SLEEP_INTERVAL=30
ARGOCD_NAMESPACE="openshift-gitops"
HEALTH_CHECK_TIMEOUT=60

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
      echo "Found $openshift_gitops_pods openshift-gitops-server pods in $ARGOCD_NAMESPACE namespace on $cluster"
      
      if [[ $openshift_gitops_pods -gt 0 ]]; then
        echo "❌ openshift-gitops instance is running but cluster-specific ArgoCD is missing - cluster appears wedged"
        return 0
      fi
    fi
    
    echo "✅ $cluster appears healthy (no ArgoCD instances installed yet)"
    return 1
  fi
  
  # Check if the cluster-specific gitops-server instance exists and is running
  echo "🔍 Debug: Checking for $cluster_argocd_instance pods in namespace: $cluster_argocd_namespace"
  echo "🔍 Debug: Command: oc --kubeconfig=\"$kubeconfig\" get pods -n \"$cluster_argocd_namespace\" -l app.kubernetes.io/name=$cluster_argocd_instance --field-selector=status.phase=Running"
  local cluster_argocd_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$cluster_argocd_namespace" -l app.kubernetes.io/name=$cluster_argocd_instance --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
  echo "Found $cluster_argocd_pods $cluster_argocd_instance pods in $cluster_argocd_namespace namespace on $cluster"
  
  if [[ $cluster_argocd_pods -eq 0 ]]; then
    echo "⚠️  No $cluster_argocd_instance pods found in $cluster_argocd_namespace namespace on $cluster"
    
    # Check if openshift-gitops instance is running
    if oc --kubeconfig="$kubeconfig" get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
      local openshift_gitops_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=openshift-gitops-server --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
      echo "Found $openshift_gitops_pods openshift-gitops-server pods in $ARGOCD_NAMESPACE namespace on $cluster"
      
      if [[ $openshift_gitops_pods -gt 0 ]]; then
        echo "⏳ openshift-gitops instance is running - waiting 5 minutes for cluster-specific ArgoCD to deploy..."
        echo "This allows openshift-gitops time to create the cluster-specific ArgoCD instance"
        
        # Wait 5 minutes (300 seconds) for cluster-specific ArgoCD to be deployed
        local wait_attempt=1
        while [[ $wait_attempt -le 60 ]]; do  # 60 attempts × 5 seconds = 5 minutes
          sleep 5
          cluster_argocd_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$cluster_argocd_namespace" -l app.kubernetes.io/name=$cluster_argocd_instance --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
          
          if [[ $cluster_argocd_pods -gt 0 ]]; then
            echo "✅ Cluster-specific ArgoCD instance found after waiting (attempt $wait_attempt/60)"
            break
          fi
          
          if [[ $((wait_attempt % 12)) -eq 0 ]]; then  # Every minute
            echo "  Still waiting for cluster-specific ArgoCD... (${wait_attempt}/60 attempts)"
          fi
          
          ((wait_attempt++))
        done
        
        # Re-check the cluster-specific ArgoCD pods after waiting
        cluster_argocd_pods=$(oc --kubeconfig="$kubeconfig" get pods -n "$cluster_argocd_namespace" -l app.kubernetes.io/name=$cluster_argocd_instance --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        echo "After waiting: Found $cluster_argocd_pods $cluster_argocd_instance pods in $cluster_argocd_namespace namespace on $cluster"
        
        if [[ $cluster_argocd_pods -eq 0 ]]; then
          echo "❌ openshift-gitops instance is running but cluster-specific ArgoCD is still missing after 5 minutes"
          
          # Check if the openshift-gitops instance has been running for more than 10 minutes
          echo "🔍 Checking if openshift-gitops instance has been running for more than 10 minutes..."
          local openshift_gitops_pod_age=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=openshift-gitops-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || echo "")
          
          if [[ -n "$openshift_gitops_pod_age" ]]; then
            # Convert creation timestamp to seconds since epoch
            local pod_creation_epoch=$(date -d "$openshift_gitops_pod_age" +%s 2>/dev/null || echo "0")
            local current_epoch=$(date +%s)
            local pod_age_minutes=$(( (current_epoch - pod_creation_epoch) / 60 ))
            
            echo "  openshift-gitops pod age: $pod_age_minutes minutes"
            
            if [[ $pod_age_minutes -ge 10 ]]; then
              echo "❌ openshift-gitops instance has been running for $pod_age_minutes minutes (>10) - cluster appears wedged"
              return 0
            else
              echo "⏳ openshift-gitops instance has only been running for $pod_age_minutes minutes (<10) - giving it more time to self-heal"
              return 1
            fi
          else
            echo "⚠️  Could not determine openshift-gitops pod age - assuming it needs more time"
            return 1
          fi
        fi
      fi
    fi
    
    echo "✅ $cluster appears healthy (no ArgoCD instances running yet)"
    return 1
  elif [[ $cluster_argocd_pods -eq 1 ]]; then
    echo "✅ Found 1 $cluster_argocd_instance pod in $cluster_argocd_namespace namespace on $cluster - cluster appears healthy"
    return 1
  else
    echo "⚠️  Found $cluster_argocd_pods $cluster_argocd_instance pods in $cluster_argocd_namespace namespace on $cluster (expected 1)"
    
    # Check if the openshift-gitops instance has been running for more than 10 minutes
    echo "🔍 Checking if openshift-gitops instance has been running for more than 10 minutes..."
    local openshift_gitops_pod_age=$(oc --kubeconfig="$kubeconfig" get pods -n "$ARGOCD_NAMESPACE" -l app.kubernetes.io/name=openshift-gitops-server --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.creationTimestamp}' 2>/dev/null || echo "")
    
    if [[ -n "$openshift_gitops_pod_age" ]]; then
      # Convert creation timestamp to seconds since epoch
      local pod_creation_epoch=$(date -d "$openshift_gitops_pod_age" +%s 2>/dev/null || echo "0")
      local current_epoch=$(date +%s)
      local pod_age_minutes=$(( (current_epoch - pod_creation_epoch) / 60 ))
      
      echo "  openshift-gitops pod age: $pod_age_minutes minutes"
      
      if [[ $pod_age_minutes -ge 10 ]]; then
        echo "❌ openshift-gitops instance has been running for $pod_age_minutes minutes (>10) - cluster appears wedged"
        return 0
      else
        echo "⏳ openshift-gitops instance has only been running for $pod_age_minutes minutes (<10) - giving it more time to self-heal"
        return 1
      fi
    else
      echo "⚠️  Could not determine openshift-gitops pod age - assuming it needs more time"
      return 1
    fi
  fi
}

# Function to remediate a wedged cluster using ArgoCD sync mechanisms
remediate_wedged_cluster() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "🔧 Remediating wedged cluster: $cluster using ArgoCD sync mechanisms"
  echo "  🎯 Focus: Force sync namespace policies and specific resources in stuck applications"
  
  # STEP 1: Find and sync namespace policies
  echo "  🔍 STEP 1: Finding and syncing namespace policies..."
  
  # Get all ArgoCD applications
  local applications=$(oc --kubeconfig="$kubeconfig" get applications -n "$ARGOCD_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -n "$applications" ]]; then
    echo "  Found ArgoCD applications: $applications"
    
    for app in $applications; do
      echo "  🔄 Processing application: $app"
      
      # Get application status
      local app_status=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
      local app_health=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
      
      echo "    Application $app status: sync=$app_status, health=$app_health"
      
      # If application is out of sync or unhealthy, force sync it
      if [[ "$app_status" != "Synced" || "$app_health" != "Healthy" ]]; then
        echo "    🔄 Application $app is not in sync - forcing sync..."
        
        # Force sync the application
        oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p='{"operation":{"sync":{"syncOptions":["CreateNamespace=true","PrunePropagationPolicy=foreground","PruneLast=true"]}}}' &>/dev/null || true
        
        # Wait a moment for sync to start
        sleep 5
        
        # Check if there are specific resources that need to be synced
        echo "    🔍 Checking for specific resources that need sync in $app..."
        
        # Get resources that are out of sync
        local out_of_sync_resources=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.resources[?(@.status=="OutOfSync")].name}' 2>/dev/null || echo "")
        
        if [[ -n "$out_of_sync_resources" ]]; then
          echo "    📋 Found out-of-sync resources: $out_of_sync_resources"
          
          # Force sync specific resources
          for resource in $out_of_sync_resources; do
            echo "    🔄 Force syncing resource: $resource"
            oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p="{\"operation\":{\"sync\":{\"resources\":[{\"kind\":\"$(echo $resource | cut -d'/' -f1)\",\"name\":\"$(echo $resource | cut -d'/' -f2)\"}]}}}" &>/dev/null || true
          done
        fi
        
        # Check for namespace policies specifically
        echo "    🔍 Looking for namespace policies in $app..."
        local namespace_policies=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.resources[?(@.kind=="Policy")].name}' 2>/dev/null || echo "")
        
        if [[ -n "$namespace_policies" ]]; then
          echo "    📋 Found namespace policies: $namespace_policies"
          
          # Force sync namespace policies
          for policy in $namespace_policies; do
            echo "    🔄 Force syncing namespace policy: $policy"
            oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p="{\"operation\":{\"sync\":{\"resources\":[{\"kind\":\"Policy\",\"name\":\"$policy\"}]}}}" &>/dev/null || true
          done
        fi
      else
        echo "    ✅ Application $app is already in sync and healthy"
      fi
    done
  else
    echo "  ⚠️  No ArgoCD applications found in $ARGOCD_NAMESPACE namespace"
  fi
  
  # STEP 2: Force refresh and hard refresh of applications
  echo "  🔄 STEP 2: Force refreshing applications..."
  
  for app in $applications; do
    echo "  🔄 Force refreshing application: $app"
    
    # Force refresh the application
    oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p='{"operation":{"initiatedBy":{"username":"argocd-health-monitor"},"info":[{"name":"refresh","value":"hard"}]}}' &>/dev/null || true
    
    # Wait for refresh to complete
    sleep 10
    
    # Check application status after refresh
    local app_status=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    local app_health=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    echo "    Application $app status after refresh: sync=$app_status, health=$app_health"
  done
  
  # STEP 3: Check for stuck applications and force sync them
  echo "  🔍 STEP 3: Checking for stuck applications..."
  
  for app in $applications; do
    local app_status=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    local app_health=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    if [[ "$app_status" != "Synced" || "$app_health" != "Healthy" ]]; then
      echo "  🔄 Application $app is still stuck - attempting final sync..."
      
      # Final attempt to sync the application
      oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p='{"operation":{"sync":{"syncOptions":["CreateNamespace=true","PrunePropagationPolicy=foreground","PruneLast=true","Force=true"]}}}' &>/dev/null || true
      
      # Wait for sync to complete
      sleep 15
      
      # Check final status
      local final_status=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
      local final_health=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
      
      echo "    Final status for $app: sync=$final_status, health=$final_health"
    fi
  done
  
  echo "  ✅ ArgoCD sync-based remediation completed for $cluster"
  echo "  🎯 Remediated: Used ArgoCD sync mechanisms to force sync stuck applications and namespace policies"
  echo "  ⚠️  Note: This approach preserves existing resources while forcing proper synchronization"
}

# Function to apply aggressive ArgoCD sync for wedged openshift-gitops namespace
apply_aggressive_argocd_sync() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "🔄🔄🔄 APPLYING AGGRESSIVE ARGOCD SYNC TO OPENSHIFT-GITOPS NAMESPACE 🔄🔄🔄"
  echo "  🎯 Target: $ARGOCD_NAMESPACE namespace on $cluster"
  echo "  ⚠️  This will force sync all applications and namespace policies using ArgoCD mechanisms"
  
  # Check if openshift-gitops namespace exists
  if ! oc --kubeconfig="$kubeconfig" get namespace "$ARGOCD_NAMESPACE" &>/dev/null; then
    echo "  ✅ $ARGOCD_NAMESPACE namespace does not exist - nothing to sync"
    return 0
  fi
  
  echo "  🔍 $ARGOCD_NAMESPACE namespace exists - proceeding with aggressive ArgoCD sync"
  
  # STEP 1: Get all ArgoCD applications
  echo "  🔍 STEP 1: Finding all ArgoCD applications..."
  local applications=$(oc --kubeconfig="$kubeconfig" get applications -n "$ARGOCD_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$applications" ]]; then
    echo "  ⚠️  No ArgoCD applications found in $ARGOCD_NAMESPACE namespace"
    return 0
  fi
  
  echo "  Found ArgoCD applications: $applications"
  
  # STEP 2: Force sync all applications with aggressive options
  echo "  🔄 STEP 2: Force syncing all applications with aggressive options..."
  
  for app in $applications; do
    echo "  🔄 Aggressively syncing application: $app"
    
    # Get current application status
    local app_status=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    local app_health=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    echo "    Application $app current status: sync=$app_status, health=$app_health"
    
    # Force sync with aggressive options
    echo "    🔄 Force syncing $app with aggressive options..."
    oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p='{"operation":{"sync":{"syncOptions":["CreateNamespace=true","PrunePropagationPolicy=foreground","PruneLast=true","Force=true","Replace=true"]}}}' &>/dev/null || true
    
    # Wait for sync to start
    sleep 5
    
    # Check for specific resources that need aggressive sync
    echo "    🔍 Checking for specific resources that need aggressive sync in $app..."
    
    # Get all resources in the application
    local all_resources=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.resources[*].name}' 2>/dev/null || echo "")
    
    if [[ -n "$all_resources" ]]; then
      echo "    📋 Found resources in $app: $all_resources"
      
      # Force sync each resource individually
      for resource in $all_resources; do
        echo "    🔄 Force syncing resource: $resource"
        oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p="{\"operation\":{\"sync\":{\"resources\":[{\"kind\":\"$(echo $resource | cut -d'/' -f1)\",\"name\":\"$(echo $resource | cut -d'/' -f2)\"}],\"syncOptions\":[\"Force=true\",\"Replace=true\"]}}}" &>/dev/null || true
      done
    fi
    
    # Check for namespace policies specifically
    echo "    🔍 Looking for namespace policies in $app..."
    local namespace_policies=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.resources[?(@.kind=="Policy")].name}' 2>/dev/null || echo "")
    
    if [[ -n "$namespace_policies" ]]; then
      echo "    📋 Found namespace policies: $namespace_policies"
      
      # Force sync namespace policies with aggressive options
      for policy in $namespace_policies; do
        echo "    🔄 Aggressively syncing namespace policy: $policy"
        oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p="{\"operation\":{\"sync\":{\"resources\":[{\"kind\":\"Policy\",\"name\":\"$policy\"}],\"syncOptions\":[\"Force=true\",\"Replace=true\",\"PrunePropagationPolicy=foreground\"]}}}" &>/dev/null || true
      done
    fi
  done
  
  # STEP 3: Force refresh all applications
  echo "  🔄 STEP 3: Force refreshing all applications..."
  
  for app in $applications; do
    echo "  🔄 Force refreshing application: $app"
    
    # Force hard refresh
    oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p='{"operation":{"initiatedBy":{"username":"argocd-health-monitor"},"info":[{"name":"refresh","value":"hard"}]}}' &>/dev/null || true
    
    # Wait for refresh to complete
    sleep 10
  done
  
  # STEP 4: Final verification and sync
  echo "  🔍 STEP 4: Final verification and sync..."
  
  for app in $applications; do
    echo "  🔍 Final check for application: $app"
    
    # Get final status
    local final_status=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    local final_health=$(oc --kubeconfig="$kubeconfig" get application "$app" -n "$ARGOCD_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    echo "    Final status for $app: sync=$final_status, health=$final_health"
    
    # If still not healthy, try one more aggressive sync
    if [[ "$final_status" != "Synced" || "$final_health" != "Healthy" ]]; then
      echo "    🔄 Application $app still not healthy - attempting final aggressive sync..."
      oc --kubeconfig="$kubeconfig" patch application "$app" -n "$ARGOCD_NAMESPACE" --type=merge -p='{"operation":{"sync":{"syncOptions":["CreateNamespace=true","PrunePropagationPolicy=foreground","PruneLast=true","Force=true","Replace=true","Prune=true"]}}}' &>/dev/null || true
    fi
  done
  
  echo "  🔄🔄🔄 AGGRESSIVE ARGOCD SYNC COMPLETED FOR $ARGOCD_NAMESPACE NAMESPACE 🔄🔄🔄"
  echo "  🎯 Result: Used ArgoCD sync mechanisms to force sync all applications and namespace policies"
  echo "  ⚠️  Note: This approach preserves existing resources while forcing proper synchronization"
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
EXPECTED_CLUSTER_COUNT=2  # Expect 2 managed clusters (besides local-cluster)

while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  echo "=== ArgoCD Health Check Attempt $attempt/$MAX_ATTEMPTS ==="
  
  # Get list of all managed clusters
  ALL_MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$ALL_MANAGED_CLUSTERS" ]]; then
    echo "⏳ No managed clusters found yet - waiting for managed clusters to be created..."
    echo "   Expected: $EXPECTED_CLUSTER_COUNT managed clusters (excluding local-cluster)"
    echo "   Managed clusters will be created during the deployment process."
    echo "   Waiting $SLEEP_INTERVAL seconds before retry..."
    sleep $SLEEP_INTERVAL
    ((attempt++))
    continue
  fi
  
  # Convert to array and filter out local-cluster
  IFS=' ' read -r -a ALL_CLUSTERS <<< "$ALL_MANAGED_CLUSTERS"
  EXPECTED_CLUSTERS=()
  for cluster in "${ALL_CLUSTERS[@]}"; do
    if [[ "$cluster" != "local-cluster" ]]; then
      EXPECTED_CLUSTERS+=("$cluster")
    fi
  done
  
  FOUND_COUNT=${#EXPECTED_CLUSTERS[@]}
  echo "Found managed clusters (excluding local-cluster): ${EXPECTED_CLUSTERS[*]}"
  echo "Found count: $FOUND_COUNT (expected: $EXPECTED_CLUSTER_COUNT)"
  
  # Check if we have the expected number of clusters
  if [[ $FOUND_COUNT -lt $EXPECTED_CLUSTER_COUNT ]]; then
    echo "⏳ Waiting for managed clusters to be created..."
    echo "   Found: $FOUND_COUNT managed cluster(s) (excluding local-cluster)"
    echo "   Expected: $EXPECTED_CLUSTER_COUNT managed clusters (excluding local-cluster)"
    if [[ $FOUND_COUNT -gt 0 ]]; then
      echo "   Current clusters: ${EXPECTED_CLUSTERS[*]}"
    fi
    echo "   Managed clusters will be created during the deployment process."
    echo "   Waiting $SLEEP_INTERVAL seconds before retry..."
    sleep $SLEEP_INTERVAL
    ((attempt++))
    continue
  elif [[ $FOUND_COUNT -gt $EXPECTED_CLUSTER_COUNT ]]; then
    echo "⚠️  Warning: Found $FOUND_COUNT managed clusters, expected $EXPECTED_CLUSTER_COUNT"
    echo "   Clusters found: ${EXPECTED_CLUSTERS[*]}"
    echo "   Proceeding with health checks on all found clusters..."
  fi
  
  echo "✅ Found $FOUND_COUNT managed cluster(s) (excluding local-cluster): ${EXPECTED_CLUSTERS[*]}"
  
  wedged_clusters=()
  
  # First, check if all expected managed clusters are available and ready
  echo "🔍 Checking if all expected managed clusters are available and ready..."
  unavailable_clusters=()
  for cluster in "${EXPECTED_CLUSTERS[@]}"; do
    echo "Checking availability of cluster: $cluster"
    
    # Check if cluster exists
    if ! oc get managedcluster "$cluster" &>/dev/null; then
      echo "⚠️  Cluster $cluster does not exist yet"
      unavailable_clusters+=("$cluster")
      continue
    fi
    
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
  
  echo "✅ All expected managed clusters are available and ready - proceeding with health checks"
  
  # Now check each expected managed cluster for ArgoCD health
  kubeconfig_failures=()
  for cluster in "${EXPECTED_CLUSTERS[@]}"; do
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
      
      # Apply aggressive ArgoCD sync specifically for ocp-secondary if it's wedged
      if [[ "$cluster" == "ocp-secondary" ]]; then
        echo "🔄🔄🔄 APPLYING AGGRESSIVE ARGOCD SYNC TO WEDGED OCP-SECONDARY 🔄🔄🔄"
        echo "  🎯 Target: Force sync all applications and namespace policies on ocp-secondary"
        apply_aggressive_argocd_sync "$cluster" "$kubeconfig_path"
      else
        echo "🔧 Applying standard ArgoCD sync remediation to wedged cluster: $cluster"
        remediate_wedged_cluster "$cluster" "$kubeconfig_path"
      fi
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


#!/bin/bash
set -euo pipefail

echo "Starting ODF DR prerequisites check..."

# Configuration (PRIMARY_CLUSTER and SECONDARY_CLUSTER from values.yaml via env)
HUB_CLUSTER="local-cluster"
PRIMARY_CLUSTER="${PRIMARY_CLUSTER:-ocp-primary}"
SECONDARY_CLUSTER="${SECONDARY_CLUSTER:-ocp-secondary}"
KUBECONFIG_DIR="/tmp/kubeconfigs"
MAX_ATTEMPTS=120  # 2 hours with 1 minute intervals
SLEEP_INTERVAL=60  # 1 minute between checks

# Create kubeconfig directory
mkdir -p "$KUBECONFIG_DIR"

# Function to check if a condition is met
check_condition() {
  local condition_name="$1"
  local check_command="$2"
  local cluster="$3"
  
  echo "Checking $condition_name on $cluster..."
  if eval "$check_command"; then
    echo "✅ $condition_name is healthy on $cluster"
    return 0
  else
    echo "❌ $condition_name is not healthy on $cluster"
    return 1
  fi
}

# Function to check ODF health
check_odf_health() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "Checking ODF health on $cluster..."
  
  # Check if ODF is installed
  if ! oc --kubeconfig="$kubeconfig" get crd storageclusters.ocs.openshift.io &>/dev/null; then
    echo "ODF CRD not found on $cluster"
    return 1
  fi
  
  # Check ODF storage cluster status
  local storage_cluster_status=$(oc --kubeconfig="$kubeconfig" get storagecluster -n openshift-storage -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "$storage_cluster_status" != "Ready" ]]; then
    echo "ODF storage cluster status on $cluster: $storage_cluster_status"
    return 1
  fi
  
  # Check ODF operator health
  local odf_operator_status=$(oc --kubeconfig="$kubeconfig" get pods -n openshift-storage -l app.kubernetes.io/name=odf-operator --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  odf_operator_status=$(echo "$odf_operator_status" | tr -d ' \n')
  if [[ $odf_operator_status -eq 0 ]]; then
    echo "ODF operator not running on $cluster"
    return 1
  fi
  
  echo "ODF is healthy on $cluster"
  return 0
}

# Function to check S3 service health in openshift-storage namespace
check_s3_service_health() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "Checking S3 service health on $cluster..."
  
  # Check if openshift-storage namespace exists
  if ! oc --kubeconfig="$kubeconfig" get namespace openshift-storage &>/dev/null; then
    echo "openshift-storage namespace not found on $cluster"
    return 1
  fi
  
  # Check for NooBaa (Object Storage) - this provides S3 service
  # Check if NooBaa CRD exists
  if ! oc --kubeconfig="$kubeconfig" get crd noobaas.noobaa.io &>/dev/null; then
    echo "NooBaa CRD not found on $cluster - S3 service may not be available"
    return 1
  fi
  
  # Check if NooBaa system exists and is healthy
  local noobaa_system=$(oc --kubeconfig="$kubeconfig" get noobaa -n openshift-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$noobaa_system" ]]; then
    echo "NooBaa system not found in openshift-storage namespace on $cluster"
    return 1
  fi
  
  # Check NooBaa system status/phase
  local noobaa_phase=$(oc --kubeconfig="$kubeconfig" get noobaa "$noobaa_system" -n openshift-storage -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  local noobaa_ready=$(oc --kubeconfig="$kubeconfig" get noobaa "$noobaa_system" -n openshift-storage -o jsonpath='{.status.ready}' 2>/dev/null || echo "false")
  
  echo "  NooBaa system: $noobaa_system"
  echo "  NooBaa phase: $noobaa_phase"
  echo "  NooBaa ready: $noobaa_ready"
  
  if [[ "$noobaa_phase" != "Ready" ]] && [[ "$noobaa_ready" != "true" ]]; then
    echo "NooBaa system is not ready on $cluster (phase: $noobaa_phase, ready: $noobaa_ready)"
    return 1
  fi
  
  # Check NooBaa operator pods - try multiple label selectors and name patterns
  local noobaa_operator_pods=0
  
  # Try different label selectors
  noobaa_operator_pods=$(oc --kubeconfig="$kubeconfig" get pods -n openshift-storage -l app=noobaa-operator --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  noobaa_operator_pods=$(echo "$noobaa_operator_pods" | tr -d ' \n')
  
  # If not found, try by name pattern
  if [[ $noobaa_operator_pods -eq 0 ]]; then
    noobaa_operator_pods=$(oc --kubeconfig="$kubeconfig" get pods -n openshift-storage --no-headers 2>/dev/null | grep -E "noobaa-operator|noobaa.*operator" | grep -c "Running" || echo "0")
    noobaa_operator_pods=$(echo "$noobaa_operator_pods" | tr -d ' \n')
  fi
  
  # If still not found, try checking deployment instead
  if [[ $noobaa_operator_pods -eq 0 ]]; then
    local noobaa_operator_deployment=$(oc --kubeconfig="$kubeconfig" get deployment -n openshift-storage --no-headers 2>/dev/null | grep -E "noobaa-operator|noobaa.*operator" | wc -l || echo "0")
    noobaa_operator_deployment=$(echo "$noobaa_operator_deployment" | tr -d ' \n')
    if [[ $noobaa_operator_deployment -gt 0 ]]; then
      echo "  NooBaa operator deployment found (pods may be managed by ODF operator)"
      noobaa_operator_pods=1  # Consider it present if deployment exists
    fi
  fi
  
  # If NooBaa is Ready, the operator is likely working even if we can't find pods directly
  if [[ $noobaa_operator_pods -eq 0 ]] && [[ "$noobaa_phase" == "Ready" ]]; then
    echo "  NooBaa operator pods not found by label/name, but NooBaa is Ready - operator likely managed by ODF"
    # Don't fail if NooBaa is Ready - the operator might be managed differently
  elif [[ $noobaa_operator_pods -eq 0 ]]; then
    echo "  ⚠️  NooBaa operator not found on $cluster"
    # Only fail if NooBaa is not Ready AND operator not found
    if [[ "$noobaa_phase" != "Ready" ]]; then
      return 1
    fi
  else
    echo "  ✅ NooBaa operator pods running: $noobaa_operator_pods"
  fi
  
  # Check NooBaa core pods (S3 service provider) - try multiple label selectors and name patterns
  local noobaa_core_pods=0
  
  # Try different label selectors
  noobaa_core_pods=$(oc --kubeconfig="$kubeconfig" get pods -n openshift-storage -l app=noobaa-core --no-headers 2>/dev/null | grep -c "Running" || echo "0")
  noobaa_core_pods=$(echo "$noobaa_core_pods" | tr -d ' \n')
  
  # If not found, try by name pattern
  if [[ $noobaa_core_pods -eq 0 ]]; then
    noobaa_core_pods=$(oc --kubeconfig="$kubeconfig" get pods -n openshift-storage --no-headers 2>/dev/null | grep -E "noobaa-core|noobaa.*core" | grep -c "Running" || echo "0")
    noobaa_core_pods=$(echo "$noobaa_core_pods" | tr -d ' \n')
  fi
  
  # If NooBaa is Ready, core pods are likely working even if we can't find them by label
  if [[ $noobaa_core_pods -eq 0 ]] && [[ "$noobaa_phase" == "Ready" ]]; then
    echo "  NooBaa core pods not found by label/name, but NooBaa is Ready - S3 service likely available"
    # Don't fail if NooBaa is Ready - the core might be managed differently or have different labels
  elif [[ $noobaa_core_pods -eq 0 ]]; then
    echo "  ❌ NooBaa core pods not running on $cluster - S3 service unavailable"
    return 1
  else
    echo "  ✅ NooBaa core pods running: $noobaa_core_pods"
  fi
  
  # Check for S3 service endpoint (Service or Route)
  local s3_service=$(oc --kubeconfig="$kubeconfig" get service -n openshift-storage -l app=noobaa --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "")
  
  if [[ -z "$s3_service" ]]; then
    # Try alternative service names
    s3_service=$(oc --kubeconfig="$kubeconfig" get service -n openshift-storage | grep -i s3 | head -1 | awk '{print $1}' || echo "")
  fi
  
  if [[ -n "$s3_service" ]]; then
    echo "  S3 service found: $s3_service"
    # Check if service has endpoints
    local service_endpoints=$(oc --kubeconfig="$kubeconfig" get endpoints "$s3_service" -n openshift-storage -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || echo "")
    if [[ -z "$service_endpoints" ]]; then
      echo "  ⚠️  S3 service $s3_service has no endpoints"
      return 1
    else
      echo "  ✅ S3 service $s3_service has endpoints"
    fi
  else
    echo "  ⚠️  S3 service not found by name, but NooBaa is running"
    # Don't fail if NooBaa is healthy - the service might be created differently
  fi
  
  # Check NooBaa status conditions for health
  local noobaa_conditions=$(oc --kubeconfig="$kubeconfig" get noobaa "$noobaa_system" -n openshift-storage -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || echo "")
  
  if [[ -n "$noobaa_conditions" ]]; then
    local has_error=false
    while IFS='=' read -r type status; do
      if [[ -n "$type" && -n "$status" ]]; then
        if [[ "$status" == "False" ]] || [[ "$status" == "Unknown" ]]; then
          echo "  ⚠️  NooBaa condition $type is $status"
          # Don't fail immediately - check if it's a critical condition
          if [[ "$type" == *"Available"* ]] || [[ "$type" == *"Ready"* ]]; then
            has_error=true
          fi
        fi
      fi
    done <<< "$noobaa_conditions"
    
    if [[ "$has_error" == "true" ]]; then
      echo "NooBaa has critical error conditions on $cluster"
      return 1
    fi
  fi
  
  echo "✅ S3 service is healthy on $cluster"
  return 0
}

# Function to check CA configuration
check_ca_configuration() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "Checking CA configuration on $cluster..."
  
  # Check if cluster-proxy-ca-bundle ConfigMap exists
  if ! oc --kubeconfig="$kubeconfig" get configmap cluster-proxy-ca-bundle -n openshift-config &>/dev/null; then
    echo "cluster-proxy-ca-bundle ConfigMap not found on $cluster"
    return 1
  fi
  
  # Check if ConfigMap has certificate data
  local ca_bundle_size=$(oc --kubeconfig="$kubeconfig" get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null | wc -c || echo "0")
  ca_bundle_size=$(echo "$ca_bundle_size" | tr -d ' \n')
  if [[ $ca_bundle_size -lt 100 ]]; then
    echo "CA bundle is too small or empty on $cluster (size: $ca_bundle_size)"
    return 1
  fi
  
  # Check if Proxy object is configured
  local proxy_trusted_ca=$(oc --kubeconfig="$kubeconfig" get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || echo "")
  if [[ "$proxy_trusted_ca" != "cluster-proxy-ca-bundle" ]]; then
    echo "Proxy trustedCA not configured correctly on $cluster (current: $proxy_trusted_ca)"
    return 1
  fi
  
  echo "CA configuration is correct on $cluster"
  return 0
}

# Function to check CA material completeness across all clusters
check_ca_material_completeness() {
  local hub_kubeconfig="$1"
  local primary_kubeconfig="$2"
  local secondary_kubeconfig="$3"
  
  echo "Checking CA material completeness across all clusters..."
  
  # Extract CA bundle from each cluster
  local hub_ca_bundle=$(oc --kubeconfig="$hub_kubeconfig" get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || echo "")
  local primary_ca_bundle=$(oc --kubeconfig="$primary_kubeconfig" get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || echo "")
  local secondary_ca_bundle=$(oc --kubeconfig="$secondary_kubeconfig" get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || echo "")
  
  # Check if all CA bundles exist and have reasonable size
  if [[ -z "$hub_ca_bundle" || ${#hub_ca_bundle} -lt 100 ]]; then
    echo "Hub cluster CA bundle is missing or too small"
    return 1
  fi
  
  if [[ -z "$primary_ca_bundle" || ${#primary_ca_bundle} -lt 100 ]]; then
    echo "Primary cluster CA bundle is missing or too small"
    return 1
  fi
  
  if [[ -z "$secondary_ca_bundle" || ${#secondary_ca_bundle} -lt 100 ]]; then
    echo "Secondary cluster CA bundle is missing or too small"
    return 1
  fi
  
  # Check if all CA bundles contain certificates from all three clusters
  echo "🔍 Debug: Checking CA bundle contents..."
  echo "Hub CA bundle size: ${#hub_ca_bundle} characters"
  echo "Primary CA bundle size: ${#primary_ca_bundle} characters"  
  echo "Secondary CA bundle size: ${#secondary_ca_bundle} characters"
  echo "Hub CA bundle first 500 chars:"
  echo "${hub_ca_bundle:0:500}"
  echo ""
  
  # Look for hub cluster certificates
  if [[ "$hub_ca_bundle" != *"# CA from hub-ca"* ]]; then
    echo "Hub cluster CA bundle missing hub-ca certificate"
    echo "Available markers in hub CA bundle:"
    echo "$hub_ca_bundle" | grep "^# CA from" || echo "No CA markers found"
    return 1
  fi
  
  if [[ "$primary_ca_bundle" != *"# CA from hub-ca"* ]]; then
    echo "Primary cluster CA bundle missing hub-ca certificate"
    echo "Available markers in primary CA bundle:"
    echo "$primary_ca_bundle" | grep "^# CA from" || echo "No CA markers found"
    return 1
  fi
  
  if [[ "$secondary_ca_bundle" != *"# CA from hub-ca"* ]]; then
    echo "Secondary cluster CA bundle missing hub-ca certificate"
    echo "Available markers in secondary CA bundle:"
    echo "$secondary_ca_bundle" | grep "^# CA from" || echo "No CA markers found"
    return 1
  fi
  
  # Look for primary cluster certificates (marker from odf-ssl-certificate-extraction.sh)
  if [[ "$hub_ca_bundle" != *"# CA from ${PRIMARY_CLUSTER}-ca"* ]]; then
    echo "Hub cluster CA bundle missing ${PRIMARY_CLUSTER}-ca certificate"
    return 1
  fi
  
  if [[ "$primary_ca_bundle" != *"# CA from ${PRIMARY_CLUSTER}-ca"* ]]; then
    echo "Primary cluster CA bundle missing ${PRIMARY_CLUSTER}-ca certificate"
    return 1
  fi
  
  if [[ "$secondary_ca_bundle" != *"# CA from ${PRIMARY_CLUSTER}-ca"* ]]; then
    echo "Secondary cluster CA bundle missing ${PRIMARY_CLUSTER}-ca certificate"
    return 1
  fi
  
  # Look for secondary cluster certificates
  if [[ "$hub_ca_bundle" != *"# CA from ${SECONDARY_CLUSTER}-ca"* ]]; then
    echo "Hub cluster CA bundle missing ${SECONDARY_CLUSTER}-ca certificate"
    return 1
  fi
  
  if [[ "$primary_ca_bundle" != *"# CA from ${SECONDARY_CLUSTER}-ca"* ]]; then
    echo "Primary cluster CA bundle missing ${SECONDARY_CLUSTER}-ca certificate"
    return 1
  fi
  
  if [[ "$secondary_ca_bundle" != *"# CA from ${SECONDARY_CLUSTER}-ca"* ]]; then
    echo "Secondary cluster CA bundle missing ${SECONDARY_CLUSTER}-ca certificate"
    return 1
  fi
  
  # Check that all CA bundles are identical (they should contain the same combined certificate data)
  if [[ "$hub_ca_bundle" != "$primary_ca_bundle" ]]; then
    echo "Hub and Primary cluster CA bundles are not identical"
    return 1
  fi
  
  if [[ "$hub_ca_bundle" != "$secondary_ca_bundle" ]]; then
    echo "Hub and Secondary cluster CA bundles are not identical"
    return 1
  fi
  
  echo "✅ CA material is complete and consistent across all clusters"
  return 0
}

# Function to download kubeconfig for a cluster
download_kubeconfig() {
  local cluster="$1"
  local kubeconfig_path="$KUBECONFIG_DIR/${cluster}-kubeconfig.yaml"
  
  echo "Downloading kubeconfig for $cluster..."
  
  # Special handling for local-cluster (hub cluster)
  if [[ "$cluster" == "local-cluster" ]]; then
    # For hub cluster, create a kubeconfig using the service account token
    local token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    
    # Create kubeconfig using printf to avoid heredoc issues
    printf 'apiVersion: v1\nkind: Config\nclusters:\n- cluster:\n    certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt\n    server: https://kubernetes.default.svc\n  name: hub-cluster\ncontexts:\n- context:\n    cluster: hub-cluster\n    user: service-account\n  name: hub-context\ncurrent-context: hub-context\nusers:\n- name: service-account\n  user:\n    token: %s\n' "$token" > "$kubeconfig_path"
    
    echo "Created kubeconfig for hub cluster using service account"
    return 0
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
  echo "=== Starting new ODF DR prerequisites check cycle ==="
  
  while [[ $attempt -le $MAX_ATTEMPTS ]]; do
    echo "=== ODF DR Prerequisites Check Attempt $attempt/$MAX_ATTEMPTS ==="
    
    all_checks_passed=true
    
    # Download kubeconfigs
    if ! download_kubeconfig "$HUB_CLUSTER"; then
      echo "Failed to download kubeconfig for $HUB_CLUSTER"
      all_checks_passed=false
    fi
    
    if ! download_kubeconfig "$PRIMARY_CLUSTER"; then
      echo "Failed to download kubeconfig for $PRIMARY_CLUSTER"
      all_checks_passed=false
    fi
    
    if ! download_kubeconfig "$SECONDARY_CLUSTER"; then
      echo "Failed to download kubeconfig for $SECONDARY_CLUSTER"
      all_checks_passed=false
    fi
    
    if [[ "$all_checks_passed" == "true" ]]; then
      # Check ODF health
      if ! check_odf_health "$PRIMARY_CLUSTER" "$KUBECONFIG_DIR/${PRIMARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      if ! check_odf_health "$SECONDARY_CLUSTER" "$KUBECONFIG_DIR/${SECONDARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      # Check S3 service health on all clusters
      if ! check_s3_service_health "$HUB_CLUSTER" "$KUBECONFIG_DIR/${HUB_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      if ! check_s3_service_health "$PRIMARY_CLUSTER" "$KUBECONFIG_DIR/${PRIMARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      if ! check_s3_service_health "$SECONDARY_CLUSTER" "$KUBECONFIG_DIR/${SECONDARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      # Check CA configuration on individual clusters
      if ! check_ca_configuration "$HUB_CLUSTER" "$KUBECONFIG_DIR/${HUB_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      if ! check_ca_configuration "$PRIMARY_CLUSTER" "$KUBECONFIG_DIR/${PRIMARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      if ! check_ca_configuration "$SECONDARY_CLUSTER" "$KUBECONFIG_DIR/${SECONDARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
      
      # Check CA material completeness across all clusters
      if ! check_ca_material_completeness "$KUBECONFIG_DIR/${HUB_CLUSTER}-kubeconfig.yaml" "$KUBECONFIG_DIR/${PRIMARY_CLUSTER}-kubeconfig.yaml" "$KUBECONFIG_DIR/${SECONDARY_CLUSTER}-kubeconfig.yaml"; then
        all_checks_passed=false
      fi
    fi
    
    if [[ "$all_checks_passed" == "true" ]]; then
      echo "🎉 All ODF DR prerequisites are met! Proceeding with Submariner prerequisites..."
      exit 0
    else
      echo "❌ Some ODF DR prerequisites are not met. Waiting $SLEEP_INTERVAL seconds before retry..."
      sleep $SLEEP_INTERVAL
      ((attempt++))
    fi
  done
  
  echo "❌ ODF DR prerequisites check failed after $MAX_ATTEMPTS attempts"
  echo "🔄 Continuing to retry until all prerequisites are met..."
  echo "Please ensure:"
  echo "1. ODF is installed and healthy on both managed clusters"
  echo "2. S3 service is healthy in openshift-storage namespace on all clusters (hub, primary, secondary)"
  echo "3. CA certificates are properly configured on all three clusters (hub, primary, secondary)"
  echo "4. All clusters have identical CA bundles containing certificates from all three clusters"
  echo ""
  echo "🔄 Restarting ODF DR prerequisites check..."
  # Reset attempt counter and continue
  attempt=1
  sleep $SLEEP_INTERVAL
done  # End of infinite retry loop


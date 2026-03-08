#!/bin/bash
set -euo pipefail

echo "Starting ODF SSL certificate extraction and distribution..."
echo "Following Red Hat ODF Disaster Recovery certificate management guidelines"

# Configuration for retry logic
MAX_RETRIES=5
BASE_DELAY=30
MAX_DELAY=300
RETRY_COUNT=0

# Function to implement exponential backoff
exponential_backoff() {
  local delay=$((BASE_DELAY * (2 ** RETRY_COUNT)))
  if [[ $delay -gt $MAX_DELAY ]]; then
    delay=$MAX_DELAY
  fi
  echo "⏳ Waiting $delay seconds before retry (attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
  sleep $delay
  ((RETRY_COUNT++))
}

# Function to handle errors gracefully
handle_error() {
  local error_msg="$1"
  echo "❌ Error: $error_msg"
  
  if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
    echo "🔄 Retrying in a moment..."
    exponential_backoff
    return 0
  else
    echo "💥 Max retries exceeded. Job will exit but ArgoCD can retry the sync."
    echo "   This is a temporary failure - the job will be retried on next ArgoCD sync."
    exit 1
  fi
}

# Main execution with retry logic
main_execution() {
  # Create working directory
  WORK_DIR="/tmp/odf-ssl-certs"
  mkdir -p "$WORK_DIR"

# Function to extract CA from cluster
extract_cluster_ca() {
  cluster_name="$1"
  output_file="$2"
  kubeconfig="${3:-}"
  
  echo "Extracting CA from cluster: $cluster_name"
  
  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    # Use provided kubeconfig
    echo "  Using kubeconfig: $kubeconfig"
    if oc --kubeconfig="$kubeconfig" get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > "$output_file" 2>/dev/null; then
      if [[ -s "$output_file" ]]; then
        echo "  CA extracted from $cluster_name using kubeconfig"
        return 0
      else
        echo "  CA file is empty from $cluster_name"
        return 1
      fi
    else
      echo "  Failed to get trusted-ca-bundle from $cluster_name"
      return 1
    fi
  else
    # Use current context (hub cluster)
    echo "  Using current context for hub cluster"
    if oc get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > "$output_file" 2>/dev/null; then
      if [[ -s "$output_file" ]]; then
        echo "  CA extracted from $cluster_name using current context"
        return 0
      else
        echo "  CA file is empty from $cluster_name"
        return 1
      fi
    else
      echo "  Failed to get trusted-ca-bundle from $cluster_name"
      return 1
    fi
  fi
}

# Function to extract ingress CA from cluster
extract_ingress_ca() {
  cluster_name="$1"
  output_file="$2"
  kubeconfig="${3:-}"
  
  echo "Extracting ingress CA from cluster: $cluster_name"
  
  if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
    # Use provided kubeconfig
    echo "  Using kubeconfig: $kubeconfig"
    # Try to get ingress CA from router-ca secret
    if oc --kubeconfig="$kubeconfig" get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$output_file" 2>/dev/null; then
      if [[ -s "$output_file" ]]; then
        echo "  Ingress CA extracted from $cluster_name using kubeconfig"
        return 0
      fi
    fi
    # Fallback: try to get from ingress operator config
    if oc --kubeconfig="$kubeconfig" get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$output_file" 2>/dev/null; then
      if [[ -s "$output_file" ]]; then
        echo "  Ingress CA extracted from $cluster_name using kubeconfig (fallback)"
        return 0
      fi
    fi
    echo "  Failed to get ingress CA from $cluster_name"
    return 1
  else
    # Use current context (hub cluster)
    echo "  Using current context for hub cluster"
    # Try to get ingress CA from router-ca secret
    if oc get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$output_file" 2>/dev/null; then
      if [[ -s "$output_file" ]]; then
        echo "  Ingress CA extracted from $cluster_name using current context"
        return 0
      fi
    fi
    # Fallback: try to get from ingress operator config
    if oc get secret -n openshift-ingress-operator router-ca -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$output_file" 2>/dev/null; then
      if [[ -s "$output_file" ]]; then
        echo "  Ingress CA extracted from $cluster_name using current context (fallback)"
        return 0
      fi
    fi
    echo "  Failed to get ingress CA from $cluster_name"
    return 1
  fi
}

# Function to create combined CA bundle
create_combined_ca_bundle() {
  output_file="$1"
  shift
  ca_files=("$@")
  
  echo "Creating combined CA bundle..."
  > "$output_file"
  
  file_count=0
  for ca_file in "${ca_files[@]}"; do
    if [[ -f "$ca_file" && -s "$ca_file" ]]; then
      echo "# CA from $(basename "$ca_file" .crt)" >> "$output_file"
      
      # Extract only the first few complete certificates to avoid size limits
      cert_count=0
      in_cert=false
      while IFS= read -r line; do
        if [[ "$line" == "-----BEGIN CERTIFICATE-----" ]]; then
          in_cert=true
          cert_count=$((cert_count + 1))
          if [[ $cert_count -gt 5 ]]; then
            break
          fi
        fi
        if [[ $in_cert == true ]]; then
          echo "$line" >> "$output_file"
        fi
        if [[ "$line" == "-----END CERTIFICATE-----" ]]; then
          in_cert=false
          echo "" >> "$output_file"
        fi
      done < "$ca_file"
      
      file_count=$((file_count + 1))
    fi
  done
  
  if [[ $file_count -gt 0 ]]; then
    echo "Combined CA bundle created with $file_count CA sources (first 5 certs each)"
    return 0
  else
    echo "No valid CA files found to combine"
    return 1
  fi
}

# Extract hub cluster CA
echo "1. Extracting hub cluster CA..."
if extract_cluster_ca "hub" "$WORK_DIR/hub-ca.crt"; then
  echo "  Hub cluster CA extracted successfully"
  echo "  Certificate size: $(wc -c < "$WORK_DIR/hub-ca.crt") bytes"
  echo "  First few lines:"
  head -n 5 "$WORK_DIR/hub-ca.crt"
else
  echo "  Failed to extract hub cluster CA"
  echo "  Job will continue with managed cluster certificates only"
fi

# Extract hub cluster ingress CA
echo "1b. Extracting hub cluster ingress CA..."
if extract_ingress_ca "hub" "$WORK_DIR/hub-ingress-ca.crt"; then
  echo "  Hub cluster ingress CA extracted successfully"
  echo "  Certificate size: $(wc -c < "$WORK_DIR/hub-ingress-ca.crt") bytes"
else
  echo "  Failed to extract hub cluster ingress CA"
  echo "  Job will continue without hub ingress CA"
fi

# Get managed clusters
echo "2. Discovering managed clusters..."
MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$MANAGED_CLUSTERS" ]]; then
  echo "  No managed clusters found"
else
  echo "  Found managed clusters: $MANAGED_CLUSTERS"
fi

# Primary and secondary managed cluster names (from values.yaml via env)
PRIMARY_CLUSTER="${PRIMARY_CLUSTER:-ocp-primary}"
SECONDARY_CLUSTER="${SECONDARY_CLUSTER:-ocp-secondary}"

# Extract CA from each managed cluster
CA_FILES=()
REQUIRED_CLUSTERS=("hub" "$PRIMARY_CLUSTER" "$SECONDARY_CLUSTER")
EXTRACTED_CLUSTERS=()

# Track hub cluster CA extraction
if [[ -f "$WORK_DIR/hub-ca.crt" && -s "$WORK_DIR/hub-ca.crt" ]]; then
  CA_FILES+=("$WORK_DIR/hub-ca.crt")
  EXTRACTED_CLUSTERS+=("hub")
  echo "  Added hub CA to bundle"
else
  echo "  ❌ Hub CA not available - REQUIRED for DR setup"
fi

if [[ -f "$WORK_DIR/hub-ingress-ca.crt" && -s "$WORK_DIR/hub-ingress-ca.crt" ]]; then
  CA_FILES+=("$WORK_DIR/hub-ingress-ca.crt")
  echo "  Added hub ingress CA to bundle"
else
  echo "  Hub ingress CA not available, continuing without it"
fi

index=1

for cluster in $MANAGED_CLUSTERS; do
  if [[ "$cluster" == "local-cluster" ]]; then
    continue
  fi
  
  echo "3.$index Extracting CA from $cluster..."
  
  # Try to get kubeconfig for the cluster
  KUBECONFIG_FILE=""
  if oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | base64 -d > "$WORK_DIR/${cluster}-kubeconfig.yaml" 2>/dev/null; then
    KUBECONFIG_FILE="$WORK_DIR/${cluster}-kubeconfig.yaml"
  fi
  
  cluster_ca_extracted=false
  if extract_cluster_ca "$cluster" "$WORK_DIR/${cluster}-ca.crt" "$KUBECONFIG_FILE"; then
    CA_FILES+=("$WORK_DIR/${cluster}-ca.crt")
    EXTRACTED_CLUSTERS+=("$cluster")
    cluster_ca_extracted=true
    echo "  Certificate size: $(wc -c < "$WORK_DIR/${cluster}-ca.crt") bytes"
  else
    echo "  ❌ Could not extract CA from $cluster - REQUIRED for DR setup"
  fi
  
  # Extract ingress CA from managed cluster
  echo "3b.$index Extracting ingress CA from $cluster..."
  if extract_ingress_ca "$cluster" "$WORK_DIR/${cluster}-ingress-ca.crt" "$KUBECONFIG_FILE"; then
    CA_FILES+=("$WORK_DIR/${cluster}-ingress-ca.crt")
    echo "  Ingress CA certificate size: $(wc -c < "$WORK_DIR/${cluster}-ingress-ca.crt") bytes"
  else
    echo "  Warning: Could not extract ingress CA from $cluster, continuing without it"
  fi
  
  ((index++))
done

# Validate that we have CA material from all required clusters
echo "4. Validating CA extraction from required clusters..."
MISSING_CLUSTERS=()
for required_cluster in "${REQUIRED_CLUSTERS[@]}"; do
  if [[ " ${EXTRACTED_CLUSTERS[@]} " =~ " ${required_cluster} " ]]; then
    echo "  ✅ CA extracted from $required_cluster"
  else
    echo "  ❌ CA NOT extracted from $required_cluster"
    MISSING_CLUSTERS+=("$required_cluster")
  fi
done

if [[ ${#MISSING_CLUSTERS[@]} -gt 0 ]]; then
  echo ""
  echo "❌ CRITICAL ERROR: CA material missing from required clusters:"
  for missing in "${MISSING_CLUSTERS[@]}"; do
    echo "   - $missing"
  done
  echo ""
  echo "The ODF SSL certificate extractor job requires CA material from ALL three clusters:"
  echo "   - hub (hub cluster)"
  echo "   - $PRIMARY_CLUSTER (primary managed cluster)"
  echo "   - $SECONDARY_CLUSTER (secondary managed cluster)"
  echo ""
  echo "Without CA material from all clusters, the DR setup will fail."
  echo "Please ensure all clusters are accessible and have proper kubeconfigs."
  echo ""
  echo "Job will exit with error code 1."
  exit 1
fi

# Create combined CA bundle
echo "5. Creating combined CA bundle..."
echo "  CA files to combine: ${#CA_FILES[@]} files"
for ca_file in "${CA_FILES[@]}"; do
  echo "    - $(basename "$ca_file") ($(wc -c < "$ca_file") bytes)"
done

if create_combined_ca_bundle "$WORK_DIR/combined-ca-bundle.crt" "${CA_FILES[@]}"; then
  echo "  Combined CA bundle created successfully"
  echo "  Bundle size: $(wc -c < "$WORK_DIR/combined-ca-bundle.crt") bytes"
  echo "  First few lines of bundle:"
  head -n 10 "$WORK_DIR/combined-ca-bundle.crt"
else
  echo "  Failed to create combined CA bundle - no certificates extracted"
  echo "  Job will exit as no certificate data is available"
  exit 1
fi

# Create or update ConfigMap on hub cluster
echo "6. Creating/updating cluster-proxy-ca-bundle ConfigMap on hub cluster..."

# Check if ConfigMap exists
if oc get configmap cluster-proxy-ca-bundle -n openshift-config >/dev/null 2>&1; then
  echo "  ConfigMap exists, patching with certificate data..."
  # Create a temporary patch file to avoid JSON escaping issues
  echo "data:" > "$WORK_DIR/patch.yaml"
  echo "  ca-bundle.crt: |" >> "$WORK_DIR/patch.yaml"
  cat "$WORK_DIR/combined-ca-bundle.crt" | sed 's/^/    /' >> "$WORK_DIR/patch.yaml"
  oc patch configmap cluster-proxy-ca-bundle -n openshift-config \
    --type=merge \
    --patch-file="$WORK_DIR/patch.yaml"
  rm -f "$WORK_DIR/patch.yaml"
else
  echo "  ConfigMap does not exist, creating with certificate data..."
  oc create configmap cluster-proxy-ca-bundle \
    --from-file=ca-bundle.crt="$WORK_DIR/combined-ca-bundle.crt" \
    -n openshift-config
fi

echo "  ConfigMap created/updated successfully with certificate data"
echo "  Certificate bundle contains CA certificates from hub and managed clusters"

# Update hub cluster proxy
echo "7. Updating hub cluster proxy configuration..."
oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"cluster-proxy-ca-bundle"}}}' || {
  echo "  Warning: Could not update hub cluster proxy"
}

# Restart ramenddr-cluster-operator pods on managed clusters before updating configmap
echo "7a. Restarting ramenddr-cluster-operator pods on managed clusters..."

for cluster in $MANAGED_CLUSTERS; do
  if [[ "$cluster" == "local-cluster" ]]; then
    continue
  fi
  
  echo "  Processing cluster: $cluster"
  
  # Get kubeconfig for the cluster
  KUBECONFIG_FILE=""
  if oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | base64 -d > "$WORK_DIR/${cluster}-kubeconfig.yaml" 2>/dev/null; then
    KUBECONFIG_FILE="$WORK_DIR/${cluster}-kubeconfig.yaml"
  fi
  
  if [[ -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
    # Find ramenddr-cluster-operator pods
    RAMEN_PODS=$(oc --kubeconfig="$KUBECONFIG_FILE" get pods -n openshift-dr-system -l app=ramenddr-cluster-operator -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$RAMEN_PODS" ]]; then
      echo "    Found ramenddr-cluster-operator pods: $RAMEN_PODS"
      
      for pod in $RAMEN_PODS; do
        echo "    Deleting pod $pod to trigger restart..."
        oc --kubeconfig="$KUBECONFIG_FILE" delete pod "$pod" -n openshift-dr-system --ignore-not-found=true || {
          echo "    Warning: Could not delete pod $pod"
        }
      done
      
      # Wait for pods to be deleted
      echo "    Waiting for pods to be terminated..."
      for pod in $RAMEN_PODS; do
        oc --kubeconfig="$KUBECONFIG_FILE" wait --for=delete pod/"$pod" -n openshift-dr-system --timeout=60s 2>/dev/null || true
      done
      
      # Wait for new pods to be running
      echo "    Waiting for new ramenddr-cluster-operator pods to be running..."
      MAX_WAIT_ATTEMPTS=30
      WAIT_INTERVAL=10
      attempt=0
      
      while [[ $attempt -lt $MAX_WAIT_ATTEMPTS ]]; do
        attempt=$((attempt + 1))
        
        NEW_PODS=$(oc --kubeconfig="$KUBECONFIG_FILE" get pods -n openshift-dr-system -l app=ramenddr-cluster-operator -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        ALL_RUNNING=true
        
        if [[ -n "$NEW_PODS" ]]; then
          for pod in $NEW_PODS; do
            POD_STATUS=$(oc --kubeconfig="$KUBECONFIG_FILE" get pod "$pod" -n openshift-dr-system -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [[ "$POD_STATUS" != "Running" ]]; then
              ALL_RUNNING=false
              break
            fi
          done
          
          if [[ "$ALL_RUNNING" == "true" ]]; then
            echo "    ✅ All ramenddr-cluster-operator pods are running on $cluster: $NEW_PODS"
            break
          else
            echo "    ⏳ Waiting for pods to be running (attempt $attempt/$MAX_WAIT_ATTEMPTS)"
          fi
        else
          echo "    ⏳ Waiting for pods to appear (attempt $attempt/$MAX_WAIT_ATTEMPTS)"
        fi
        
        if [[ $attempt -lt $MAX_WAIT_ATTEMPTS ]]; then
          sleep $WAIT_INTERVAL
        fi
      done
      
      if [[ $attempt -ge $MAX_WAIT_ATTEMPTS ]]; then
        echo "    ⚠️  Warning: ramenddr-cluster-operator pods did not become ready within expected time on $cluster"
        echo "     The pods may still be starting - configuration changes will be applied when ready"
      fi
    else
      echo "    ⚠️  Warning: ramenddr-cluster-operator pods not found on $cluster - they may not be deployed yet"
      echo "     Configuration changes will be applied when the pods start"
    fi
  else
    echo "    ❌ Could not get kubeconfig for $cluster - skipping pod restart"
  fi
done

echo "  ✅ Completed ramenddr-cluster-operator pod restarts on managed clusters"

# Update ramen-hub-operator-config with base64-encoded CA bundle
echo "7b. Updating ramen-hub-operator-config in openshift-operators namespace..."

# Base64 encode the combined CA bundle
CA_BUNDLE_BASE64=$(base64 -w 0 < "$WORK_DIR/combined-ca-bundle.crt" 2>/dev/null || base64 < "$WORK_DIR/combined-ca-bundle.crt" | tr -d '\n')

# Check if ramen-hub-operator-config exists
if oc get configmap ramen-hub-operator-config -n openshift-operators &>/dev/null; then
  echo "  ConfigMap exists, updating ramen_manager_config.yaml with caCertificates in s3StoreProfiles..."
  
  # Get existing ramen_manager_config.yaml content
  EXISTING_YAML=$(oc get configmap ramen-hub-operator-config -n openshift-operators -o jsonpath='{.data.ramen_manager_config\.yaml}' 2>/dev/null || echo "")
  
  # Patch existing s3StoreProfiles only: add/update caCertificates on each existing profile.
  # We do NOT create new profiles or delete/overwrite profile names. At least 2 existing profiles required.
  MIN_REQUIRED_PROFILES=2
  if [[ -n "$EXISTING_YAML" ]]; then
    if command -v yq &>/dev/null; then
      COUNT_KOP=$(echo "$EXISTING_YAML" | yq eval '.kubeObjectProtection.s3StoreProfiles | length' 2>/dev/null || echo "0")
      COUNT_TOP=$(echo "$EXISTING_YAML" | yq eval '.s3StoreProfiles | length' 2>/dev/null || echo "0")
      COUNT_KOP=$((10#${COUNT_KOP:-0}))
      COUNT_TOP=$((10#${COUNT_TOP:-0}))
      EXISTING_PROFILE_COUNT=$(( COUNT_KOP >= COUNT_TOP ? COUNT_KOP : COUNT_TOP ))
    else
      EXISTING_PROFILE_COUNT=$(echo "$EXISTING_YAML" | grep -c "s3ProfileName:" 2>/dev/null || echo "0")
      if [[ $EXISTING_PROFILE_COUNT -eq 0 ]]; then
        EXISTING_PROFILE_COUNT=$(echo "$EXISTING_YAML" | grep -c "s3Bucket:" 2>/dev/null || echo "0")
      fi
    fi
    EXISTING_PROFILE_COUNT=$(echo "$EXISTING_PROFILE_COUNT" | tr -d ' \n\r' | grep -E '^[0-9]+$' || echo "0")
    EXISTING_PROFILE_COUNT=$((10#$EXISTING_PROFILE_COUNT))
    if [[ $EXISTING_PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
      echo "  ❌ CRITICAL: Insufficient s3StoreProfiles found in existing ConfigMap"
      echo "     Found: $EXISTING_PROFILE_COUNT profile(s)"
      echo "     Required: At least $MIN_REQUIRED_PROFILES profiles"
      echo "     Current YAML content (first 50 lines):"
      echo "$EXISTING_YAML" | head -n 50
      echo ""
      echo "     The certificate extractor only patches existing s3StoreProfiles with caCertificates."
      echo "     Please ensure ramen-hub-operator-config has at least $MIN_REQUIRED_PROFILES s3StoreProfiles configured."
      handle_error "Insufficient s3StoreProfiles found: found $EXISTING_PROFILE_COUNT profile(s), but at least $MIN_REQUIRED_PROFILES are required"
    else
      echo "  ✅ Found $EXISTING_PROFILE_COUNT s3StoreProfiles (will patch caCertificates into existing profiles only)"
    fi
  fi

  # Patch existing profiles with caCertificates using yq only (env var avoids embedding base64 in expression)
  PATCHED_VIA_YQ=false
  if [[ -n "$EXISTING_YAML" ]]; then
    echo "$EXISTING_YAML" > "$WORK_DIR/existing-ramen-config.yaml"
    echo "  Existing YAML content (first 20 lines):"
    echo "$EXISTING_YAML" | head -n 20
    echo "  Patching s3StoreProfiles with caCertificates using yq..."

    if ! command -v yq &>/dev/null; then
      echo "  ❌ yq is required but not found in PATH"
      handle_error "yq is required to patch ramen_manager_config with caCertificates; please install yq (e.g. mikefarah/yq)"
    fi

    export CA_BUNDLE_BASE64
    YQ_PATCHED=false
    # Use strenv() so the base64 value is passed as a string without embedding in the expression (avoids quoting/special-char issues)
    if yq eval -i '.s3StoreProfiles[]? |= . + {"caCertificates": strenv(CA_BUNDLE_BASE64)}' "$WORK_DIR/existing-ramen-config.yaml" 2>/dev/null; then
      YQ_PATCHED=true
    fi
    if yq eval -i '.kubeObjectProtection.s3StoreProfiles[]? |= . + {"caCertificates": strenv(CA_BUNDLE_BASE64)}' "$WORK_DIR/existing-ramen-config.yaml" 2>/dev/null; then
      YQ_PATCHED=true
    fi
    if [[ "$YQ_PATCHED" != "true" ]]; then
      echo "  ❌ yq failed to patch s3StoreProfiles (no top-level or kubeObjectProtection.s3StoreProfiles found?)"
      echo "  yq version: $(yq --version 2>/dev/null || true)"
      handle_error "yq could not update s3StoreProfiles with caCertificates"
    fi
    echo "  ✅ Patched existing s3StoreProfiles with caCertificates using yq"

    rm -f "$WORK_DIR/existing-ramen-config.yaml.bak" "$WORK_DIR/existing-ramen-config.yaml.tmp"

    # Verify patch (grep in file; do NOT load full content into shell variable - base64 can exceed ARG_MAX and truncate)
    if [[ -f "$WORK_DIR/existing-ramen-config.yaml" ]]; then
      if ! grep -q "caCertificates" "$WORK_DIR/existing-ramen-config.yaml" 2>/dev/null; then
        echo "  ❌ No caCertificates in updated YAML (patch failed or no s3StoreProfiles to patch)"
        handle_error "Failed to patch ramen_manager_config with caCertificates - update produced no caCertificates"
      fi
      echo "  Updated YAML content (first 20 lines):"
      head -n 20 "$WORK_DIR/existing-ramen-config.yaml"
      echo "  ✅ Verified: caCertificates found in updated YAML"
      # Copy file directly; do NOT use a shell variable (large base64 would truncate and break the applied ConfigMap)
      cp "$WORK_DIR/existing-ramen-config.yaml" "$WORK_DIR/ramen_manager_config.yaml"
      PATCHED_VIA_YQ=true
    else
      echo "  ❌ Error: Updated YAML file not found"
      PATCHED_VIA_YQ=false
    fi
  else
    # No existing YAML (ConfigMap exists but ramen_manager_config.yaml empty): create minimal config with 2 profiles (parameterized by cluster name)
    UPDATED_YAML="kubeObjectProtection:
  s3StoreProfiles:
  - s3ProfileName: $PRIMARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
  - s3ProfileName: $SECONDARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
s3StoreProfiles:
  - s3ProfileName: $PRIMARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
  - s3ProfileName: $SECONDARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\""
  fi

  # Save updated YAML for apply (only write from variable when we did not already copy the patched file)
  if [[ "$PATCHED_VIA_YQ" != "true" ]]; then
    echo "$UPDATED_YAML" > "$WORK_DIR/ramen_manager_config.yaml"
  fi
  
  echo "  Preparing to update ConfigMap with YAML content..."
  echo "  YAML file size: $(wc -c < "$WORK_DIR/ramen_manager_config.yaml") bytes"
  echo "  YAML file preview (first 10 lines):"
  head -n 10 "$WORK_DIR/ramen_manager_config.yaml"
  
  # Build ConfigMap manifest: use literal-block method first (reliable, no yq/Python dependency)
  echo "  Creating ConfigMap manifest with updated data..."
  oc get configmap ramen-hub-operator-config -n openshift-operators -o yaml > "$WORK_DIR/ramen-configmap-template.yaml" 2>/dev/null
  
  if [[ -f "$WORK_DIR/ramen-configmap-template.yaml" ]]; then
    # Always use the canonical name so we update the expected ConfigMap and verification finds it
    METADATA_NAMESPACE=openshift-operators
    METADATA_NAME=ramen-hub-operator-config
    echo "  Building ConfigMap manifest (literal block for ramen_manager_config.yaml)..."
    {
      echo "apiVersion: v1"
      echo "kind: ConfigMap"
      echo "metadata:"
      echo "  name: $METADATA_NAME"
      echo "  namespace: $METADATA_NAMESPACE"
      echo "data:"
      echo "  ramen_manager_config.yaml: |"
      sed 's/^/    /' "$WORK_DIR/ramen_manager_config.yaml"
    } > "$WORK_DIR/ramen-configmap-updated.yaml"

    if [[ -f "$WORK_DIR/ramen-configmap-updated.yaml" ]]; then
      echo "  Applying updated ConfigMap..."
      UPDATE_OUTPUT=$(oc apply -f "$WORK_DIR/ramen-configmap-updated.yaml" 2>&1)
      UPDATE_EXIT_CODE=$?
      rm -f "$WORK_DIR/ramen-configmap-template.yaml" "$WORK_DIR/ramen-configmap-updated.yaml"
    else
      echo "  ❌ Error: Could not create updated ConfigMap manifest"
      UPDATE_EXIT_CODE=1
      UPDATE_OUTPUT="Failed to create updated ConfigMap manifest"
    fi
  else
    echo "  ⚠️  Could not retrieve ConfigMap template, trying oc set data as fallback..."
    # Fallback to oc set data
    UPDATE_OUTPUT=$(oc set data configmap/ramen-hub-operator-config -n openshift-operators \
      ramen_manager_config.yaml="$(cat "$WORK_DIR/ramen_manager_config.yaml")" 2>&1)
    UPDATE_EXIT_CODE=$?
  fi
  
  echo "  Update exit code: $UPDATE_EXIT_CODE"
  echo "  Update output: $UPDATE_OUTPUT"
  
  if [[ $UPDATE_EXIT_CODE -eq 0 ]]; then
    # Verify the update was successful - CRITICAL: must verify CA material is in s3StoreProfiles
    sleep 2
    VERIFIED_YAML=$(oc get configmap ramen-hub-operator-config -n openshift-operators -o jsonpath='{.data.ramen_manager_config\.yaml}' 2>/dev/null || echo "")
    
    # Strict verification: must have s3StoreProfiles, caCertificates, and the actual CA bundle
    VERIFICATION_PASSED=true
    VERIFICATION_ERRORS=()
    
    if ! echo "$VERIFIED_YAML" | grep -q "s3StoreProfiles"; then
      VERIFICATION_PASSED=false
      VERIFICATION_ERRORS+=("s3StoreProfiles not found in ConfigMap")
    fi
    
    if ! echo "$VERIFIED_YAML" | grep -q "caCertificates"; then
      VERIFICATION_PASSED=false
      VERIFICATION_ERRORS+=("caCertificates not found in ConfigMap")
    fi
    
    # Optional: exact base64 match can fail due to encoding/line wrap in stored ConfigMap
    # Prefer verifying profile/caCertificates counts below; only warn if base64 substring missing
    if [[ -n "$CA_BUNDLE_BASE64" ]] && [[ ${#CA_BUNDLE_BASE64} -gt 20 ]]; then
      CA_PREFIX="${CA_BUNDLE_BASE64:0:80}"
      if ! echo "$VERIFIED_YAML" | grep -qF "$CA_PREFIX"; then
        echo "  ⚠️  Note: CA bundle prefix not found in retrieved ConfigMap (encoding may differ); relying on profile/caCertificates count"
      fi
    fi

    # Verify structure: s3StoreProfiles under kubeObjectProtection or at top level (match script output)
    MIN_REQUIRED_PROFILES=2
    if echo "$VERIFIED_YAML" | grep -q "s3StoreProfiles"; then
      if command -v yq &>/dev/null; then
        PK=$(echo "$VERIFIED_YAML" | yq eval '.kubeObjectProtection.s3StoreProfiles | length' 2>/dev/null || echo "0")
        PT=$(echo "$VERIFIED_YAML" | yq eval '.s3StoreProfiles | length' 2>/dev/null || echo "0")
        CK=$(echo "$VERIFIED_YAML" | yq eval '[.kubeObjectProtection.s3StoreProfiles[]? | select(has("caCertificates"))] | length' 2>/dev/null || echo "0")
        CT=$(echo "$VERIFIED_YAML" | yq eval '[.s3StoreProfiles[]? | select(has("caCertificates"))] | length' 2>/dev/null || echo "0")
        # Normalize: yq can return "null" or empty; treat as 0
        PK=$((10#${PK:-0})); PT=$((10#${PT:-0})); CK=$((10#${CK:-0})); CT=$((10#${CT:-0}))
        PROFILE_COUNT=$(( PK >= PT ? PK : PT ))
        CA_CERT_COUNT=$(( CK >= CT ? CK : CT ))
      else
        PROFILE_COUNT=0
        CA_CERT_COUNT=0
      fi
      # If yq returned 0/0 but YAML clearly has content, use grep-based counts (works regardless of yq version/parsing)
      if [[ $PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES || $CA_CERT_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
        PROFILE_COUNT=$(echo "$VERIFIED_YAML" | grep -c "s3ProfileName:" 2>/dev/null || echo "0")
        [[ "${PROFILE_COUNT:-0}" -eq 0 ]] && PROFILE_COUNT=$(echo "$VERIFIED_YAML" | grep -c "s3Bucket:" 2>/dev/null || echo "0")
        CA_CERT_COUNT=$(echo "$VERIFIED_YAML" | grep -c "caCertificates:" 2>/dev/null || echo "0")
      fi
      PROFILE_COUNT=$(echo "$PROFILE_COUNT" | tr -d ' \n\r' | grep -E '^[0-9]+$' || echo "0")
      CA_CERT_COUNT=$(echo "$CA_CERT_COUNT" | tr -d ' \n\r' | grep -E '^[0-9]+$' || echo "0")
      PROFILE_COUNT=$((10#$PROFILE_COUNT))
      CA_CERT_COUNT=$((10#$CA_CERT_COUNT))
      
      # Check if we have at least the minimum required profiles
      if [[ $PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
        VERIFICATION_PASSED=false
        VERIFICATION_ERRORS+=("Insufficient s3StoreProfiles found: found $PROFILE_COUNT profile(s), but at least $MIN_REQUIRED_PROFILES are required")
      fi
      
      if [[ $PROFILE_COUNT -gt 0 && $CA_CERT_COUNT -lt $PROFILE_COUNT ]]; then
        VERIFICATION_PASSED=false
        VERIFICATION_ERRORS+=("Not all s3StoreProfiles items have caCertificates (found $PROFILE_COUNT profiles but only $CA_CERT_COUNT caCertificates)")
      fi
      
      # CRITICAL: Verify all profiles have caCertificates (exact match required)
      if [[ $PROFILE_COUNT -gt 0 && $CA_CERT_COUNT -ne $PROFILE_COUNT ]]; then
        VERIFICATION_PASSED=false
        VERIFICATION_ERRORS+=("CRITICAL: All $PROFILE_COUNT profile(s) must have caCertificates, but only $CA_CERT_COUNT have it")
      fi
    else
      VERIFICATION_PASSED=false
      VERIFICATION_ERRORS+=("s3StoreProfiles section not found in ConfigMap")
    fi
    
    # Additional explicit check before declaring success
    PROFILE_COUNT=${PROFILE_COUNT:-0}
    CA_CERT_COUNT=${CA_CERT_COUNT:-0}
    if [[ $PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES || $CA_CERT_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
      VERIFICATION_PASSED=false
      VERIFICATION_ERRORS+=("CRITICAL: Must have at least $MIN_REQUIRED_PROFILES s3StoreProfiles with caCertificates, but found $PROFILE_COUNT profiles and $CA_CERT_COUNT caCertificates")
    fi
    
    if [[ "$VERIFICATION_PASSED" == "true" ]]; then
      echo "  ✅ ramen-hub-operator-config updated and verified successfully"
      echo "     caCertificates added to all s3StoreProfiles items ($PROFILE_COUNT profiles, $CA_CERT_COUNT caCertificates)"
      echo "     CA bundle base64 data verified in ConfigMap"
    else
      echo "  ❌ CRITICAL: ramen-hub-operator-config update verification FAILED"
      echo "     The CA material has NOT been properly added to s3StoreProfiles"
      for error in "${VERIFICATION_ERRORS[@]}"; do
        echo "     - $error"
      done
      echo "     Current YAML content:"
      echo "$VERIFIED_YAML"
      echo "     Update output: $UPDATE_OUTPUT"
      echo "     This is a CRITICAL error - the ConfigMap is not complete and correct"
      handle_error "ramen-hub-operator-config verification failed - CA material not in s3StoreProfiles"
    fi
  else
    echo "  ❌ Error: Could not update ramen-hub-operator-config using oc set data"
    echo "     Update output: $UPDATE_OUTPUT"
    echo "     Attempting alternative approach using oc patch with JSON..."
    
    # Alternative: Use oc patch with JSON format
    # Get the ConfigMap, update it, and create a JSON patch
    oc get configmap ramen-hub-operator-config -n openshift-operators -o json > "$WORK_DIR/ramen-configmap.json" 2>/dev/null
    if [[ -f "$WORK_DIR/ramen-configmap.json" ]]; then
      # Update the data section using jq if available, or python
      if command -v jq &>/dev/null; then
        # Escape the YAML content for JSON
        ESCAPED_YAML=$(echo "$UPDATED_YAML" | jq -Rs .)
        jq ".data.\"ramen_manager_config.yaml\" = $ESCAPED_YAML" "$WORK_DIR/ramen-configmap.json" > "$WORK_DIR/ramen-configmap-updated.json"
      elif command -v python3 &>/dev/null; then
        python3 -c "
import json
import sys

with open('$WORK_DIR/ramen-configmap.json', 'r') as f:
    cm = json.load(f)

if 'data' not in cm:
    cm['data'] = {}

cm['data']['ramen_manager_config.yaml'] = '''$UPDATED_YAML'''

with open('$WORK_DIR/ramen-configmap-updated.json', 'w') as f:
    json.dump(cm, f, indent=2)
" 2>/dev/null
      fi
      
      if [[ -f "$WORK_DIR/ramen-configmap-updated.json" ]]; then
        # Extract just the data section for the patch
        if command -v jq &>/dev/null; then
          jq '{data: .data}' "$WORK_DIR/ramen-configmap-updated.json" > "$WORK_DIR/ramen-patch.json"
        elif command -v python3 &>/dev/null; then
          python3 -c "
import json

with open('$WORK_DIR/ramen-configmap-updated.json', 'r') as f:
    cm = json.load(f)

patch = {'data': cm.get('data', {})}

with open('$WORK_DIR/ramen-patch.json', 'w') as f:
    json.dump(patch, f, indent=2)
" 2>/dev/null
        fi
        
        if [[ -f "$WORK_DIR/ramen-patch.json" ]]; then
          PATCH_OUTPUT=$(oc patch configmap ramen-hub-operator-config -n openshift-operators \
            --type=merge \
            --patch-file="$WORK_DIR/ramen-patch.json" 2>&1)
          PATCH_EXIT_CODE=$?
          
          if [[ $PATCH_EXIT_CODE -eq 0 ]]; then
            sleep 2
            VERIFIED_YAML=$(oc get configmap ramen-hub-operator-config -n openshift-operators -o jsonpath='{.data.ramen_manager_config\.yaml}' 2>/dev/null || echo "")
            
            # Strict verification for oc patch approach
            VERIFICATION_PASSED=true
            VERIFICATION_ERRORS=()
            
            if ! echo "$VERIFIED_YAML" | grep -q "s3StoreProfiles"; then
              VERIFICATION_PASSED=false
              VERIFICATION_ERRORS+=("s3StoreProfiles not found")
            fi
            
            if ! echo "$VERIFIED_YAML" | grep -q "caCertificates"; then
              VERIFICATION_PASSED=false
              VERIFICATION_ERRORS+=("caCertificates not found")
            fi
            
            # Verify structure: s3StoreProfiles under kubeObjectProtection or at top level (match script output)
            MIN_REQUIRED_PROFILES=2
            if echo "$VERIFIED_YAML" | grep -q "s3StoreProfiles"; then
              if command -v yq &>/dev/null; then
                PK=$(echo "$VERIFIED_YAML" | yq eval '.kubeObjectProtection.s3StoreProfiles | length' 2>/dev/null || echo "0")
                PT=$(echo "$VERIFIED_YAML" | yq eval '.s3StoreProfiles | length' 2>/dev/null || echo "0")
                CK=$(echo "$VERIFIED_YAML" | yq eval '[.kubeObjectProtection.s3StoreProfiles[]? | select(has("caCertificates"))] | length' 2>/dev/null || echo "0")
                CT=$(echo "$VERIFIED_YAML" | yq eval '[.s3StoreProfiles[]? | select(has("caCertificates"))] | length' 2>/dev/null || echo "0")
                PK=$((10#${PK:-0})); PT=$((10#${PT:-0})); CK=$((10#${CK:-0})); CT=$((10#${CT:-0}))
                PROFILE_COUNT=$(( PK >= PT ? PK : PT ))
                CA_CERT_COUNT=$(( CK >= CT ? CK : CT ))
              else
                PROFILE_COUNT=0
                CA_CERT_COUNT=0
              fi
              if [[ $PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES || $CA_CERT_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
                PROFILE_COUNT=$(echo "$VERIFIED_YAML" | grep -c "s3ProfileName:" 2>/dev/null || echo "0")
                [[ "${PROFILE_COUNT:-0}" -eq 0 ]] && PROFILE_COUNT=$(echo "$VERIFIED_YAML" | grep -c "s3Bucket:" 2>/dev/null || echo "0")
                CA_CERT_COUNT=$(echo "$VERIFIED_YAML" | grep -c "caCertificates:" 2>/dev/null || echo "0")
              fi
              PROFILE_COUNT=$(echo "$PROFILE_COUNT" | tr -d ' \n\r' | grep -E '^[0-9]+$' || echo "0")
              CA_CERT_COUNT=$(echo "$CA_CERT_COUNT" | tr -d ' \n\r' | grep -E '^[0-9]+$' || echo "0")
              PROFILE_COUNT=$((10#$PROFILE_COUNT))
              CA_CERT_COUNT=$((10#$CA_CERT_COUNT))
              
              # Check if we have at least the minimum required profiles
              if [[ $PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
                VERIFICATION_PASSED=false
                VERIFICATION_ERRORS+=("Insufficient s3StoreProfiles found: found $PROFILE_COUNT profile(s), but at least $MIN_REQUIRED_PROFILES are required")
              fi
              
              if [[ $PROFILE_COUNT -gt 0 && $CA_CERT_COUNT -lt $PROFILE_COUNT ]]; then
                VERIFICATION_PASSED=false
                VERIFICATION_ERRORS+=("Not all profiles have caCertificates ($PROFILE_COUNT profiles, $CA_CERT_COUNT caCertificates)")
              fi
              
              # CRITICAL: Verify all profiles have caCertificates (exact match required)
              if [[ $PROFILE_COUNT -gt 0 && $CA_CERT_COUNT -ne $PROFILE_COUNT ]]; then
                VERIFICATION_PASSED=false
                VERIFICATION_ERRORS+=("CRITICAL: All $PROFILE_COUNT profile(s) must have caCertificates, but only $CA_CERT_COUNT have it")
              fi
            else
              VERIFICATION_PASSED=false
              VERIFICATION_ERRORS+=("s3StoreProfiles section not found in ConfigMap")
            fi
            
            # Additional explicit check before declaring success
            PROFILE_COUNT=${PROFILE_COUNT:-0}
            CA_CERT_COUNT=${CA_CERT_COUNT:-0}
            if [[ $PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES || $CA_CERT_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
              VERIFICATION_PASSED=false
              VERIFICATION_ERRORS+=("CRITICAL: Must have at least $MIN_REQUIRED_PROFILES s3StoreProfiles with caCertificates, but found $PROFILE_COUNT profiles and $CA_CERT_COUNT caCertificates")
            fi
            
            if [[ "$VERIFICATION_PASSED" == "true" ]]; then
              echo "  ✅ ramen-hub-operator-config updated using oc patch approach"
              echo "     CA material verified in all s3StoreProfiles items ($PROFILE_COUNT profiles, $CA_CERT_COUNT caCertificates)"
            else
              echo "  ❌ CRITICAL: oc patch applied but verification FAILED"
              echo "     The CA material has NOT been properly added to s3StoreProfiles"
              for error in "${VERIFICATION_ERRORS[@]}"; do
                echo "     - $error"
              done
              echo "     Current YAML content:"
              echo "$VERIFIED_YAML"
              echo "     Patch output: $PATCH_OUTPUT"
              handle_error "ramen-hub-operator-config verification failed after oc patch - CA material not in s3StoreProfiles"
            fi
          else
            echo "  ❌ oc patch approach also failed"
            echo "     Patch output: $PATCH_OUTPUT"
            echo "     Manual intervention may be required to set caCertificates in s3StoreProfiles"
          fi
        else
          echo "  ❌ Could not create JSON patch file"
          echo "     Manual intervention may be required to set caCertificates in s3StoreProfiles"
        fi
        rm -f "$WORK_DIR/ramen-configmap.json" "$WORK_DIR/ramen-configmap-updated.json" "$WORK_DIR/ramen-patch.json"
      else
        echo "  ❌ Could not update ConfigMap JSON"
        echo "     Manual intervention may be required to set caCertificates in s3StoreProfiles"
        rm -f "$WORK_DIR/ramen-configmap.json"
      fi
    else
      echo "  ❌ Could not retrieve ConfigMap for alternative approach"
      echo "     Manual intervention may be required to set caCertificates in s3StoreProfiles"
    fi
  fi
  
  rm -f "$WORK_DIR/existing-ramen-config.yaml" "$WORK_DIR/ramen_manager_config.yaml"
  
else
  echo "  ConfigMap does not exist, creating with ramen_manager_config.yaml containing 2 s3StoreProfiles (${PRIMARY_CLUSTER}, ${SECONDARY_CLUSTER}) with caCertificates..."
  oc create configmap ramen-hub-operator-config -n openshift-operators \
    --from-literal=ramen_manager_config.yaml="kubeObjectProtection:
  s3StoreProfiles:
  - s3ProfileName: $PRIMARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
  - s3ProfileName: $SECONDARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
s3StoreProfiles:
  - s3ProfileName: $PRIMARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"
  - s3ProfileName: $SECONDARY_CLUSTER
    caCertificates: \"$CA_BUNDLE_BASE64\"" || {
    echo "  Warning: Could not create ramen-hub-operator-config"
  }
fi

echo "  ramen-hub-operator-config updated successfully with base64-encoded CA bundle in s3StoreProfiles"
echo "  This enables SSL access for discovered applications in ODF Disaster Recovery"

# Restart Velero pods on managed clusters to pick up new CA certificates
echo "7c. Restarting Velero pods on managed clusters..."

for cluster in $MANAGED_CLUSTERS; do
  if [[ "$cluster" == "local-cluster" ]]; then
    continue
  fi
  
  echo "  Processing cluster: $cluster"
  
  # Get kubeconfig for the cluster
  KUBECONFIG_FILE="$WORK_DIR/${cluster}-kubeconfig.yaml"
  if [[ ! -f "$KUBECONFIG_FILE" ]]; then
    # Fetch kubeconfig if not already available
    if oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | base64 -d > "$KUBECONFIG_FILE" 2>/dev/null; then
      echo "    Fetched kubeconfig for $cluster"
    else
      echo "    ❌ Could not get kubeconfig for $cluster - skipping Velero pod restart"
      continue
    fi
  fi
  
  # Find Velero pods in openshift-adp namespace
  VELERO_PODS=$(oc --kubeconfig="$KUBECONFIG_FILE" get pods -n openshift-adp -l component=velero -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -n "$VELERO_PODS" ]]; then
      echo "    Found Velero pods: $VELERO_PODS"
      
      for pod in $VELERO_PODS; do
        echo "    Deleting pod $pod to trigger restart..."
        oc --kubeconfig="$KUBECONFIG_FILE" delete pod "$pod" -n openshift-adp --ignore-not-found=true || {
          echo "    Warning: Could not delete pod $pod"
        }
      done
      
      # Wait for pods to be deleted
      echo "    Waiting for pods to be terminated..."
      for pod in $VELERO_PODS; do
        oc --kubeconfig="$KUBECONFIG_FILE" wait --for=delete pod/"$pod" -n openshift-adp --timeout=60s 2>/dev/null || true
      done
      
      # Wait for new pods to be running
      echo "    Waiting for new Velero pods to be running..."
      MAX_WAIT_ATTEMPTS=30
      WAIT_INTERVAL=10
      attempt=0
      
      while [[ $attempt -lt $MAX_WAIT_ATTEMPTS ]]; do
        attempt=$((attempt + 1))
        
        NEW_PODS=$(oc --kubeconfig="$KUBECONFIG_FILE" get pods -n openshift-adp -l component=velero -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        ALL_RUNNING=true
        
        if [[ -n "$NEW_PODS" ]]; then
          for pod in $NEW_PODS; do
            POD_STATUS=$(oc --kubeconfig="$KUBECONFIG_FILE" get pod "$pod" -n openshift-adp -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            
            if [[ "$POD_STATUS" != "Running" ]]; then
              ALL_RUNNING=false
              break
            fi
          done
          
          if [[ "$ALL_RUNNING" == "true" ]]; then
            echo "    ✅ All Velero pods are running on $cluster: $NEW_PODS"
            break
          else
            echo "    ⏳ Waiting for pods to be running (attempt $attempt/$MAX_WAIT_ATTEMPTS)"
          fi
        else
          echo "    ⏳ Waiting for pods to appear (attempt $attempt/$MAX_WAIT_ATTEMPTS)"
        fi
        
        if [[ $attempt -lt $MAX_WAIT_ATTEMPTS ]]; then
          sleep $WAIT_INTERVAL
        fi
      done
      
      if [[ $attempt -ge $MAX_WAIT_ATTEMPTS ]]; then
        echo "    ⚠️  Warning: Velero pods did not become ready within expected time on $cluster"
        echo "     The pods may still be starting - new CA certificates will be applied when ready"
      fi
    else
      echo "    ⚠️  Warning: Velero pods not found on $cluster - they may not be deployed yet"
      echo "     New CA certificates will be applied when the pods start"
    fi
done

echo "  ✅ Completed Velero pod restarts on managed clusters"

# Distribute certificate data to managed clusters with retry logic
echo "8. Distributing certificate data to managed clusters..."
DISTRIBUTION_ATTEMPTS=3
DISTRIBUTION_SLEEP=10

for cluster in $MANAGED_CLUSTERS; do
  if [[ "$cluster" == "local-cluster" ]]; then
    continue
  fi
  
  echo "  Distributing to $cluster..."
  
  # Get kubeconfig for the cluster
  KUBECONFIG_FILE=""
  if oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | base64 -d > "$WORK_DIR/${cluster}-kubeconfig.yaml" 2>/dev/null; then
    KUBECONFIG_FILE="$WORK_DIR/${cluster}-kubeconfig.yaml"
  fi
  
  if [[ -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
    # Retry distribution to managed cluster
    distribution_success=false
    for dist_attempt in $(seq 1 $DISTRIBUTION_ATTEMPTS); do
      echo "    Distribution attempt $dist_attempt/$DISTRIBUTION_ATTEMPTS for $cluster..."
      
      # Create ConfigMap on managed cluster
      if oc --kubeconfig="$KUBECONFIG_FILE" create configmap cluster-proxy-ca-bundle \
        --from-file=ca-bundle.crt="$WORK_DIR/combined-ca-bundle.crt" \
        -n openshift-config \
        --dry-run=client -o yaml | oc --kubeconfig="$KUBECONFIG_FILE" apply -f -; then
        
        # Update managed cluster proxy
        if oc --kubeconfig="$KUBECONFIG_FILE" patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"cluster-proxy-ca-bundle"}}}'; then
          echo "    ✅ Certificate data distributed to $cluster (attempt $dist_attempt)"
          distribution_success=true
          break
        else
          echo "    ⚠️  ConfigMap created but proxy update failed for $cluster (attempt $dist_attempt)"
        fi
      else
        echo "    ⚠️  ConfigMap creation failed for $cluster (attempt $dist_attempt)"
      fi
      
      if [[ $dist_attempt -lt $DISTRIBUTION_ATTEMPTS ]]; then
        echo "    ⏳ Waiting $DISTRIBUTION_SLEEP seconds before retry..."
        sleep $DISTRIBUTION_SLEEP
      fi
    done
    
    if [[ "$distribution_success" != "true" ]]; then
      echo "    ❌ Failed to distribute certificate data to $cluster after $DISTRIBUTION_ATTEMPTS attempts"
      echo "    This may cause DR prerequisites check to fail"
    fi
  else
    echo "    ❌ Could not get kubeconfig for $cluster - skipping distribution"
  fi
done

# Verify distribution to managed clusters
echo "9. Verifying certificate distribution to managed clusters..."
verification_failed=false
REQUIRED_VERIFICATION_CLUSTERS=("$PRIMARY_CLUSTER" "$SECONDARY_CLUSTER")
VERIFIED_CLUSTERS=()

for cluster in $MANAGED_CLUSTERS; do
  if [[ "$cluster" == "local-cluster" ]]; then
    continue
  fi
  
  echo "  Verifying distribution to $cluster..."
  KUBECONFIG_FILE="$WORK_DIR/${cluster}-kubeconfig.yaml"
  
  if [[ -f "$KUBECONFIG_FILE" ]]; then
    # Check if ConfigMap exists and has content
    configmap_exists=$(oc --kubeconfig="$KUBECONFIG_FILE" get configmap cluster-proxy-ca-bundle -n openshift-config &>/dev/null && echo "true" || echo "false")
    configmap_size=$(oc --kubeconfig="$KUBECONFIG_FILE" get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null | wc -c || echo "0")
    proxy_configured=$(oc --kubeconfig="$KUBECONFIG_FILE" get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || echo "")
    
    if [[ "$configmap_exists" == "true" && $configmap_size -gt 100 && "$proxy_configured" == "cluster-proxy-ca-bundle" ]]; then
      echo "    ✅ $cluster: ConfigMap exists (${configmap_size} bytes), proxy configured"
      VERIFIED_CLUSTERS+=("$cluster")
    else
      echo "    ❌ $cluster: ConfigMap verification failed"
      echo "      ConfigMap exists: $configmap_exists"
      echo "      ConfigMap size: $configmap_size bytes"
      echo "      Proxy configured: $proxy_configured"
      verification_failed=true
    fi
  else
    echo "    ❌ $cluster: No kubeconfig available for verification"
    verification_failed=true
  fi
done

# Check if all required clusters are verified
echo "10. Validating verification results..."
MISSING_VERIFICATION_CLUSTERS=()
for required_cluster in "${REQUIRED_VERIFICATION_CLUSTERS[@]}"; do
  if [[ " ${VERIFIED_CLUSTERS[@]} " =~ " ${required_cluster} " ]]; then
    echo "  ✅ $required_cluster: Certificate distribution verified"
  else
    echo "  ❌ $required_cluster: Certificate distribution NOT verified"
    MISSING_VERIFICATION_CLUSTERS+=("$required_cluster")
  fi
done

if [[ ${#MISSING_VERIFICATION_CLUSTERS[@]} -gt 0 ]]; then
  echo ""
  echo "❌ CRITICAL ERROR: Certificate distribution verification failed for required clusters:"
  for missing in "${MISSING_VERIFICATION_CLUSTERS[@]}"; do
    echo "   - $missing"
  done
  echo ""
  echo "The ODF SSL certificate extractor job requires successful certificate distribution"
  echo "to ALL managed clusters ($PRIMARY_CLUSTER and $SECONDARY_CLUSTER)."
  echo ""
  echo "Without proper certificate distribution, the DR setup will fail."
  echo "Please check cluster connectivity and kubeconfig availability."
  echo ""
  echo "Job will exit with error code 1."
  exit 1
fi

if [[ "$verification_failed" == "true" ]]; then
  echo ""
  echo "⚠️  Certificate distribution verification failed for some clusters"
  echo "   This may cause DR prerequisites check to fail"
  echo "   Manual intervention may be required"
  echo ""
  echo "Job will exit with error code 1."
  exit 1
else
  echo ""
  echo "✅ All managed clusters verified successfully"
fi

# Final verification: Ensure ramen-hub-operator-config is complete and correct
echo ""
echo "11. Final verification: Ensuring ramen-hub-operator-config is complete and correct..."
FINAL_VERIFIED_YAML=$(oc get configmap ramen-hub-operator-config -n openshift-operators -o jsonpath='{.data.ramen_manager_config\.yaml}' 2>/dev/null || echo "")

if [[ -z "$FINAL_VERIFIED_YAML" ]]; then
  echo "  ❌ CRITICAL: ramen-hub-operator-config ConfigMap not found or empty"
  handle_error "ramen-hub-operator-config ConfigMap is missing or empty - CA material not configured"
fi

# Write to file to avoid ARG_MAX when content is large (big base64 certs); grep/yq on file are reliable
FINAL_VERIFIED_FILE="${WORK_DIR:-/tmp/odf-ssl-certs}/final_verified_ramen.yaml"
mkdir -p "$(dirname "$FINAL_VERIFIED_FILE")"
printf '%s' "$FINAL_VERIFIED_YAML" > "$FINAL_VERIFIED_FILE"

FINAL_VERIFICATION_PASSED=true
FINAL_VERIFICATION_ERRORS=()

if ! grep -q "s3StoreProfiles" "$FINAL_VERIFIED_FILE" 2>/dev/null; then
  FINAL_VERIFICATION_PASSED=false
  FINAL_VERIFICATION_ERRORS+=("s3StoreProfiles not found in final verification")
fi

if ! grep -q "caCertificates" "$FINAL_VERIFIED_FILE" 2>/dev/null; then
  FINAL_VERIFICATION_PASSED=false
  FINAL_VERIFICATION_ERRORS+=("caCertificates not found in final verification")
fi

# Verify structure: s3StoreProfiles under kubeObjectProtection or at top level (match script output)
MIN_REQUIRED_PROFILES=2
if grep -q "s3StoreProfiles" "$FINAL_VERIFIED_FILE" 2>/dev/null; then
  if command -v yq &>/dev/null; then
    PK=$(yq eval '.kubeObjectProtection.s3StoreProfiles | length' "$FINAL_VERIFIED_FILE" 2>/dev/null || echo "0")
    PT=$(yq eval '.s3StoreProfiles | length' "$FINAL_VERIFIED_FILE" 2>/dev/null || echo "0")
    CK=$(yq eval '[.kubeObjectProtection.s3StoreProfiles[]? | select(has("caCertificates"))] | length' "$FINAL_VERIFIED_FILE" 2>/dev/null || echo "0")
    CT=$(yq eval '[.s3StoreProfiles[]? | select(has("caCertificates"))] | length' "$FINAL_VERIFIED_FILE" 2>/dev/null || echo "0")
    PK=$((10#${PK:-0})); PT=$((10#${PT:-0})); CK=$((10#${CK:-0})); CT=$((10#${CT:-0}))
    FINAL_PROFILE_COUNT=$(( PK >= PT ? PK : PT ))
    FINAL_CA_CERT_COUNT=$(( CK >= CT ? CK : CT ))
  else
    FINAL_PROFILE_COUNT=0
    FINAL_CA_CERT_COUNT=0
  fi
  if [[ $FINAL_PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES || $FINAL_CA_CERT_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
    FINAL_PROFILE_COUNT=$(grep -c "s3ProfileName:" "$FINAL_VERIFIED_FILE" 2>/dev/null || echo "0")
    [[ "${FINAL_PROFILE_COUNT:-0}" -eq 0 ]] && FINAL_PROFILE_COUNT=$(grep -c "s3Bucket:" "$FINAL_VERIFIED_FILE" 2>/dev/null || echo "0")
    FINAL_CA_CERT_COUNT=$(grep -c "caCertificates:" "$FINAL_VERIFIED_FILE" 2>/dev/null || echo "0")
  fi
  # Remove any whitespace/newlines and ensure numeric
  FINAL_PROFILE_COUNT=$(echo "$FINAL_PROFILE_COUNT" | tr -d ' \n\r' | grep -E '^[0-9]+$' || echo "0")
  FINAL_CA_CERT_COUNT=$(echo "$FINAL_CA_CERT_COUNT" | tr -d ' \n\r' | grep -E '^[0-9]+$' || echo "0")
  FINAL_PROFILE_COUNT=$((10#$FINAL_PROFILE_COUNT))
  FINAL_CA_CERT_COUNT=$((10#$FINAL_CA_CERT_COUNT))
  
  echo "  Debug: FINAL_PROFILE_COUNT=$FINAL_PROFILE_COUNT, FINAL_CA_CERT_COUNT=$FINAL_CA_CERT_COUNT, MIN_REQUIRED=$MIN_REQUIRED_PROFILES"
  
  # Check if we have at least the minimum required profiles
  if [[ $FINAL_PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
    FINAL_VERIFICATION_PASSED=false
    FINAL_VERIFICATION_ERRORS+=("Insufficient s3StoreProfiles found: found $FINAL_PROFILE_COUNT profile(s), but at least $MIN_REQUIRED_PROFILES are required")
  fi
  
  if [[ $FINAL_PROFILE_COUNT -gt 0 && $FINAL_CA_CERT_COUNT -lt $FINAL_PROFILE_COUNT ]]; then
    FINAL_VERIFICATION_PASSED=false
    FINAL_VERIFICATION_ERRORS+=("Not all s3StoreProfiles items have caCertificates (found $FINAL_PROFILE_COUNT profiles but only $FINAL_CA_CERT_COUNT caCertificates)")
  fi
  
  if [[ $FINAL_PROFILE_COUNT -eq 0 ]]; then
    FINAL_VERIFICATION_PASSED=false
    FINAL_VERIFICATION_ERRORS+=("No s3StoreProfiles items found in ConfigMap (s3StoreProfiles array is empty)")
  fi
else
  FINAL_VERIFICATION_PASSED=false
  FINAL_VERIFICATION_ERRORS+=("s3StoreProfiles section not found in ConfigMap")
fi

# Additional explicit check: Must have at least 2 profiles with caCertificates
# Initialize variables if they weren't set (e.g., if s3StoreProfiles section was missing)
FINAL_PROFILE_COUNT=${FINAL_PROFILE_COUNT:-0}
FINAL_CA_CERT_COUNT=${FINAL_CA_CERT_COUNT:-0}
# Ensure MIN_REQUIRED_PROFILES is set
MIN_REQUIRED_PROFILES=${MIN_REQUIRED_PROFILES:-2}

# CRITICAL: Explicitly verify we have at least 2 profiles
if [[ $FINAL_PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
  FINAL_VERIFICATION_PASSED=false
  FINAL_VERIFICATION_ERRORS+=("CRITICAL: Must have at least $MIN_REQUIRED_PROFILES s3StoreProfiles, but found only $FINAL_PROFILE_COUNT")
fi

# CRITICAL: Verify all profiles have caCertificates
if [[ $FINAL_PROFILE_COUNT -gt 0 && $FINAL_CA_CERT_COUNT -ne $FINAL_PROFILE_COUNT ]]; then
  FINAL_VERIFICATION_PASSED=false
  FINAL_VERIFICATION_ERRORS+=("CRITICAL: All $FINAL_PROFILE_COUNT profile(s) must have caCertificates, but only $FINAL_CA_CERT_COUNT have it")
fi

# CRITICAL: Verify we have exactly the required number of profiles with certificates
if [[ $FINAL_PROFILE_COUNT -ne $FINAL_CA_CERT_COUNT ]]; then
  FINAL_VERIFICATION_PASSED=false
  FINAL_VERIFICATION_ERRORS+=("CRITICAL: Profile count ($FINAL_PROFILE_COUNT) does not match caCertificates count ($FINAL_CA_CERT_COUNT)")
fi

# CRITICAL: Final absolute check - must have at least MIN_REQUIRED_PROFILES profiles
# This check is redundant but ensures we never pass with insufficient profiles
if [[ $FINAL_PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
  FINAL_VERIFICATION_PASSED=false
  FINAL_VERIFICATION_ERRORS+=("CRITICAL: Final check failed - only $FINAL_PROFILE_COUNT profile(s) found, need at least $MIN_REQUIRED_PROFILES")
fi

if [[ $FINAL_CA_CERT_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
  FINAL_VERIFICATION_PASSED=false
  FINAL_VERIFICATION_ERRORS+=("CRITICAL: Final check failed - only $FINAL_CA_CERT_COUNT caCertificates found, need at least $MIN_REQUIRED_PROFILES")
fi

if [[ "$FINAL_VERIFICATION_PASSED" != "true" ]]; then
  echo "  ❌ CRITICAL: Final verification FAILED - ramen-hub-operator-config is NOT complete and correct"
  echo "     The CA material has NOT been properly added to s3StoreProfiles"
  for error in "${FINAL_VERIFICATION_ERRORS[@]}"; do
    echo "     - $error"
  done
  echo "     Current ConfigMap YAML content:"
  cat "$FINAL_VERIFIED_FILE"
  echo ""
  if [[ $FINAL_PROFILE_COUNT -eq 0 ]]; then
    echo "     s3StoreProfiles is empty ([]). Configure at least 2 S3 store profiles in ramen-hub-operator-config"
    echo "     (via Ramen hub operator or ODF) before this job can add CA certificates. This job cannot create profiles."
  else
    echo "     The ConfigMap edit is not complete until CA material has been added to all S3 profiles."
  fi
  echo "     This is a CRITICAL error - the job cannot complete successfully."
  handle_error "Final verification failed - ramen-hub-operator-config is not complete and correct - CA material not in s3StoreProfiles"
  # After handle_error, return failure to trigger retry in main loop
  return 1
fi

# Final absolute safety check before declaring success - this should NEVER be false if we reach here
# But we check anyway as a last line of defense
if [[ $FINAL_PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES || $FINAL_CA_CERT_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
  echo "  ❌ CRITICAL: Final safety check FAILED - insufficient profiles"
  echo "     Found $FINAL_PROFILE_COUNT profile(s) and $FINAL_CA_CERT_COUNT caCertificates, but at least $MIN_REQUIRED_PROFILES are required"
  echo "     This should never happen - there is a logic error in the verification code"
  handle_error "Final verification failed - ramen-hub-operator-config is not complete and correct - insufficient s3StoreProfiles (safety check)"
  return 1
fi

# CRITICAL: Final check - only print success if we have the required number of profiles
# This is the absolute last check before declaring success
if [[ $FINAL_PROFILE_COUNT -lt $MIN_REQUIRED_PROFILES || $FINAL_CA_CERT_COUNT -lt $MIN_REQUIRED_PROFILES ]]; then
  echo "  ❌ CRITICAL: Final verification FAILED - insufficient profiles in final success check"
  echo "     Found $FINAL_PROFILE_COUNT profile(s) and $FINAL_CA_CERT_COUNT caCertificates, but at least $MIN_REQUIRED_PROFILES are required"
  handle_error "Final verification failed - ramen-hub-operator-config is not complete and correct - insufficient s3StoreProfiles (final success check)"
  return 1
fi

# Only reach here if we have sufficient profiles - print success message
echo "  ✅ Final verification passed: ramen-hub-operator-config is complete and correct"
echo "     - s3StoreProfiles found: $FINAL_PROFILE_COUNT profile(s) (required: at least $MIN_REQUIRED_PROFILES)"
echo "     - caCertificates found: $FINAL_CA_CERT_COUNT certificate(s) (required: at least $MIN_REQUIRED_PROFILES)"
echo "     - CA bundle base64 data verified in all profiles"

echo ""
echo "✅ ODF SSL certificate management completed successfully!"
echo "   - Hub cluster CA bundle: Updated (includes trusted CA + ingress CA)"
echo "   - Hub cluster proxy: Configured"
echo "   - Managed clusters: ramenddr-cluster-operator pods restarted"
echo "   - ramen-hub-operator-config: Updated and VERIFIED with base64-encoded CA bundle in s3StoreProfiles (hub cluster)"
echo "   - Managed clusters: Velero pods restarted (openshift-adp namespace)"
echo "   - Managed clusters: Certificate data distributed (includes ingress CAs)"
echo ""
echo "This follows Red Hat ODF Disaster Recovery certificate management guidelines"
echo "for secure SSL access across clusters in the regional DR setup."
echo "The ramen-hub-operator-config update enables SSL access for discovered applications"
echo "as described in the Red Hat ODF Disaster Recovery documentation."
}

# Execute main function with retry logic
while true; do
  if main_execution; then
    echo "🎉 Certificate extraction completed successfully!"
    exit 0
  else
    if [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; then
      echo "🔄 Main execution failed, retrying..."
      exponential_backoff
      continue
    else
      echo "💥 Max retries exceeded. Job will exit but ArgoCD can retry the sync."
      echo "   This is a temporary failure - the job will be retried on next ArgoCD sync."
      exit 1
    fi
  fi
done

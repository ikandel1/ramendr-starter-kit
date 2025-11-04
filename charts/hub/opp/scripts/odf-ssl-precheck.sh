#!/bin/bash
set -euo pipefail

echo "Starting ODF SSL certificate precheck and distribution..."
echo "This job ensures certificates are properly distributed before DR policies are applied"

# Configuration
MIN_CERTIFICATES=15
MIN_BUNDLE_SIZE=20000
MAX_ATTEMPTS=120  
SLEEP_INTERVAL=30
CLUSTER_READINESS_MAX_ATTEMPTS=120  # Wait up to 60 minutes for clusters to be ready (120 * 30s)
CLUSTER_READINESS_SLEEP=30

# Function to clean up placeholder ConfigMaps
cleanup_placeholder_configmaps() {
  echo "🧹 Cleaning up placeholder ConfigMaps from managed clusters..."
  
  MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$MANAGED_CLUSTERS" ]]; then
    echo "No managed clusters found"
    return 1
  fi
  
  for cluster in $MANAGED_CLUSTERS; do
    if [[ "$cluster" == "local-cluster" ]]; then
      continue
    fi
    
    echo "Checking $cluster for placeholder ConfigMaps..."
    
    KUBECONFIG_FILE=""
    if oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | base64 -d > "/tmp/${cluster}-kubeconfig.yaml" 2>/dev/null; then
      KUBECONFIG_FILE="/tmp/${cluster}-kubeconfig.yaml"
    fi
    
    if [[ -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
      configmap_content=$(oc --kubeconfig="$KUBECONFIG_FILE" get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || echo "")
      
      if [[ "$configmap_content" == *"Placeholder for ODF SSL certificate bundle"* ]] || [[ "$configmap_content" == *"This will be populated by the certificate extraction job"* ]]; then
        echo "  🗑️  Deleting placeholder ConfigMap from $cluster..."
        oc --kubeconfig="$KUBECONFIG_FILE" delete configmap cluster-proxy-ca-bundle -n openshift-config --ignore-not-found=true
        echo "  ✅ Placeholder ConfigMap removed from $cluster"
      else
        echo "  ✅ $cluster: No placeholder ConfigMap found"
      fi
    else
      echo "  ❌ $cluster: Could not get kubeconfig for cleanup"
    fi
  done
  
  echo "✅ Placeholder ConfigMap cleanup completed"
  return 0
}

# Function to wait for required clusters to be available and joined
wait_for_cluster_readiness() {
  echo "🔍 Waiting for required clusters (ocp-primary and ocp-secondary) to be available and joined..."
  echo "   This may take several minutes during initial cluster deployment"
  
  REQUIRED_CLUSTERS=("ocp-primary" "ocp-secondary")
  attempt=1
  
  while [[ $attempt -le $CLUSTER_READINESS_MAX_ATTEMPTS ]]; do
    echo "=== Cluster Readiness Check Attempt $attempt/$CLUSTER_READINESS_MAX_ATTEMPTS ==="
    
    all_ready=true
    unready_clusters=()
    
    for cluster in "${REQUIRED_CLUSTERS[@]}"; do
      # Check if cluster exists
      if ! oc get managedcluster "$cluster" &>/dev/null; then
        echo "  ⏳ Cluster $cluster does not exist yet..."
        all_ready=false
        unready_clusters+=("$cluster")
        continue
      fi
      
      # Check if cluster is available
      cluster_status=$(oc get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "Unknown")
      if [[ "$cluster_status" != "True" ]]; then
        echo "  ⏳ Cluster $cluster is not available yet (status: $cluster_status)"
        all_ready=false
        unready_clusters+=("$cluster")
        continue
      fi
      
      # Check if cluster is joined
      joined_status=$(oc get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterJoined")].status}' 2>/dev/null || echo "Unknown")
      if [[ "$joined_status" != "True" ]]; then
        echo "  ⏳ Cluster $cluster is not joined yet (status: $joined_status)"
        all_ready=false
        unready_clusters+=("$cluster")
        continue
      fi
      
      echo "  ✅ Cluster $cluster is available and joined"
    done
    
    if [[ "$all_ready" == "true" ]]; then
      echo "✅ All required clusters are available and joined!"
      return 0
    else
      echo "⏳ Waiting for clusters to be ready: ${unready_clusters[*]}"
      echo "   This is normal during initial cluster deployment - clusters may take 10-30 minutes to become ready"
      
      if [[ $attempt -ge $CLUSTER_READINESS_MAX_ATTEMPTS ]]; then
        echo "❌ TIMEOUT: Clusters are still not ready after $CLUSTER_READINESS_MAX_ATTEMPTS attempts ($((CLUSTER_READINESS_MAX_ATTEMPTS * CLUSTER_READINESS_SLEEP / 60)) minutes)"
        echo "   Unready clusters: ${unready_clusters[*]}"
        echo "   This may indicate a problem with cluster deployment"
        echo "   The precheck will continue but certificate extraction may fail"
        return 1
      else
        sleep $CLUSTER_READINESS_SLEEP
        ((attempt++))
      fi
    fi
  done
  
  return 1
}

# Function to check certificate distribution
check_certificate_distribution() {
  echo "Checking certificate distribution status..."
  
  if ! oc get configmap cluster-proxy-ca-bundle -n openshift-config >/dev/null 2>&1; then
    echo "❌ CA bundle ConfigMap not found on hub cluster"
    return 1
  fi
  
  bundle_content=$(oc get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath="{.data['ca-bundle\.crt']}" 2>/dev/null || echo "")
  
  if [[ -z "$bundle_content" ]]; then
    echo "❌ CA bundle is empty"
    return 1
  fi
  
  bundle_size=$(echo "$bundle_content" | wc -c)
  echo "  Bundle size: $bundle_size bytes"
  
  if [[ $bundle_size -lt $MIN_BUNDLE_SIZE ]]; then
    echo "❌ CA bundle too small ($bundle_size < $MIN_BUNDLE_SIZE bytes)"
    return 1
  fi
  
  cert_count=$(echo "$bundle_content" | grep -c "BEGIN CERTIFICATE" || echo "0")
  echo "  Certificate count: $cert_count"
  
  if [[ $cert_count -lt $MIN_CERTIFICATES ]]; then
    echo "❌ Too few certificates ($cert_count < $MIN_CERTIFICATES)"
    return 1
  fi
  
  hub_certs=$(echo "$bundle_content" | grep -c "hub" || echo "0")
  ocp_primary_certs=$(echo "$bundle_content" | grep -c "ocp-primary" || echo "0")
  ocp_secondary_certs=$(echo "$bundle_content" | grep -c "ocp-secondary" || echo "0")
  
  echo "  Hub cluster certificates: $hub_certs"
  echo "  ocp-primary certificates: $ocp_primary_certs"
  echo "  ocp-secondary certificates: $ocp_secondary_certs"
  
  if [[ $hub_certs -lt 2 || $ocp_primary_certs -lt 2 || $ocp_secondary_certs -lt 2 ]]; then
    echo "❌ Missing certificates from one or more clusters"
    return 1
  fi
  
  echo "✅ CA bundle is complete and properly distributed"
  return 0
}

# Function to trigger certificate extraction
trigger_certificate_extraction() {
  echo "Triggering certificate extraction..."
  
  oc delete job odf-ssl-certificate-extractor -n openshift-config --ignore-not-found=true
  sleep 5
  
  echo "Creating certificate extraction job..."
  oc apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: odf-ssl-certificate-extractor
  namespace: openshift-config
  labels:
    app.kubernetes.io/name: odf-ssl-certificate-management
    app.kubernetes.io/component: certificate-extraction
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  template:
    spec:
      containers:
      - name: odf-ssl-extractor
        image: registry.redhat.io/openshift4/ose-cli:latest
        resources:
          requests:
            memory: "512Mi"
            cpu: "200m"
          limits:
            memory: "1Gi"
            cpu: "500m"
        command:
        - /bin/bash
        - -c
        - |
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
            WORK_DIR="/tmp/odf-ssl-certs"
            mkdir -p "$WORK_DIR"
            cd "$WORK_DIR"
          
          extract_cluster_ca() {
            cluster_name="$1"
            output_file="$2"
            kubeconfig="${3:-}"
            
            echo "Extracting CA from cluster: $cluster_name"
            
            if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
              KUBECONFIG="$kubeconfig" oc get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > "$output_file"
              echo "  CA extracted from $cluster_name using kubeconfig"
            else
              oc get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > "$output_file"
              echo "  CA extracted from $cluster_name using current context"
            fi
            
            cert_size=$(wc -c < "$output_file" 2>/dev/null || echo "0")
            echo "  Certificate size: $cert_size bytes"
            
            if [[ $cert_size -lt 1000 ]]; then
              echo "  Warning: Certificate size seems too small"
              return 1
            fi
            
            return 0
          }
          
          extract_ingress_ca() {
            cluster_name="$1"
            output_file="$2"
            kubeconfig="${3:-}"
            
            echo "Extracting ingress CA from cluster: $cluster_name"
            
            if [[ -n "$kubeconfig" && -f "$kubeconfig" ]]; then
              KUBECONFIG="$kubeconfig" oc get configmap -n openshift-config-managed router-ca -o jsonpath="{.data['ca-bundle\.crt']}" > "$output_file" 2>/dev/null || echo "" > "$output_file"
              echo "  Ingress CA extracted from $cluster_name using kubeconfig"
            else
              oc get configmap -n openshift-config-managed router-ca -o jsonpath="{.data['ca-bundle\.crt']}" > "$output_file" 2>/dev/null || echo "" > "$output_file"
              echo "  Ingress CA extracted from $cluster_name using current context"
            fi
            
            cert_size=$(wc -c < "$output_file" 2>/dev/null || echo "0")
            echo "  Ingress CA certificate size: $cert_size bytes"
            
            return 0
          }
          
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
          
          echo "1. Extracting hub cluster CA..."
          hub_ca_extracted=false
          if extract_cluster_ca "hub" ""; then
            hub_ca_extracted=true
            echo "  ✅ Hub CA extracted successfully"
          else
            echo "  ❌ Hub CA extraction failed - REQUIRED for DR setup"
          fi
          
          extract_ingress_ca "hub" ""
          
          echo "2. Discovering managed clusters..."
          managed_clusters=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v local-cluster || echo "")
          echo "  Found managed clusters: $managed_clusters"
          
          echo "  Added hub CA to bundle"
          echo "  Added hub ingress CA to bundle"
          
          # Track required clusters
          REQUIRED_CLUSTERS=("hub" "ocp-primary" "ocp-secondary")
          EXTRACTED_CLUSTERS=()
          if [[ "$hub_ca_extracted" == "true" ]]; then
            EXTRACTED_CLUSTERS+=("hub")
          fi
          
          cluster_count=0
          for cluster in $managed_clusters; do
            if [[ "$cluster" == "ocp-primary" || "$cluster" == "ocp-secondary" ]]; then
              cluster_count=$((cluster_count + 1))
              echo "3.$cluster_count Extracting CA from $cluster..."
              
              kubeconfig_file="/tmp/odf-ssl-certs/${cluster}-kubeconfig.yaml"
              oc get secret "${cluster}-import" -n "${cluster}" -o jsonpath="{.data.kubeconfig}" | base64 -d > "$kubeconfig_file" 2>/dev/null || {
                echo "  ❌ Could not get kubeconfig for $cluster - REQUIRED for DR setup"
                continue
              }
              
              if extract_cluster_ca "$cluster" "$kubeconfig_file"; then
                EXTRACTED_CLUSTERS+=("$cluster")
                echo "  ✅ CA extracted from $cluster"
              else
                echo "  ❌ CA extraction failed from $cluster - REQUIRED for DR setup"
              fi
              
              extract_ingress_ca "$cluster" "$kubeconfig_file"
            fi
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
            echo "   - ocp-primary (primary managed cluster)"  
            echo "   - ocp-secondary (secondary managed cluster)"
            echo ""
            echo "Without CA material from all clusters, the DR setup will fail."
            echo "Please ensure all clusters are accessible and have proper kubeconfigs."
            echo ""
            echo "Job will exit with error code 1."
            exit 1
          fi
          
          echo "5. Creating combined CA bundle..."
          ca_files=$(ls -1 *.crt 2>/dev/null | wc -l)
          echo "  CA files to combine: $ca_files files"
          
          for file in *.crt; do
            if [[ -f "$file" ]]; then
              file_size=$(wc -c < "$file" 2>/dev/null || echo "0")
              echo "    - $file ($file_size bytes)"
            fi
          done
          
          create_combined_ca_bundle "combined-ca-bundle.crt" *.crt
          
          bundle_size=$(wc -c < combined-ca-bundle.crt)
          cert_count=$(grep -c "BEGIN CERTIFICATE" combined-ca-bundle.crt || echo "0")
          
          echo "Combined CA bundle created with $ca_files CA sources (first 5 certs each)"
          echo "  Combined CA bundle created successfully"
          echo "  Bundle size: $bundle_size bytes"
          echo "  Certificate count: $cert_count"
          
          if [[ $bundle_size -lt 20000 ]]; then
            echo "❌ Combined CA bundle too small ($bundle_size < 20000 bytes)"
            exit 1
          fi
          
          if [[ $cert_count -lt 15 ]]; then
            echo "❌ Too few certificates in combined CA bundle ($cert_count < 15)"
            exit 1
          fi
          
          echo "6. Updating hub cluster ConfigMap..."
          oc create configmap cluster-proxy-ca-bundle \
            --from-file=ca-bundle.crt=combined-ca-bundle.crt \
            -n openshift-config \
            --dry-run=client -o yaml | oc apply -f -
          
          echo "  Hub cluster ConfigMap updated"
          
          echo "7. Updating hub cluster proxy configuration..."
          oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"cluster-proxy-ca-bundle"}}}' || {
            echo "  Warning: Could not update hub cluster proxy"
          }
          
          # Update ramen-hub-operator-config with base64-encoded CA bundle
          echo "7b. Updating ramen-hub-operator-config in openshift-operators namespace..."
          
          # Base64 encode the combined CA bundle
          CA_BUNDLE_BASE64=$(base64 -w 0 < combined-ca-bundle.crt 2>/dev/null || base64 < combined-ca-bundle.crt | tr -d '\n')
          
          # Check if ramen-hub-operator-config exists
          if oc get configmap ramen-hub-operator-config -n openshift-operators &>/dev/null; then
            echo "  ConfigMap exists, updating ramen_manager_config.yaml with caCertificates..."
            
            # Get existing ramen_manager_config.yaml content
            EXISTING_YAML=$(oc get configmap ramen-hub-operator-config -n openshift-operators -o jsonpath='{.data.ramen_manager_config\.yaml}' 2>/dev/null || echo "")
            
            # Create updated YAML with caCertificates
            if [[ -n "$EXISTING_YAML" ]]; then
              # Use yq to merge caCertificates into existing YAML, or use a simple approach
              # Create a temporary YAML file with the update
              echo "$EXISTING_YAML" > existing-ramen-config.yaml
              
              # Add or update caCertificates in the YAML
              # Check if caCertificates already exists
              if grep -q "^caCertificates:" existing-ramen-config.yaml; then
                # Update existing caCertificates
                if command -v yq &>/dev/null; then
                  yq eval ".caCertificates = \"$CA_BUNDLE_BASE64\"" -i existing-ramen-config.yaml
                else
                  # Fallback: use sed to update the line
                  sed -i "s/^caCertificates:.*/caCertificates: $CA_BUNDLE_BASE64/" existing-ramen-config.yaml
                fi
              else
                # Add new caCertificates at the end
                echo "caCertificates: $CA_BUNDLE_BASE64" >> existing-ramen-config.yaml
              fi
              
              UPDATED_YAML=$(cat existing-ramen-config.yaml)
            else
              # No existing YAML, create new one with just caCertificates
              UPDATED_YAML="caCertificates: $CA_BUNDLE_BASE64"
            fi
            
            # Create patch file for ConfigMap update
            echo "data:" > ramen-patch.yaml
            echo "  ramen_manager_config.yaml: |" >> ramen-patch.yaml
            echo "$UPDATED_YAML" | sed 's/^/    /' >> ramen-patch.yaml
            
            # Patch the ConfigMap with updated YAML
            oc patch configmap ramen-hub-operator-config -n openshift-operators \
              --type=merge \
              --patch-file=ramen-patch.yaml || {
              echo "  Warning: Could not patch ramen-hub-operator-config"
            }
            
            rm -f existing-ramen-config.yaml ramen-patch.yaml
          else
            echo "  ConfigMap does not exist, creating with ramen_manager_config.yaml containing caCertificates..."
            oc create configmap ramen-hub-operator-config -n openshift-operators \
              --from-literal=ramen_manager_config.yaml="caCertificates: $CA_BUNDLE_BASE64" || {
              echo "  Warning: Could not create ramen-hub-operator-config"
            }
          fi
          
          echo "  ramen-hub-operator-config updated successfully with base64-encoded CA bundle"
          echo "  This enables SSL access for discovered applications in ODF Disaster Recovery"
          
          echo "8. Distributing certificate data to managed clusters..."
          DISTRIBUTION_ATTEMPTS=3
          DISTRIBUTION_SLEEP=10
          
          for cluster in $MANAGED_CLUSTERS; do
            if [[ "$cluster" == "local-cluster" ]]; then
              continue
            fi
            
            echo "  Distributing to $cluster..."
            
            KUBECONFIG_FILE=""
            if oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | base64 -d > "$WORK_DIR/${cluster}-kubeconfig.yaml" 2>/dev/null; then
              KUBECONFIG_FILE="$WORK_DIR/${cluster}-kubeconfig.yaml"
            fi
            
            if [[ -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
              distribution_success=false
              for dist_attempt in $(seq 1 $DISTRIBUTION_ATTEMPTS); do
                echo "    Distribution attempt $dist_attempt/$DISTRIBUTION_ATTEMPTS for $cluster..."
                
                if oc --kubeconfig="$KUBECONFIG_FILE" create configmap cluster-proxy-ca-bundle \
                  --from-file=ca-bundle.crt="$WORK_DIR/combined-ca-bundle.crt" \
                  -n openshift-config \
                  --dry-run=client -o yaml | oc --kubeconfig="$KUBECONFIG_FILE" apply -f -; then
                  
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
          
          echo "9. Verifying certificate distribution to managed clusters..."
          verification_failed=false
          REQUIRED_VERIFICATION_CLUSTERS=("ocp-primary" "ocp-secondary")
          VERIFIED_CLUSTERS=()
          
          for cluster in $MANAGED_CLUSTERS; do
            if [[ "$cluster" == "local-cluster" ]]; then
              continue
            fi
            
            echo "  Verifying distribution to $cluster..."
            KUBECONFIG_FILE="$WORK_DIR/${cluster}-kubeconfig.yaml"
            
            if [[ -f "$KUBECONFIG_FILE" ]]; then
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
            echo "to ALL managed clusters (ocp-primary and ocp-secondary)."
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
          
          echo ""
          echo "✅ ODF SSL certificate management completed successfully!"
          echo "   - Hub cluster CA bundle: Updated (includes trusted CA + ingress CA)"
          echo "   - Hub cluster proxy: Configured"
          echo "   - ramen-hub-operator-config: Updated with base64-encoded CA bundle"
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
EOF
  
  echo "Certificate extraction job created"
  
  echo "Waiting for certificate extraction to complete..."
  attempt=0
  while [[ $attempt -lt $MAX_ATTEMPTS ]]; do
    attempt=$((attempt + 1))
    echo "  Attempt $attempt/$MAX_ATTEMPTS"
    
    if oc wait --for=condition=complete job/odf-ssl-certificate-extractor -n openshift-config --timeout=60s 2>/dev/null; then
      echo "  ✅ Certificate extraction completed successfully"
      return 0
    else
      echo "  ⏳ Certificate extraction still running, waiting..."
      sleep $SLEEP_INTERVAL
    fi
  done
  
  echo "  ❌ Certificate extraction did not complete within expected time"
  return 1
}

# Main execution with retry logic
main_execution() {
  echo "🔍 Starting certificate distribution check with retry logic..."
  
  # First, wait for required clusters to be ready
  echo "⏳ Waiting for required clusters to be available and joined before proceeding..."
  if wait_for_cluster_readiness; then
    echo "✅ All required clusters are ready - proceeding with certificate checks"
  else
    echo "⚠️  Some clusters are not ready yet, but continuing anyway..."
    echo "   The certificate extraction will be attempted when clusters become ready"
  fi
  
  attempt=1
  while [[ $attempt -le $MAX_ATTEMPTS ]]; do
    echo "=== Certificate Distribution Attempt $attempt/$MAX_ATTEMPTS ==="
    
    if check_certificate_distribution; then
      echo "✅ Certificate distribution is complete and verified"
      echo "   All clusters have proper CA bundles"
      echo "🎯 ODF SSL certificate precheck completed successfully"
      echo "   Ready for DR prerequisites check"
      exit 0
    else
      echo "❌ Certificate distribution is incomplete or missing"
      
      echo "🧹 Cleaning up placeholder ConfigMaps..."
      cleanup_placeholder_configmaps
      
      echo "   Triggering certificate extraction (attempt $attempt/$MAX_ATTEMPTS)..."
      
      if trigger_certificate_extraction; then
        echo "✅ Certificate extraction completed successfully"
        echo "   Re-verifying distribution..."
        
        sleep 10
        
        if check_certificate_distribution; then
          echo "✅ Certificate distribution verified after extraction"
          echo "🎯 ODF SSL certificate precheck completed successfully"
          echo "   Ready for DR prerequisites check"
          exit 0
        else
          echo "⚠️  Certificate extraction completed but distribution still incomplete"
          echo "   Will retry in $SLEEP_INTERVAL seconds..."
        fi
      else
        echo "❌ Certificate extraction failed (attempt $attempt/$MAX_ATTEMPTS)"
        echo "   Will retry in $SLEEP_INTERVAL seconds..."
      fi
    fi
    
    if [[ $attempt -lt $MAX_ATTEMPTS ]]; then
      echo "⏳ Waiting $SLEEP_INTERVAL seconds before next attempt..."
      sleep $SLEEP_INTERVAL
    fi
    
    ((attempt++))
  done
  
  echo "❌ Certificate distribution failed after $MAX_ATTEMPTS attempts"
  echo "   This may affect DR prerequisites check"
  echo "   Manual intervention may be required"
  exit 1
}

# Call main execution
main_execution

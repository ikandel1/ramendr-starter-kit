#!/bin/bash

# Script to update the CA bundle with additional certificates
# This can be used to add managed cluster CAs when they become available

set -euo pipefail

echo "CA Bundle Update Script"
echo "========================"

# Function to add CA to the bundle
add_ca_to_bundle() {
    local ca_file="$1"
    local bundle_file="/tmp/updated-ca-bundle.crt"
    
    if [[ -f "$ca_file" && -s "$ca_file" ]]; then
        echo "Adding CA from: $ca_file"
        
        # Get existing bundle
        oc get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath="{.data['ca-bundle\.crt']}" > "$bundle_file" 2>/dev/null || touch "$bundle_file"
        
        # Add new CA
        cat "$ca_file" >> "$bundle_file"
        echo "" >> "$bundle_file"  # Add separator
        
        # Remove duplicates and empty lines
        sort "$bundle_file" | uniq | grep -v '^$' > "${bundle_file}.tmp"
        mv "${bundle_file}.tmp" "$bundle_file"
        
        # Update ConfigMap
        oc create configmap cluster-proxy-ca-bundle \
            --from-file=ca-bundle.crt="$bundle_file" \
            -n openshift-config \
            --dry-run=client -o yaml | oc apply -f -
        
        echo "✓ CA bundle updated successfully"
        echo "Bundle now contains $(grep -c 'BEGIN CERTIFICATE' "$bundle_file" 2>/dev/null || echo "0") certificates"
        
        # Cleanup
        rm -f "$bundle_file"
        
        return 0
    else
        echo "✗ CA file is empty or doesn't exist: $ca_file"
        return 1
    fi
}

# Function to extract CA from managed cluster
extract_managed_cluster_ca() {
    local cluster_name="$1"
    local output_file="$2"
    
    echo "Extracting CA from managed cluster: $cluster_name"
    
    # Try ManagedClusterInfo first
    if oc get managedclusterinfo -n "$cluster_name" -o jsonpath='{.items[0].spec.loggingCA}' 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
        oc get managedclusterinfo -n "$cluster_name" -o jsonpath='{.items[0].spec.loggingCA}' > "$output_file" 2>/dev/null
        echo "✓ CA extracted from ManagedClusterInfo for $cluster_name"
        return 0
    else
        echo "✗ No CA found in ManagedClusterInfo for $cluster_name"
        return 1
    fi
}

# Function to check current bundle status
check_bundle_status() {
    echo "Current CA Bundle Status:"
    echo "========================"
    
    if oc get configmap cluster-proxy-ca-bundle -n openshift-config >/dev/null 2>&1; then
        local cert_count
        cert_count=$(oc get configmap cluster-proxy-ca-bundle -n openshift-config -o jsonpath="{.data['ca-bundle\.crt']}" | grep -c 'BEGIN CERTIFICATE' 2>/dev/null || echo "0")
        echo "✓ ConfigMap exists with $cert_count certificates"
        
        # Check proxy configuration
        local proxy_ca
        proxy_ca=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || echo "")
        if [[ "$proxy_ca" == "cluster-proxy-ca-bundle" ]]; then
            echo "✓ Proxy is configured to use the CA bundle"
        else
            echo "⚠️  Proxy is not using the CA bundle (current: $proxy_ca)"
        fi
    else
        echo "✗ CA bundle ConfigMap does not exist"
        return 1
    fi
}

# Main execution
main() {
    local action="${1:-status}"
    
    case "$action" in
        "status")
            check_bundle_status
            ;;
        "add")
            if [[ $# -lt 2 ]]; then
                echo "Usage: $0 add <ca-file>"
                exit 1
            fi
            add_ca_to_bundle "$2"
            ;;
        "extract")
            if [[ $# -lt 2 ]]; then
                echo "Usage: $0 extract <cluster-name>"
                exit 1
            fi
            local cluster_name="$2"
            local temp_file="/tmp/${cluster_name}-ca.crt"
            if extract_managed_cluster_ca "$cluster_name" "$temp_file"; then
                add_ca_to_bundle "$temp_file"
                rm -f "$temp_file"
            fi
            ;;
        "update-all")
            echo "Updating CA bundle with all available managed cluster CAs..."
            local temp_dir="/tmp/ca-update-$(date +%s)"
            mkdir -p "$temp_dir"
            
            # Get all managed clusters
            local managed_clusters
            managed_clusters=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
            
            for cluster in $managed_clusters; do
                if [[ "$cluster" == "local-cluster" ]]; then
                    continue
                fi
                
                local ca_file="$temp_dir/${cluster}-ca.crt"
                if extract_managed_cluster_ca "$cluster" "$ca_file"; then
                    add_ca_to_bundle "$ca_file"
                fi
            done
            
            # Cleanup
            rm -rf "$temp_dir"
            ;;
        *)
            echo "Usage: $0 {status|add|extract|update-all}"
            echo ""
            echo "Commands:"
            echo "  status      - Check current bundle status"
            echo "  add <file>  - Add CA from file to bundle"
            echo "  extract <cluster> - Extract and add CA from managed cluster"
            echo "  update-all  - Update bundle with all available managed cluster CAs"
            exit 1
            ;;
    esac
}

# Show usage if help requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 {status|add|extract|update-all}"
    echo ""
    echo "This script helps manage the cluster proxy CA bundle by:"
    echo "1. Checking current bundle status"
    echo "2. Adding CAs from files"
    echo "3. Extracting CAs from managed clusters"
    echo "4. Updating with all available CAs"
    echo ""
    echo "Examples:"
    echo "  $0 status                    # Check current status"
    echo "  $0 add /path/to/ca.crt      # Add CA from file"
    echo "  $0 extract \${PRIMARY_CLUSTER:-ocp-primary}  # Extract CA from primary managed cluster (set PRIMARY_CLUSTER to match values.yaml)"
    echo "  $0 update-all               # Update with all managed cluster CAs"
    exit 0
fi

# Run main function
main "$@"

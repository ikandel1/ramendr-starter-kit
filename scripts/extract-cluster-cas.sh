#!/bin/bash

# Script to extract CA certificates from hub and managed clusters
# and update the values files with the CA data

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VALUES_DIR="$PROJECT_ROOT"
CA_OUTPUT_DIR="$PROJECT_ROOT/ca-certificates"

# Create output directory
mkdir -p "$CA_OUTPUT_DIR"

# Function to extract CA from a cluster
extract_cluster_ca() {
    local cluster_name="$1"
    local kubeconfig="$2"
    local output_file="$3"
    
    echo "Extracting CA certificate from cluster: $cluster_name"
    
    # Extract CA certificate from the cluster
    if oc --kubeconfig="$kubeconfig" get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}" > "$output_file" 2>/dev/null; then
        echo "Successfully extracted CA certificate for $cluster_name"
        return 0
    else
        echo "Warning: Could not extract CA certificate from $cluster_name"
        echo "# CA certificate for $cluster_name could not be extracted" > "$output_file"
        return 1
    fi
}

# Function to update values file with CA data
update_values_with_ca() {
    local values_file="$1"
    local ca_file="$2"
    local ca_key="$3"
    
    if [[ -f "$ca_file" ]]; then
        # Read CA content and escape it for YAML
        local ca_content
        ca_content=$(cat "$ca_file" | sed 's/^/        /' | sed '1s/^/      /')
        
        # Create temporary file with updated content
        local temp_file
        temp_file=$(mktemp)
        
        # Check if the CA key already exists in the values file
        if grep -q "^$ca_key:" "$values_file"; then
            # Update existing CA key
            awk -v key="$ca_key" -v content="$ca_content" '
                /^'$ca_key':/ { 
                    print key ": |"
                    print content
                    next 
                }
                /^[[:space:]]*[a-zA-Z]/ && !/^'$ca_key':/ { 
                    if (in_ca_block) { in_ca_block=0 }
                }
                /^[[:space:]]+/ && in_ca_block { next }
                { print }
            ' "$values_file" > "$temp_file"
        else
            # Add new CA key at the end of the file
            cp "$values_file" "$temp_file"
            echo "" >> "$temp_file"
            echo "$ca_key: |" >> "$temp_file"
            echo "$ca_content" >> "$temp_file"
        fi
        
        mv "$temp_file" "$values_file"
        echo "Updated $values_file with CA data for $ca_key"
    fi
}

# Main execution
main() {
    echo "Starting CA certificate extraction process..."
    
    # Extract hub cluster CA (assuming current context is hub)
    if [[ -n "${HUB_KUBECONFIG:-}" ]]; then
        extract_cluster_ca "hub" "$HUB_KUBECONFIG" "$CA_OUTPUT_DIR/hub-ca.crt"
        update_values_with_ca "$VALUES_DIR/values-global.yaml" "$CA_OUTPUT_DIR/hub-ca.crt" "hubClusterCA"
    else
        echo "Warning: HUB_KUBECONFIG not set, skipping hub cluster CA extraction"
    fi
    
    # Extract managed cluster CAs
    # This assumes you have kubeconfigs for managed clusters
    # You can set them via environment variables like MANAGED1_KUBECONFIG, etc.
    
    local cluster_index=1
    while [[ -n "${!MANAGED${cluster_index}_KUBECONFIG:-}" ]]; do
        local kubeconfig_var="MANAGED${cluster_index}_KUBECONFIG"
        local kubeconfig="${!kubeconfig_var}"
        local cluster_name="managed-${cluster_index}"
        
        extract_cluster_ca "$cluster_name" "$kubeconfig" "$CA_OUTPUT_DIR/${cluster_name}-ca.crt"
        
        # Update the appropriate values file
        # For now, we'll update the global values file
        # In a real scenario, you might want to update cluster-specific values
        update_values_with_ca "$VALUES_DIR/values-global.yaml" "$CA_OUTPUT_DIR/${cluster_name}-ca.crt" "${cluster_name}ClusterCA"
        
        ((cluster_index++))
    done
    
    # For the specific clusters in your configuration (set PRIMARY_CLUSTER/SECONDARY_CLUSTER to match values.yaml)
    PRIMARY_CLUSTER="${PRIMARY_CLUSTER:-ocp-primary}"
    SECONDARY_CLUSTER="${SECONDARY_CLUSTER:-ocp-secondary}"
    echo ""
    echo "CA certificate extraction completed."
    echo "Certificates are stored in: $CA_OUTPUT_DIR"
    echo ""
    echo "To extract CAs from your specific clusters, run:"
    echo "  # For $PRIMARY_CLUSTER cluster:"
    echo "  oc --kubeconfig=<primary-kubeconfig> get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath=\"{.data['ca-bundle\\.crt']}\" > $CA_OUTPUT_DIR/${PRIMARY_CLUSTER}-ca.crt"
    echo ""
    echo "  # For $SECONDARY_CLUSTER cluster:"
    echo "  oc --kubeconfig=<secondary-kubeconfig> get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath=\"{.data['ca-bundle\\.crt']}\" > $CA_OUTPUT_DIR/${SECONDARY_CLUSTER}-ca.crt"
    echo ""
    echo "Then update your values files with the CA data."
}

# Show usage if no arguments provided
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [options]"
    echo ""
    echo "Environment variables:"
    echo "  HUB_KUBECONFIG          - Kubeconfig for hub cluster"
    echo "  MANAGED1_KUBECONFIG     - Kubeconfig for first managed cluster"
    echo "  MANAGED2_KUBECONFIG     - Kubeconfig for second managed cluster"
    echo "  ...                     - Additional managed cluster kubeconfigs"
    echo ""
    echo "Example:"
    echo "  HUB_KUBECONFIG=/path/to/hub/kubeconfig \\"
    echo "  MANAGED1_KUBECONFIG=/path/to/managed1/kubeconfig \\"
    echo "  $0"
    echo ""
    echo "Or run interactively:"
    echo "  $0 --interactive"
    exit 0
fi

# Handle interactive mode
if [[ "${1:-}" == "--interactive" ]]; then
    echo "Interactive CA extraction mode"
    echo "Please provide the kubeconfig paths:"
    echo ""
    
    read -p "Hub cluster kubeconfig path: " hub_kubeconfig
    if [[ -n "$hub_kubeconfig" && -f "$hub_kubeconfig" ]]; then
        export HUB_KUBECONFIG="$hub_kubeconfig"
    fi
    
    local index=1
    while true; do
        read -p "Managed cluster $index kubeconfig path (or press Enter to skip): " managed_kubeconfig
        if [[ -z "$managed_kubeconfig" ]]; then
            break
        fi
        if [[ -f "$managed_kubeconfig" ]]; then
            export "MANAGED${index}_KUBECONFIG"="$managed_kubeconfig"
            ((index++))
        else
            echo "File not found: $managed_kubeconfig"
        fi
    done
fi

# Run main function
main

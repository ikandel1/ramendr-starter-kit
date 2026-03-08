#!/bin/bash

# Script to download kubeconfigs from all managed clusters
# Downloads kubeconfigs to <cluster-name>.yaml format

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if we're connected to a hub cluster
check_hub_connection() {
    if ! oc get managedclusters &>/dev/null; then
        print_error "Not connected to a hub cluster or ACM is not installed"
        print_error "Please ensure you're connected to the hub cluster with ACM"
        exit 1
    fi
}

# Function to get all managed clusters
get_managed_clusters() {
    oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || {
        print_error "Failed to get managed clusters"
        exit 1
    }
}

# Function to download kubeconfig for a specific cluster
download_kubeconfig() {
    local cluster_name="$1"
    local output_file="${cluster_name}.yaml"
    
    print_status "Processing cluster: $cluster_name"
    
    # Check if cluster is available
    local cluster_status=$(oc get managedcluster "$cluster_name" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$cluster_status" != "True" ]]; then
        print_warning "Cluster $cluster_name is not available (status: $cluster_status), skipping..."
        return 0
    fi
    
    # Get the kubeconfig secret name
    local kubeconfig_secret=$(oc get secret -n "$cluster_name" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1)
    
    if [[ -z "$kubeconfig_secret" ]]; then
        print_warning "No kubeconfig secret found for cluster $cluster_name, skipping..."
        return 0
    fi
    
    print_status "Found kubeconfig secret: $kubeconfig_secret"
    
    # Try to get the kubeconfig data
    local kubeconfig_data=""
    
    # First try to get the 'kubeconfig' field
    kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster_name" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    
    # If that fails, try the 'raw-kubeconfig' field
    if [[ -z "$kubeconfig_data" ]]; then
        kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster_name" -o jsonpath='{.data.raw-kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
    fi
    
    if [[ -z "$kubeconfig_data" ]]; then
        print_warning "Could not extract kubeconfig data for cluster $cluster_name, skipping..."
        return 0
    fi
    
    # Write the kubeconfig to file
    echo "$kubeconfig_data" > "$output_file"
    
    # Verify the kubeconfig is valid
    if oc --kubeconfig="$output_file" get nodes &>/dev/null; then
        print_success "Downloaded kubeconfig for $cluster_name to $output_file"
        
        # Show cluster info
        local server_url=$(echo "$kubeconfig_data" | grep -E "^\s*server:" | head -1 | awk '{print $2}' || echo "Unknown")
        print_status "  Server URL: $server_url"
        
        # Show node count
        local node_count=$(oc --kubeconfig="$output_file" get nodes --no-headers 2>/dev/null | wc -l || echo "0")
        print_status "  Node count: $node_count"
        
    else
        print_warning "Downloaded kubeconfig for $cluster_name but it may not be valid"
        print_status "  File saved as: $output_file"
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help              Show this help message"
    echo "  -c, --cluster CLUSTER   Download kubeconfig for specific cluster only"
    echo "  -o, --output-dir DIR    Output directory (default: current directory)"
    echo "  -f, --force             Overwrite existing files"
    echo "  --dry-run               Show what would be downloaded without actually downloading"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Download all managed cluster kubeconfigs"
    echo "  $0 -c \${PRIMARY_CLUSTER:-ocp-primary}          # Download only primary cluster kubeconfig (set PRIMARY_CLUSTER to match values.yaml)"
    echo "  $0 -o /tmp/kubeconfigs               # Download to /tmp/kubeconfigs directory"
    echo "  $0 --dry-run                         # Show what would be downloaded"
    echo ""
    echo "Environment variables:"
    echo "  KUBECONFIG                           # Kubeconfig for hub cluster (if not using current context)"
    echo "  PRIMARY_CLUSTER                      # Primary DR cluster name (default: ocp-primary; match values.yaml)"
    echo "  SECONDARY_CLUSTER                    # Secondary DR cluster name (default: ocp-secondary; match values.yaml)"
}

# Main function
main() {
    local specific_cluster=""
    local output_dir="."
    local force_overwrite=false
    local dry_run=false
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -c|--cluster)
                specific_cluster="$2"
                shift 2
                ;;
            -o|--output-dir)
                output_dir="$2"
                shift 2
                ;;
            -f|--force)
                force_overwrite=true
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            *)
                print_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Create output directory if it doesn't exist
    if [[ ! -d "$output_dir" ]]; then
        mkdir -p "$output_dir"
        print_status "Created output directory: $output_dir"
    fi
    
    # Change to output directory
    cd "$output_dir"
    
    # Check hub connection
    print_status "Checking hub cluster connection..."
    check_hub_connection
    print_success "Connected to hub cluster"
    
    # Get managed clusters
    print_status "Getting managed clusters..."
    local managed_clusters
    managed_clusters=$(get_managed_clusters)
    
    if [[ -z "$managed_clusters" ]]; then
        print_warning "No managed clusters found"
        exit 0
    fi
    
    print_status "Found managed clusters: $managed_clusters"
    
    # Filter clusters if specific cluster requested
    if [[ -n "$specific_cluster" ]]; then
        if echo "$managed_clusters" | grep -q "$specific_cluster"; then
            managed_clusters="$specific_cluster"
        else
            print_error "Cluster '$specific_cluster' not found in managed clusters"
            exit 1
        fi
    fi
    
    # Process each cluster
    local total_clusters=0
    local successful_downloads=0
    
    for cluster in $managed_clusters; do
        # Skip local-cluster (hub cluster)
        if [[ "$cluster" == "local-cluster" ]]; then
            print_status "Skipping hub cluster (local-cluster)"
            continue
        fi
        
        total_clusters=$((total_clusters + 1))
        
        if [[ "$dry_run" == "true" ]]; then
            print_status "Would download kubeconfig for: $cluster"
            continue
        fi
        
        # Check if file already exists
        local output_file="${cluster}.yaml"
        if [[ -f "$output_file" && "$force_overwrite" != "true" ]]; then
            print_warning "File $output_file already exists, use -f to overwrite"
            continue
        fi
        
        # Download kubeconfig
        if download_kubeconfig "$cluster"; then
            successful_downloads=$((successful_downloads + 1))
        fi
        
        echo ""
    done
    
    # Summary
    if [[ "$dry_run" == "true" ]]; then
        print_status "Dry run completed. Would process $total_clusters clusters."
    else
        print_success "Download completed!"
        print_status "Total clusters processed: $total_clusters"
        print_status "Successful downloads: $successful_downloads"
        
        if [[ $successful_downloads -gt 0 ]]; then
            echo ""
            print_status "Downloaded kubeconfigs:"
            ls -la *.yaml 2>/dev/null || true
        fi
    fi
}

# Run main function with all arguments
main "$@"

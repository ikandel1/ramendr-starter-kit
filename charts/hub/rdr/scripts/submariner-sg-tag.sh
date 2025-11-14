#!/bin/bash
set -euo pipefail

echo "Starting Submariner security group tagging..."

# Check if AWS CLI is available, install to user-writable location if needed
AWS_CLI_PATH="/tmp/aws-cli"
if ! command -v aws &>/dev/null; then
  echo "AWS CLI is not available. Installing to $AWS_CLI_PATH..."
  # Try to install AWS CLI v2 to a user-writable location
  if command -v curl &>/dev/null && command -v unzip &>/dev/null; then
    curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp
    # Install to user-writable location (no sudo needed)
    /tmp/aws/install -i "$AWS_CLI_PATH" -b "$AWS_CLI_PATH/bin"
    rm -rf /tmp/aws /tmp/awscliv2.zip
    # Add to PATH
    export PATH="$AWS_CLI_PATH/bin:$PATH"
  else
    echo "❌ Cannot install AWS CLI - required tools (curl, unzip) not available"
    exit 1
  fi
fi

# Verify AWS CLI is working
if ! aws --version &>/dev/null; then
  echo "❌ AWS CLI is not working"
  exit 1
fi

echo "✅ AWS CLI is available: $(aws --version 2>&1)"

# Configuration
KUBECONFIG_DIR="/tmp/kubeconfigs"
MAX_ATTEMPTS=30
SLEEP_INTERVAL=10

# Create kubeconfig directory
mkdir -p "$KUBECONFIG_DIR"

# Function to download kubeconfig for a cluster
download_kubeconfig() {
  local cluster="$1"
  local kubeconfig_path="$KUBECONFIG_DIR/${cluster}-kubeconfig.yaml"
  
  echo "Downloading kubeconfig for $cluster..."
  
  # Get the kubeconfig secret name
  local kubeconfig_secret=$(oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1)
  
  if [[ -z "$kubeconfig_secret" ]]; then
    echo "  ❌ No kubeconfig secret found for cluster $cluster"
    return 1
  fi
  
  echo "  Found kubeconfig secret: $kubeconfig_secret"
  
  # Try to get the kubeconfig data
  local kubeconfig_data=""
  kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -z "$kubeconfig_data" ]]; then
    kubeconfig_data=$(oc get "$kubeconfig_secret" -n "$cluster" -o jsonpath='{.data.raw-kubeconfig}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  fi
  
  if [[ -z "$kubeconfig_data" ]]; then
    echo "  ❌ Could not extract kubeconfig data for cluster $cluster"
    return 1
  fi
  
  # Write the kubeconfig to file
  echo "$kubeconfig_data" > "$kubeconfig_path"
  
  # Verify the kubeconfig is valid
  if oc --kubeconfig="$kubeconfig_path" get nodes &>/dev/null; then
    echo "  ✅ Successfully downloaded and verified kubeconfig for $cluster"
    echo "$kubeconfig_path"
    return 0
  else
    echo "  ❌ Kubeconfig for $cluster is invalid"
    return 1
  fi
}

# Function to get infrastructure name from a cluster
get_infrastructure_name() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "  Getting infrastructure name for cluster $cluster..."
  
  local infra_name=""
  
  # Method 1: Try to get from ClusterDeployment on hub (most reliable, no need for managed cluster access)
  # Try status.infrastructureName first (set after cluster is provisioned)
  infra_name=$(oc get clusterdeployment "$cluster" -n "$cluster" -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
  # Fallback to spec.clusterMetadata.infraID if status doesn't have it
  if [[ -z "$infra_name" ]]; then
    infra_name=$(oc get clusterdeployment "$cluster" -n "$cluster" -o jsonpath='{.spec.clusterMetadata.infraID}' 2>/dev/null || echo "")
  fi
  
  # Method 2: Try to get from infrastructure status on managed cluster
  if [[ -z "$infra_name" ]]; then
    echo "  Trying to get infrastructure name from managed cluster infrastructure status..."
    infra_name=$(oc --kubeconfig="$kubeconfig" get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
  fi
  
  # Method 3: Try to get from infrastructure metadata name
  if [[ -z "$infra_name" ]]; then
    echo "  Trying to get infrastructure name from infrastructure metadata..."
    infra_name=$(oc --kubeconfig="$kubeconfig" get infrastructure cluster -o jsonpath='{.metadata.name}' 2>/dev/null || echo "")
  fi
  
  # Method 4: Try to extract from install-config secret
  if [[ -z "$infra_name" ]]; then
    echo "  Trying to get infrastructure name from install-config..."
    local install_config_secret="${cluster}-cluster-install-config"
    if oc get secret "$install_config_secret" -n "$cluster" &>/dev/null; then
      # The infrastructure name is typically the cluster name with a random suffix
      # Try to get it from the metadata name in install-config
      local cluster_name_from_config=$(oc get secret "$install_config_secret" -n "$cluster" -o jsonpath='{.data.install-config\.yaml}' 2>/dev/null | \
        base64 -d 2>/dev/null | grep -E '^\s*metadata:' -A 5 | grep -E '^\s*name:' | awk '{print $2}' | tr -d '"' || echo "")
      if [[ -n "$cluster_name_from_config" ]]; then
        # Infrastructure name is usually cluster name with a random suffix
        # We can't get the exact suffix, but we can use the cluster name as a fallback
        infra_name="$cluster_name_from_config"
      fi
    fi
  fi
  
  # Method 5: Use cluster name as fallback (last resort)
  if [[ -z "$infra_name" ]]; then
    echo "  ⚠️  Using cluster name as infrastructure name fallback..."
    infra_name="$cluster"
  fi
  
  if [[ -z "$infra_name" ]]; then
    echo "  ❌ Could not get infrastructure name for cluster $cluster using any method"
    return 1
  fi
  
  echo "  ✅ Infrastructure name: $infra_name"
  echo "$infra_name"
  return 0
}

# Function to get AWS credentials from hub cluster
get_aws_credentials() {
  local cluster="$1"
  local kubeconfig="$2"
  
  echo "  Getting AWS credentials for cluster $cluster..."
  
  # Try to get AWS credentials from the cluster's AWS creds secret in the hub cluster
  local aws_secret_name="${cluster}-cluster-aws-creds"
  local aws_access_key=""
  local aws_secret_key=""
  local aws_region=""
  
  # Get AWS access key from hub cluster (secret is in the cluster's namespace on hub)
  aws_access_key=$(oc get secret "$aws_secret_name" -n "$cluster" -o jsonpath='{.data.aws_access_key_id}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -z "$aws_access_key" ]]; then
    echo "  ❌ Could not get AWS access key from secret $aws_secret_name in namespace $cluster"
    return 1
  fi
  
  # Get AWS secret key from hub cluster
  aws_secret_key=$(oc get secret "$aws_secret_name" -n "$cluster" -o jsonpath='{.data.aws_secret_access_key}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  
  if [[ -z "$aws_secret_key" ]]; then
    echo "  ❌ Could not get AWS secret key from secret $aws_secret_name in namespace $cluster"
    return 1
  fi
  
  # Try multiple methods to get AWS region
  aws_region=""
  
  # Method 1: Try to get from ClusterDeployment on hub cluster
  echo "  Trying to get region from ClusterDeployment..."
  aws_region=$(oc get clusterdeployment "$cluster" -n "$cluster" -o jsonpath='{.spec.platform.aws.region}' 2>/dev/null || echo "")
  
  # Method 2: Try to get from install-config secret on hub cluster
  if [[ -z "$aws_region" ]]; then
    echo "  Trying to get region from install-config secret..."
    local install_config_secret="${cluster}-cluster-install-config"
    if oc get secret "$install_config_secret" -n "$cluster" &>/dev/null; then
      aws_region=$(oc get secret "$install_config_secret" -n "$cluster" -o jsonpath='{.data.install-config\.yaml}' 2>/dev/null | \
        base64 -d 2>/dev/null | grep -E '^\s*region:' | awk '{print $2}' | tr -d '"' || echo "")
    fi
  fi
  
  # Method 3: Try to get from managed cluster's infrastructure (using managed cluster kubeconfig)
  if [[ -z "$aws_region" ]]; then
    echo "  Trying to get region from managed cluster infrastructure..."
    aws_region=$(oc --kubeconfig="$kubeconfig" get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.region}' 2>/dev/null || echo "")
  fi
  
  # Method 4: Try to get from ManagedClusterInfo on hub
  if [[ -z "$aws_region" ]]; then
    echo "  Trying to get region from ManagedClusterInfo..."
    aws_region=$(oc get managedclusterinfo "$cluster" -n "$cluster" -o jsonpath='{.status.clusterClaims[?(@.name=="region.open-cluster-management.io")].value}' 2>/dev/null || echo "")
  fi
  
  # Method 5: Try to get from infrastructure spec (fallback)
  if [[ -z "$aws_region" ]]; then
    echo "  Trying to get region from infrastructure spec..."
    aws_region=$(oc --kubeconfig="$kubeconfig" get infrastructure cluster -o jsonpath='{.spec.platformSpec.aws.region}' 2>/dev/null || echo "")
  fi
  
  # Method 6: Try to detect from AWS using credentials (if we have them and have infra_name)
  # This requires the infrastructure name to search for cluster resources
  if [[ -z "$aws_region" && -n "$aws_access_key" && -n "$aws_secret_key" ]]; then
    echo "  Trying to detect region from AWS resources..."
    # Get infrastructure name first (we'll need it to find cluster resources)
    local temp_infra_name=$(oc --kubeconfig="$kubeconfig" get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "")
    
    if [[ -n "$temp_infra_name" ]]; then
      # Temporarily set credentials
      export AWS_ACCESS_KEY_ID="$aws_access_key"
      export AWS_SECRET_ACCESS_KEY="$aws_secret_key"
      
      # Get list of all available regions
      local available_regions=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text 2>/dev/null || echo "")
      
      if [[ -n "$available_regions" ]]; then
        # Search for VPCs or security groups tagged with the cluster infrastructure name
        for test_region in $available_regions; do
          export AWS_DEFAULT_REGION="$test_region"
          # Look for VPCs with tags matching the cluster infrastructure name
          local vpc_found=$(aws ec2 describe-vpcs \
            --filters "Name=tag:Name,Values=${temp_infra_name}*" \
            --query 'Vpcs[0].VpcId' \
            --output text 2>/dev/null || echo "")
          
          if [[ -n "$vpc_found" && "$vpc_found" != "None" ]]; then
            aws_region="$test_region"
            echo "  Found cluster VPC in region: $test_region"
            break
          fi
        done
      fi
      
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
    fi
  fi
  
  if [[ -z "$aws_region" ]]; then
    echo "  ❌ Could not determine AWS region using any method"
    echo "  Tried: ClusterDeployment, install-config secret, infrastructure status, ManagedClusterInfo, infrastructure spec, AWS detection"
    return 1
  fi
  
  echo "  ✅ Successfully determined AWS region: $aws_region"
  
  # Export AWS credentials
  export AWS_ACCESS_KEY_ID="$aws_access_key"
  export AWS_SECRET_ACCESS_KEY="$aws_secret_key"
  export AWS_DEFAULT_REGION="$aws_region"
  
  return 0
}

# Function to find Submariner security group
find_submariner_security_group() {
  local cluster="$1"
  local infra_name="$2"
  
  echo "  Finding Submariner security group for cluster $cluster..."
  
  # Submariner security groups are typically tagged with submariner-related tags
  # Look for security groups with submariner tags or names
  local sg_id=""
  
  # Method 1: Look for security groups tagged with submariner.io/gateway
  sg_id=$(aws ec2 describe-security-groups \
    --filters "Name=tag:submariner.io/gateway,Values=true" \
              "Name=tag:Name,Values=*submariner*" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")
  
  # Method 2: Look for security groups with submariner in the name
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Name,Values=*submariner*" \
      --query 'SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || echo "")
  fi
  
  # Method 3: Look for security groups tagged with the cluster infrastructure name and submariner
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    sg_id=$(aws ec2 describe-security-groups \
      --filters "Name=tag:Name,Values=${infra_name}*submariner*" \
      --query 'SecurityGroups[0].GroupId' \
      --output text 2>/dev/null || echo "")
  fi
  
  # Method 4: Look for security groups that are part of the cluster's VPC and have submariner-related names
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    # Get VPC ID from cluster infrastructure
    local vpc_id=$(oc --kubeconfig="$KUBECONFIG_DIR/${cluster}-kubeconfig.yaml" get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.vpc}' 2>/dev/null || echo "")
    
    if [[ -n "$vpc_id" && "$vpc_id" != "None" ]]; then
      sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$vpc_id" \
                  "Name=group-name,Values=*submariner*" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || echo "")
    fi
  fi
  
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    echo "  ❌ Could not find Submariner security group for cluster $cluster"
    return 1
  fi
  
  echo "  ✅ Found Submariner security group: $sg_id"
  echo "$sg_id"
  return 0
}

# Function to tag security group
tag_security_group() {
  local cluster="$1"
  local infra_name="$2"
  local sg_id="$3"
  
  # Validate inputs
  if [[ -z "$infra_name" ]]; then
    echo "  ❌ Infrastructure name is empty, cannot create tag"
    return 1
  fi
  
  if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
    echo "  ❌ Security group ID is empty or invalid, cannot create tag"
    return 1
  fi
  
  echo "  Tagging security group $sg_id with kubernetes.io/cluster/${infra_name}=owned..."
  
  local tag_key="kubernetes.io/cluster/${infra_name}"
  local tag_value="owned"
  
  # Check if tag already exists
  local existing_tag=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$sg_id" \
              "Name=key,Values=$tag_key" \
    --query 'Tags[0].Value' \
    --output text 2>/dev/null || echo "")
  
  if [[ "$existing_tag" == "$tag_value" ]]; then
    echo "  ✅ Tag already exists with correct value: $tag_key=$tag_value"
    return 0
  fi
  
  # Create or update the tag
  if aws ec2 create-tags \
    --resources "$sg_id" \
    --tags "Key=$tag_key,Value=$tag_value" 2>/dev/null; then
    echo "  ✅ Successfully tagged security group $sg_id with $tag_key=$tag_value"
    return 0
  else
    echo "  ❌ Failed to tag security group $sg_id"
    return 1
  fi
}

# Main execution
echo ""
echo "Discovering managed clusters (excluding local-cluster)..."
MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[?(@.metadata.name!="local-cluster")].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$MANAGED_CLUSTERS" ]]; then
  echo "❌ No managed clusters found (excluding local-cluster)"
  exit 1
fi

echo "Found managed clusters: $MANAGED_CLUSTERS"
echo ""

SUCCESS_COUNT=0
FAILED_CLUSTERS=()

# Process each managed cluster
for cluster in $MANAGED_CLUSTERS; do
  echo "=========================================="
  echo "Processing cluster: $cluster"
  echo "=========================================="
  
  # Download kubeconfig
  kubeconfig=$(download_kubeconfig "$cluster" || echo "")
  if [[ -z "$kubeconfig" ]]; then
    echo "❌ Failed to download kubeconfig for $cluster, skipping..."
    FAILED_CLUSTERS+=("$cluster")
    continue
  fi
  
  # Verify kubeconfig works before trying to get infrastructure name
  echo "  Verifying kubeconfig connection to $cluster..."
  if ! oc --kubeconfig="$kubeconfig" get nodes &>/dev/null; then
    echo "  ⚠️  Warning: Cannot connect to cluster $cluster with kubeconfig, but continuing..."
  else
    echo "  ✅ Successfully connected to cluster $cluster"
  fi
  
  # Get infrastructure name
  infra_name=$(get_infrastructure_name "$cluster" "$kubeconfig" || echo "")
  if [[ -z "$infra_name" ]]; then
    echo "❌ Failed to get infrastructure name for $cluster, skipping..."
    echo "  Debug: Attempted to get infrastructure name using multiple methods"
    FAILED_CLUSTERS+=("$cluster")
    continue
  fi
  
  echo "  ✅ Retrieved infrastructure name: $infra_name"
  
  # Get AWS credentials (need kubeconfig for region detection)
  if ! get_aws_credentials "$cluster" "$kubeconfig"; then
    echo "❌ Failed to get AWS credentials for $cluster, skipping..."
    FAILED_CLUSTERS+=("$cluster")
    continue
  fi
  
  # Find Submariner security group
  sg_id=$(find_submariner_security_group "$cluster" "$infra_name" || echo "")
  if [[ -z "$sg_id" ]]; then
    echo "❌ Failed to find Submariner security group for $cluster, skipping..."
    FAILED_CLUSTERS+=("$cluster")
    continue
  fi
  
  # Tag security group
  if tag_security_group "$cluster" "$infra_name" "$sg_id"; then
    echo "✅ Successfully processed cluster $cluster"
    ((SUCCESS_COUNT++))
  else
    echo "❌ Failed to tag security group for $cluster"
    FAILED_CLUSTERS+=("$cluster")
  fi
  
  echo ""
done

# Summary
echo "=========================================="
echo "Summary"
echo "=========================================="
echo "Successfully processed: $SUCCESS_COUNT cluster(s)"
if [[ ${#FAILED_CLUSTERS[@]} -gt 0 ]]; then
  echo "Failed clusters: ${FAILED_CLUSTERS[*]}"
  exit 1
else
  echo "✅ All clusters processed successfully"
  exit 0
fi


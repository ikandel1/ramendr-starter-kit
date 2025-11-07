#!/bin/bash
set -euo pipefail

echo "Starting Edge GitOps VMs deployment check and deployment..."
echo "This job will check for existing VMs, Services, and Routes before applying the helm template"

# Configuration
HELM_CHART_URL="https://github.com/validatedpatterns/helm-charts/releases/download/main/edge-gitops-vms-0.2.10.tgz"
VALUES_FILE="overrides/values-egv-dr.yaml"
WORK_DIR="/tmp/edge-gitops-vms"
PRIMARY_CLUSTER="ocp-primary"

# Create working directory
mkdir -p "$WORK_DIR"

# Function to check if resource exists
check_resource_exists() {
  local api_version="$1"
  local kind="$2"
  local namespace="$3"
  local name="$4"
  
  if [[ -z "$namespace" || "$namespace" == "null" ]]; then
    # Cluster-scoped resource
    if oc get "$kind" "$name" -o jsonpath='{.metadata.name}' &>/dev/null; then
      return 0
    fi
  else
    # Namespace-scoped resource
    if oc get "$kind" "$name" -n "$namespace" -o jsonpath='{.metadata.name}' &>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Function to get kubeconfig for primary managed cluster
get_primary_cluster_kubeconfig() {
  echo "Getting kubeconfig for primary managed cluster: $PRIMARY_CLUSTER"
  
  # Try to get kubeconfig from secret
  if oc get secret -n "$PRIMARY_CLUSTER" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | \
     xargs -I {} oc get {} -n "$PRIMARY_CLUSTER" -o jsonpath='{.data.kubeconfig}' | \
     base64 -d > "$WORK_DIR/primary-kubeconfig.yaml" 2>/dev/null; then
    echo "  ✅ Retrieved kubeconfig for $PRIMARY_CLUSTER"
    export KUBECONFIG="$WORK_DIR/primary-kubeconfig.yaml"
    
    # Verify we can connect to the primary cluster
    if oc get nodes &>/dev/null; then
      echo "  ✅ Successfully connected to primary managed cluster"
      PRIMARY_CLUSTER_NAME=$(oc get managedcluster "$PRIMARY_CLUSTER" -o jsonpath='{.metadata.name}' 2>/dev/null || echo "$PRIMARY_CLUSTER")
      echo "  Primary cluster name: $PRIMARY_CLUSTER_NAME"
      return 0
    else
      echo "  ⚠️  Warning: Could not verify connection to primary cluster"
      return 1
    fi
  else
    echo "  ⚠️  Could not get kubeconfig for $PRIMARY_CLUSTER"
    echo "  Will use current context (assuming we're already on the primary cluster)"
    return 1
  fi
}

# Get kubeconfig for primary cluster
if ! get_primary_cluster_kubeconfig; then
  echo "  ⚠️  Warning: Could not get kubeconfig for primary cluster"
  echo "  Continuing with current context..."
fi

# Check if we're on the right cluster
CURRENT_CLUSTER=$(oc config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || echo "")
echo "Current cluster context: $CURRENT_CLUSTER"

# Step 1: Check for helm and install if needed
echo ""
echo "Step 1: Checking for helm..."
if ! command -v helm &>/dev/null; then
  echo "  Helm not found, installing..."
  if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash 2>&1; then
    echo "  ✅ Helm installed successfully"
  else
    echo "  ❌ Error: Failed to install helm"
    exit 1
  fi
else
  echo "  ✅ Helm is available"
  helm version
fi

# Step 2: Get helm template output
echo ""
echo "Step 2: Rendering helm template..."
echo "  Chart URL: $HELM_CHART_URL"
echo "  Values file: $VALUES_FILE"

if [[ ! -f "$VALUES_FILE" ]]; then
  echo "  ⚠️  Warning: Values file $VALUES_FILE not found, using default values"
  VALUES_ARG=""
else
  VALUES_ARG="-f $VALUES_FILE"
fi

# Render helm template
if helm template edge-gitops-vms "$HELM_CHART_URL" $VALUES_ARG > "$WORK_DIR/helm-output.yaml" 2>&1; then
  echo "  ✅ Helm template rendered successfully"
else
  echo "  ❌ Error: Failed to render helm template"
  echo "  Attempting to download chart first..."
  
  # Try downloading the chart first
  if curl -L -o "$WORK_DIR/edge-gitops-vms.tgz" "$HELM_CHART_URL" 2>/dev/null; then
    echo "  ✅ Chart downloaded successfully"
    if helm template edge-gitops-vms "$WORK_DIR/edge-gitops-vms.tgz" $VALUES_ARG > "$WORK_DIR/helm-output.yaml" 2>&1; then
      echo "  ✅ Helm template rendered successfully from local chart"
    else
      echo "  ❌ Error: Failed to render helm template from local chart"
      exit 1
    fi
  else
    echo "  ❌ Error: Failed to download chart"
    exit 1
  fi
fi

# Step 3: Extract VMs, Services, and Routes from helm output
echo ""
echo "Step 3: Extracting VMs, Services, and Routes from helm template..."

# Extract resources using yq or awk
if command -v yq &>/dev/null; then
  # Use yq to extract resources
  yq eval 'select(.kind == "VirtualMachine" or .kind == "Service" or .kind == "Route")' \
    -d'*' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources-to-check.yaml" 2>/dev/null || true
else
  # Use awk to extract resources
  awk '
    BEGIN { RS="---\n"; ORS="---\n" }
    /^kind: (VirtualMachine|Service|Route)$/ || /^kind: VirtualMachine$/ || /^kind: Service$/ || /^kind: Route$/ {
      print
      getline
      while (getline && !/^---$/) {
        print
      }
    }
  ' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources-to-check.yaml" 2>/dev/null || true
fi

# Alternative: Use grep and awk to extract resources
if [[ ! -s "$WORK_DIR/resources-to-check.yaml" ]]; then
  echo "  Using alternative method to extract resources..."
  awk '
    BEGIN { 
      RS="---"
      resource=""
    }
    /^kind: VirtualMachine$/ || /^kind: Service$/ || /^kind: Route$/ {
      resource=$0
      getline
      while (getline && !/^---$/) {
        resource=resource "\n" $0
      }
      if (resource != "") {
        print "---" resource
      }
    }
  ' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources-to-check.yaml" 2>/dev/null || true
fi

# Count resources
VM_COUNT=$(grep -c "^kind: VirtualMachine" "$WORK_DIR/resources-to-check.yaml" 2>/dev/null || echo "0")
SERVICE_COUNT=$(grep -c "^kind: Service" "$WORK_DIR/resources-to-check.yaml" 2>/dev/null || echo "0")
ROUTE_COUNT=$(grep -c "^kind: Route" "$WORK_DIR/resources-to-check.yaml" 2>/dev/null || echo "0")

echo "  Found resources in template:"
echo "    - VirtualMachines: $VM_COUNT"
echo "    - Services: $SERVICE_COUNT"
echo "    - Routes: $ROUTE_COUNT"

if [[ $VM_COUNT -eq 0 && $SERVICE_COUNT -eq 0 && $ROUTE_COUNT -eq 0 ]]; then
  echo "  ⚠️  Warning: No VMs, Services, or Routes found in helm template"
  echo "  Will proceed with applying the template anyway"
fi

# Step 4: Check if resources already exist
echo ""
echo "Step 4: Checking if resources already exist..."

ALL_EXIST=true
MISSING_RESOURCES=()

# Parse resources and check if they exist
if [[ -s "$WORK_DIR/helm-output.yaml" ]]; then
  # Extract each resource and check if it exists
  awk '
    BEGIN { 
      RS="---"
      resource=""
    }
    {
      resource=$0
      if (resource ~ /^kind: (VirtualMachine|Service|Route)$/ || resource ~ /kind: VirtualMachine/ || resource ~ /kind: Service/ || resource ~ /kind: Route/) {
        # Extract kind, name, and namespace
        kind=""
        name=""
        namespace=""
        
        split(resource, lines, "\n")
        for (i=1; i<=length(lines); i++) {
          if (lines[i] ~ /^kind:/) {
            split(lines[i], parts, ":")
            gsub(/^[ \t]+|[ \t]+$/, "", parts[2])
            kind=parts[2]
          }
          if (lines[i] ~ /^[ \t]*name:/ && name == "") {
            split(lines[i], parts, ":")
            gsub(/^[ \t]+|[ \t]+$/, "", parts[2])
            name=parts[2]
          }
          if (lines[i] ~ /^[ \t]*namespace:/ && namespace == "") {
            split(lines[i], parts, ":")
            gsub(/^[ \t]+|[ \t]+$/, "", parts[2])
            namespace=parts[2]
          }
        }
        
        if (kind != "" && name != "") {
          print kind "|" name "|" namespace
        }
      }
    }
  ' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources-list.txt"
  
  # Check each resource
  while IFS='|' read -r kind name namespace; do
    if [[ -z "$kind" || -z "$name" ]]; then
      continue
    fi
    
    echo "  Checking $kind/$name in namespace: ${namespace:-<default>}"
    
    if check_resource_exists "" "$kind" "$namespace" "$name"; then
      echo "    ✅ $kind/$name exists"
    else
      echo "    ❌ $kind/$name does not exist"
      ALL_EXIST=false
      MISSING_RESOURCES+=("$kind/$name in namespace ${namespace:-<default>}")
    fi
  done < "$WORK_DIR/resources-list.txt"
  
  if [[ ! -s "$WORK_DIR/resources-list.txt" ]]; then
    echo "  ⚠️  Warning: No VMs, Services, or Routes found in helm template"
    echo "  Will proceed with applying the template"
    ALL_EXIST=false
  fi
else
  echo "  ⚠️  Warning: Helm output file is empty"
  echo "  Will proceed with applying the template"
  ALL_EXIST=false
fi

# Step 5: Apply template if resources don't exist
echo ""
if [[ "$ALL_EXIST" == "true" && ${#MISSING_RESOURCES[@]} -eq 0 ]]; then
  echo "Step 5: All resources already exist"
  echo "  ✅ VMs, Services, and Routes are already deployed"
  echo "  Exiting successfully without applying template"
  exit 0
else
  echo "Step 5: Applying helm template..."
  echo "  Some resources are missing, applying template..."
  
  if [[ ${#MISSING_RESOURCES[@]} -gt 0 ]]; then
    echo "  Missing resources:"
    for resource in "${MISSING_RESOURCES[@]}"; do
      echo "    - $resource"
    done
  fi
  
  # Apply the helm template
  if helm template edge-gitops-vms "$HELM_CHART_URL" $VALUES_ARG | oc apply -f- 2>&1; then
    echo "  ✅ Helm template applied successfully"
    
    # Verify resources were created
    echo ""
    echo "Step 6: Verifying deployed resources..."
    VERIFY_SUCCESS=true
    
    if [[ -s "$WORK_DIR/resources-list.txt" ]]; then
      while IFS='|' read -r kind name namespace; do
        if [[ -n "$kind" && -n "$name" ]]; then
          sleep 1  # Give resources a moment to be created
          if check_resource_exists "" "$kind" "$namespace" "$name"; then
            echo "  ✅ Verified: $kind/$name exists"
          else
            echo "  ⚠️  Warning: $kind/$name not found after apply (may still be creating)"
            VERIFY_SUCCESS=false
          fi
        fi
      done < "$WORK_DIR/resources-list.txt"
    fi
    
    if [[ "$VERIFY_SUCCESS" == "true" ]]; then
      echo ""
      echo "✅ Edge GitOps VMs deployment completed successfully!"
      exit 0
    else
      echo ""
      echo "⚠️  Deployment completed but some resources may not be ready yet"
      exit 0
    fi
  else
    echo "  ❌ Error: Failed to apply helm template"
    exit 1
  fi
fi

# Cleanup
rm -rf "$WORK_DIR"


#!/bin/bash
set -euo pipefail

echo "Starting Edge GitOps VMs deployment check and deployment..."
echo "This job will check for existing VMs, Services, Routes, and ExternalSecrets before applying the helm template"

# Configuration
HELM_CHART_URL="https://github.com/validatedpatterns/helm-charts/releases/download/main/edge-gitops-vms-0.2.10.tgz"
WORK_DIR="/tmp/edge-gitops-vms"
VALUES_FILE="$WORK_DIR/values-egv-dr.yaml"
VM_NAMESPACE="gitops-vms"
DRPC_NAMESPACE="openshift-dr-ops"
DRPC_NAME="gitops-vm-protection"
PLACEMENT_NAME="gitops-vm-protection-placement-1"

# Create working directory
mkdir -p "$WORK_DIR"

# Values file is created by Helm template using .Files.Get
# It should already exist at $VALUES_FILE from the job template
# We'll check for it later when we need to use it

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

# Function to get target cluster from Placement resource
get_target_cluster_from_placement() {
  echo "Getting target cluster from Placement resource: $PLACEMENT_NAME"
  
  # Get the PlacementDecision for the Placement resource
  PLACEMENT_DECISION=$(oc get placementdecision -n "$DRPC_NAMESPACE" \
    -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  
  if [[ -z "$PLACEMENT_DECISION" ]]; then
    echo "  ⚠️  Warning: Could not find PlacementDecision for $PLACEMENT_NAME"
    echo "  Will default to primary cluster (ocp-primary)"
    TARGET_CLUSTER="ocp-primary"
    return 1
  fi
  
  # Get the cluster name from PlacementDecision
  TARGET_CLUSTER=$(oc get placementdecision "$PLACEMENT_DECISION" -n "$DRPC_NAMESPACE" \
    -o jsonpath='{.status.decisions[0].clusterName}' 2>/dev/null || echo "")
  
  if [[ -z "$TARGET_CLUSTER" ]]; then
    echo "  ⚠️  Warning: Could not determine target cluster from PlacementDecision"
    echo "  Will default to primary cluster (ocp-primary)"
    TARGET_CLUSTER="ocp-primary"
    return 1
  fi
  
  echo "  ✅ Target cluster determined from Placement: $TARGET_CLUSTER"
  return 0
}

# Function to get kubeconfig for target managed cluster
get_target_cluster_kubeconfig() {
  local cluster="$1"
  echo "Getting kubeconfig for target managed cluster: $cluster"
  
  # Try to get kubeconfig from secret
  if oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | \
     xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | \
     base64 -d > "$WORK_DIR/target-kubeconfig.yaml" 2>/dev/null; then
    echo "  ✅ Retrieved kubeconfig for $cluster"
    export KUBECONFIG="$WORK_DIR/target-kubeconfig.yaml"
    
    # Verify we can connect to the target cluster
    if oc get nodes &>/dev/null; then
      echo "  ✅ Successfully connected to target managed cluster: $cluster"
      return 0
    else
      echo "  ⚠️  Warning: Could not verify connection to target cluster"
      return 1
    fi
  else
    echo "  ⚠️  Could not get kubeconfig for $cluster"
    echo "  Will use current context (assuming we're already on the target cluster)"
    return 1
  fi
}

# Get target cluster from Placement resource
TARGET_CLUSTER="ocp-primary"  # Default to primary
if get_target_cluster_from_placement; then
  echo "  Target cluster: $TARGET_CLUSTER"
else
  echo "  Using default target cluster: $TARGET_CLUSTER"
fi

# Get kubeconfig for target cluster
if ! get_target_cluster_kubeconfig "$TARGET_CLUSTER"; then
  echo "  ⚠️  Warning: Could not get kubeconfig for target cluster"
  echo "  Continuing with current context..."
fi

# Check if we're on the right cluster
CURRENT_CLUSTER=$(oc config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || echo "")
echo "Current cluster context: $CURRENT_CLUSTER"
echo "Target cluster for deployment: $TARGET_CLUSTER"

# Ensure the gitops-vms namespace exists on the target cluster
echo ""
echo "Ensuring namespace $VM_NAMESPACE exists on target cluster..."
if oc get namespace "$VM_NAMESPACE" &>/dev/null; then
  echo "  ✅ Namespace $VM_NAMESPACE already exists"
else
  echo "  Creating namespace $VM_NAMESPACE..."
  if oc create namespace "$VM_NAMESPACE" 2>&1; then
    echo "  ✅ Namespace $VM_NAMESPACE created successfully"
  else
    echo "  ⚠️  Warning: Failed to create namespace $VM_NAMESPACE (may already exist or insufficient permissions)"
  fi
fi

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

# Change to /tmp to avoid permission issues with helm cache
echo "  Changing working directory to /tmp for helm operations..."
cd /tmp || {
  echo "  ❌ Error: Failed to change to /tmp directory"
  exit 1
}

# Set helm cache and config directories to /tmp to avoid permission issues
export HELM_CACHE_HOME="/tmp/.helm/cache"
export HELM_CONFIG_HOME="/tmp/.helm/config"
mkdir -p "$HELM_CACHE_HOME" "$HELM_CONFIG_HOME" 2>/dev/null || true

# Step 2: Get helm template output
echo ""
echo "Step 2: Rendering helm template..."
echo "  Chart URL: $HELM_CHART_URL"
echo "  Values file: $VALUES_FILE (from Helm template)"

# Values file is created by Helm template using .Files.Get
# Check if it exists and set VALUES_ARG accordingly
if [[ -f "$VALUES_FILE" ]]; then
  VALUES_ARG="-f $VALUES_FILE"
  echo "  ✅ Using values file from Helm template: $VALUES_FILE"
else
  echo "  ⚠️  Warning: Values file $VALUES_FILE not found, using default values"
  VALUES_ARG=""
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

# Step 3: Extract VMs, Services, Routes, and ExternalSecrets from helm output
echo ""
echo "Step 3: Extracting VMs, Services, Routes, and ExternalSecrets from helm template..."

# Extract resources using yq or awk
if command -v yq &>/dev/null; then
  # Use yq to extract resources
  yq eval 'select(.kind == "VirtualMachine" or .kind == "Service" or .kind == "Route" or .kind == "ExternalSecret")' \
    -d'*' "$WORK_DIR/helm-output.yaml" > "$WORK_DIR/resources-to-check.yaml" 2>/dev/null || true
else
  # Use awk to extract resources
  awk '
    BEGIN { RS="---\n"; ORS="---\n" }
    /^kind: (VirtualMachine|Service|Route|ExternalSecret)$/ || /^kind: VirtualMachine$/ || /^kind: Service$/ || /^kind: Route$/ || /^kind: ExternalSecret$/ {
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
    /^kind: VirtualMachine$/ || /^kind: Service$/ || /^kind: Route$/ || /^kind: ExternalSecret$/ {
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

# Count resources (remove any newlines/whitespace)
VM_COUNT=$(grep -c "^kind: VirtualMachine" "$WORK_DIR/resources-to-check.yaml" 2>/dev/null | tr -d ' \n' || echo "0")
SERVICE_COUNT=$(grep -c "^kind: Service" "$WORK_DIR/resources-to-check.yaml" 2>/dev/null | tr -d ' \n' || echo "0")
ROUTE_COUNT=$(grep -c "^kind: Route" "$WORK_DIR/resources-to-check.yaml" 2>/dev/null | tr -d ' \n' || echo "0")
EXTERNAL_SECRET_COUNT=$(grep -c "^kind: ExternalSecret" "$WORK_DIR/resources-to-check.yaml" 2>/dev/null | tr -d ' \n' || echo "0")

# Ensure counts are numeric (handle empty results)
VM_COUNT=${VM_COUNT:-0}
SERVICE_COUNT=${SERVICE_COUNT:-0}
ROUTE_COUNT=${ROUTE_COUNT:-0}
EXTERNAL_SECRET_COUNT=${EXTERNAL_SECRET_COUNT:-0}

echo "  Found resources in template:"
echo "    - VirtualMachines: $VM_COUNT"
echo "    - Services: $SERVICE_COUNT"
echo "    - Routes: $ROUTE_COUNT"
echo "    - ExternalSecrets: $EXTERNAL_SECRET_COUNT"

if [[ $VM_COUNT -eq 0 && $SERVICE_COUNT -eq 0 && $ROUTE_COUNT -eq 0 && $EXTERNAL_SECRET_COUNT -eq 0 ]]; then
  echo "  ⚠️  Warning: No VMs, Services, Routes, or ExternalSecrets found in helm template"
  echo "  Note: These resources are optional - will proceed with applying the template anyway"
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
      if (resource ~ /^kind: (VirtualMachine|Service|Route|ExternalSecret)$/ || resource ~ /kind: VirtualMachine/ || resource ~ /kind: Service/ || resource ~ /kind: Route/ || resource ~ /kind: ExternalSecret/) {
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
  
  # Check each resource in the gitops-vms namespace (all resources should be in gitops-vms)
  while IFS='|' read -r kind name namespace; do
    if [[ -z "$kind" || -z "$name" ]]; then
      continue
    fi
    
    # All resources (VMs, Services, Routes) should be in gitops-vms namespace
    check_namespace="$VM_NAMESPACE"
    
    echo "  Checking $kind/$name in namespace: $check_namespace"
    
    if check_resource_exists "" "$kind" "$check_namespace" "$name"; then
      echo "    ✅ $kind/$name exists in namespace $check_namespace"
    else
      echo "    ❌ $kind/$name does not exist in namespace $check_namespace"
      ALL_EXIST=false
      MISSING_RESOURCES+=("$kind/$name in namespace $check_namespace")
    fi
  done < "$WORK_DIR/resources-list.txt"
  
  if [[ ! -s "$WORK_DIR/resources-list.txt" ]]; then
    echo "  ⚠️  Warning: No VMs, Services, Routes, or ExternalSecrets found in helm template"
    echo "  Note: These resources are optional - will proceed with applying the template"
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
  echo "  ✅ VMs, Services, Routes, and ExternalSecrets are already deployed"
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
  
  # Apply the helm template with namespace override to gitops-vms
  echo "  Applying helm template to namespace: $VM_NAMESPACE"
  echo "  Rendering and applying helm template..."
  
  # First, render the helm template and save it to /tmp
  TEMPLATE_OUTPUT_FILE="/tmp/edge-gitops-vms-template.yaml"
  echo "  Rendering helm template to: $TEMPLATE_OUTPUT_FILE"
  
  if ! helm template edge-gitops-vms "$HELM_CHART_URL" $VALUES_ARG --set namespace="$VM_NAMESPACE" > "$TEMPLATE_OUTPUT_FILE" 2>&1; then
    echo "  ❌ Error: Failed to render helm template"
    echo "  Helm template output:"
    cat "$TEMPLATE_OUTPUT_FILE" 2>/dev/null || echo "  (no output captured)"
    exit 1
  fi
  
  # Check if template output is valid
  if [[ ! -s "$TEMPLATE_OUTPUT_FILE" ]]; then
    echo "  ❌ Error: Helm template output is empty"
    exit 1
  fi
  
  # Report what got rendered
  echo "  ✅ Helm template rendered successfully"
  echo "  Template file: $TEMPLATE_OUTPUT_FILE"
  echo "  Template file size: $(wc -c < "$TEMPLATE_OUTPUT_FILE" 2>/dev/null || echo "0") bytes"
  echo ""
  echo "  Resources rendered in template:"
  
  # Count and list resources
  RESOURCE_COUNT=$(grep -c "^kind:" "$TEMPLATE_OUTPUT_FILE" 2>/dev/null || echo "0")
  echo "    Total resources: $RESOURCE_COUNT"
  
  # List resource kinds
  echo "    Resource kinds found:"
  grep "^kind:" "$TEMPLATE_OUTPUT_FILE" 2>/dev/null | sort | uniq -c | sed 's/^/      /' || echo "      (none found)"
  
  # List resources with names and namespaces
  echo "    Resources with names:"
  awk '
    BEGIN { RS="---"; kind=""; name=""; namespace="" }
    /^kind:/ { kind=$2 }
    /^  name:/ && name=="" { name=$2 }
    /^  namespace:/ { namespace=$2 }
    /^---$/ || /^$/ {
      if (kind != "" && name != "") {
        printf "      %s/%s", kind, name
        if (namespace != "") printf " (namespace: %s)", namespace
        printf "\n"
      }
      kind=""; name=""; namespace=""
    }
  ' "$TEMPLATE_OUTPUT_FILE" 2>/dev/null | head -20 || echo "      (could not parse resources)"
  
  if [[ $RESOURCE_COUNT -gt 20 ]]; then
    echo "    ... (showing first 20 resources, total: $RESOURCE_COUNT)"
  fi
  
  echo ""
  echo "  Applying template to namespace: $VM_NAMESPACE..."
  
  # Verify we're using the correct kubeconfig (target cluster)
  if [[ -n "${KUBECONFIG:-}" && -f "$KUBECONFIG" ]]; then
    CURRENT_CLUSTER=$(oc config view --minify -o jsonpath='{.contexts[0].context.cluster}' 2>/dev/null || echo "")
    echo "  Using kubeconfig: $KUBECONFIG"
    echo "  Current cluster context: $CURRENT_CLUSTER"
    echo "  Target cluster: $TARGET_CLUSTER"
  else
    echo "  ⚠️  Warning: KUBECONFIG not set or file not found, using default context"
    echo "  This may apply to the wrong cluster!"
  fi
  
  # Now apply the template and capture both stdout, stderr, and exit code
  # The oc apply will use the KUBECONFIG set earlier (target cluster's kubeconfig)
  # Use temporary files to capture stdout and stderr separately for better debugging
  APPLY_STDOUT_FILE="$WORK_DIR/oc-apply-stdout.log"
  APPLY_STDERR_FILE="$WORK_DIR/oc-apply-stderr.log"
  
  echo "  Executing: oc apply -n $VM_NAMESPACE -f $TEMPLATE_OUTPUT_FILE"
  
  # Capture stdout and stderr separately, then capture exit code
  oc apply -n "$VM_NAMESPACE" -f "$TEMPLATE_OUTPUT_FILE" >"$APPLY_STDOUT_FILE" 2>"$APPLY_STDERR_FILE"
  APPLY_EXIT_CODE=$?
  
  # Read stdout and stderr from files
  APPLY_STDOUT=$(cat "$APPLY_STDOUT_FILE" 2>/dev/null || echo "")
  APPLY_STDERR=$(cat "$APPLY_STDERR_FILE" 2>/dev/null || echo "")
  
  # Combine stdout and stderr for full output
  APPLY_OUTPUT=""
  if [[ -n "$APPLY_STDOUT" ]]; then
    APPLY_OUTPUT="STDOUT:
${APPLY_STDOUT}"
  fi
  if [[ -n "$APPLY_STDERR" ]]; then
    if [[ -n "$APPLY_OUTPUT" ]]; then
      APPLY_OUTPUT="${APPLY_OUTPUT}

STDERR:
${APPLY_STDERR}"
    else
      APPLY_OUTPUT="STDERR:
${APPLY_STDERR}"
    fi
  fi
  
  echo "  oc apply exit code: $APPLY_EXIT_CODE"
  
  if [[ $APPLY_EXIT_CODE -eq 0 ]]; then
    echo "  ✅ Helm template applied successfully to namespace $VM_NAMESPACE"
    echo ""
    if [[ -n "$APPLY_OUTPUT" ]]; then
      echo "  Apply output:"
      echo "$APPLY_OUTPUT" | head -30 | sed 's/^/    /'
      if [[ $(echo "$APPLY_OUTPUT" | wc -l) -gt 30 ]]; then
        echo "    ... (output truncated, showing first 30 lines)"
      fi
    fi
    
    # Verify resources were created
    echo ""
    echo "Step 6: Verifying deployed resources..."
    VERIFY_SUCCESS=true
    
    if [[ -s "$WORK_DIR/resources-list.txt" ]]; then
      while IFS='|' read -r kind name namespace; do
        if [[ -n "$kind" && -n "$name" ]]; then
          # All resources (VMs, Services, Routes) should be in gitops-vms namespace
          check_namespace="$VM_NAMESPACE"
          
          sleep 1  # Give resources a moment to be created
          if check_resource_exists "" "$kind" "$check_namespace" "$name"; then
            echo "  ✅ Verified: $kind/$name exists in namespace $check_namespace"
          else
            echo "  ⚠️  Warning: $kind/$name not found in namespace $check_namespace after apply (may still be creating)"
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
    echo ""
    echo "  ========================================"
    echo "  ERROR DETAILS"
    echo "  ========================================"
    echo "  Exit code: $APPLY_EXIT_CODE"
    echo ""
    if [[ -n "$APPLY_OUTPUT" ]]; then
      echo "  Full output (stdout + stderr):"
      echo "  ----------------------------------------"
      echo "$APPLY_OUTPUT" | sed 's/^/  /'
      echo "  ----------------------------------------"
    fi
    if [[ -n "$APPLY_STDOUT" ]]; then
      echo ""
      echo "  Standard output:"
      echo "  ----------------------------------------"
      echo "$APPLY_STDOUT" | sed 's/^/  /'
      echo "  ----------------------------------------"
    fi
    if [[ -n "$APPLY_STDERR" ]]; then
      echo ""
      echo "  Standard error output:"
      echo "  ----------------------------------------"
      echo "$APPLY_STDERR" | sed 's/^/  /'
      echo "  ----------------------------------------"
    fi
    echo ""
    echo "  ========================================"
    echo "  DEBUGGING INFORMATION"
    echo "  ========================================"
    echo "  - Namespace $VM_NAMESPACE exists: $(oc get namespace "$VM_NAMESPACE" &>/dev/null && echo "yes" || echo "no")"
    if oc get namespace "$VM_NAMESPACE" &>/dev/null; then
      echo "  - Namespace $VM_NAMESPACE status:"
      oc get namespace "$VM_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "    (could not get status)"
    fi
    echo "  - Helm chart URL: $HELM_CHART_URL"
    echo "  - Values file: $VALUES_FILE"
    echo "  - Values file exists: $([ -f "$VALUES_FILE" ] && echo "yes" || echo "no")"
    echo "  - Template file: $TEMPLATE_OUTPUT_FILE"
    echo "  - Template file exists: $([ -f "$TEMPLATE_OUTPUT_FILE" ] && echo "yes" || echo "no")"
    echo "  - Template file size: $(wc -c < "$TEMPLATE_OUTPUT_FILE" 2>/dev/null || echo "0") bytes"
    echo ""
    echo "  ========================================"
    echo "  TEMPLATE FILE PREVIEW (first 100 lines)"
    echo "  ========================================"
    if [[ -f "$TEMPLATE_OUTPUT_FILE" ]]; then
      head -100 "$TEMPLATE_OUTPUT_FILE" | sed 's/^/  /'
      if [[ $(wc -l < "$TEMPLATE_OUTPUT_FILE" 2>/dev/null || echo "0") -gt 100 ]]; then
        echo "  ... (file truncated, showing first 100 lines)"
        echo "  Full template saved at: $TEMPLATE_OUTPUT_FILE"
      fi
    else
      echo "  Template file not found!"
    fi
    echo ""
    echo "  ========================================"
    echo "  PERMISSIONS CHECK"
    echo "  ========================================"
    echo "  - Can create resources in namespace $VM_NAMESPACE:"
    if oc auth can-i create virtualmachines -n "$VM_NAMESPACE" &>/dev/null; then
      echo "    ✅ Yes (VirtualMachines)"
    else
      echo "    ❌ No (VirtualMachines)"
    fi
    if oc auth can-i create services -n "$VM_NAMESPACE" &>/dev/null; then
      echo "    ✅ Yes (Services)"
    else
      echo "    ❌ No (Services)"
    fi
    if oc auth can-i create routes -n "$VM_NAMESPACE" &>/dev/null; then
      echo "    ✅ Yes (Routes)"
    else
      echo "    ❌ No (Routes)"
    fi
    echo ""
    echo "  ========================================"
    echo "  SUGGESTED ACTIONS"
    echo "  ========================================"
    echo "  1. Check the full error output above"
    echo "  2. Inspect the template file: $TEMPLATE_OUTPUT_FILE"
    echo "  3. Verify namespace exists: oc get namespace $VM_NAMESPACE"
    echo "  4. Check permissions: oc auth can-i create virtualmachines -n $VM_NAMESPACE"
    echo "  5. Try applying manually: oc apply -n $VM_NAMESPACE -f $TEMPLATE_OUTPUT_FILE"
    echo ""
    exit 1
  fi
fi

# Cleanup
rm -rf "$WORK_DIR"


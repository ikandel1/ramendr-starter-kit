#!/bin/bash
set -euo pipefail

#
# RamenDR Starter Kit — Full Environment Redeploy Script
#
# Usage:
#   ./redeploy.sh                    # Full redeploy: all clusters in parallel + pattern
#   ./redeploy.sh --destroy-only     # Destroy everything without redeploying
#   ./redeploy.sh --pattern-only     # Skip cluster installs, deploy pattern on existing hub
#   ./redeploy.sh --status           # Check current environment status
#
# All three clusters (hub + ocp-primary + ocp-secondary) are provisioned in
# parallel using openshift-install. The pattern runs in BYOC mode — spoke
# kubeconfigs are provided as secrets and the hub imports the clusters directly
# without going through Hive.
#
# Each cluster needs its own install directory containing install-config.yaml.bak:
#   HUB_INSTALL_DIR      (default: ~/git/hub-cluster-install)
#   PRIMARY_INSTALL_DIR  (default: ~/git/ocp-primary-install)
#   SECONDARY_INSTALL_DIR(default: ~/git/ocp-secondary-install)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
SECONDARY_INSTALL_DIR="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}"
VALUES_SECRET="${VALUES_SECRET:-$HOME/values-secret.yaml}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z01653801KMZNKX9NGW6G}"
BASE_DOMAIN="ecoengverticals-qe.devcluster.openshift.com"
HUB_REGION="eu-north-1"
PRIMARY_REGION="eu-central-1"
SECONDARY_REGION="eu-west-1"
# Target OCP z-stream for hub + spokes (e.g. 4.20.6). Must match overrides/values-cluster-names.yaml.
# Pin the release payload so a 4.21+ openshift-install binary does not install 4.21 bits on the hub/spokes.
HUB_OCP_VERSION="${HUB_OCP_VERSION:-4.20.6}"
HUB_DEFAULT_RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:${HUB_OCP_VERSION}-x86_64"
hub_release_image() { echo "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-$HUB_DEFAULT_RELEASE_IMAGE}"; }

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARNING:${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*"; }

check_prerequisites() {
    log "Checking prerequisites..."
    local missing=0
    for cmd in oc openshift-install aws podman git; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing: $cmd"
            missing=1
        fi
    done
    if oi_vers=$(openshift-install version 2>/dev/null | head -1) && [[ -n "$oi_vers" ]]; then
        if ! echo "$oi_vers" | grep -qE 'openshift-install[[:space:]]+4\.20\.'; then
            warn "Your openshift-install is not 4.20.x: $oi_vers"
            warn "Clusters are still installed using payload $(hub_release_image) (HUB_OCP_VERSION=${HUB_OCP_VERSION}); a 4.20.x client is recommended."
        fi
    fi
    if [[ ! -f "$VALUES_SECRET" ]]; then
        err "Missing secrets file: $VALUES_SECRET"
        missing=1
    fi
    for dir_var in HUB_INSTALL_DIR PRIMARY_INSTALL_DIR SECONDARY_INSTALL_DIR; do
        local dir="${!dir_var}"
        if [[ ! -f "$dir/install-config.yaml.bak" ]]; then
            err "Missing install-config backup: $dir/install-config.yaml.bak"
            missing=1
        fi
    done
    if ! podman machine info &>/dev/null; then
        warn "Podman machine not running. Starting..."
        podman machine start 2>/dev/null || true
    fi
    [[ $missing -eq 1 ]] && { err "Prerequisites not met. Aborting."; exit 1; }
    log "All prerequisites met."
    log "OCP z-stream ${HUB_OCP_VERSION}  Release image: $(hub_release_image)"
}

cleanup_dns() {
    log "Cleaning stale DNS records from Route53..."
    local stale
    stale=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
        --no-paginate --max-items 1000 --output json 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
base = '${BASE_DOMAIN}.'
changes = []
for r in data.get('ResourceRecordSets', []):
    name = r['Name']
    rtype = r['Type']
    if rtype in ('SOA', 'NS'):
        continue
    # Delete A/AAAA/CNAME records for any subdomain (cluster API, ingress, VM services, etc.)
    if rtype in ('A', 'AAAA', 'CNAME') and name != base:
        changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})
    # Delete TXT records created by the External DNS operator
    elif rtype == 'TXT' and name != base and base in name:
        changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})
if changes:
    print(json.dumps({'Comment': 'Cleanup stale records', 'Changes': changes}))
else:
    print('')
" 2>/dev/null)

    if [[ -n "$stale" ]]; then
        echo "$stale" > /tmp/dns-cleanup-batch.json
        local count
        count=$(python3 -c "import json; d=json.load(open('/tmp/dns-cleanup-batch.json')); print(len(d['Changes']))")
        aws route53 change-resource-record-sets \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --change-batch file:///tmp/dns-cleanup-batch.json &>/dev/null
        log "Stale DNS records cleaned ($count records deleted)."
    else
        log "No stale DNS records found."
    fi
}

release_orphaned_eips() {
    log "Releasing orphaned Elastic IPs..."
    # Derive actual regions from metadata.json (the install dir is the ground truth).
    # Fall back to the configured region variables when metadata doesn't exist yet.
    local hub_region primary_region secondary_region
    hub_region=$(python3 -c "import json; print(json.load(open('$HUB_INSTALL_DIR/metadata.json'))['aws']['region'])" 2>/dev/null || echo "$HUB_REGION")
    primary_region=$(python3 -c "import json; print(json.load(open('$PRIMARY_INSTALL_DIR/metadata.json'))['aws']['region'])" 2>/dev/null || echo "$PRIMARY_REGION")
    secondary_region=$(python3 -c "import json; print(json.load(open('$SECONDARY_INSTALL_DIR/metadata.json'))['aws']['region'])" 2>/dev/null || echo "$SECONDARY_REGION")

    # Deduplicate regions (hub and primary may share a region)
    local regions
    regions=$(echo -e "$hub_region\n$primary_region\n$secondary_region" | sort -u)

    for region in $regions; do
        local eips
        eips=$(aws ec2 describe-addresses --region "$region" \
            --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null)
        for eip in $eips; do
            aws ec2 release-address --region "$region" --allocation-id "$eip" 2>/dev/null
            log "  Released EIP $eip in $region"
        done
    done
}

destroy_cluster() {
    local name="$1"
    local dir="$2"
    if [[ -f "$dir/metadata.json" ]]; then
        log "Destroying $name cluster..."
        openshift-install destroy cluster --dir "$dir" --log-level=info 2>&1 \
            || warn "$name destroy had errors (may already be destroyed)"
    else
        warn "No metadata found for $name — skipping (may already be destroyed)."
    fi
}

destroy_managed_clusters() {
    log "Destroying spoke clusters in parallel..."
    destroy_cluster "ocp-primary" "$PRIMARY_INSTALL_DIR" &
    destroy_cluster "ocp-secondary" "$SECONDARY_INSTALL_DIR" &
    wait
    log "Spoke clusters destroyed."
}

destroy_hub() {
    destroy_cluster "hub" "$HUB_INSTALL_DIR"
}

install_one_cluster() {
    local name="$1"
    local dir="$2"
    export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE
    OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(hub_release_image)"
    log "Installing $name cluster (payload: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE})..."
    cd "$dir"
    setopt +o nomatch 2>/dev/null || true
    rm -rf .clusterapi_output .openshift_install.log .openshift_install_state.json \
           auth metadata.json terraform* 2>/dev/null || true
    cp install-config.yaml.bak install-config.yaml
    openshift-install create cluster --dir . --log-level=info 2>&1
    log "$name cluster installed."
}

install_hub() {
    install_one_cluster "hub" "$HUB_INSTALL_DIR"

    log "Hub cluster installed. Setting up kubeconfig..."
    mkdir -p "$HOME/.kube"
    cp "$HUB_INSTALL_DIR/auth/kubeconfig" "$HOME/.kube/config"
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

    log "Hub console: https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
    grep -o 'password: "[^"]*"' "$HUB_INSTALL_DIR/.openshift_install.log" | tail -1 || true
}

install_spokes() {
    log "Installing ocp-primary and ocp-secondary in parallel..."
    install_one_cluster "ocp-primary" "$PRIMARY_INSTALL_DIR" &
    install_one_cluster "ocp-secondary" "$SECONDARY_INSTALL_DIR" &
    wait
    log "Both spoke clusters installed."
}

# ─── Spoke post-install: c5n.metal MachineSet for ODF + KVM ──────────────────
# ─── Spoke: c5n.metal MachineSet ─────────────────────────────────────────────
#
# OCP install-config does not allow two compute pools with the same name, so the
# c5n.metal bare-metal node (needed for ODF quorum + /dev/kvm) cannot be declared
# in install-config.yaml.bak alongside the m8i.4xlarge workers. Instead it is
# added post-install via a MachineSet cloned from the first existing worker
# MachineSet (inheriting correct subnet/AMI/SG) with only the instance type and
# root disk overridden.

create_spoke_metal_machinesets() {
    log "Creating c5n.metal MachineSets on spoke clusters (300 GiB root disk)..."
    for entry in "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
        local cluster="${entry%%:*}"
        local dir="${entry##*:}"
        local kubeconfig="$dir/auth/kubeconfig"
        [[ -f "$kubeconfig" ]] || { warn "  No kubeconfig for $cluster — skipping metal MachineSet."; continue; }

        local infra_id
        infra_id=$(python3 -c "import json; print(json.load(open('$dir/metadata.json'))['infraID'])")

        local template_name
        template_name=$(KUBECONFIG="$kubeconfig" oc get machineset -n openshift-machine-api \
            --no-headers -o custom-columns=':.metadata.name' 2>/dev/null | sort | head -1)
        [[ -n "$template_name" ]] || { warn "  No MachineSet template found for $cluster — skipping."; continue; }

        local metal_name="${infra_id}-metal"
        log "  Cloning $template_name → $metal_name (c5n.metal, 300 GiB) on $cluster..."

        KUBECONFIG="$kubeconfig" oc get machineset "$template_name" \
                -n openshift-machine-api -o json 2>/dev/null | \
        python3 -c "
import sys, json, copy
ms = json.load(sys.stdin)
new_name = '${metal_name}'
n = copy.deepcopy(ms)
for k in ('resourceVersion','uid','generation','creationTimestamp','managedFields','annotations'):
    n['metadata'].pop(k, None)
n['metadata']['name'] = new_name
n.pop('status', None)
n['spec']['replicas'] = 1
n['spec']['selector']['matchLabels']['machine.openshift.io/cluster-api-machineset'] = new_name
n['spec']['template']['metadata']['labels']['machine.openshift.io/cluster-api-machineset'] = new_name
pv = n['spec']['template']['spec']['providerSpec']['value']
pv['instanceType'] = 'c5n.metal'
bdm = pv.get('blockDeviceMappings', [])
root_dev = bdm[0].get('deviceName', '/dev/xvda') if bdm else '/dev/xvda'
pv['blockDeviceMappings'] = [{'deviceName': root_dev, 'ebs': {
    'encrypted': True, 'kmsKey': {}, 'volumeSize': 300, 'volumeType': 'gp3'}}]
print(json.dumps(n))
" | KUBECONFIG="$kubeconfig" oc apply -f - 2>/dev/null && \
        log "  MachineSet $metal_name created on $cluster." || \
        warn "  MachineSet $metal_name may already exist on $cluster (apply failed — continuing)."
    done
}

# Wait for c5n.metal nodes to join the spoke clusters, then label all workers
# (m8i.4xlarge × 2 + c5n.metal × 1 = 3-node ODF quorum) for ODF storage.
wait_for_spoke_metal_nodes() {
    log "Waiting for c5n.metal nodes on spoke clusters and labeling workers for ODF..."
    for entry in "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
        local cluster="${entry%%:*}"
        local dir="${entry##*:}"
        local kubeconfig="$dir/auth/kubeconfig"
        [[ -f "$kubeconfig" ]] || continue

        log "  Waiting for c5n.metal node on $cluster (up to 30 min)..."
        local tries=0
        while [[ $tries -lt 60 ]]; do
            local ready
            ready=$(KUBECONFIG="$kubeconfig" oc get nodes \
                -l node.kubernetes.io/instance-type=c5n.metal \
                --no-headers 2>/dev/null | grep -c " Ready " || true)
            [[ "$ready" -ge 1 ]] && { log "  c5n.metal node is Ready on $cluster."; break; }
            sleep 30
            tries=$((tries + 1))
        done
        [[ $tries -ge 60 ]] && \
            warn "  Timeout waiting for c5n.metal node on $cluster — ODF may need manual intervention."

        log "  Labeling worker nodes for ODF storage on $cluster..."
        while IFS= read -r node; do
            KUBECONFIG="$kubeconfig" oc label "$node" \
                cluster.ocs.openshift.io/openshift-storage="" --overwrite 2>/dev/null || true
        done < <(KUBECONFIG="$kubeconfig" oc get nodes \
            -l node-role.kubernetes.io/worker -o name 2>/dev/null)
        log "  All workers labeled for ODF on $cluster."
    done
}

# ─── Spoke: kubeconfigs in Vault ──────────────────────────────────────────────
#
# The regionaldr chart's ExternalSecret template looks for:
#   secret/hub/ocp-primary_cluster_kubeconfig   (underscore, not hyphen)
#   secret/hub/ocp-secondary_cluster_kubeconfig
#
# Spoke clusters use self-signed certificates; the odf-ssl-certificate-extractor
# Ansible job fails with SSLCertVerificationError unless we strip
# certificate-authority-data and set insecure-skip-tls-verify: true.
# Storing the insecure version here fixes both the path and the TLS issue.

store_spoke_kubeconfigs_in_vault() {
    log "[vault-kc] Storing spoke kubeconfigs in Vault (insecure-skip-tls-verify for self-signed certs)..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

    # Stage 1: wait for the vault-0 pod to be Running (up to 10 min).
    local tries=0
    log "[vault-kc] Waiting for vault-0 pod to be Running..."
    until oc get pod vault-0 -n vault --no-headers 2>/dev/null | grep -q " Running "; do
        [[ $tries -ge 40 ]] && { warn "[vault-kc] vault-0 pod not Running after 10 min — skipping kubeconfig storage."; return 1; }
        sleep 15
        tries=$((tries + 1))
    done

    # Stage 2: wait for Vault to be initialised and unsealed (up to 20 min).
    tries=0
    log "[vault-kc] Waiting for Vault to be initialized and unsealed..."
    until oc exec -n vault vault-0 -- vault status 2>/dev/null | grep -q "Initialized.*true" && \
          oc exec -n vault vault-0 -- vault status 2>/dev/null | grep -q "Sealed.*false"; do
        [[ $tries -ge 80 ]] && { warn "[vault-kc] Vault not ready after 20 min — skipping kubeconfig storage."; return 1; }
        sleep 15
        tries=$((tries + 1))
    done
    log "[vault-kc] Vault is ready."

    for entry in "ocp-primary:$PRIMARY_INSTALL_DIR" "ocp-secondary:$SECONDARY_INSTALL_DIR"; do
        local cluster="${entry%%:*}"
        local dir="${entry##*:}"
        local kc_file="$dir/auth/kubeconfig"
        [[ -f "$kc_file" ]] || { warn "  No kubeconfig at $kc_file — skipping."; continue; }

        # Strip certificate-authority-data and add insecure-skip-tls-verify.
        local tmp_kc
        tmp_kc=$(mktemp)
        python3 -c "
import sys
kc_file = '$kc_file'
try:
    import yaml
    with open(kc_file) as f:
        kc = yaml.safe_load(f)
    for c in kc.get('clusters', []):
        ci = c.get('cluster', {})
        ci.pop('certificate-authority-data', None)
        ci['insecure-skip-tls-verify'] = True
    sys.stdout.write(yaml.dump(kc, default_flow_style=False))
except ImportError:
    import re
    with open(kc_file) as f:
        content = f.read()
    content = re.sub(r'\n    certificate-authority-data: [^\n]+', '', content)
    content = re.sub(r'(    server: [^\n]+)', r'\1\n    insecure-skip-tls-verify: true', content)
    sys.stdout.write(content)
" > "$tmp_kc"

        # Retry the write up to 5 times — oc cp can fail transiently if the
        # vault-0 pod restarts during initialization.
        local vault_path="secret/hub/${cluster}_cluster_kubeconfig"
        local write_tries=0
        local stored=false
        while [[ $write_tries -lt 5 ]]; do
            if oc cp "$tmp_kc" "vault/vault-0:/tmp/${cluster}-kubeconfig.yaml" 2>/dev/null && \
               oc exec -n vault vault-0 -- \
                   vault kv put "$vault_path" "kubeconfig=@/tmp/${cluster}-kubeconfig.yaml" 2>/dev/null; then
                oc exec -n vault vault-0 -- rm -f "/tmp/${cluster}-kubeconfig.yaml" 2>/dev/null || true
                log "[vault-kc] Stored insecure kubeconfig for $cluster at $vault_path."
                stored=true
                break
            fi
            write_tries=$((write_tries + 1))
            warn "[vault-kc] Write attempt $write_tries/5 failed for $cluster — retrying in 15s..."
            sleep 15
        done
        [[ "$stored" == "false" ]] && warn "[vault-kc] Failed to store kubeconfig for $cluster in Vault after 5 attempts."
        rm -f "$tmp_kc"
    done
}

scale_hub_workers() {
    log "Scaling hub workers to 6 (required for ODF)..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
    for ms in $(oc get machinesets.machine.openshift.io -n openshift-machine-api -o name 2>/dev/null); do
        oc scale "$ms" --replicas=2 -n openshift-machine-api 2>/dev/null
    done

    log "Waiting for workers to be Ready..."
    local tries=0
    while [[ $tries -lt 30 ]]; do
        local ready
        ready=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c " Ready " || true)
        if [[ "$ready" -ge 5 ]]; then
            log "  $ready workers Ready."
            break
        fi
        log "  $ready/6 workers Ready, waiting..."
        sleep 30
        tries=$((tries + 1))
    done

    log "Labeling workers for ODF storage..."
    for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null); do
        oc label "$node" cluster.ocs.openshift.io/openshift-storage="" --overwrite 2>/dev/null
    done
}

deploy_pattern() {
    log "Deploying RamenDR pattern (BYOC mode)..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
    cd "$SCRIPT_DIR"

    # Start storing spoke kubeconfigs in Vault as a background job that runs
    # concurrently with the pattern install.  The function has its own wait loops
    # for Vault readiness (pod Running → initialized → unsealed), so it will write
    # the kubeconfigs as soon as Vault is ready — typically 5-10 min into the
    # pattern install, well before ArgoCD syncs regional-dr and the ExternalSecrets
    # make their first pull.  Running it here (rather than after pattern.sh returns)
    # is the key fix: pattern.sh blocks for ~20 min on its Ansible wait loop, and
    # without this the kubeconfigs would not be in Vault until after regional-dr has
    # already cached a SecretSyncedError.
    store_spoke_kubeconfigs_in_vault &
    local store_pid=$!

    log "Running pattern install (this takes ~20 minutes for operators to settle)..."
    VALUES_SECRET="$VALUES_SECRET" ./pattern.sh make install 2>&1 || warn "Pattern install exited with warnings (expected during first sync)"

    # Wait for the background store job.  It should be long done by now, but block
    # just in case Vault took unusually long to initialise.
    if ! wait "$store_pid"; then
        warn "store_spoke_kubeconfigs_in_vault background job failed — retrying synchronously..."
        store_spoke_kubeconfigs_in_vault
    fi

    # Force-refresh all kubeconfig ExternalSecrets so that any cached failure is
    # cleared immediately, without waiting for the 24 h refresh interval.
    log "Force-refreshing kubeconfig ExternalSecrets..."
    for cluster in ocp-primary ocp-secondary; do
        oc annotate externalsecret -n "$cluster" --all \
            force-sync="$(date +%s)" --overwrite 2>/dev/null || true
    done

    log "Fixing Vault privatekey secret..."
    local privkey pubkey
    privkey=$(oc exec -n vault vault-0 -- vault kv get -field=ssh-privatekey secret/hub/aws 2>/dev/null) || true
    pubkey=$(oc exec -n vault vault-0 -- vault kv get -field=ssh-publickey secret/hub/aws 2>/dev/null) || true
    if [[ -n "$privkey" ]]; then
        oc exec -n vault vault-0 -- vault kv put secret/hub/privatekey \
            ssh-privatekey="$privkey" ssh-publickey="$pubkey" 2>/dev/null
        log "  Vault secret/hub/privatekey created."
    fi
}

wait_for_convergence() {
    log "Waiting for full environment convergence..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

    log "Monitoring ArgoCD applications..."
    local tries=0
    while [[ $tries -lt 120 ]]; do
        local unhealthy
        unhealthy=$(oc get applications.argoproj.io -n ramendr-starter-kit-hub \
            -o custom-columns=':.status.sync.status,:.status.health.status' --no-headers 2>/dev/null \
            | grep -v "Synced.*Healthy" | grep -v "Synced.*Progressing" | wc -l | tr -d ' ')

        if [[ "$unhealthy" -eq 0 ]]; then
            log "All ArgoCD applications are Synced/Healthy!"
            break
        fi

        log "  $unhealthy apps still converging (attempt $tries/120)..."
        sleep 60
        tries=$((tries + 1))

        # Re-sync stuck apps periodically
        if [[ $((tries % 10)) -eq 0 ]]; then
            for app in regional-dr opp-policy; do
                oc patch applications.argoproj.io "$app" -n ramendr-starter-kit-hub --type merge \
                    -p '{"operation":{"initiatedBy":{"automated":true},"sync":{}}}' 2>/dev/null || true
            done
        fi
    done
}

show_status() {
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
    echo ""
    echo "============================================"
    echo "  RamenDR Starter Kit — Environment Status"
    echo "============================================"
    echo ""
    echo "--- Clusters ---"
    oc get managedclusters 2>&1 || echo "Cannot reach hub cluster"
    echo ""
    echo "--- ClusterDeployments ---"
    oc get clusterdeployments -A 2>&1
    echo ""
    echo "--- ArgoCD Applications ---"
    oc get applications.argoproj.io -n ramendr-starter-kit-hub \
        -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>&1
    echo ""
    echo "--- DR Status ---"
    oc get drpolicy 2>&1
    oc get drplacementcontrol -A 2>&1
    echo ""
    echo "--- VMs (on primary) ---"
    local primary_kc
    primary_kc=$(oc get secret -n ocp-primary -o name 2>/dev/null | grep admin-kubeconfig | head -1)
    if [[ -n "$primary_kc" ]]; then
        oc get vm -A --kubeconfig <(oc get "$primary_kc" -n ocp-primary -o jsonpath='{.data.kubeconfig}' | base64 -d) 2>&1
    else
        echo "Primary cluster kubeconfig not found"
    fi
    echo ""
    echo "--- Access ---"
    echo "Hub Console:  https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
    echo "ArgoCD:       $(oc get route hub-gitops-server -n ramendr-starter-kit-hub -o jsonpath='https://{.spec.host}' 2>/dev/null)"
    echo "KUBECONFIG:   $HUB_INSTALL_DIR/auth/kubeconfig"
    echo ""
}

full_redeploy() {
    check_prerequisites
    cleanup_dns
    release_orphaned_eips

    # Destroy all clusters (spokes in parallel, hub after)
    destroy_managed_clusters
    destroy_hub
    cleanup_dns

    # Install all three clusters in parallel, then wait for all to complete
    log "Starting parallel install of hub + ocp-primary + ocp-secondary..."
    install_hub &
    install_spokes &
    wait
    log "All three clusters installed."

    # Create c5n.metal MachineSets immediately so AWS starts provisioning the
    # bare-metal nodes while we spend the next ~15 min scaling hub workers.
    create_spoke_metal_machinesets

    scale_hub_workers

    # By the time hub workers are done, the c5n.metal nodes have been
    # provisioning for 15+ min. Wait for them to join and label for ODF.
    wait_for_spoke_metal_nodes

    deploy_pattern
    wait_for_convergence
    show_status
    log "Full redeploy complete!"
}

case "${1:-}" in
    --destroy-only)
        check_prerequisites
        destroy_managed_clusters
        destroy_hub
        cleanup_dns
        release_orphaned_eips
        log "Environment destroyed."
        ;;
    --pattern-only)
        check_prerequisites
        create_spoke_metal_machinesets
        scale_hub_workers
        wait_for_spoke_metal_nodes
        deploy_pattern
        wait_for_convergence
        show_status
        ;;
    --status)
        show_status
        ;;
    --help|-h)
        echo "Usage: ./redeploy.sh [--destroy-only|--pattern-only|--status|--help]"
        echo ""
        echo "  (no args)        Full redeploy: destroy + install all 3 clusters in parallel + deploy pattern"
        echo "  --destroy-only   Destroy all clusters and clean up AWS resources"
        echo "  --pattern-only   Deploy pattern on an existing hub cluster"
        echo "  --status         Show current environment status"
        echo ""
        echo "Environment variables:"
        echo "  HUB_INSTALL_DIR       Hub cluster install directory (default: ~/git/hub-cluster-install)"
        echo "  PRIMARY_INSTALL_DIR   Primary spoke install directory (default: ~/git/ocp-primary-install)"
        echo "  SECONDARY_INSTALL_DIR Secondary spoke install directory (default: ~/git/ocp-secondary-install)"
        echo "  VALUES_SECRET         Path to values-secret.yaml (default: ~/values-secret.yaml)"
        echo "  HUB_OCP_VERSION       OCP z-stream for all clusters; match values-cluster-names (default: 4.20.6)"
        echo "  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE  Optional; defaults to the 4.20.6 public payload for HUB_OCP_VERSION"
        echo "  HOSTED_ZONE_ID        Route53 hosted zone ID (default: Z01653801KMZNKX9NGW6G)"
        ;;
    *)
        full_redeploy
        ;;
esac

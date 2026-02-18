# RamenDR Starter Kit — Deployment Guide

This guide documents the full step-by-step deployment of the RamenDR Starter Kit pattern for regional disaster recovery of OpenShift virtual machine workloads on AWS.

**Official documentation:**
- [Getting Started](https://validatedpatterns.io/patterns/ramendr-starter-kit/getting-started/)
- [Installation Details](https://validatedpatterns.io/patterns/ramendr-starter-kit/installation-details/)
- [Cluster Sizing](https://validatedpatterns.io/patterns/ramendr-starter-kit/cluster-sizing/)

---

## Architecture Overview

The pattern deploys **3 OpenShift clusters** on AWS:

| Cluster | Role | AWS Region | Purpose |
|---|---|---|---|
| **hub** | Management | `eu-north-1` | Runs ACM, ArgoCD, Vault, ODF Multicluster Orchestrator |
| **ocp-primary** | Managed | `eu-north-1` | Runs VMs, ODF storage, primary DR site |
| **ocp-secondary** | Managed | `eu-west-1` | Runs ODF storage, secondary DR site (failover target) |

Key components installed by the pattern:
- **Red Hat ACM** — multi-cluster management, provisions managed clusters via Hive
- **OpenShift Data Foundations (ODF)** — Ceph storage with cross-cluster replication
- **ODF Multicluster Orchestrator** — manages DR policies across clusters
- **OpenShift Virtualization (KubeVirt)** — runs VMs on managed clusters
- **Submariner** — VPN connectivity between managed clusters
- **HashiCorp Vault** — secrets management
- **External Secrets Operator** — syncs secrets from Vault to Kubernetes
- **Red Hat OpenShift GitOps (ArgoCD)** — GitOps-based deployment

---

## Prerequisites

### 1. Tools (install on your Mac)

| Tool | Install Command | Verification |
|---|---|---|
| `oc` (OpenShift CLI) | `brew install openshift-cli` | `oc version --client` |
| `podman` | `brew install podman` | `podman --version` (>= 4.3.0) |
| `git` | `brew install git` | `git --version` |
| `make` | Xcode CLI tools: `xcode-select --install` | `make --version` |
| `aws` (AWS CLI v2) | `brew install awscli` | `aws --version` |
| `openshift-install` | See Step 3 below | `openshift-install version` |

> **Note:** `helm` and `ansible-playbook` are **not** required locally — they run inside the pattern's utility container via `./pattern.sh`.

### 2. Accounts and Credentials

You will need:

| Item | Where to Get It |
|---|---|
| **AWS Access Key ID + Secret** | AWS IAM Console → Users → Security Credentials → Create Access Key |
| **OpenShift Pull Secret** | [Red Hat Console](https://console.redhat.com/openshift/install/pull-secret) — download as JSON |
| **SSH Key Pair** | Generate with `ssh-keygen -t ed25519 -C "your-email"` |
| **GitHub Account** | Any account with repo read/write access |
| **DNS Base Domain** | A Route 53 hosted zone (e.g., `example.devcluster.openshift.com`) |

### 3. Install `openshift-install` CLI

Download the **amd64 (x86_64)** version even on Apple Silicon Macs — the clusters run x86 instances:

```bash
# Download amd64 version for OCP 4.18
curl -L -o /tmp/openshift-install.tar.gz \
  "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.18/openshift-install-mac-amd64.tar.gz"

mkdir -p ~/.local/bin
tar xzf /tmp/openshift-install.tar.gz -C ~/.local/bin openshift-install
chmod +x ~/.local/bin/openshift-install
export PATH="$HOME/.local/bin:$PATH"

# Verify
openshift-install version
```

> **Important:** Do NOT use the ARM64 installer — it will try to provision ARM instances, but the pattern uses `m5` (x86) instance types.

### 4. Configure AWS Credentials

```bash
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name: eu-north-1
# Default output format: json
```

This creates `~/.aws/credentials` which the pattern reads for provisioning managed clusters.

---

## Step-by-Step Deployment

### Step 1: Provision the Hub Cluster

Create an install directory and configuration:

```bash
mkdir -p ~/git/hub-cluster-install
cat > ~/git/hub-cluster-install/install-config.yaml << 'EOF'
apiVersion: v1
baseDomain: <YOUR_BASE_DOMAIN>
metadata:
  name: hub
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m5.4xlarge
compute:
  - name: worker
    replicas: 3
    platform:
      aws:
        type: m5.2xlarge
networking:
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.0.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.30.0.0/16
platform:
  aws:
    region: eu-north-1
    userTags:
      project: ValidatedPatterns
publish: External
sshKey: "<YOUR_SSH_PUBLIC_KEY>"
pullSecret: '<YOUR_PULL_SECRET_JSON>'
EOF
```

> **Tip:** Back up the install-config before running the installer — it gets consumed:
> ```bash
> cp ~/git/hub-cluster-install/install-config.yaml ~/git/hub-cluster-install/install-config.yaml.bak
> ```

Run the installer (takes ~40-60 minutes):

```bash
export PATH="$HOME/.local/bin:$PATH"
openshift-install create cluster --dir=~/git/hub-cluster-install --log-level=info
```

When complete, you'll see:
```
Install complete!
export KUBECONFIG=~/git/hub-cluster-install/auth/kubeconfig
Access the OpenShift web-console here: https://console-openshift-console.apps.hub.<domain>
Login to the console with user: "kubeadmin", and password: "<password>"
```

**Save these credentials!** Copy the kubeconfig to the standard location:

```bash
mkdir -p ~/.kube
cp ~/git/hub-cluster-install/auth/kubeconfig ~/.kube/config
chmod 600 ~/.kube/config
```

### Step 2: Fork and Clone the Repository

1. Go to [https://github.com/validatedpatterns/ramendr-starter-kit/fork](https://github.com/validatedpatterns/ramendr-starter-kit/fork)
2. Fork to your GitHub account
3. Clone your fork:

```bash
git clone https://github.com/<YOUR_GITHUB_USER>/ramendr-starter-kit.git
cd ramendr-starter-kit
```

4. Add the upstream remote:

```bash
git remote add -f upstream https://github.com/validatedpatterns/ramendr-starter-kit.git
```

5. Verify remotes:

```bash
git remote -v
# origin    https://github.com/<YOUR_GITHUB_USER>/ramendr-starter-kit.git (fetch)
# origin    https://github.com/<YOUR_GITHUB_USER>/ramendr-starter-kit.git (push)
# upstream  https://github.com/validatedpatterns/ramendr-starter-kit.git (fetch)
# upstream  https://github.com/validatedpatterns/ramendr-starter-kit.git (push)
```

### Step 3: Customize AWS Regions

Edit `charts/hub/rdr/values.yaml` and update the `region` fields for your primary and secondary clusters:

```yaml
# Primary cluster (line ~41)
platform:
  aws:
    region: eu-north-1    # <-- Change to your primary region

# Secondary cluster (line ~79)
platform:
  aws:
    region: eu-west-1     # <-- Change to your secondary region (must be different!)
```

> **Important:** The two managed clusters MUST be in different AWS regions for regional DR to work.

### Step 4: Create the Secrets File

Copy the template to your **home directory** (outside the repo — never commit secrets!):

```bash
cp values-secret.yaml.template ~/values-secret.yaml
```

Edit `~/values-secret.yaml` with your real credentials:

```yaml
---
version: "2.0"
secrets:
  - name: vm-ssh
    vaultPrefixes:
    - global
    fields:
    - name: username
      value: 'cloud-user'
    - name: privatekey
      path: '~/.ssh/id_ed25519'          # Path to your private key
    - name: publickey
      path: '~/.ssh/id_ed25519.pub'      # Path to your public key

  - name: cloud-init
    vaultPrefixes:
    - global
    fields:
    - name: userData
      value: |-
        #cloud-config
        user: 'cloud-user'
        password: 'your-password-here'
        chpasswd: { expire: False }

  - name: aws
    fields:
      - name: aws_access_key_id
        ini_file: ~/.aws/credentials
        ini_key: aws_access_key_id
      - name: aws_secret_access_key
        ini_file: ~/.aws/credentials
        ini_key: aws_secret_access_key
      - name: baseDomain
        value: "your-base-domain.example.com"
      - name: pullSecret
        path: ~/pull_secret.json          # Or use value: '<json>'
      - name: ssh-privatekey
        path: ~/.ssh/id_ed25519
      - name: ssh-publickey
        path: ~/.ssh/id_ed25519.pub

  - name: openshiftPullSecret
    fields:
      - name: .dockerconfigjson
        path: ~/pull_secret.json          # Or use value: '<json>'
```

> **Tip:** You can use either `path:` (points to a file) or `value:` (inline content) for each field. Using `path:` is cleaner for large values like pull secrets and SSH keys.

### Step 5: Commit and Push

```bash
git add charts/hub/rdr/values.yaml
git commit -m "Update AWS regions for our deployment"
git push origin main
```

### Step 6: Start Podman Machine

The pattern runs inside a utility container. Make sure Podman is running:

```bash
podman machine list
podman machine start    # Start if not running
```

### Step 7: Deploy the Pattern

```bash
export KUBECONFIG=~/.kube/config
VALUES_SECRET=~/values-secret.yaml ./pattern.sh make install
```

> **Critical:** Always pass `VALUES_SECRET=~/values-secret.yaml` to ensure the installer uses your real secrets, not the template file in the repo.

This will:
1. Install the Validated Patterns Operator
2. Install OpenShift GitOps (ArgoCD)
3. Install HashiCorp Vault and load your secrets
4. Install ACM, ODF, and ODF Multicluster Orchestrator
5. Create ArgoCD applications for all components

### Step 8: Wait for Deployment (~2-3 hours total)

The pattern deploys in stages. Monitor progress via:

**ArgoCD UI:**
```
URL:  https://hub-gitops-server-ramendr-starter-kit-hub.apps.hub.<your-domain>
User: admin
Pass: <retrieve with command below>
```

```bash
oc get secret hub-gitops-cluster -n ramendr-starter-kit-hub \
  -o jsonpath='{.data.admin\.password}' | base64 -d
```

**Check application status:**
```bash
oc get pattern ramendr-starter-kit -n openshift-operators \
  -o jsonpath='{range .status.applications[*]}{.name}{"\t"}{.syncStatus}{"\t"}{.healthStatus}{"\n"}{end}'
```

**Check managed clusters:**
```bash
oc get managedclusters
oc get clusterdeployments -A
```

Expected deployment timeline:
| Phase | Duration | What Happens |
|---|---|---|
| 1. Operators install on hub | ~15 min | ACM, ODF, GitOps, Vault |
| 2. Managed clusters provisioned | ~45-60 min | Hive creates ocp-primary and ocp-secondary |
| 3. Operators install on managed clusters | ~30-45 min | ODF, KubeVirt, Submariner |
| 4. Storage + DR configured | ~15-20 min | ODF mirroring, DRPolicy |
| 5. VMs deployed | ~10-15 min | 4 RHEL9 VMs on primary |

### Step 9: Verify the Deployment

1. **All ArgoCD apps should be Synced/Healthy** (except `opp-policy` may show OutOfSync — this is a [known issue](https://github.com/validatedpatterns/ramendr-starter-kit/issues))

2. **Managed clusters joined:**
   ```bash
   oc get managedclusters
   # NAME            JOINED   AVAILABLE
   # local-cluster   True     True
   # ocp-primary     True     True
   # ocp-secondary   True     True
   ```

3. **VMs running on primary cluster** — check via Hub Console:
   `All Clusters → Virtualization → VirtualMachines`

4. **DR protection active** — check via Hub Console:
   `All Clusters → Data Services → Disaster Recovery → Protected Applications`
   Both "Kubernetes objects" and "Application volumes" should show Healthy.

---

## Day-2 Operations

### Pulling Upstream Updates

When the upstream pattern is updated:

```bash
cd ~/git/ramendr-starter-kit
git fetch upstream
git merge upstream/main
# Resolve any conflicts (typically only in charts/hub/rdr/values.yaml regions)
git push origin main
```

ArgoCD will automatically pick up the changes.

### Reloading Secrets

If you need to update credentials (e.g., rotated AWS keys):

```bash
# Edit ~/values-secret.yaml with new values, then:
VALUES_SECRET=~/values-secret.yaml ./pattern.sh make load-secrets
```

### Testing Failover

1. Go to Hub Console → `All Clusters → Data Services → Disaster Recovery → Protected Applications`
2. Click **Failover**
3. Confirm the target cluster and click **Initiate**
4. After failover completes, run the cleanup script:
   ```bash
   export KUBECONFIG=~/.kube/config
   ./pattern.sh scripts/cleanup-gitops-vms-non-primary.sh
   ```
5. Wait a few minutes for resources to show healthy and protected again.

### Destroying the Deployment

To tear down everything:

```bash
# Delete managed clusters first (via ACM or ArgoCD)
# Then destroy the hub cluster:
export PATH="$HOME/.local/bin:$PATH"
openshift-install destroy cluster --dir=~/git/hub-cluster-install --log-level=info
```

---

## Troubleshooting

| Issue | Solution |
|---|---|
| `./pattern.sh` fails with "Cannot connect to Podman" | Run `podman machine start` |
| Install uses template instead of real secrets | Always pass `VALUES_SECRET=~/values-secret.yaml` |
| Pattern points to wrong git repo | `oc patch pattern ramendr-starter-kit -n openshift-operators --type merge -p '{"spec":{"gitSpec":{"targetRepo":"https://github.com/<USER>/ramendr-starter-kit.git"}}}'` |
| `openshift-install` fails with architecture mismatch | Download the **amd64** version of the installer (not ARM64) |
| Vault secrets not loading (retrying) | Check vault pod: `oc get pods -n vault`, check status: `oc exec -n vault vault-0 -- vault status` |
| Managed clusters not provisioning | Check ACM is healthy: `oc get csv -n open-cluster-management`, check Hive: `oc get clusterdeployments -A` |
| Managed cluster provision fails with `AddressLimitExceeded` | Increase EIP quota: `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-0263D0A3 --desired-value 15 --region <REGION>` |
| Hub ODF pods stuck Pending (`Insufficient cpu`) | Scale hub worker MachineSets: `oc scale machineset <name> -n openshift-machine-api --replicas=2` for each AZ |
| New hub workers missing ODF label | Label nodes: `oc label node <NODE> cluster.ocs.openshift.io/openshift-storage=""` |
| ExternalSecrets can't find `secret/hub/privatekey` | Create it in Vault: `oc exec -n vault vault-0 -- vault kv put secret/hub/privatekey privatekey="$(cat ~/.ssh/id_ed25519)"` |
| `regional-dr` stuck on prerequisites checker | Manually create the Job if ArgoCD sync is deadlocked: `oc apply -f` the Job manifest from `charts/hub/rdr/templates/job-odf-dr-prerequisites.yaml` |
| Managed cluster shows `ProvisionStopped` but is actually running | If the cluster API is reachable, patch the CD: `oc patch clusterdeployment <name> -n <ns> --type merge -p '{"spec":{"installed":true,"clusterMetadata":{...}}}'` |

### AWS EIP Quota Planning

Each OpenShift cluster uses **3 Elastic IPs** (one per availability zone for NAT gateways). The default AWS limit is **5 EIPs per region**. Plan accordingly:

| Region | Clusters | EIPs Needed | Recommended Quota |
|---|---|---|---|
| `eu-north-1` | hub + ocp-primary | 6 | 15 |
| `eu-west-1` | ocp-secondary | 3 | 10 |

Request increases **before** deploying:
```bash
aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-0263D0A3 \
  --desired-value 15 --region eu-north-1

aws service-quotas request-service-quota-increase \
  --service-code ec2 --quota-code L-0263D0A3 \
  --desired-value 10 --region eu-west-1
```

### Hub Cluster Sizing Note

The hub cluster runs ACM, ODF Multicluster Orchestrator, Vault, ArgoCD, and Hive. The default 3 workers (`m5.2xlarge`) may not have enough CPU for ODF pods. **Recommendation:** Scale to 6 workers (2 per AZ) before running `./pattern.sh make install`, or monitor and scale if pods are stuck Pending:

```bash
# Scale each worker MachineSet to 2 replicas
for ms in $(oc get machineset -n openshift-machine-api -o name | grep worker); do
  oc scale $ms -n openshift-machine-api --replicas=2
done

# Wait for new nodes, then label them for ODF
for node in $(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o name | tail -3); do
  oc label $node cluster.ocs.openshift.io/openshift-storage=""
done
```

---

## Reference: Our Deployment Details

### Cluster Inventory

#### Hub Cluster

| Item | Value |
|---|---|
| **Cluster Name** | `hub` |
| **OCP Version** | 4.18.32 |
| **AWS Region** | `eu-north-1` (Stockholm) |
| **Cluster ID** | `5df8d356-4d0e-4455-a1eb-81cc9225d05b` |
| **API** | `https://api.hub.ecoengverticals-qe.devcluster.openshift.com:6443` |
| **Console** | `https://console-openshift-console.apps.hub.ecoengverticals-qe.devcluster.openshift.com` |
| **Login** | `kubeadmin` / `KHRWV-2QLNR-gRWfb-WNShV` |
| **KUBECONFIG** | `~/git/hub-cluster-install/auth/kubeconfig` (also `~/.kube/config`) |
| **Install Dir** | `~/git/hub-cluster-install/` |
| **Nodes** | 3 masters (`m5.4xlarge`) + 6 workers (`m5.2xlarge`) |

#### ocp-primary (Managed)

| Item | Value |
|---|---|
| **Cluster Name** | `ocp-primary` |
| **OCP Version** | 4.18.7 |
| **AWS Region** | `eu-north-1` (Stockholm) |
| **InfraID** | `ocp-primary-d85dm` |
| **Cluster ID** | `1099b67e-462c-40ce-a9eb-59eaca6f9d74` |
| **API** | `https://api.ocp-primary.ecoengverticals-qe.devcluster.openshift.com:6443` |
| **Console** | `https://console-openshift-console.apps.ocp-primary.ecoengverticals-qe.devcluster.openshift.com` |
| **Login** | `kubeadmin` / `bSqje-hbg9N-vR9L6-ymE43` |
| **Nodes** | 3 masters (`m5.4xlarge`) + 3 workers (`m5.metal`) + 1 Submariner GW (`c5d.large`) |

#### ocp-secondary (Managed)

| Item | Value |
|---|---|
| **Cluster Name** | `ocp-secondary` |
| **OCP Version** | 4.18.7 |
| **AWS Region** | `eu-west-1` (Ireland) |
| **InfraID** | `ocp-secondary-5bm82` |
| **Cluster ID** | `571ba9ba-4a36-49b8-8ea6-bdbeb0bfb1db` |
| **API** | `https://api.ocp-secondary.ecoengverticals-qe.devcluster.openshift.com:6443` |
| **Console** | `https://console-openshift-console.apps.ocp-secondary.ecoengverticals-qe.devcluster.openshift.com` |
| **Login** | `kubeadmin` / `z2rCY-FXZ6r-6fTmu-gZmCI` |
| **Nodes** | 3 masters (`m5.4xlarge`) + 3 workers (`m5.metal`) + 1 Submariner GW (`c5d.large`) |

### Networking

| Cluster | Service CIDR | Cluster CIDR | Machine CIDR |
|---|---|---|---|
| **hub** | `172.30.0.0/16` | `10.128.0.0/14` | `10.0.0.0/16` |
| **ocp-primary** | `172.20.0.0/16` | `10.132.0.0/14` | `10.1.0.0/16` |
| **ocp-secondary** | `172.21.0.0/16` | `10.136.0.0/14` | `10.2.0.0/16` |

### Key URLs

| Service | URL |
|---|---|
| **ArgoCD (Hub)** | `https://hub-gitops-server-ramendr-starter-kit-hub.apps.hub.ecoengverticals-qe.devcluster.openshift.com` |
| **ArgoCD Login** | `admin` / `FqfvVayBz8muXeAgRWMZ4OI2Pk0KD9CY` |
| **Vault** | `https://vault-vault.apps.hub.ecoengverticals-qe.devcluster.openshift.com` |

### Git Repository

| Item | Value |
|---|---|
| **Fork** | `https://github.com/ikandel1/ramendr-starter-kit.git` |
| **Upstream** | `https://github.com/validatedpatterns/ramendr-starter-kit.git` |
| **Branch** | `main` |
| **Local Path** | `~/git/ramendr-starter-kit` |
| **Base Domain** | `ecoengverticals-qe.devcluster.openshift.com` |

### Secrets (loaded into Vault)

| Vault Path | Contents |
|---|---|
| `secret/global/vm-ssh` | SSH username (`cloud-user`), private key, public key |
| `secret/global/cloud-init` | Cloud-init userData |
| `secret/hub/aws` | AWS credentials, baseDomain, pullSecret, SSH keys |
| `secret/hub/openshiftPullSecret` | `.dockerconfigjson` |
| `secret/hub/privatekey` | SSH private key (required by ExternalSecrets for managed clusters) |

### Key Files

| File | Purpose |
|---|---|
| `~/.aws/credentials` | AWS Access Key ID + Secret Access Key |
| `~/values-secret.yaml` | Real secrets file (never commit!) |
| `~/git/hub-cluster-install/auth/kubeconfig` | Hub cluster kubeconfig |
| `~/git/hub-cluster-install/auth/kubeadmin-password` | Hub admin password |

### ArgoCD Application Status (Final)

| Application | Sync | Health |
|---|---|---|
| `acm` | Synced | Healthy |
| `odf` | Synced | Healthy |
| `vault` | Synced | Healthy |
| `golang-external-secrets` | Synced | Healthy |
| `ensure-openshift-console-plugins` | Synced | Healthy |
| `opp-policy` | Synced | Healthy |
| `regional-dr` | Synced | Healthy |

### Installed Operators

#### Hub Cluster

| Operator | Version |
|---|---|
| Validated Patterns Operator | 0.0.65 |
| OpenShift GitOps (ArgoCD) | 1.18.3 |
| Advanced Cluster Management | 2.13.5 |
| ODF Multicluster Orchestrator | 4.18.15 |
| ODF Operator | 4.18.15 |
| ODR Hub Operator | 4.18.15 |

#### Managed Clusters (both primary and secondary)

| Operator | Version |
|---|---|
| OpenShift Virtualization (KubeVirt) | 4.18.29 |
| ODF Operator | 4.18.15 |
| OCS Operator | 4.18.15 |
| ODR Cluster Operator | 4.18.15 |
| Submariner | 0.20.2 |
| OADP Operator | 1.4.7 |
| External DNS Operator | 1.3.2 |
| Node Health Check Operator | 0.10.1 |
| Self Node Remediation | 0.11.0 |
| OpenShift GitOps | 1.18.3 |

### DR Protection Status

| Component | Status |
|---|---|
| **DRPolicy `2m-vm`** | Validated — 2-minute RPO with VM support |
| **DRPolicy `2m-novm`** | Validated — 2-minute RPO without VM support |
| **DRClusters** | Both `ocp-primary` and `ocp-secondary` Available |
| **MirrorPeer** | `ExchangedSecret` — ODF secrets exchanged between clusters |
| **Submariner** | Healthy — both clusters connected |
| **ODF StorageCluster** | Ready on both clusters (v4.18.15) |
| **Volume Replication** | 4 PVCs replicating (Primary state) |
| **DRPC `gitops-vm-protection`** | Deployed + Protected on `ocp-primary` |

### Virtual Machines on ocp-primary

| VM Name | Namespace | Status | CPU | Memory | IP |
|---|---|---|---|---|---|
| `rhel9-node-001` | `gitops-vms` | Running | 1 | 4Gi | `10.132.2.125` |
| `rhel9-node-002` | `gitops-vms` | Running | 1 | 4Gi | `10.132.2.126` |
| `rhel9-node-003` | `gitops-vms` | Running | 1 | 4Gi | `10.133.2.72` |
| `rhel9-node-004` | `gitops-vms` | Running | 1 | 4Gi | `10.133.2.73` |

All 4 VMs are DR-protected with volume replication to ocp-secondary.

---

## Known Issues and Fixes Applied

| Issue | Root Cause | Resolution |
|---|---|---|
| `./pattern.sh` used template instead of real secrets | `values-secret.yaml.template` in repo was picked up before `~/values-secret.yaml` | Always pass `VALUES_SECRET=~/values-secret.yaml` explicitly |
| Pattern's `targetRepo` pointed to upstream instead of fork | Default behavior when cloning upstream first | Patched with `oc patch pattern ... targetRepo` |
| `openshift-install` ARM64 binary couldn't deploy x86 instances | Apple Silicon Mac downloads ARM64 by default | Downloaded amd64 version of the installer |
| Hub worker nodes exhausted CPU, ODF pods pending | 3 workers insufficient for ACM + ODF + operators | Scaled hub workers from 3 to 6 via MachineSet |
| New hub workers missing ODF storage label | Auto-scaling doesn't apply ODF labels | Manually labeled with `cluster.ocs.openshift.io/openshift-storage=""` |
| ExternalSecrets for SSH private key failed | Pattern expects `secret/hub/privatekey` in Vault, not part of `secret/hub/aws` | Created `secret/hub/privatekey` in Vault explicitly |
| ocp-primary failed to provision (EIP limit) | AWS default limit is 5 Elastic IPs per region; hub uses 3 | Requested quota increase to 15 via `aws service-quotas` |
| ocp-secondary marked as failed despite being functional | Install failed only on bootstrap cleanup (SSH rule timeout), cluster was actually running | Patched ClusterDeployment `spec.installed: true` with correct `clusterMetadata` |
| `regional-dr` ArgoCD sync deadlocked | Prerequisites checker Job blocked sync waves; it needed clusters that were in later waves | Manually created the Job to unblock; once it passed, sync proceeded normally |
| Submariner CRDs missing (early in deployment) | ACM/ODF hadn't finished deploying when `regional-dr` first tried to sync | Re-synced after operators were installed |


# RamenDR Starter Kit — Deployment Guide

This guide documents the full step-by-step deployment of the RamenDR Starter Kit pattern for regional disaster recovery of OpenShift virtual machine workloads on AWS.

**Official documentation:**
- [Getting Started](https://validatedpatterns.io/patterns/ramendr-starter-kit/getting-started/)
- [Installation Details](https://validatedpatterns.io/patterns/ramendr-starter-kit/installation-details/)
- [Cluster Sizing](https://validatedpatterns.io/patterns/ramendr-starter-kit/cluster-sizing/)

---

## New Team Member Quick Start

If you're joining this project, here's what you need to get the full environment running:

1. **Get credentials from your team lead:**
   - AWS Access Key ID + Secret Access Key (for the shared `automation-user`)
   - OpenShift Pull Secret (from [console.redhat.com](https://console.redhat.com/openshift/install/pull-secret))
   - The Route53 Hosted Zone ID and base domain

2. **Install tools on your Mac** (takes ~10 min):
   ```bash
   brew install openshift-cli podman awscli git
   xcode-select --install   # for make
   podman machine init && podman machine start
   ```
   Then install `openshift-install` — see [Step 3 below](#3-install-openshift-install-cli).

3. **Configure AWS** (takes ~2 min):
   ```bash
   aws configure   # enter your Access Key, Secret Key, region: eu-central-1, format: json
   ```

4. **Fork the repo** → [github.com/validatedpatterns/ramendr-starter-kit/fork](https://github.com/validatedpatterns/ramendr-starter-kit/fork)

5. **Clone, configure, and deploy** (takes ~2 hours unattended in BYOC mode):
   ```bash
   git clone https://github.com/<YOUR_USER>/ramendr-starter-kit.git
   cd ramendr-starter-kit
   ```
   Then follow [Step-by-Step Deployment](#step-by-step-deployment) below, or if `install-config.yaml.bak` files already exist for all three clusters, you can run:
   ```bash
   ./redeploy.sh
   ```
   The script will provision all three clusters **in parallel**, then deploy the pattern.

6. **Important gotchas** (read these before deploying!):
   - Always use `VALUES_SECRET=~/values-secret.yaml` when running `./pattern.sh make install`
   - Download the **amd64** `openshift-install` binary, even on Apple Silicon Macs
   - Request AWS EIP quota increase to **15** in `eu-central-1` and **10** in `eu-west-1` **before** deploying
   - Hub needs **6 workers** (not 3) — the redeploy script handles this automatically
   - Create `install-config.yaml.bak` for **all three** clusters (hub + primary + secondary) before running `./redeploy.sh`
   - Clusters on `devcluster.openshift.com` are **auto-destroyed** after a few days — use `./redeploy.sh` to rebuild

---

## Architecture Overview

The pattern deploys **3 OpenShift clusters** on AWS:

| Cluster | Role | AWS Region | Purpose |
|---|---|---|---|
| **hub** | Management | `eu-north-1` | Runs ACM, ArgoCD, Vault, ODF Multicluster Orchestrator |
| **ocp-primary** | Managed | `eu-central-1` | Runs VMs, ODF storage, primary DR site |
| **ocp-secondary** | Managed | `eu-west-1` | Runs ODF storage, secondary DR site (failover target) |

> **BYOC mode (v1.1+):** All three clusters are provisioned **in parallel** using `openshift-install` and independent install directories. The hub imports the spoke clusters via their kubeconfigs (`byoc: true` in `overrides/values-cluster-names.yaml`), bypassing Hive-based provisioning. This reduces total deployment time by ~50% and eliminates Hive as a dependency for spoke lifecycle management.

Key components installed by the pattern:
- **Red Hat ACM** — multi-cluster management, imports pre-provisioned spoke clusters via BYOC kubeconfigs
- **OpenShift Data Foundations (ODF)** — Ceph storage with cross-cluster replication
- **ODF Multicluster Orchestrator** — manages DR policies across clusters
- **OpenShift Virtualization (KubeVirt)** — runs VMs on managed clusters
- **Submariner** — VPN connectivity between managed clusters
- **HashiCorp Vault** — secrets management
- **External Secrets Operator** — syncs secrets from Vault to Kubernetes
- **Red Hat OpenShift GitOps (ArgoCD)** — GitOps-based deployment

### Bare-Metal Worker Requirement (c5n.metal)

OpenShift Virtualization (KubeVirt) requires `/dev/kvm` on worker nodes to schedule VMs. Standard EC2 instance types — including m5, m8i, c5, r5, and their variants — run on the AWS Nitro hypervisor and **do not** expose the `vmx`/`svm` CPU flags needed for KVM. As a result, `virt-handler` reports `devices.kubevirt.io/kvm: 0` on those nodes and VMs fail with `ErrorUnschedulable`.

OCP `install-config.yaml` does not support two compute pools with the same `name: worker`, so the `c5n.metal` node cannot be declared alongside the `m8i.4xlarge` workers at install time. Instead, `redeploy.sh` adds it post-install by cloning the first existing worker MachineSet and overriding the instance type to `c5n.metal` with a 300 GiB root disk (to avoid ODF disk-pressure evictions).

**Both clusters need a metal node:** VMs initially run on the primary cluster, but during a DR failover they must start on the secondary cluster. Without a metal node there, failover will fail with the same `ErrorUnschedulable` error.

> **Cost note:** `c5n.metal` instances are significantly more expensive than standard workers. The `redeploy.sh` script handles creation automatically — no manual MachineSet work is needed.

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
# Download amd64 version for OCP 4.20
curl -L -o /tmp/openshift-install.tar.gz \
  "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.20/openshift-install-mac-amd64.tar.gz"

mkdir -p ~/.local/bin
tar xzf /tmp/openshift-install.tar.gz -C ~/.local/bin openshift-install
chmod +x ~/.local/bin/openshift-install
export PATH="$HOME/.local/bin:$PATH"

# Verify
openshift-install version
```

> **Important:** Do NOT use the ARM64 installer — it will try to provision ARM instances, but the pattern uses x86 instance types (`m8i.4xlarge`, `c5.metal`).

### 4. Configure AWS Credentials

```bash
aws configure
# AWS Access Key ID: <your-key>
# AWS Secret Access Key: <your-secret>
# Default region name: eu-central-1
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
        type: m8i.4xlarge
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

### Step 1b: Provision Spoke Clusters in Parallel (BYOC)

While the hub is installing (or after it completes), provision both spoke clusters **simultaneously** using their own `install-config.yaml.bak` files (created in Step 3b below). Open two separate terminal sessions:

```bash
# Terminal 1 — ocp-primary
mkdir -p ~/git/ocp-primary-install
cp ~/git/ocp-primary-install/install-config.yaml.bak \
   ~/git/ocp-primary-install/install-config.yaml
openshift-install create cluster \
  --dir=~/git/ocp-primary-install --log-level=info
```

```bash
# Terminal 2 — ocp-secondary
mkdir -p ~/git/ocp-secondary-install
cp ~/git/ocp-secondary-install/install-config.yaml.bak \
   ~/git/ocp-secondary-install/install-config.yaml
openshift-install create cluster \
  --dir=~/git/ocp-secondary-install --log-level=info
```

> **Why parallel?** All three `openshift-install` runs can proceed concurrently — they use independent AWS accounts/regions and install directories. Running in parallel cuts provisioning time from ~2.5 hours (sequential) to ~60-75 minutes.

Once both spoke installs complete, their kubeconfigs will be at:
- `~/git/ocp-primary-install/auth/kubeconfig`
- `~/git/ocp-secondary-install/auth/kubeconfig`

These paths must match what is configured in `~/values-secret.yaml` (see Step 4).

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

### Step 3: Configure Spoke Cluster Names, Regions, and BYOC Mode

In this repository the cluster-provisioning configuration is stored in `overrides/values-cluster-names.yaml` (not in the externalized chart values). Edit that file to set your cluster names, regions, OCP version, and enable BYOC mode:

```yaml
clusterGroup:
  managedClusterGroups:
    - name: region-one
      clusterSelector:
        matchLabels:
          clusterGroup: region-one
      clusters:
        - name: ocp-primary
          region: eu-central-1   # Frankfurt — change if needed
          ocpVersion: "4.20"
          byoc: true             # BYOC: hub imports this cluster via kubeconfig
    - name: region-two
      clusterSelector:
        matchLabels:
          clusterGroup: region-two
      clusters:
        - name: ocp-secondary
          region: eu-west-1      # Ireland — must differ from primary!
          ocpVersion: "4.20"
          byoc: true             # BYOC: hub imports this cluster via kubeconfig
```

> **Important:** The two managed clusters MUST be in **different** AWS regions for regional DR to work.

### Step 3b: Create `install-config.yaml.bak` for Spoke Clusters

In BYOC mode the spokes are provisioned independently with `openshift-install`. Create one install directory per spoke:

```bash
# --- ocp-primary (Frankfurt, eu-central-1) ---
mkdir -p ~/git/ocp-primary-install
cat > ~/git/ocp-primary-install/install-config.yaml.bak << 'EOF'
apiVersion: v1
baseDomain: <YOUR_BASE_DOMAIN>
metadata:
  name: ocp-primary
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m5.2xlarge
compute:
  - name: worker
    replicas: 2
    platform:
      aws:
        type: m8i.4xlarge
  - name: worker
    replicas: 1
    platform:
      aws:
        type: c5n.metal
        rootVolume:
          iops: 3000
          size: 300
          type: gp3
networking:
  clusterNetwork:
    - cidr: 10.132.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.1.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.31.0.0/16
platform:
  aws:
    region: eu-central-1
    userTags:
      project: ValidatedPatterns
      owner: <YOUR_USERNAME>
      environment: dev
publish: External
sshKey: "<YOUR_SSH_PUBLIC_KEY>"
pullSecret: '<YOUR_PULL_SECRET_JSON>'
EOF

# --- ocp-secondary (Ireland, eu-west-1) ---
mkdir -p ~/git/ocp-secondary-install
cat > ~/git/ocp-secondary-install/install-config.yaml.bak << 'EOF'
apiVersion: v1
baseDomain: <YOUR_BASE_DOMAIN>
metadata:
  name: ocp-secondary
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m5.2xlarge
compute:
  - name: worker
    replicas: 2
    platform:
      aws:
        type: m8i.4xlarge
  - name: worker
    replicas: 1
    platform:
      aws:
        type: c5n.metal
        rootVolume:
          iops: 3000
          size: 300
          type: gp3
networking:
  clusterNetwork:
    - cidr: 10.136.0.0/14
      hostPrefix: 23
  machineNetwork:
    - cidr: 10.2.0.0/16
  networkType: OVNKubernetes
  serviceNetwork:
    - 172.21.0.0/16
platform:
  aws:
    region: eu-west-1
    userTags:
      project: ValidatedPatterns
      owner: <YOUR_USERNAME>
      environment: dev
publish: External
sshKey: "<YOUR_SSH_PUBLIC_KEY>"
pullSecret: '<YOUR_PULL_SECRET_JSON>'
EOF
```

> **Key points:**
> - Use **non-overlapping** CIDRs across all three clusters (hub, primary, secondary) — they must be reachable to each other via Submariner.
> - The spoke clusters start with 2× `m8i.4xlarge` workers. `redeploy.sh` adds a `c5n.metal` node post-install via a MachineSet (bare-metal, required for `/dev/kvm` and KubeVirt VMs, with a 300 GiB root disk to prevent ODF disk-pressure evictions).
> - The `install-config.yaml.bak` is the source of truth; `openshift-install` consumes and deletes the `.yaml` copy, leaving only `.bak` for re-runs.

### Step 3c: Add Cost Attribution Tags (Recommended)

For stable non-spot deployments simply ensure the `userTags` in each `install-config.yaml.bak` include your `owner`, `project`, and `environment` tags (as shown above).

For cost-optimized dev/test environments with spot bare-metal workers, see `overrides/values-aws-cost-optimized.yaml` — but note that in BYOC mode instance type configuration is done directly in the `install-config.yaml.bak` files.

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

  # BYOC: kubeconfigs for the spoke clusters provisioned externally.
  # These are loaded into Vault so the hub can import the clusters.
  - name: ocp-primary-kubeconfig
    fields:
      - name: kubeconfig
        path: ~/git/ocp-primary-install/auth/kubeconfig

  - name: ocp-secondary-kubeconfig
    fields:
      - name: kubeconfig
        path: ~/git/ocp-secondary-install/auth/kubeconfig
```

> **Tip:** You can use either `path:` (points to a file) or `value:` (inline content) for each field. Using `path:` is cleaner for large values like pull secrets and SSH keys. The kubeconfig entries must be populated **after** the spoke clusters are provisioned (Step 1b below), before running `./pattern.sh make install`.

### Step 5: Commit and Push

```bash
git add overrides/values-cluster-names.yaml
git commit -m "Enable BYOC mode for spoke clusters"
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

**Check managed clusters (BYOC — no ClusterDeployments):**
```bash
oc get managedclusters
# Both ocp-primary and ocp-secondary should appear as JOINED=True, AVAILABLE=True
# shortly after the pattern loads their kubeconfigs from Vault.
```

Expected deployment timeline (BYOC parallel mode):
| Phase | Duration | What Happens |
|---|---|---|
| 0. Parallel cluster installs | ~60-75 min | Hub + primary + secondary all running `openshift-install` simultaneously |
| 1. Operators install on hub | ~15 min | ACM, ODF, GitOps, Vault |
| 2. Spokes imported via BYOC | ~5-10 min | Hub reads kubeconfigs from Vault and imports managed clusters |
| 3. Operators install on managed clusters | ~30-45 min | ODF, KubeVirt, Submariner |
| 4. Storage + DR configured | ~15-20 min | ODF mirroring, DRPolicy, MirrorPeer |
| 5. VMs deployed | ~10-15 min | 4 RHEL9 VMs on primary (scheduled on c5n.metal node) |

> With BYOC the total time is approximately **2 hours** end-to-end, compared to ~3 hours with sequential Hive-based provisioning.

### Step 9: Verify Bare-Metal Workers for KubeVirt

`redeploy.sh` automatically creates a `c5n.metal` MachineSet on each spoke immediately after installation and waits for the node to become Ready before deploying the pattern. No manual action is needed.

To verify the node is Ready and KVM is exposed:

```bash
# Check on ocp-primary
export KUBECONFIG=~/git/ocp-primary-install/auth/kubeconfig

oc get nodes -l node.kubernetes.io/instance-type=c5n.metal
# Should show a Ready node

oc get node <metal-node-name> -o jsonpath='{.status.allocatable.devices\.kubevirt\.io/kvm}'
# Should show "1k"
```

Repeat for `ocp-secondary` before testing DR failover.

### Step 10: Verify the Deployment

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

## Cost Investigation and Optimization

### Investigate untagged usage and owner attribution

Use the audit script:

```bash
./scripts/audit-aws-cost-and-tags.sh
```

Useful environment variables:

```bash
# Optional filters
OWNER_TAG_KEY=owner \
LAUNCHED_BY_TAG_KEY=launchedBy \
LAUNCHED_BY_FILTER=automation-user \
START_DATE=2026-03-01 \
END_DATE=2026-04-01 \
./scripts/audit-aws-cost-and-tags.sh
```

What this reports:
- EC2 compute cost grouped by owner tag (Cost Explorer)
- EC2 compute cost where owner tag is absent
- Instances missing owner tag, across all AWS regions

### Optional: Use a cost-optimized dev/test profile

For disposable environments, the repo enables an aggressive profile with spot bare-metal workers by merging `overrides/values-aws-cost-optimized.yaml` into the `regional-dr` ArgoCD application via `values-hub.yaml` (`extraValueFiles`).

To **disable** that profile (for example for a stable non-spot deployment), remove this line from `values-hub.yaml` under the `rdr` application and push:

- `'/overrides/values-aws-cost-optimized.yaml'`

If your tooling supports it, you can pass extra Helm options through the utility container:

```bash
EXTRA_HELM_OPTS="..." VALUES_SECRET=~/values-secret.yaml ./pattern.sh make install
```

The override file `overrides/values-aws-cost-optimized.yaml` sets:
- `c5n.metal` workers with `spotMarketOptions`
- cheaper region defaults for primary/secondary
- explicit owner/launcher/environment tags

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
| Managed clusters not imported (BYOC) | Check kubeconfig secrets exist in Vault (`oc exec -n vault vault-0 -- vault kv get secret/hub/ocp-primary-kubeconfig`) and that `values-secret.yaml` paths point to the correct auth directories |
| Managed cluster provision fails with `AddressLimitExceeded` | Increase EIP quota: `aws service-quotas request-service-quota-increase --service-code ec2 --quota-code L-0263D0A3 --desired-value 15 --region <REGION>` |
| Hub ODF pods stuck Pending (`Insufficient cpu`) | Scale hub worker MachineSets: `oc scale machineset <name> -n openshift-machine-api --replicas=2` for each AZ |
| New hub workers missing ODF label | Label nodes: `oc label node <NODE> cluster.ocs.openshift.io/openshift-storage=""` |
| VMs stuck in `ErrorUnschedulable` (Insufficient `devices.kubevirt.io/kvm`) | Standard EC2 instances lack KVM. `redeploy.sh` adds a `c5n.metal` MachineSet automatically — verify with `oc get nodes -l node.kubernetes.io/instance-type=c5n.metal` |
| `c5n.metal` node not Ready after 20 min | Bare-metal instances take 15-20 min to boot. Check CSRs: `oc get csr`; approve any pending with `oc adm certificate approve <name>` |
| ExternalSecrets can't find `secret/hub/privatekey` | Create it in Vault: `oc exec -n vault vault-0 -- vault kv put secret/hub/privatekey privatekey="$(cat ~/.ssh/id_ed25519)"` |
| `regional-dr` stuck on prerequisites checker | Manually create the Job if ArgoCD sync is deadlocked: `oc apply -f` the Job manifest from `charts/hub/rdr/templates/job-odf-dr-prerequisites.yaml` |
| Managed cluster shows `ProvisionStopped` but is actually running | If the cluster API is reachable, patch the CD: `oc patch clusterdeployment <name> -n <ns> --type merge -p '{"spec":{"installed":true,"clusterMetadata":{...}}}'` |

### AWS EIP Quota Planning

Each OpenShift cluster uses **3 Elastic IPs** (one per availability zone for NAT gateways). The default AWS limit is **5 EIPs per region**. Plan accordingly:

| Region | Clusters | EIPs Needed | Recommended Quota |
|---|---|---|---|
| `eu-north-1` | hub | 3 | 10 |
| `eu-central-1` | ocp-primary | 3 | 10 |
| `eu-west-1` | ocp-secondary | 3 | 10 |

Request increases **before** deploying:
```bash
for region in eu-north-1 eu-central-1 eu-west-1; do
  aws service-quotas request-service-quota-increase \
    --service-code ec2 --quota-code L-0263D0A3 \
    --desired-value 10 --region $region
done
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

## Reference: Deployment Configuration

> **Note:** Cluster IDs, passwords, and IPs change with every deployment. Use the commands below to retrieve current values after each redeploy.

### Cluster Layout

| Cluster | Name | Region | Instance Types | Notes |
|---|---|---|---|---|
| Hub | `hub` | `eu-north-1` | 3x `m5.2xlarge` masters, 6x `m5.xlarge` workers | Runs ACM, ArgoCD, Vault, ODF orchestrator |
| Primary | `ocp-primary` | `eu-central-1` | 3x `m5.2xlarge` masters, 2x `m8i.4xlarge` workers + 1x `c5n.metal` (added post-install via MachineSet) | Runs VMs (on metal node), primary DR site |
| Secondary | `ocp-secondary` | `eu-west-1` | 3x `m5.2xlarge` masters, 2x `m8i.4xlarge` workers + 1x `c5n.metal` (added post-install via MachineSet) | Secondary DR site (failover target), metal node needed for failover VMs |

### Networking (configured in `overrides/values-cluster-names.yaml` and spoke `install-config.yaml.bak`)

| Cluster | Service CIDR | Cluster CIDR | Machine CIDR |
|---|---|---|---|
| **hub** | `172.30.0.0/16` | `10.128.0.0/14` | `10.0.0.0/16` |
| **ocp-primary** | `172.20.0.0/16` | `10.132.0.0/14` | `10.1.0.0/16` |
| **ocp-secondary** | `172.21.0.0/16` | `10.136.0.0/14` | `10.2.0.0/16` |

### How to Retrieve Current Credentials

```bash
# Hub console password
cat ~/git/hub-cluster-install/auth/kubeadmin-password

# ArgoCD admin password
oc get secret hub-gitops-cluster -n ramendr-starter-kit-hub \
  -o jsonpath='{.data.admin\.password}' | base64 -d

# Hub console URL
echo "https://console-openshift-console.apps.hub.<YOUR_BASE_DOMAIN>"

# ArgoCD URL
oc get route hub-gitops-server -n ramendr-starter-kit-hub -o jsonpath='https://{.spec.host}'

# Managed cluster kubeadmin passwords
oc get secret -n ocp-primary $(oc get secrets -n ocp-primary -o name | grep admin-password) \
  -o jsonpath='{.data.password}' | base64 -d

oc get secret -n ocp-secondary $(oc get secrets -n ocp-secondary -o name | grep admin-password) \
  -o jsonpath='{.data.password}' | base64 -d

# Quick status check
./redeploy.sh --status
```

### Git Repository

| Item | Value |
|---|---|
| **Fork** | `https://github.com/ikandel1/ramendr-starter-kit.git` |
| **Upstream** | `https://github.com/validatedpatterns/ramendr-starter-kit.git` |
| **Branch** | `main` |
| **Local Path** | `~/git/ramendr-starter-kit` |
| **Base Domain** | `ecoengverticals-qe.devcluster.openshift.com` |
| **Route53 Hosted Zone ID** | `Z01653801KMZNKX9NGW6G` |

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
| `~/git/hub-cluster-install/install-config.yaml.bak` | Hub install config (source of truth) |
| `~/git/hub-cluster-install/auth/kubeconfig` | Hub cluster kubeconfig |
| `~/git/hub-cluster-install/auth/kubeadmin-password` | Hub admin password |
| `~/git/ocp-primary-install/install-config.yaml.bak` | ocp-primary install config (BYOC) |
| `~/git/ocp-primary-install/auth/kubeconfig` | ocp-primary kubeconfig (loaded into Vault for BYOC import) |
| `~/git/ocp-secondary-install/install-config.yaml.bak` | ocp-secondary install config (BYOC) |
| `~/git/ocp-secondary-install/auth/kubeconfig` | ocp-secondary kubeconfig (loaded into Vault for BYOC import) |
| `overrides/values-cluster-names.yaml` | Cluster names, regions, OCP versions, byoc: true flags |

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
| OpenShift GitOps (ArgoCD) | 1.14.x |
| Advanced Cluster Management | 2.12.x |
| ODF Multicluster Orchestrator | 4.20.x |
| ODF Operator | 4.20.x |
| ODR Hub Operator | 4.20.x |

#### Managed Clusters (both primary and secondary)

| Operator | Version |
|---|---|
| OpenShift Virtualization (KubeVirt) | 4.20.x |
| ODF Operator | 4.20.x |
| OCS Operator | 4.20.x |
| ODR Cluster Operator | 4.20.x |
| Submariner | 0.20.x |
| OADP Operator | 1.4.x |
| External DNS Operator | 1.3.x |
| Node Health Check Operator | 0.10.x |
| Self Node Remediation | 0.11.x |
| OpenShift GitOps | 1.14.x |

### DR Protection Status

| Component | Status |
|---|---|
| **DRPolicy `2m-vm`** | Validated — 2-minute RPO with VM support |
| **DRPolicy `2m-novm`** | Validated — 2-minute RPO without VM support |
| **DRClusters** | Both `ocp-primary` and `ocp-secondary` Available |
| **MirrorPeer** | `ExchangedSecret` — ODF secrets exchanged between clusters |
| **Submariner** | Healthy — both clusters connected |
| **ODF StorageCluster** | Ready on both clusters (v4.20.x) |
| **Volume Replication** | 4 PVCs replicating (Primary state) |
| **DRPC `gitops-vm-protection`** | Deployed + Protected on `ocp-primary` |

### Virtual Machines

The pattern deploys 4 RHEL9 VMs on ocp-primary, each with 1 vCPU and 4Gi memory in the `gitops-vms` namespace. All VMs are DR-protected with volume replication to ocp-secondary.

```bash
# Check VM status (run from hub cluster)
PRIMARY_KC=$(oc get secrets -n ocp-primary -o name | grep admin-kubeconfig | head -1)
oc get vm -A --kubeconfig <(oc get $PRIMARY_KC -n ocp-primary -o jsonpath='{.data.kubeconfig}' | base64 -d)
```

---

## Quick Redeploy (Single Command)

> **Important:** Clusters on `devcluster.openshift.com` are ephemeral and auto-destroyed after a few days. Use this script to redeploy the entire environment.

### Full Redeploy (destroy + rebuild everything)

```bash
cd ~/git/ramendr-starter-kit
./redeploy.sh
```

This single command will:
1. Clean stale DNS records from Route53
2. Release orphaned Elastic IPs from all three regions
3. Destroy old spoke clusters in parallel using `openshift-install destroy cluster`
4. Destroy the old hub cluster
5. Provision hub + primary + secondary **in parallel** (~60-75 min)
6. Scale hub workers to 6 and label for ODF
7. Deploy the RamenDR pattern (~20 min for operators)
8. Wait for spokes to be imported via BYOC kubeconfigs
9. Wait for full DR convergence
10. Print environment status

**Total time: ~2 hours unattended**

> **Prerequisites:** `install-config.yaml.bak` must exist in `~/git/hub-cluster-install/`, `~/git/ocp-primary-install/`, and `~/git/ocp-secondary-install/` before running this command. See Steps 1 and 3b.

### Other Commands

```bash
# Check current status
./redeploy.sh --status

# Destroy everything without redeploying
./redeploy.sh --destroy-only

# Redeploy pattern only (hub already exists)
./redeploy.sh --pattern-only
```

### Environment Variables

| Variable | Default | Description |
|---|---|---|
| `HUB_INSTALL_DIR` | `~/git/hub-cluster-install` | Hub cluster install directory |
| `PRIMARY_INSTALL_DIR` | `~/git/ocp-primary-install` | ocp-primary install directory (BYOC) |
| `SECONDARY_INSTALL_DIR` | `~/git/ocp-secondary-install` | ocp-secondary install directory (BYOC) |
| `HUB_OCP_VERSION` | `4.20.6` | OCP version to install for the hub cluster |
| `VALUES_SECRET` | `~/values-secret.yaml` | Path to secrets file |
| `HOSTED_ZONE_ID` | `Z01653801KMZNKX9NGW6G` | Route53 hosted zone ID |
| `HUB_REGION` | `eu-north-1` | AWS region for the hub cluster |
| `PRIMARY_REGION` | `eu-central-1` | AWS region for ocp-primary |
| `SECONDARY_REGION` | `eu-west-1` | AWS region for ocp-secondary |

### Manual Step-by-Step (if you prefer)

If you want to run each step manually instead of using the script:

```bash
# 1. Clean up stale resources
#    (DNS records, orphaned EIPs)

# 2. Install hub cluster
cd ~/git/hub-cluster-install
cp install-config.yaml.bak install-config.yaml
openshift-install create cluster --dir . --log-level=info
export KUBECONFIG=~/git/hub-cluster-install/auth/kubeconfig
cp auth/kubeconfig ~/.kube/config

# 3. Scale hub workers (needed for ODF)
for ms in $(oc get machinesets.machine.openshift.io -n openshift-machine-api -o name); do
  oc scale $ms --replicas=2 -n openshift-machine-api
done
# Wait for workers, then label for ODF:
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  oc label $node cluster.ocs.openshift.io/openshift-storage="" --overwrite
done

# 4. Deploy pattern
cd ~/git/ramendr-starter-kit
VALUES_SECRET=~/values-secret.yaml ./pattern.sh make install

# 5. Fix Vault privatekey (if ExternalSecrets fail)
PRIVKEY=$(oc exec -n vault vault-0 -- vault kv get -field=ssh-privatekey secret/hub/aws)
PUBKEY=$(oc exec -n vault vault-0 -- vault kv get -field=ssh-publickey secret/hub/aws)
oc exec -n vault vault-0 -- vault kv put secret/hub/privatekey ssh-privatekey="$PRIVKEY" ssh-publickey="$PUBKEY"

# 6. Monitor convergence
watch 'oc get applications.argoproj.io -n ramendr-starter-kit-hub -o custom-columns="NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status"'
```

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
| NooBaa DB CrashLoopBackOff on secondary | `role "noobaa" does not exist` — DB initialized without noobaa role due to race condition | Delete the PVC `db-noobaa-db-pg-0`, scale StatefulSet to 0/1 to force fresh init |
| Clusters auto-destroyed after a few days | `devcluster.openshift.com` has automatic TTL cleanup | Use `./redeploy.sh` to rebuild the entire environment |
| Submariner `subscription` fails with `no operators found in package submariner` on OCP 4.21 | The `redhat-operator-index:v4.21` catalog does not yet include the `submariner` package | Fixed in v1.1: a `ManifestWork` deploys a custom `submariner-catalog` CatalogSource (backed by `redhat-operator-index:v4.20`) to each managed cluster; `SubmarinerConfig.subscriptionConfig` points to it |
| Submariner gateway node stuck in `Provisioned` / `rpm-ostreed.service` crash loop on OCP 4.21 | `c5d`/`r5d`/`m5d` instance types have NVMe local SSD; RHCOS on OCP 4.21 fails to boot on these | Fixed in v1.1: gateway instance type changed from `c5d.large` to `m5.large` (no local NVMe) |
| VMs `ErrorUnschedulable`: `Insufficient devices.kubevirt.io/kvm` | Standard EC2 instances (m5, m8i, c5, etc.) do not expose `vmx`/`svm` CPU flags — `/dev/kvm` is missing | `redeploy.sh` creates a `c5n.metal` MachineSet post-install. Verify with `oc get nodes -l node.kubernetes.io/instance-type=c5n.metal`; if missing, re-run `./redeploy.sh --pattern-only`. |
| DR failover fails with `ErrorUnschedulable` on secondary cluster | Secondary cluster has no metal worker, so VMs cannot be scheduled there | `redeploy.sh` applies the `c5n.metal` MachineSet to both spokes. Check secondary with its kubeconfig. |
| `odf-ssl-certificate-extractor` job fails with `SSLCertVerificationError` | Ansible's `kubernetes.core.k8s_info` module does not honour `certificate-authority-data` in kubeconfigs, causing SSL verification to fail against self-signed OCP API certificates | Generate insecure kubeconfigs with `oc login --insecure-skip-tls-verify` and patch the admin kubeconfig secrets on the hub; or set `insecure-skip-tls-verify: true` in the kubeconfig files stored in Vault |
| Spoke install fails in a region with `InvalidNatGatewayID.NotFound` | AWS NAT Gateway provisioning race condition; some regions are more prone to this | Destroy the partial infra (`openshift-install destroy cluster --dir ...`) and retry, or switch to a different AZ/region |
| ODF version mismatch: `StorageCluster version on ManagedCluster is incompatible with Multicluster Orchestrator version` | Hub ODF and spoke ODF must be on the same minor version | Pin all clusters to the same OCP version in `overrides/values-cluster-names.yaml` (`ocpVersion: "4.20"`) and ensure `values-hub.yaml` ODF subscriptions use `stable-4.20` channel |


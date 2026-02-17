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

---

## Reference: Our Deployment Details

| Item | Value |
|---|---|
| **Hub API** | `https://api.hub.ecoengverticals-qe.devcluster.openshift.com:6443` |
| **Hub Console** | `https://console-openshift-console.apps.hub.ecoengverticals-qe.devcluster.openshift.com` |
| **Hub Login** | `kubeadmin` / `KHRWV-2QLNR-gRWfb-WNShV` |
| **Hub KUBECONFIG** | `~/git/hub-cluster-install/auth/kubeconfig` |
| **ArgoCD URL** | `https://hub-gitops-server-ramendr-starter-kit-hub.apps.hub.ecoengverticals-qe.devcluster.openshift.com` |
| **ArgoCD Login** | `admin` / `FqfvVayBz8muXeAgRWMZ4OI2Pk0KD9CY` |
| **Git Fork** | `https://github.com/ikandel1/ramendr-starter-kit.git` |
| **Git Branch** | `main` |
| **Base Domain** | `ecoengverticals-qe.devcluster.openshift.com` |
| **Primary Region** | `eu-north-1` (Stockholm) |
| **Secondary Region** | `eu-west-1` (Ireland) |
| **OCP Version** | 4.18.32 (hub), 4.18.7 (managed clusters) |
| **Cluster ID** | `5df8d356-4d0e-4455-a1eb-81cc9225d05b` |


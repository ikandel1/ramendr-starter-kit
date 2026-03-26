# ODF SSL Certificate Management for Disaster Recovery

This document describes the enhanced certificate management policies specifically designed for OpenShift Data Foundation (ODF) disaster recovery scenarios, following Red Hat's official documentation guidelines.

## Overview

The ODF SSL certificate management system provides automated certificate extraction, distribution, and configuration for secure SSL access across clusters in a regional disaster recovery setup. This implementation follows the [Red Hat ODF Disaster Recovery documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.21/html-single/configuring_openshift_data_foundation_disaster_recovery_for_openshift_workloads/index#creating-odf-cluster-on-managed-clusters_rdr).

## Key Features

### 1. **Automated Certificate Extraction**

- Extracts CA certificates from hub and managed clusters

- Uses multiple extraction methods for reliability

- Handles regional DR cluster configurations specifically

### 2. **ODF-Specific SSL Configuration**

- Follows Red Hat ODF disaster recovery guidelines

- Ensures secure SSL access for S3 endpoints

- Supports MirrorPeer and DRCluster validation

### 3. **Dynamic Cluster Discovery**

- Automatically discovers managed clusters via ACM

- Targets clusters with `purpose: regionalDR` labels

- Handles cluster connectivity and kubeconfig management

### 4. **Comprehensive Distribution**

- Creates combined CA bundle ConfigMaps

- Updates cluster proxy configurations

- Distributes certificates to all managed clusters

## Policy Components

### 1. **ODF SSL Certificate Management Policy** (`policy-odf-ssl-certificate-management.yaml`)

**Purpose:** Main policy that extracts and distributes SSL certificates for ODF disaster recovery.

**Features:**

- Extracts CA certificates from hub and managed clusters

- Creates combined CA bundle ConfigMap

- Updates hub cluster proxy configuration

- Creates placement rules and distribution policies

- Follows ODF-specific certificate management guidelines

**Key Capabilities:**

```yaml
# Extracts certificates from multiple sources

- Hub cluster: openshift-config-managed/trusted-ca-bundle

- Managed clusters: via kubeconfig or ACM resources

- Creates combined CA bundle with deduplication

- Updates cluster proxy to use CA bundle

- Creates policies for managed cluster distribution

```text

### 2. **Managed Cluster SSL Policy** (`policy-odf-managed-cluster-ssl.yaml`)

**Purpose:** Ensures managed clusters have proper SSL certificate configuration.

**Features:**

- Creates `cluster-proxy-ca-bundle` ConfigMap on managed clusters

- Updates proxy configuration to use CA bundle

- Creates ODF SSL verification ConfigMap

- Applied via placement rules to regional DR clusters
### 3. **Placement Rule** (`placement-odf-ssl-certificates.yaml`)

**Purpose:** Targets the correct clusters for SSL certificate distribution.

**Features:**

- Targets clusters with `purpose: regionalDR`

- Ensures clusters are available before applying policies

- Supports OpenShift clusters in clustersets

- Configures for 2-cluster regional DR setup
### 4. **Placement Binding** (`placement-binding-odf-ssl.yaml`)

**Purpose:** Connects the placement rule with the managed cluster policy.

**Features:**

- Links placement rule to managed cluster policy

- Ensures proper policy distribution

- Supports ODF disaster recovery requirements

## How It Works
### Step 1: Certificate Extraction (Hub Cluster)

The main policy extracts certificates from all clusters:
```bash
# Hub cluster CA extraction
oc get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}"

# Managed cluster discovery
oc get managedclusters -o jsonpath='{.items[*].metadata.name}'

# Extract CA from each managed cluster
for cluster in $MANAGED_CLUSTERS; do
  # Get kubeconfig for cluster
  oc get secret -n "$cluster" -o name | grep kubeconfig | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | base64 -d > "/tmp/${cluster}-kubeconfig.yaml"

  # Extract CA using kubeconfig
  oc --kubeconfig="/tmp/${cluster}-kubeconfig.yaml" get configmap -n openshift-config-managed trusted-ca-bundle -o jsonpath="{.data['ca-bundle\.crt']}"
done

```text

### Step 2: CA Bundle Creation

Creates a combined CA bundle with certificates from all clusters:
```bash
# Combine all CA certificates
cat hub-ca.crt managed-cluster-1-ca.crt managed-cluster-2-ca.crt > combined-ca-bundle.crt

# Remove duplicates
sort combined-ca-bundle.crt | uniq > combined-ca-bundle-dedup.crt

```text

### Step 3: Hub Cluster Configuration

Updates the hub cluster with the combined CA bundle:
```bash
# Create ConfigMap on hub cluster
oc create configmap cluster-proxy-ca-bundle \

  --from-file=ca-bundle.crt=combined-ca-bundle.crt \

  -n openshift-config

# Update hub cluster proxy
oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"cluster-proxy-ca-bundle"}}}'

```text

### Step 4: Managed Cluster Distribution

Creates policies to distribute the CA bundle to managed clusters:
```yaml
# Policy creates ConfigMap on managed clusters
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-proxy-ca-bundle
  namespace: openshift-config
data:
  ca-bundle.crt: |
    # Combined CA bundle content

# Policy updates proxy on managed clusters
apiVersion: config.openshift.io/v1
kind: Proxy
metadata:
  name: cluster
spec:
  trustedCA:
    name: cluster-proxy-ca-bundle

```text
## ODF-Specific Features
### 1. **Regional DR Support**

- Targets clusters with `purpose: regionalDR` labels

- Supports 2-cluster regional DR configurations

- Handles cluster connectivity for S3 endpoints
### 2. **S3 Endpoint SSL Support**

- Ensures SSL certificates are trusted for S3 access

- Supports MirrorPeer validation requirements

- Enables DRCluster S3 profile validation
### 3. **Automated Certificate Management**

- No manual certificate configuration required

- Automatic discovery of managed clusters

- Self-healing certificate distribution

## Usage
### Automatic Deployment

The policies are automatically deployed when the hub policy set is applied:
```bash
# Policies automatically:
# 1. Extract certificates from all clusters
# 2. Create combined CA bundle
# 3. Update hub cluster proxy
# 4. Distribute certificates to managed clusters
# 5. Configure SSL access for ODF disaster recovery

```text

### Manual Trigger

To manually trigger certificate extraction:
```bash
# Delete the existing job to trigger recreation
oc delete job odf-ssl-certificate-extractor -n openshift-config

# The policy will automatically recreate the job

```text

### Verification

Check the certificate management status:
```bash
# Verify hub cluster configuration
oc get configmap cluster-proxy-ca-bundle -n openshift-config
oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}'

# Verify managed cluster policies
oc get policy policy-odf-managed-cluster-ssl -n open-cluster-management
oc get placementrule placement-odf-ssl-certificates -n open-cluster-management

# Check job status
oc get job odf-ssl-certificate-extractor -n openshift-config
oc logs job/odf-ssl-certificate-extractor -n openshift-config

```text
## Benefits
### 1. **ODF Compliance**

- Follows Red Hat ODF disaster recovery guidelines

- Ensures proper SSL configuration for S3 access

- Supports MirrorPeer and DRCluster requirements
### 2. **Automated Management**

- No manual certificate configuration

- Automatic cluster discovery

- Self-healing certificate distribution
### 3. **Security**

- Ensures all clusters trust each other's certificates

- Supports secure SSL access for disaster recovery

- Maintains certificate trust across the cluster set
### 4. **Reliability**

- Multiple certificate extraction methods

- Robust error handling and logging

- Automatic retry and recovery mechanisms

## Troubleshooting
### Common Issues

1. **Certificate Extraction Failures**
   ```bash
   # Check job logs
   oc logs job/odf-ssl-certificate-extractor -n openshift-config

   # Verify cluster connectivity
   oc get managedclusters
   ```

1. **Policy Distribution Issues**

   ```bash
   # Check placement rule
   oc get placementrule placement-odf-ssl-certificates -n open-cluster-management

   # Check placement binding
   oc get placementbinding binding-odf-ssl-certificates -n open-cluster-management
   ```

2. **SSL Access Problems**

   ```bash
   # Verify ConfigMap exists on managed clusters
   oc get configmap cluster-proxy-ca-bundle -n openshift-config

   # Check proxy configuration
   oc get proxy cluster -o yaml
   ```

### Monitoring Commands

```bash
# Watch certificate extraction job
oc logs -f job/odf-ssl-certificate-extractor -n openshift-config

# Monitor policy compliance
oc get policy policy-odf-managed-cluster-ssl -n open-cluster-management -o yaml

# Check placement rule status
oc get placementrule placement-odf-ssl-certificates -n open-cluster-management -o yaml

```text
## References
- [Red Hat ODF Disaster Recovery Documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.21/html-single/configuring_openshift_data_foundation_disaster_recovery_for_openshift_workloads/index#creating-odf-cluster-on-managed-clusters_rdr)

- [OpenShift Data Foundation Regional DR](https://docs.redhat.com/en/documentation/red_hat_openshift_data_foundation/4.21/html-single/configuring_openshift_data_foundation_disaster_recovery_for_openshift_workloads/index#regional-dr-solution-for-openshift-data-foundation)

- [Advanced Cluster Management Policies](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.9/html/governance/governance#governance-intro)

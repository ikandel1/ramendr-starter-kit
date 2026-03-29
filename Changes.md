# Change history for significant pattern releases

v1.0 - November 2025

* Arrange to default baseDomain settings appropriately so that forking the pattern is not a hard requirement
* Initial release

v1.0 - February 2026

* The names ocp-primary and ocp-secondary were hardcoded in various places, which caused issues when trying
to install two copies of this pattern into the same DNS domain.
* Also parameterize the version of edge-gitops-vms chart in case it needs to get updated. It too was hardcoded.
* Update to ACM 2.14 in prep for OCP 4.20+ testing.

v1.1 - March 2026

* Update managed cluster version from 4.18.7 to 4.21.6 (hub, primary, and secondary).
* Update ACM subscription channel from release-2.14 to release-2.16 (compatible with OCP 4.21).
* Add explicit ODF channel stable-4.21 for odf-operator and odf-multicluster-orchestrator on hub and managed clusters.
* Update OADP subscription channel from stable-1.4 to stable (tracks the single supported version for OCP 4.21, currently 1.7.x).
* Update openshift-install download URL to stable-4.21 in deployment guide.
* Fix Submariner gateway node provisioning for OCP 4.21:
  - Change gateway instance type from c5d.large to m5.large (c5d/r5d/m5d NVMe instance types
    fail to bootstrap on OCP 4.21 due to rpm-ostreed crash loops).
  - Add a ManifestWork-based CatalogSource (redhat-operator-index:v4.20) on managed clusters
    to provide the submariner package, which is absent from redhat-operator-index:v4.21.
  - Configure SubmarinerConfig.subscriptionConfig to use this custom catalog source.
* Fix VM startup failures on OCP 4.21:
  - Update VM machineType from pc-q35-rhel8.4.0 to pc-q35-rhel9.4.0 (deprecated type triggers
    DeprecatedMachineType alerts and may cause startup failures on 4.21).
  - Add boot source readiness check in edge-gitops-vms-deploy script: waits up to 10 minutes
    for the rhel9 DataSource in openshift-virtualization-os-images to become ready before
    deploying VMs, preventing ErrorPvcNotFound / DataVolumeError states.
  - Switch worker instance type from m5.4xlarge to m8i.4xlarge: the first-gen m5 instances
    (Intel Xeon 8175M) do not expose vmx/svm CPU flags, so /dev/kvm is unavailable and
    KubeVirt reports allocatable KVM=0, making VMs ErrorUnschedulable. The m8i instances
    (Intel Xeon 6) support nested virtualization on AWS.
  - Move primary cluster region from eu-north-1 to eu-central-1 because m8i instances
    are not available in eu-north-1.
* Fix klusterlet ManifestWork RBAC for ACM 2.16:
  - ACM 2.16 restricts klusterlet-work-sa permissions. Added a ManifestWork that deploys
    ClusterRole/Binding granting access to CatalogSource and Submariner CRDs on managed
    clusters, preventing ManifestWork apply failures.

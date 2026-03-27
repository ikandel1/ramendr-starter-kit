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

* Update managed cluster version from 4.18.7 to 4.21.1 (hub, primary, and secondary).
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

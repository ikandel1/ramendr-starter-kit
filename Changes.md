# Change history for significant pattern releases

v1.0 - November 2025

* Arrange to default baseDomain settings appropriately so that forking the pattern is not a hard requirement
* Initial release

v1.0 - February 2026

* The names ocp-primary and ocp-secondary were hardcoded in various places, which caused issues when trying
to install two copies of this pattern into the same DNS domain.
* Also parameterize the version of edge-gitops-vms chart in case it needs to get updated. It too was hardcoded.
* Update to ACM 2.14 in prep for OCP 4.20+ testing.

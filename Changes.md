# Change history for significant pattern releases

v1.0 - November 2025

* Arrange to default baseDomain settings appropriately so that forking the pattern is not a hard requirement
* Initial release

v1.0 - February 2026

* The names ocp-primary and ocp-secondary were hardcoded in various places, which caused issues when trying
to install two copies of this pattern into the same DNS domain.
* Also parameterize the version of edge-gitops-vms chart in case it needs to get updated. It too was hardcoded.
* Update to ACM 2.14 in prep for OCP 4.20+ testing.

v1.0 - March 2026 (validatedpatterns)

* Updated workload deployment script to check both clusters for workload instead of just the primary, in case
a failover was in progress at the time.
* Update ACM to 2.15 and golang-external-secrets. Move to 0.2 golang-secrets chart to allow use of v1 API. This is
  in prep to move to OCP 4.20 as the default.
* Change machine instance type for submariner to allow deployment on 4.20.
* rdr chart previously used hardcoded and undocumented Vault secrets. Exposed these as variables and referenced
  the previously documented AWS secret instead of creating a new one with the same material.
* Externalize all charts to prep for subsequent demo pattern.
* Pass values-egv-dr into edge-gitops-vms chart. It used to use a symlink when it was local.

v1.1 - April 2026 (validatedpatterns)

* Change submariner to use vxlan mode by default, for compatibility reasons
* Default to OCP 4.20+. The subscription for OADP requires "stable" channel not "stable-1.4".
* Numerous small changes to deal with race conditions and other potential issues
* Introduce "BYOC" (bring-your-own-cluster) as an option for cluster provisioning (thanks @darkdoc)

v1.1 - March 2026 (this fork, historical)

* Experimental OCP 4.21.6 / ACM 2.16 / ODF stable-4.21 work; the fork was later merged with validatedpatterns
  main and aligned to OCP 4.20.x. Deployment notes: Submariner gateway m5.large + custom catalog for 4.21;
  KubeVirt VM machineType and boot-source waits; c5.metal for KVM; primary region eu-central-1; klusterlet
  CatalogSource/Submariner RBAC. See git history on branch main before the upstream merge for file-level detail.

Tooling (this fork, post–upstream merge)

* `redeploy.sh` pins the hub to OCP 4.20.6: sets `OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE` to
  `quay.io/openshift-release-dev/ocp-release:4.20.6-x86_64` (override with `HUB_OCP_VERSION` or that env)
  so a 4.21+ `openshift-install` on `PATH` does not provision a 4.21 hub when spokes are 4.20.6 in
  `overrides/values-cluster-names.yaml` (same issue Martin/Elsa called out for mixed 4.20/4.21).

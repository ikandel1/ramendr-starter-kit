# RDR (Regional DR) chart

Helm chart for Regional DR configuration (cluster pair, install_config, DRPC, etc.).

## Updating the default install_config JSON files

When `values.yaml` is changed (e.g. machine types, networking CIDRs, platform settings) under `regionalDR[0].clusters.primary.install_config` or `secondary.install_config`, the chart’s fallback files must be kept in sync so minimal `regionalDR` values still produce a full install_config.

From the **repository root**:

```bash
./scripts/update-rdr-default-install-config-json.sh
```

- **What it does:** Reads `charts/hub/rdr/values.yaml`, extracts both `install_config` sections, and overwrites:
  - `charts/hub/rdr/files/default-primary-install-config.json`
  - `charts/hub/rdr/files/default-secondary-install-config.json`
- **When to run:** After editing `install_config` in this chart’s `values.yaml`.
- **Dry-run:** To print the generated JSON without writing files:

  ```bash
  ./scripts/update-rdr-default-install-config-json.sh --dry-run
  ```

- **Requirements:** Python 3 with PyYAML (`pip install pyyaml`), or `yq` (and optionally `jq`).

Then run the install_config tests to confirm nothing is broken:

```bash
./scripts/test-rdr-install-config.sh
```

## Troubleshooting: DRCluster validation — "DRClusterConfig is not applied to cluster"

The DRCluster validation job (sync-wave 8) waits until each DRCluster’s status shows `Validated=True`. If you see:

```text
DRCluster ocp-p: Not validated yet (status: False)
  Message: DRClusterConfig is not applied to cluster (ocp-p)
```

then the Ramen/ODF DR controller has not yet applied the DR config to that managed cluster (usually via a ManifestWork).

**Checks:**

1. **Hub operator** – ODF Multicluster Orchestrator / Ramen DR is installed on the hub and DRPolicy + DRCluster resources exist and are correct.
2. **Clusters joined** – Both clusters appear as ManagedClusters and are available:

   ```bash
   oc get managedcluster ocp-p ocp-s
   ```

3. **ManifestWorks** – Ramen creates ManifestWorks in each cluster’s namespace to deploy the DR cluster operator. On the hub:

   ```bash
   oc get manifestwork -n ocp-p
   oc get manifestwork -n ocp-s
   ```

   If these are missing or not applied, check Ramen controller logs on the hub.
4. **Cluster readiness** – Clusters must be reachable from the hub so the hub can apply and reconcile the ManifestWork; ensure they are not degraded or not ready.

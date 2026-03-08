#!/usr/bin/env bash
# Update charts/hub/rdr/files/default-*-install-config.json from the install_config
# sections in charts/hub/rdr/values.yaml. Run this when you change machine types,
# networking, platform, or other install_config in the rdr chart values.
#
# Requires: Python 3 with PyYAML (pip install pyyaml) or yq.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RDR_CHART="$REPO_ROOT/charts/hub/rdr"
VALUES_YAML="$RDR_CHART/values.yaml"
DEFAULT_BASE_DOMAIN="cluster.example.com"
OUT_PRIMARY="$RDR_CHART/files/default-primary-install-config.json"
OUT_SECONDARY="$RDR_CHART/files/default-secondary-install-config.json"

usage() {
  echo "Usage: $0 [--dry-run]"
  echo "  Updates $OUT_PRIMARY and $OUT_SECONDARY from $VALUES_YAML"
  echo "  --dry-run  Print what would be written, do not overwrite files."
  exit 0
}

DRY_RUN=
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage ;;
  esac
done

[[ -f "$VALUES_YAML" ]] || { echo "Error: $VALUES_YAML not found."; exit 1; }

# Prefer Python so we have one code path and predictable JSON formatting
run_python() {
  python3 - "$VALUES_YAML" "$DEFAULT_BASE_DOMAIN" "$OUT_PRIMARY" "$OUT_SECONDARY" "$DRY_RUN" << 'PY'
import json
import sys
import yaml

def main():
    values_path = sys.argv[1]
    default_base_domain = sys.argv[2]
    out_primary = sys.argv[3]
    out_secondary = sys.argv[4]
    dry_run = sys.argv[5] == "1"

    with open(values_path) as f:
        data = yaml.safe_load(f)

    try:
        clusters = data["regionalDR"][0]["clusters"]
        primary_ic = clusters["primary"]["install_config"]
        secondary_ic = clusters["secondary"]["install_config"]
    except (KeyError, TypeError) as e:
        sys.stderr.write("Error: could not find regionalDR[0].clusters.primary/secondary.install_config in values.yaml\n")
        sys.exit(1)

    def normalize(ic):
        # Deep copy and replace template baseDomain with static default
        out = json.loads(json.dumps(ic))
        if isinstance(out.get("baseDomain"), str) and "{{" in out["baseDomain"]:
            out["baseDomain"] = default_base_domain
        return out

    primary = normalize(primary_ic)
    secondary = normalize(secondary_ic)

    opts = {"indent": 2, "sort_keys": False}
    primary_json = json.dumps(primary, **opts)
    secondary_json = json.dumps(secondary, **opts)

    if dry_run:
        print("--- primary (would write to", out_primary, ") ---")
        print(primary_json)
        print("--- secondary (would write to", out_secondary, ") ---")
        print(secondary_json)
        return

    with open(out_primary, "w") as f:
        f.write(primary_json)
        f.write("\n")
    with open(out_secondary, "w") as f:
        f.write(secondary_json)
        f.write("\n")
    print("Wrote", out_primary)
    print("Wrote", out_secondary)

if __name__ == "__main__":
    main()
PY
}

if command -v python3 &>/dev/null; then
  if python3 -c "import yaml" 2>/dev/null; then
    run_python
    exit 0
  fi
fi

# Fallback: yq (if available)
if command -v yq &>/dev/null; then
  echo "Using yq (Python/PyYAML not available)."
  extract_one() {
    local path="$1"
    local out="$2"
    local tmp
    tmp=$(mktemp)
    trap "rm -f $tmp" EXIT
    # yq v4: .regionalDR[0].clusters.primary.install_config
    yq eval '.regionalDR[0].clusters.'"$path"'.install_config' "$VALUES_YAML" -o=json > "$tmp" 2>/dev/null || \
    yq r -j "$VALUES_YAML" "regionalDR.0.clusters.$path.install_config" > "$tmp" 2>/dev/null || \
    { echo "Error: yq could not extract install_config. Try: pip install pyyaml && $0"; exit 1; }
    # Replace template baseDomain
    if command -v jq &>/dev/null; then
      jq --arg dom "$DEFAULT_BASE_DOMAIN" '.baseDomain = $dom' "$tmp" > "${tmp}.2" && mv "${tmp}.2" "$tmp"
    else
      sed -i "s/\"{{ join.*}}\"/\"$DEFAULT_BASE_DOMAIN\"/" "$tmp" 2>/dev/null || true
    fi
    if [[ -n "$DRY_RUN" ]]; then
      echo "--- $out (dry-run) ---"
      cat "$tmp"
    else
      cp "$tmp" "$out"
      echo "Wrote $out"
    fi
    rm -f "$tmp"
    trap - EXIT
  }
  extract_one "primary" "$OUT_PRIMARY"
  extract_one "secondary" "$OUT_SECONDARY"
  exit 0
fi

echo "Error: Need Python 3 with PyYAML (pip install pyyaml) or yq to run this script."
exit 1

#!/usr/bin/env bash
# Prints the files the commits from <base> to <head> change among those an OpenTofu root depends on.
# A deploy applies a root only when it prints one, and a pull request plans the GitHub root only then.
#
# Usage: root-changes.sh <root> <base> <head>
set -euo pipefail

root="$1" base="$2" head="$3"

# A root depends on the action that applies it, its directory and the local modules it calls,
# directly or through another module. The loop also visits each module it adds.
paths=(.opentofu-version .github/actions/tofu/ .github/workflows/deploy.yaml)
# The cluster root reads each service root's pins from its terraform.tfvars, and its health checks
# run the smoke-check module's script. The Grafana root reads foundation's node pool. The GitHub
# root's job copies the governance secrets, asserts the repository settings and prunes after it
# applies.
[ "$root" != environments/production/cluster ] || paths+=('environments/production/*/terraform.tfvars' modules/smoke-check/smoke.sh)
[ "$root" != environments/production/grafana ] || paths+=(environments/production/foundation/terraform.tfvars environments/production/cluster/terraform.tfvars)
[ "$root" != environments/production/github ] || paths+=(.github/scripts/secret-sync.mjs .github/scripts/repository-asserts.mjs .github/scripts/prune.mjs)
dirs=("$root")
for ((i = 0; i < ${#dirs[@]}; i++)); do
  paths+=("${dirs[i]}/")
  while read -r source; do
    dirs+=("$(realpath --relative-to=. "${dirs[i]}/$source")")
  done < <(grep -ho 'source *= *"\.[^"]*"' "${dirs[i]}"/*.tf | sed -E 's/.*"(.*)"/\1/')
done

# OpenTofu never reads Markdown, so documentation alone changes nothing.
git diff --name-only "$base" "$head" -- "${paths[@]}" ':(exclude)*.md'

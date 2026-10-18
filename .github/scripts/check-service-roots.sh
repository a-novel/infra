#!/usr/bin/env bash
# Fails when a service root lacks the workflow wiring GitHub Actions cannot derive from disk. deploy.yaml
# and drift.yaml find the roots by directory, but each root's plan is a required check named by its
# own job, and a manual dispatch offers only the choices its workflow lists.
set -euo pipefail

workflows=.github/workflows
status=0
for dir in environments/production/*/; do
  ROOT="$(basename "$dir")"
  [ "$ROOT" = foundation ] && continue
  ROOT_PATH="environments/production/$ROOT"
  export ROOT ROOT_PATH
  missing=()
  [ "$(yq '[.jobs[].steps[]?.with.root] | any_c(. == strenv(ROOT_PATH))' "$workflows/main.yaml")" = true ] ||
    missing+=("a plan job in main.yaml")
  [ "$(yq '.on.workflow_dispatch.inputs.service.options | any_c(. == strenv(ROOT))' "$workflows/roll-database.yaml")" = true ] ||
    missing+=("a service option in roll-database.yaml")
  for item in "${missing[@]}"; do
    echo "::error::$ROOT_PATH lacks $item."
    status=1
  done
done
exit "$status"

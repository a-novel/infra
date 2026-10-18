#!/usr/bin/env bash
# Fails when a service root lacks the workflow wiring every root needs. deploy.yaml finds the service
# roots by directory and applies each one on every deploy, but GitHub Actions cannot generate the
# jobs, outputs and lists below, so a new root must add them by hand.
set -euo pipefail

workflows=.github/workflows
status=0
for dir in environments/production/*/; do
  ROOT="$(basename "$dir")"
  [ "$ROOT" = foundation ] && continue
  ROOT_PATH="environments/production/$ROOT" KEY="${ROOT//-/_}"
  export ROOT ROOT_PATH KEY
  missing=()
  [ "$(yq '[.jobs[].steps[]?.with.root] | any_c(. == strenv(ROOT_PATH))' "$workflows/main.yaml")" = true ] ||
    missing+=("a plan job in main.yaml")
  [ "$(yq '[.jobs[strenv(ROOT)].steps[]?.with.root] | any_c(. == strenv(ROOT_PATH))' "$workflows/deploy.yaml")" = true ] ||
    missing+=("a $ROOT job applying it in deploy.yaml")
  [ "$(yq '.jobs.changes.outputs | has(strenv(KEY))' "$workflows/deploy.yaml")" = true ] ||
    missing+=("the $KEY output of deploy.yaml's changes job")
  [ "$(yq '.jobs.notify.needs | any_c(. == strenv(ROOT))' "$workflows/deploy.yaml")" = true ] ||
    missing+=("$ROOT in deploy.yaml's notify needs")
  [ "$(yq '[.jobs[].strategy.matrix.root[]?] | any_c(. == strenv(ROOT_PATH))' "$workflows/drift.yaml")" = true ] ||
    missing+=("an entry in drift.yaml's matrix")
  for item in "${missing[@]}"; do
    echo "::error::$ROOT_PATH lacks $item."
    status=1
  done
done
exit "$status"

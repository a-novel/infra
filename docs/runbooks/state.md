# State

Each root's state is one object in `$STATE/<prefix>/default.tfstate`: `bootstrap`, `foundation`,
`json-keys` or `authentication`. The bucket keeps prior versions for 90 days and deleted objects for
7 days. State holds no secret values, but it is private: never paste it anywhere.

## Remove a stale lock

A cancelled deploy can leave `default.tflock` behind, and the next run then fails with "Error
acquiring the state lock".

1. Make sure no `deploy` run is in progress:

   ```bash
   gh run list --repo a-novel/infra --workflow deploy.yaml --limit 3
   ```

2. Delete the lock, then re-run the failed deploy:

   ```bash
   gcloud storage rm "$STATE/foundation/default.tflock"
   ```

## Restore an older version

Use this only when a state object is corrupt or was overwritten. Resources themselves are not
affected.

1. Freeze deploys: `gh workflow disable deploy.yaml --repo a-novel/infra`.
2. List the versions, newest first, and choose one:

   ```bash
   OBJ="$STATE/foundation/default.tfstate"
   gcloud storage ls -a -l "$OBJ" | sort -k2 -r | head
   ```

3. Copy it over the live object. The precondition makes the copy fail if someone wrote in the
   meantime.

   ```bash
   LIVE=<current generation>; OLD=<chosen generation>
   gcloud storage cp "$OBJ#$OLD" "$OBJ" --if-generation-match="$LIVE"
   ```

4. Check the result by running `drift` by hand (`gh workflow run drift.yaml --repo a-novel/infra`).
   The plan should show only what changed since that version. Fix any remaining differences with a
   pull request.
5. Re-enable deploys.

To undo, repeat step 3 with the generation you replaced.

## Move, adopt or forget a resource

Do it in code, in a pull request, and let the plan prove it:

- `moved { from = …; to = … }` renames an address in the same state;
- `import { to = …; id = "…" }` adopts an existing resource;
- `removed { from = …; lifecycle { destroy = false } }` forgets a resource without deleting it. It
  needs the deletion label.

Delete `import` blocks once they are applied.

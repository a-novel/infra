import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const foundation = new URL(
  "../environments/production/foundation/",
  import.meta.url,
);

test("every firewall declaration waits for the managed write grant", () => {
  const network = readFileSync(new URL("network.tf", foundation), "utf8");
  const firewalls = network
    .split(/(?=^resource )/m)
    .filter((block) => block.startsWith('resource "google_compute_firewall"'));
  assert.equal(firewalls.length, 5);
  for (const firewall of firewalls) {
    assert.match(
      firewall,
      /depends_on\s*=\s*\[google_project_iam_member\.foundation_firewall\]/,
      firewall.split("\n")[0],
    );
  }
});

test("the firewall binding uses the managed role in the selected workload", () => {
  const iam = readFileSync(new URL("firewall-iam.tf", foundation), "utf8");
  const binding = iam.split(
    'resource "google_project_iam_member" "foundation_firewall"',
  )[1];
  assert.ok(binding);
  assert.match(
    binding,
    /role\s*=\s*google_project_iam_custom_role\.foundation_firewall\.name/,
  );
  assert.match(binding, /project\s*=\s*google_project\.workload\.project_id/);
});

const repairGuide = readFileSync(
  new URL(
    "../docs/runbooks/repair-foundation-firewall-access.md",
    import.meta.url,
  ),
  "utf8",
);

test("firewall repair commands parse without executing cloud operations", () => {
  const blocks = [...repairGuide.matchAll(/```sh\n([\s\S]*?)\n```/g)];
  assert.ok(blocks.length > 0);
  for (const [, body] of blocks) {
    const result = spawnSync("zsh", ["-fn"], { input: body, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
  }
});

test("the temporary grant matches the managed writes and has bounded cleanup", () => {
  const iam = readFileSync(new URL("firewall-iam.tf", foundation), "utf8");
  const managedPermissions = [...iam.matchAll(/"(compute\.[^"]+)"/g)].map(
    ([, permission]) => permission,
  );
  const temporaryPermissions = repairGuide
    .match(/--permissions=([^\s]+)/)[1]
    .split(",");
  assert.deepEqual(temporaryPermissions.sort(), managedPermissions.sort());
  assert.match(repairGuide, /date -u -d '\+1 hour'/);
  assert.match(repairGuide, /expression=request\.time < timestamp/);
  for (const operation of ["add", "remove"]) {
    assert.match(
      repairGuide,
      new RegExp(
        `gcloud projects ${operation}-iam-policy-binding[^\\n]+--condition="\\$\\{FIREWALL_REPAIR_CONDITION:\\?\\}"`,
      ),
    );
  }
  assert.match(
    repairGuide,
    /gcloud iam roles delete "\$\{FIREWALL_REPAIR_ROLE_ID:\?\}"/,
  );
});

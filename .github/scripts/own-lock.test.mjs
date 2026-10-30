import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { ownLock } from "./own-lock.mjs";

const runner = "runner@runnervm48cm3";

// What tofu printed when it failed on a lock, as deploy run 41141960360's Studio plan did on its
// own: the lock's object was created at 23:05:34.5, and tofu reported it six minutes later.
const failed = (summary, message, who) => `
Error: ${summary}

Error message: ${message}
Lock Info:
  ID:        1793401534526162
  Path:      gs://a-novel-management-prod-232403541574-tofu-state/studio/default.tflock
  Operation: OperationTypePlan
  Who:       ${who}
  Version:   1.13.2
  Created:   2026-10-30 23:05:34.143509882 +0000 UTC
  Info:


OpenTofu acquires a state lock to protect the state from being written
by multiple users at the same time.
`;
const acquiring = (who) =>
  failed(
    "Error acquiring the state lock",
    `writing
"gs://a-novel-management-prod-232403541574-tofu-state/studio/default.tflock"
failed: googleapi: Error 412: At least one of the pre-conditions you
specified did not hold., conditionNotMet`,
    who,
  );

describe("ownLock", () => {
  for (const [name, output, lock] of [
    [
      "returns a lock this runner failed to acquire",
      acquiring(runner),
      "1793401534526162",
    ],
    [
      "returns a lock this runner failed to release",
      failed(
        "Error releasing the state lock",
        "googleapi: Error 503: We encountered an internal error., backendError",
        runner,
      ),
      "1793401534526162",
    ],
    [
      "ignores a lock another writer holds",
      acquiring("kushuh@laptop"),
      undefined,
    ],
    [
      "ignores an error without a lock",
      'Error: Failed to get existing workspaces: "code": 503',
      undefined,
    ],
  ]) {
    it(name, () => {
      assert.equal(ownLock(output, runner), lock);
    });
  }
});

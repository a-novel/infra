import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { assert as assertRepository, settings } from "./repository-asserts.mjs";

// A repository holding each setting's value, except the overrides, keyed by endpoint. It records
// every request.
function repository(overrides = {}) {
  const calls = [];
  const request = async (method, path, body) => {
    calls.push(body === undefined ? [method, path] : [method, path, body]);
    const setting = settings.find(
      (setting) => path === `repos/a-novel/infra${setting.endpoint}`,
    );
    return { [setting.field]: overrides[setting.endpoint] ?? setting.value };
  };
  return { calls, request };
}

const drifted = {
  "/code-scanning/default-setup": "configured",
  "": "all",
};

describe("assert", () => {
  it("reads every setting and writes nothing when the repository holds each value", async () => {
    const { calls, request } = repository();

    assert.deepEqual(
      await assertRepository(request, "a-novel/infra", true),
      [],
    );
    assert.deepEqual(calls, [
      ["GET", "repos/a-novel/infra/code-scanning/default-setup"],
      ["GET", "repos/a-novel/infra/code-quality/setup"],
      [
        "GET",
        "repos/a-novel/infra/actions/permissions/fork-pr-contributor-approval",
      ],
      ["GET", "repos/a-novel/infra"],
    ]);
  });

  it("writes back each setting that differs, with apply", async () => {
    const { calls, request } = repository(drifted);

    const found = await assertRepository(request, "a-novel/infra", true);
    assert.deepEqual(
      found.map(({ name, live }) => [name, live]),
      [
        ["code scanning default setup", "configured"],
        ["pull request creation", "all"],
      ],
    );
    assert.deepEqual(calls.slice(4), [
      [
        "PATCH",
        "repos/a-novel/infra/code-scanning/default-setup",
        { state: "not-configured" },
      ],
      [
        "PATCH",
        "repos/a-novel/infra",
        { pull_request_creation_policy: "collaborators_only" },
      ],
    ]);
  });

  it("only reads without apply, as the drift check runs it", async () => {
    const { calls, request } = repository(drifted);

    assert.equal(
      (await assertRepository(request, "a-novel/infra", false)).length,
      2,
    );
    assert.ok(calls.every(([method]) => method === "GET"));
  });
});

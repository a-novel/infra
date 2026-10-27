import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { organizationApi, record, releases } from "./sentry-deploys.mjs";

const digest = `sha256:${"a".repeat(64)}`;
const copy = (path, tag, extra = {}) => ({
  source: `ghcr.io/a-novel/${path}:${tag}@${digest}`,
  producer: `a-novel/${path.split("/")[0]}`,
  target: "unused",
  ...extra,
});
const pins = (...copies) => ({
  planned_values: { outputs: { image_copies: { value: copies } } },
});

describe("releases", () => {
  it("names each release the root pins once, after its repository", () => {
    assert.deepEqual(
      releases(
        pins(
          copy("service-authentication/rest", "v2.18.4"),
          copy("service-authentication/jobs/migrations", "v2.18.4"),
          copy("service-authentication/database", "v2.18.4"),
        ),
      ),
      ["service-authentication@2.18.4"],
    );
  });

  it("skips images no release built", () => {
    assert.deepEqual(
      releases(
        pins(
          copy("infra/host-credentials", "sha-fd585ed-1", {
            workflow: "publish-rollout-verifier.yaml",
          }),
        ),
      ),
      [],
    );
    assert.deepEqual(releases({}), []);
  });
});

describe("organizationApi", () => {
  const token = (claims) =>
    `sntrys_${Buffer.from(JSON.stringify(claims)).toString("base64")}_c2VjcmV0`;

  it("reads the organization and its region from the token", () => {
    assert.equal(
      organizationApi(
        token({
          iat: 1,
          url: "https://sentry.io/",
          region_url: "https://de.sentry.io",
          org: "a-novel",
        }),
      ),
      "https://de.sentry.io/api/0/organizations/a-novel",
    );
    assert.equal(
      organizationApi(token({ iat: 1, url: "https://sentry.io/", org: "a" })),
      "https://sentry.io/api/0/organizations/a",
    );
  });

  it("refuses any other token", () => {
    assert.throws(() => organizationApi("sntryu_0123456789abcdef"));
  });
});

describe("record", () => {
  // A fake organization API: GET answers with the release's deploys, POST records one.
  const api = (deploys, { list = 200, create = 201 } = {}) => {
    const calls = [];
    const request = async (method, path, body) => {
      calls.push(body ? [method, path, body] : [method, path]);
      if (method === "GET")
        return {
          status: list,
          ok: list < 300,
          json: async () => deploys.map((environment) => ({ environment })),
        };
      return { status: create, ok: create < 300 };
    };
    return { calls, request };
  };
  const path = "/releases/service-authentication%402.18.4/deploys/";

  it("records a production deploy for a release that has none", async () => {
    const { calls, request } = api(["staging"]);
    const log = [];
    await record(["service-authentication@2.18.4"], request, (line) =>
      log.push(line),
    );
    assert.deepEqual(calls, [
      ["GET", path],
      [
        "POST",
        path,
        { environment: "production", projects: ["service-authentication"] },
      ],
    ]);
    assert.deepEqual(log, [
      "Recorded the production deploy of service-authentication@2.18.4.",
    ]);
  });

  it("records nothing for a release already deployed", async () => {
    const { calls, request } = api(["production"]);
    await record(["service-authentication@2.18.4"], request, () => {});
    assert.deepEqual(calls, [["GET", path]]);
  });

  it("warns and moves on when Sentry lacks the release or fails", async () => {
    for (const [answers, warning] of [
      [{ list: 404 }, /has no release service-authentication@2\.18\.4/],
      [{ list: 503 }, /listing its deploys: HTTP 503/],
      [{ create: 400 }, /recording the deploy: HTTP 400/],
    ]) {
      const { calls, request } = api([], answers);
      const log = [];
      await record(
        ["service-authentication@2.18.4", "service-genai@0.7.4"],
        request,
        (line) => log.push(line),
      );
      assert.match(log[0], /^::warning::/);
      assert.match(log[0], warning);
      // The next release is still recorded or tried.
      assert(
        calls.some(([, called]) => called.includes("service-genai%400.7.4")),
      );
    }
  });

  it("warns when Sentry cannot be reached", async () => {
    const log = [];
    await record(
      ["service-authentication@2.18.4"],
      async () => {
        throw new Error("fetch failed");
      },
      (line) => log.push(line),
    );
    assert.deepEqual(log, [
      "::warning::Sentry deploy of service-authentication@2.18.4: fetch failed.",
    ]);
  });
});

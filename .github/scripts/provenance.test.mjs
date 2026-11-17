import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { describe, it } from "node:test";

import { attestationArgs, checks } from "./provenance.mjs";

const digest = (letter) => `sha256:${letter.repeat(64)}`;
const grpc = (tag, letter) =>
  `ghcr.io/a-novel/service-json-keys/grpc:${tag}@${digest(letter)}`;
const migrations = (tag, letter) =>
  `ghcr.io/a-novel/service-json-keys/jobs/migrations:${tag}@${digest(letter)}`;
const credentials = `ghcr.io/a-novel/infra/host-credentials:sha-fd585ed-37551742865-1@${digest("c")}`;
const copy = (source, extra = {}) => ({
  source,
  producer: "a-novel/service-json-keys",
  target: "unused",
  ...extra,
});
const plan = (before, after) => ({
  output_changes: {
    image_copies: { before: before?.map((source) => copy(source)) ?? null },
  },
  planned_values: { outputs: { image_copies: { value: after } } },
});

describe("checks", () => {
  it("verifies every image of a new root against its release tag", () => {
    assert.deepEqual(
      checks(
        plan(null, [
          copy(grpc("v2.10.4", "a")),
          copy(migrations("v2.10.4", "b")),
        ]),
      ),
      [
        {
          source: grpc("v2.10.4", "a"),
          subject: `oci://ghcr.io/a-novel/service-json-keys/grpc@${digest("a")}`,
          producer: "a-novel/service-json-keys",
          workflow: "release.yaml",
          tag: "v2.10.4",
        },
        {
          source: migrations("v2.10.4", "b"),
          subject: `oci://ghcr.io/a-novel/service-json-keys/jobs/migrations@${digest("b")}`,
          producer: "a-novel/service-json-keys",
          workflow: "release.yaml",
          tag: "v2.10.4",
        },
      ],
    );
  });

  it("skips the pins the last apply deployed, and checks each new source once", () => {
    const deployed = grpc("v2.10.4", "a");
    const next = migrations("v2.10.5", "d");
    const result = checks(
      plan(
        [deployed],
        [copy(deployed), copy(next), copy(next, { target: "another" })],
      ),
    );
    assert.deepEqual(
      result.map((check) => check.source),
      [next],
    );
  });

  it("verifies a non-release image against its producer's workflow on master", () => {
    const [check] = checks(
      plan(
        [],
        [
          copy(credentials, {
            producer: "a-novel/infra",
            workflow: "publish-rollout-verifier.yaml",
          }),
        ],
      ),
    );
    assert.equal(check.workflow, "publish-rollout-verifier.yaml");
    assert.equal(
      check.subject,
      `oci://ghcr.io/a-novel/infra/host-credentials@${digest("c")}`,
    );
  });

  it("treats a null workflow as a release", () => {
    assert.equal(
      checks(plan([], [copy(grpc("v2.10.4", "a"), { workflow: null })]))[0]
        .workflow,
      "release.yaml",
    );
  });

  it("refuses to lower a deployed release, per image", () => {
    assert.throws(
      () => checks(plan([grpc("v2.10.4", "a")], [copy(grpc("v2.9.9", "e"))])),
      /grpc:v2\.9\.9@.* lowers ghcr\.io\/a-novel\/service-json-keys\/grpc from v2\.10\.4/,
    );
    // Another image's newer version is not a floor for this one.
    assert.equal(
      checks(plan([migrations("v3.0.0", "f")], [copy(grpc("v2.10.4", "a"))]))
        .length,
      1,
    );
    // The same version with another digest is not a lowering.
    assert.equal(
      checks(plan([grpc("v2.10.4", "a")], [copy(grpc("v2.10.4", "e"))])).length,
      1,
    );
  });
});

describe("attestationArgs", () => {
  const flag = (args, name) => args[args.indexOf(name) + 1];

  it("admits a release tag's own release.yaml or main.yaml run, and no other signer", () => {
    const args = attestationArgs(
      checks(plan([], [copy(grpc("v2.10.4", "a"))]))[0],
    );
    const signer = new RegExp(flag(args, "--cert-identity-regex"));
    const identity = (repository, workflow) =>
      `https://github.com/a-novel/${repository}/.github/workflows/${workflow}@refs/tags/v2.10.4`;
    assert.ok(signer.test(identity("service-json-keys", "release.yaml")));
    assert.ok(signer.test(identity("service-json-keys", "main.yaml")));
    assert.ok(!signer.test(identity("service-json-keys", "gates.yaml")));
    assert.ok(!signer.test(identity("service-json-keys-fork", "main.yaml")));
    assert.ok(!signer.test(identity("service-genai", "release.yaml")));
    assert.ok(
      !signer.test(
        identity("service-json-keys", "main.yaml").replace(
          "v2.10.4",
          "v2.10.40",
        ),
      ),
    );
    assert.ok(
      !signer.test(
        identity("service-json-keys", "main.yaml").replace(
          "v2.10.4",
          "v2x10x4",
        ),
      ),
    );
    assert.equal(flag(args, "--source-ref"), "refs/tags/v2.10.4");
    assert.ok(args.includes("--deny-self-hosted-runners"));
  });

  it("admits only its producer's workflow on master for any other image", () => {
    const args = attestationArgs(
      checks(
        plan(
          [],
          [
            copy(credentials, {
              producer: "a-novel/infra",
              workflow: "publish-rollout-verifier.yaml",
            }),
          ],
        ),
      )[0],
    );
    assert.equal(
      flag(args, "--signer-workflow"),
      "a-novel/infra/.github/workflows/publish-rollout-verifier.yaml",
    );
    assert.equal(flag(args, "--source-ref"), "refs/heads/master");
    assert.ok(!args.includes("--cert-identity-regex"));
  });

  // A flag gh does not know would fail every plan's verification.
  it("passes only flags the installed gh attestation verify knows", () => {
    const help = execFileSync("gh", ["attestation", "verify", "--help"], {
      encoding: "utf8",
    });
    const known = new Set(help.match(/--[a-z-]+/g));
    for (const check of [
      checks(plan([], [copy(grpc("v2.10.4", "a"))]))[0],
      checks(
        plan(
          [],
          [
            copy(credentials, {
              producer: "a-novel/infra",
              workflow: "publish-rollout-verifier.yaml",
            }),
          ],
        ),
      )[0],
    ]) {
      for (const flag of attestationArgs(check).filter((arg) =>
        arg.startsWith("--"),
      ))
        assert.ok(known.has(flag), flag);
    }
  });
});

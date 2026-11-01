import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { branchVersion, paths, pins, rewrite, run } from "./pin-release.mjs";

const old = `sha256:${"a".repeat(64)}`;
const fresh = `sha256:${"b".repeat(64)}`;

describe("branchVersion", () => {
  it("reads the release a pin commit names", () => {
    assert.equal(
      branchVersion(
        "chore(deps): update service-genai images to v0.5.1\n\nbody",
      ),
      "v0.5.1",
    );
  });

  it("ignores any other commit", () => {
    assert.equal(
      branchVersion("chore(deps): update dependency renovate to v44.163.0"),
      "",
    );
    assert.equal(
      branchVersion("fix: chore(deps): update service-genai images to v0.5.1"),
      "",
    );
    assert.equal(branchVersion(""), "");
  });
});

describe("pins", () => {
  it("finds every image of a source, and only of it", () => {
    const content = [
      `grpc = "ghcr.io/a-novel/service-json-keys/grpc:v2.10.4@${old}"`,
      `migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.10.4@${old}"`,
      `rest = "ghcr.io/a-novel/service-json-keys-legacy/rest:v1.0.0@${old}"`,
      `credentials = "ghcr.io/a-novel/infra/host-credentials:sha-1@${old}"`,
    ].join("\n");
    assert.deepEqual(pins(content, "a-novel/service-json-keys"), [
      ["ghcr.io/a-novel/service-json-keys/grpc", "v2.10.4"],
      ["ghcr.io/a-novel/service-json-keys/jobs/migrations", "v2.10.4"],
    ]);
  });
});

describe("rewrite", () => {
  const image = "ghcr.io/a-novel/service-json-keys/database";

  it("moves a digest pin to the new version and digest", () => {
    assert.equal(
      rewrite(`database = "${image}:v2.10.4@${old}"`, image, "v2.11.0", fresh),
      `database = "${image}:v2.11.0@${fresh}"`,
    );
  });

  it("leaves other images alone", () => {
    const other = `replica = "${image}-replica:v2.10.4@${old}"\ngrpc = "ghcr.io/a-novel/service-json-keys/grpc:v2.10.4@${old}"`;
    assert.equal(rewrite(other, image, "v2.11.0", fresh), other);
  });
});

describe("committed pins", () => {
  // Git refuses to merge edits to adjacent lines, so concurrent release pull requests conflict
  // when two repositories' pins touch.
  it("keep a line between the pins of different repositories", () => {
    for (const file of run("git", ["ls-files", "--", ...paths]).split("\n")) {
      const owners = readFileSync(file, "utf8")
        .split("\n")
        .map((line) => /ghcr\.io\/([a-z0-9-]+\/[a-z0-9-]+)/.exec(line)?.[1]);
      owners.forEach((owner, index) => {
        const previous = owners[index - 1];
        assert.ok(
          !owner || !previous || owner === previous,
          `${file}:${index + 1} pins ${owner} next to ${previous}.`,
        );
      });
    }
  });
});

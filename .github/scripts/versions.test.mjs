import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { isRelease, newest } from "./versions.mjs";

describe("newest", () => {
  it("compares each part as a number", () => {
    assert.equal(newest("v2.9.0", "v2.10.0"), "v2.10.0");
    assert.equal(newest("v2.10.4", "v2.10.10", "v2.10.9"), "v2.10.10");
    assert.equal(newest("v3.0.0", "v2.99.99"), "v3.0.0");
    assert.equal(newest("v1.2.3", "v1.2.3"), "v1.2.3");
  });

  it("ignores empty versions", () => {
    assert.equal(newest("", "v1.0.0", ""), "v1.0.0");
    assert.equal(newest("", ""), "");
  });
});

describe("isRelease", () => {
  it("accepts only vX.Y.Z", () => {
    assert.ok(isRelease("v0.5.0"));
    for (const version of [
      "",
      "0.5.0",
      "v0.5",
      "v0.5.0-rc.1",
      "latest",
      "v0.5.0\nv9.9.9",
    ]) {
      assert.ok(!isRelease(version), version);
    }
  });
});

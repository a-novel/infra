import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { subtract } from "./google-service-ranges.mjs";

describe("subtract", () => {
  it("keeps a range nothing excludes", () => {
    assert.deepEqual(subtract(["8.8.4.0/24"], ["10.0.0.0/8"]), ["8.8.4.0/24"]);
  });

  it("drops a range an exclusion covers", () => {
    assert.deepEqual(subtract(["34.76.0.0/16"], ["34.64.0.0/10"]), []);
  });

  it("splits a range around a hole into the fewest aligned blocks", () => {
    assert.deepEqual(subtract(["10.0.0.0/24"], ["10.0.0.64/26"]), [
      "10.0.0.0/26",
      "10.0.0.128/25",
    ]);
    assert.deepEqual(subtract(["10.0.0.0/30"], ["10.0.0.1/32"]), [
      "10.0.0.0/32",
      "10.0.0.2/31",
    ]);
  });

  it("joins overlapping and adjacent inputs, and sorts the result", () => {
    assert.deepEqual(
      subtract(["10.0.1.0/24", "10.0.0.0/24", "10.0.0.128/25"], []),
      ["10.0.0.0/23"],
    );
  });

  it("applies one exclusion to every range it spans", () => {
    assert.deepEqual(
      subtract(
        ["10.0.0.0/26", "10.0.0.128/26"],
        ["10.0.0.32/27", "10.0.0.64/26", "10.0.0.128/27"],
      ),
      ["10.0.0.0/27", "10.0.0.160/27"],
    );
  });

  it("handles addresses at and above 2^31", () => {
    assert.deepEqual(subtract(["128.0.0.0/1"], ["192.0.0.0/2"]), [
      "128.0.0.0/2",
    ]);
    assert.deepEqual(subtract(["255.255.255.254/31"], ["255.255.255.254/32"]), [
      "255.255.255.255/32",
    ]);
  });
});

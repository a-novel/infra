import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { next } from "./refresh-google-ranges.mjs";

describe("next", () => {
  it("does nothing while master holds Google's list and no pull request is open", () => {
    assert.equal(
      next({ master: "a", latest: "a", proposed: undefined }),
      "none",
    );
  });

  it("closes a pull request once master holds Google's list again", () => {
    assert.equal(next({ master: "a", latest: "a", proposed: "b" }), "close");
  });

  it("keeps a pull request that already proposes Google's list, so its checks are not restarted", () => {
    assert.equal(next({ master: "a", latest: "b", proposed: "b" }), "keep");
  });

  it("pushes Google's list to a new or outdated pull request", () => {
    assert.equal(
      next({ master: "a", latest: "b", proposed: undefined }),
      "push",
    );
    assert.equal(next({ master: "a", latest: "c", proposed: "b" }), "push");
  });
});

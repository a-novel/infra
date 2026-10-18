import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { approvedAtMerge, label } from "./deletion-approval.mjs";

const admin = { login: "kushuh", type: "User" };
const writer = { login: "someone", type: "User" };
const trusted = (actor) => actor === admin;
const merged = "2026-10-18T12:39:28Z";
const event = (kind, actor, at, name = label) => ({
  event: kind,
  label: { name },
  actor,
  created_at: at,
});

describe("approvedAtMerge", () => {
  it("counts a label a maintainer applied before the merge", () => {
    assert.equal(
      approvedAtMerge(
        [event("labeled", admin, "2026-10-18T12:33:19Z")],
        merged,
        trusted,
      ),
      true,
    );
  });

  it("ignores a label applied after the merge", () => {
    assert.equal(
      approvedAtMerge(
        [event("labeled", admin, "2026-10-18T13:00:00Z")],
        merged,
        trusted,
      ),
      false,
    );
  });

  it("ignores a label removed before the merge", () => {
    const events = [
      event("labeled", admin, "2026-10-18T12:00:00Z"),
      event("unlabeled", admin, "2026-10-18T12:30:00Z"),
    ];
    assert.equal(approvedAtMerge(events, merged, trusted), false);
  });

  it("reads only the last application before the merge", () => {
    const relabeled = [
      event("labeled", admin, "2026-10-18T12:00:00Z"),
      event("unlabeled", writer, "2026-10-18T12:10:00Z"),
    ];
    assert.equal(
      approvedAtMerge(
        [...relabeled, event("labeled", writer, "2026-10-18T12:20:00Z")],
        merged,
        trusted,
      ),
      false,
    );
    assert.equal(
      approvedAtMerge(
        [...relabeled, event("labeled", admin, "2026-10-18T12:20:00Z")],
        merged,
        trusted,
      ),
      true,
    );
  });

  it("ignores other labels and other events", () => {
    const events = [
      event("labeled", admin, "2026-10-18T12:00:00Z", "allow-downtime"),
      {
        event: "review_requested",
        actor: admin,
        created_at: "2026-10-18T12:05:00Z",
      },
    ];
    assert.equal(approvedAtMerge(events, merged, trusted), false);
    assert.equal(approvedAtMerge([], merged, trusted), false);
  });
});

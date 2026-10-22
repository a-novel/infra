import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import {
  chmodSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

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

describe("the command line", () => {
  it("denies deletions with a warning when GitHub keeps failing", (t) => {
    const bin = mkdtempSync(join(tmpdir(), "deletion-approval-"));
    t.after(() => rmSync(bin, { recursive: true, force: true }));
    writeFileSync(
      join(bin, "gh"),
      `#!/bin/sh\necho "$*" >> "${bin}/calls"\necho "unexpected end of JSON input" >&2\nexit 1\n`,
    );
    chmodSync(join(bin, "gh"), 0o755);

    const run = spawnSync(
      process.execPath,
      [
        fileURLToPath(new URL("deletion-approval.mjs", import.meta.url)),
        "7e1e237",
      ],
      {
        encoding: "utf8",
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          REPOSITORY: "a-novel/infra",
        },
      },
    );

    assert.equal(run.status, 0);
    assert.equal(run.stdout, "false\n");
    assert.match(run.stderr, /^::warning::Deletions stay blocked/);
    assert.equal(
      readFileSync(join(bin, "calls"), "utf8").trim().split("\n").length,
      3,
    );
  });
});

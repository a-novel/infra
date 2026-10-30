import assert from "node:assert/strict";
import { createVerify, generateKeyPairSync } from "node:crypto";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, it } from "node:test";

import { appJwt, copy, plan } from "./secret-sync.mjs";

const day = (n) => new Date(Date.UTC(2026, 9, n));

describe("plan", () => {
  it("writes a secret the environment lacks", () => {
    assert.deepEqual(
      plan(["AGENT_BOT_PRIVATE_KEY"], {}, { AGENT_BOT_PRIVATE_KEY: day(1) }),
      {
        write: ["AGENT_BOT_PRIVATE_KEY"],
        remove: [],
      },
    );
  });

  it("rewrites a copy older than its pinned version, and leaves a newer one", () => {
    assert.deepEqual(
      plan(
        ["AGENT_BOT_PRIVATE_KEY", "BWS_READ_TOKEN"],
        { AGENT_BOT_PRIVATE_KEY: day(1), BWS_READ_TOKEN: day(3) },
        { AGENT_BOT_PRIVATE_KEY: day(2), BWS_READ_TOKEN: day(2) },
      ),
      { write: ["AGENT_BOT_PRIVATE_KEY"], remove: [] },
    );
  });

  it("deletes each secret no workflow names", () => {
    assert.deepEqual(
      plan(
        ["BWS_READ_TOKEN"],
        { BWS_READ_TOKEN: day(3), OLD_KEY: day(1), ANOTHER: day(1) },
        { BWS_READ_TOKEN: day(2) },
      ),
      { write: [], remove: ["ANOTHER", "OLD_KEY"] },
    );
  });
});

describe("appJwt", () => {
  it("signs a token the App's public key verifies, valid for 10 minutes from a minute ago", () => {
    const { privateKey, publicKey } = generateKeyPairSync("rsa", {
      modulusLength: 2048,
      privateKeyEncoding: { type: "pkcs1", format: "pem" },
      publicKeyEncoding: { type: "spki", format: "pem" },
    });
    const token = appJwt(5544096, privateKey, Date.UTC(2026, 9, 30, 21));
    const [header, claims, signature] = token.split(".");

    assert.ok(
      createVerify("RSA-SHA256")
        .update(`${header}.${claims}`)
        .verify(publicKey, signature, "base64url"),
    );
    assert.deepEqual(JSON.parse(Buffer.from(header, "base64url")), {
      alg: "RS256",
      typ: "JWT",
    });
    const { iat, exp, iss } = JSON.parse(Buffer.from(claims, "base64url"));
    assert.equal(iss, "5544096");
    assert.equal(exp - iat, 600);
    assert.equal(iat, Date.UTC(2026, 9, 30, 21) / 1000 - 60);
  });
});

describe("copy", () => {
  let bin, path;
  const stub = (name, body) => {
    writeFileSync(join(bin, name), `#!/usr/bin/env bash\n${body}\n`);
    chmodSync(join(bin, name), 0o755);
  };

  beforeEach(() => {
    bin = mkdtempSync(join(tmpdir(), "secret-sync-"));
    path = process.env.PATH;
    process.env.PATH = `${bin}:${path}`;
    // gh records what it received: its arguments, its token and its stdin.
    stub(
      "gh",
      `printf '%s\\n' "$*" "$GH_TOKEN" >"${bin}/gh.args"; cat >"${bin}/gh.stdin"`,
    );
  });

  afterEach(() => {
    process.env.PATH = path;
  });

  it("pipes the pinned version's payload into the environment, untouched", () => {
    stub(
      "gcloud",
      `[ "$*" = "secrets versions access 2 --secret=production-github-governance-a-novel-agent-bot-private-key --project=management" ] && printf -- '-----BEGIN KEY-----\\nabc\\n-----END KEY-----\\n'`,
    );
    copy(
      "management",
      {
        secret: "production-github-governance-a-novel-agent-bot-private-key",
        version: 2,
      },
      "a-novel/infra",
      "AGENT_BOT_PRIVATE_KEY",
      "installation-token",
    );
    assert.equal(
      readFileSync(join(bin, "gh.stdin"), "utf8"),
      "-----BEGIN KEY-----\nabc\n-----END KEY-----\n",
    );
    assert.equal(
      readFileSync(join(bin, "gh.args"), "utf8"),
      "secret set AGENT_BOT_PRIVATE_KEY --env governance --repo a-novel/infra\ninstallation-token\n",
    );
  });

  it("fails when gcloud cannot read the version, whatever gh does", () => {
    stub("gcloud", "exit 1");
    assert.throws(
      () =>
        copy(
          "management",
          { secret: "missing", version: 1 },
          "a-novel/infra",
          "BWS_READ_TOKEN",
          "token",
        ),
      /copy BWS_READ_TOKEN into a-novel\/infra failed/,
    );
  });
});

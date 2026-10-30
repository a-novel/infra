import assert from "node:assert/strict";
import { createVerify, generateKeyPairSync } from "node:crypto";
import { describe, it } from "node:test";

import { appJwt, plan } from "./secret-sync.mjs";

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

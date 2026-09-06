import assert from "node:assert/strict";
import { execFile as execFileCallback } from "node:child_process";
import {
  chmod,
  mkdtemp,
  mkdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFile = promisify(execFileCallback);
const restore = await readFile(
  new URL(
    "../environments/production/release/scripts/postgres-restore.sh",
    import.meta.url,
  ),
  "utf8",
);
const cleanup = restore.slice(
  restore.indexOf("cleanup() {"),
  restore.indexOf("for variable_name"),
);
const startup = restore
  .slice(
    restore.indexOf("install -d -m 0700"),
    restore.indexOf("export PGDATABASE="),
  )
  .replaceAll(
    "/usr/local/bin/docker-entrypoint.sh",
    '"${FIXTURE_DIRECTORY}/entrypoint"',
  )
  .replace("SECONDS + 120", "SECONDS + 2");
assert.ok(cleanup.includes("trap cleanup EXIT"));
assert.ok(startup.includes("READY_DEADLINE="));

for (const scenario of ["ready", "crash", "missing-pid", "unready"]) {
  test(`restore startup: ${scenario}`, async (context) => {
    const directory = await mkdtemp(
      path.join(os.tmpdir(), "infra-restore-startup-"),
    );
    context.after(() => rm(directory, { recursive: true, force: true }));
    const binaryDirectory = path.join(directory, "bin");
    await mkdir(binaryDirectory);
    await writeFile(path.join(directory, "events"), "");

    const executables = {
      "bin/install": 'mkdir -p "$PGDATA"',
      "bin/gosu": 'printf "stop-server\\n" >>"$FIXTURE_DIRECTORY/events"',
      "bin/pg_isready": `
if [ -f "$FIXTURE_DIRECTORY/final-started" ]; then
    printf 'probe-final\\n' >>"$FIXTURE_DIRECTORY/events"
else
    printf 'probe-temporary\\n' >>"$FIXTURE_DIRECTORY/events"
fi
[ "$FIXTURE_SCENARIO" != unready ]`,
      entrypoint: `
case "$FIXTURE_SCENARIO" in
    crash) exit 9 ;;
    missing-pid) exec sleep 30 ;;
esac
printf '0\\n' >"$PGDATA/postmaster.pid"
sleep 0.2
exec bash "$FIXTURE_DIRECTORY/final-server"`,
      "final-server": `
trap 'exit 0' TERM INT
touch "$FIXTURE_DIRECTORY/final-started"
printf '%s\\n' "$$" >"$PGDATA/postmaster.pid"
while :; do sleep 0.05; done`,
    };
    for (const [name, body] of Object.entries(executables)) {
      const filename = path.join(directory, name);
      await writeFile(filename, `#!/bin/bash\nset -euo pipefail\n${body}\n`);
      await chmod(filename, 0o700);
    }

    const harness = `set -euo pipefail
POSTGRES_PID=""
kill() {
    if [ "$1" != -0 ]; then
        printf 'stop-entrypoint\\n' >>"$FIXTURE_DIRECTORY/events"
    fi
    builtin kill "$@"
}
${cleanup}
${startup}
printf 'restore-ready\\n' >>"$FIXTURE_DIRECTORY/events"
`;
    const result = await execFile("bash", ["-c", harness], {
      env: {
        PATH: `${binaryDirectory}:${process.env.PATH}`,
        FIXTURE_DIRECTORY: directory,
        FIXTURE_SCENARIO: scenario,
        PGDATA: path.join(directory, "pgdata"),
        PGSOCKET: path.join(directory, "socket"),
        WORKSPACE: directory,
        DATABASE_NAME: "fixture",
        DATABASE_OWNER: "postgres",
      },
      timeout: 10_000,
    }).catch((error) => error);
    const events = (await readFile(path.join(directory, "events"), "utf8"))
      .trim()
      .split("\n");
    assert.ok(
      !events.includes("probe-temporary"),
      "temporary server must never satisfy readiness",
    );
    if (scenario === "ready") {
      assert.equal(result.code, undefined, result.stderr);
      assert.deepEqual(events, [
        "probe-final",
        "restore-ready",
        "stop-entrypoint",
        "stop-server",
      ]);
    } else {
      assert.equal(result.code, 1, result.stderr);
      assert.match(
        result.stderr,
        /clean restore database did not become ready/,
      );
      assert.ok(!events.includes("restore-ready"));
      if (scenario !== "crash") {
        assert.deepEqual(events.slice(-2), ["stop-entrypoint", "stop-server"]);
      }
    }
  });
}

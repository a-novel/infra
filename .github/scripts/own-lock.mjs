// The state lock a failed tofu command left behind as this runner's own. OpenTofu takes the lock
// by creating its object on condition that none exists, and Google's client retries a write whose
// answer it lost. When the lost write had succeeded, the retry fails on the lock it created, so tofu
// reports the lock as held, never releases it, and every later run of the root fails on it.
//
// tofu prints the lock it failed on, with its writer as user@host. A hosted runner's host name is
// its own, and its job runs one tofu command at a time, so once the command exits, a lock this
// runner wrote is stale.
import { readFileSync } from "node:fs";
import { hostname, userInfo } from "node:os";
import { fileURLToPath } from "node:url";

/** The ID of the lock that tofu's output names, when `who` wrote it. */
export function ownLock(output, who) {
  const fields = {};
  for (const line of (output.split("Lock Info:\n")[1] ?? "").split("\n")) {
    const field = /^ {2}(\w+): +(.*)$/.exec(line);
    if (!field) break;
    fields[field[1]] = field[2];
  }
  return fields.Who === who ? fields.ID : undefined;
}

function main([outputPath]) {
  const lock = ownLock(
    readFileSync(outputPath, "utf8"),
    `${userInfo().username}@${hostname()}`,
  );
  if (lock) console.log(lock);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`::error::${error.message}`);
    process.exit(1);
  }
}

// The planned downtime: the window downtime.yaml builds from its inputs, and the Discord posts it
// hands to Google Cloud Workflows. Both are pure functions of their inputs and the clock.
import { appendFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

// discord-post's palette (a-novel-kit/workflows) for the states these posts show.
const colors = {
  upcoming: 15844367,
  inProgress: 15105570,
  informational: 3447003,
  succeeded: 3066993,
  cancelled: 9807270,
};
// The post each change sends now, as its title and its color before the downtime starts.
const changes = {
  scheduled: ["🗓️ Planned downtime scheduled", colors.upcoming],
  extended: ["⏩ Planned downtime extended", colors.informational],
  rescheduled: ["🔁 Planned downtime rescheduled", colors.informational],
  ended: ["✅ Planned downtime ended", colors.succeeded],
  cancelled: ["✖️ Planned downtime cancelled", colors.cancelled],
};
const reminders = [
  [604800, "in 1 week"],
  [86400, "in 1 day"],
  [21600, "in 6 hours"],
  [1800, "in 30 minutes"],
];

// RFC 3339 UTC, the one format a window stores, so its times compare as strings.
const rfc3339 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const duration = /^(?:(\d+)d)?(?:(\d+)h)?(?:(\d+)m)?$/;

const seconds = (time) => Date.parse(time) / 1000;
const format = (epoch) =>
  new Date(epoch * 1000).toISOString().replace(".000Z", "Z");

/** A time in RFC 3339 UTC, or a duration such as 1d12h or 30m counted from base; null otherwise. */
export function epoch(value, base) {
  if (rfc3339.test(value)) return seconds(value);
  const match = value ? duration.exec(value) : null;
  if (!match) return null;
  const [days, hours, minutes] = match
    .slice(1)
    .map((part) => Number(part ?? 0));
  return base + ((days * 24 + hours) * 60 + minutes) * 60;
}

/**
 * The downtime to schedule. "*" names every known component, and naming none, or no start, keeps
 * the previous downtime's. A started downtime's start cannot move. Throws with the message to show.
 */
export function buildWindow({ components, start, end, previous, known, now }) {
  let names = components.split(/[\s,]+/).filter(Boolean);
  if (names.length === 1 && names[0] === "*") names = known;
  if (names.length === 0) names = previous?.components ?? [];
  if (names.length === 0) {
    throw new Error(
      'No downtime is scheduled, so components can\'t be empty: name them, or use "*" for all of them.',
    );
  }
  const unknown = names.find((name) => !known.includes(name));
  if (unknown)
    throw new Error(
      `Unknown component "${unknown}"; known: ${known.join(",")}.`,
    );

  const current = previous?.start ?? "";
  if (start && current && seconds(current) <= now) {
    throw new Error(
      `The downtime started at ${current}, so its start can't move. Leave start empty to keep it.`,
    );
  }
  const from = epoch(start || current, now);
  const to = from === null ? null : epoch(end, from);
  if (from === null || to === null || to <= from) {
    throw new Error(
      "A downtime needs a start and an end, each in RFC 3339 UTC or a duration such as 1d12h, with the end after the start.",
    );
  }
  // Sorted, so the same components always compare equal.
  return {
    components: [...new Set(names)].sort(),
    start: format(from),
    end: format(to),
  };
}

function body(window, headline) {
  const start = seconds(window.start);
  const end = seconds(window.end);
  const minutes = Math.floor((end - start) / 60);
  const length = [
    minutes >= 60 && `${Math.floor(minutes / 60)} h`,
    minutes % 60 && `${minutes % 60} min`,
  ]
    .filter(Boolean)
    .join(" ");
  return [
    ...(headline ? [headline, ""] : []),
    "**Affects**",
    ...window.components.map(affected),
    "",
    "**When**",
    `- **From** <t:${start}:F>`,
    `- **Back by** <t:${end}:F> *(expected)*`,
    `-# About ${length || "0 min"} · shown in your time zone`,
  ].join("\n");
}

/** A component's line in a post: service-json-keys.database reads as "json-keys database". */
function affected(component) {
  const [, name = component, part = ""] =
    /^service-(.+)\.([^.]+)$/.exec(component) ?? [];
  return `- **${name}** ${part}`;
}

function post(at, title, color, window, headline) {
  return {
    at,
    message: {
      embeds: [{ title, color, description: body(window, headline) }],
      allowed_mentions: { parse: [] },
    },
  };
}

/**
 * Every post a change from previous to window needs, in time order: the change itself now, then the
 * reminders still ahead. The countdowns are Discord timestamps, so a post written now still reads
 * right when it lands. Either side may be null.
 */
export function planAnnouncements({ previous, window, now }) {
  if (!window) {
    if (!previous) return [];
    const [title, color] =
      seconds(previous.start) <= now ? changes.ended : changes.cancelled;
    return [post(now, title, color, previous, "")];
  }
  const start = seconds(window.start);
  const countdown = `## Starts <t:${start}:R>`;
  const back = `## Expected back <t:${seconds(window.end)}:R>`;
  const started = now >= start;
  const [title, pending] = changes[change(previous, window)];
  // The color shows the same state as the headline: a started downtime is in progress.
  const color = started ? colors.inProgress : pending;
  const posts = [post(now, title, color, window, started ? back : countdown)];
  for (const [ahead, label] of reminders) {
    const at = start - ahead;
    if (at > now) {
      posts.push(
        post(
          at,
          `⏰ Planned downtime ${label}`,
          colors.upcoming,
          window,
          countdown,
        ),
      );
    }
  }
  if (start > now) {
    posts.push(
      post(
        start,
        "🚧 Planned downtime started",
        colors.inProgress,
        window,
        back,
      ),
    );
  }
  return posts;
}

/** How window changes previous: scheduled, extended or rescheduled. */
function change(previous, window) {
  if (!previous) return "scheduled";
  const extended =
    window.start === previous.start &&
    JSON.stringify(window.components) === JSON.stringify(previous.components) &&
    window.end > previous.end;
  return extended ? "extended" : "rescheduled";
}

const parse = (value) => (value ? JSON.parse(value) : null);

function main(command) {
  const {
    GITHUB_OUTPUT,
    OPERATION,
    COMPONENTS = "",
    START = "",
    END = "",
    PREVIOUS = "",
    WINDOW = "",
  } = process.env;
  const now = Math.floor(Date.now() / 1000);
  let output;
  if (command === "window") {
    // Each service root has a database that can be stopped.
    const known = readdirSync("environments/production", {
      withFileTypes: true,
    })
      .filter((entry) => entry.isDirectory() && entry.name !== "foundation")
      .map((entry) => `service-${entry.name}.database`)
      .sort();
    const window =
      OPERATION === "clear"
        ? null
        : buildWindow({
            components: COMPONENTS,
            start: START,
            end: END,
            previous: parse(PREVIOUS),
            known,
            now,
          });
    output = `window=${window ? JSON.stringify(window) : ""}\n`;
  } else if (command === "announcements") {
    const posts = planAnnouncements({
      previous: parse(PREVIOUS),
      window: parse(WINDOW),
      now,
    });
    output = `posts=${JSON.stringify({ posts })}\n`;
  } else {
    throw new Error(
      `Unknown command "${command}": use window or announcements.`,
    );
  }
  appendFileSync(GITHUB_OUTPUT, output);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv[2]);
  } catch (error) {
    console.log(`::error::${error.message}`);
    process.exit(1);
  }
}

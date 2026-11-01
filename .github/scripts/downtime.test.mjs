import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  buildWindow,
  epoch,
  knownComponents,
  planAnnouncements,
  startedFor,
} from "./downtime.mjs";

const known = [
  "service-authentication.database",
  "service-genai.database",
  "service-json-keys.database",
];
const now = Date.parse("2026-10-12T05:00:00Z") / 1000;
const build = (inputs) =>
  buildWindow({
    components: "",
    start: "",
    end: "",
    previous: null,
    known,
    now,
    ...inputs,
  });

describe("epoch", () => {
  it("reads RFC 3339 UTC and durations from a base", () => {
    assert.equal(epoch("2026-10-12T06:00:00Z", 0), now + 3600);
    assert.equal(epoch("1d12h30m", 100), 100 + 131400);
    assert.equal(epoch("45m", 100), 100 + 2700);
  });

  it("refuses anything else", () => {
    for (const value of [
      "",
      "2026-10-12 06:00",
      "2026-10-12T06:00:00+02:00",
      "1h1d",
      "90s",
      "1.5h",
    ]) {
      assert.equal(epoch(value, now), null, value);
    }
  });
});

describe("knownComponents", () => {
  it("names the database of each service root, and of no shared root", () => {
    assert.deepEqual(
      knownComponents([
        "json-keys",
        "cluster",
        "foundation",
        "authentication",
        "github",
        "grafana",
      ]),
      ["service-authentication.database", "service-json-keys.database"],
    );
  });
});

describe("buildWindow", () => {
  it("schedules named components after a delay, sorted", () => {
    assert.deepEqual(
      build({
        components:
          "service-json-keys.database, service-authentication.database",
        start: "2h",
        end: "1h30m",
      }),
      {
        components: [
          "service-authentication.database",
          "service-json-keys.database",
        ],
        start: "2026-10-12T07:00:00Z",
        end: "2026-10-12T08:30:00Z",
      },
    );
  });

  it("names every component with *", () => {
    assert.deepEqual(
      build({ components: "*", start: "2026-10-12T06:00:00Z", end: "1h" })
        .components,
      known,
    );
  });

  it("keeps the previous components and start when left empty", () => {
    const previous = {
      components: ["service-genai.database"],
      start: "2026-10-12T06:00:00Z",
      end: "2026-10-12T07:00:00Z",
    };
    assert.deepEqual(build({ end: "2026-10-12T09:00:00Z", previous }), {
      ...previous,
      end: "2026-10-12T09:00:00Z",
    });
  });

  it("refuses to move a started downtime's start", () => {
    const previous = {
      components: ["service-genai.database"],
      start: "2026-10-12T04:00:00Z",
      end: "2026-10-12T07:00:00Z",
    };
    assert.throws(
      () => build({ start: "1h", end: "1h", previous }),
      /started at 2026-10-12T04:00:00Z/,
    );
    assert.equal(build({ end: "3h", previous }).start, previous.start);
  });

  it("refuses unknown, missing or empty components", () => {
    assert.throws(
      () =>
        build({
          components: "service-narrative.database",
          start: "1h",
          end: "1h",
        }),
      /Unknown component/,
    );
    assert.throws(
      () => build({ start: "1h", end: "1h" }),
      /components can't be empty/,
    );
  });

  it("refuses a missing start or end, and an end before the start", () => {
    for (const [start, end] of [
      ["", "1h"],
      ["1h", ""],
      ["2026-10-12T06:00:00Z", "2026-10-12T06:00:00Z"],
      ["1h", "tomorrow"],
    ]) {
      assert.throws(
        () => build({ components: "*", start, end }),
        /needs a start and an end/,
        `${start} ${end}`,
      );
    }
  });
});

describe("startedFor", () => {
  const component = "service-json-keys.database";
  const downtime = (start) =>
    JSON.stringify({
      components: [component],
      start,
      end: "2026-10-12T09:00:00Z",
    });

  it("starts at its start for the components it lists", () => {
    for (const [start, started] of [
      ["2026-10-12T04:00:00Z", true],
      ["2026-10-12T05:00:00Z", true],
      ["2026-10-12T05:00:01Z", false],
    ]) {
      assert.equal(startedFor(downtime(start), component, now), started, start);
    }
    assert.equal(
      startedFor(
        downtime("2026-10-12T04:00:00Z"),
        "service-genai.database",
        now,
      ),
      false,
    );
  });

  it("has not started without a readable downtime and start", () => {
    for (const value of [
      "",
      "{",
      "null",
      JSON.stringify({ components: component, start: "2026-10-12T04:00:00Z" }),
      downtime(undefined),
      downtime(""),
      downtime("garbage"),
      downtime("2026-10-12 04:00"),
      downtime("2026-10-99T04:00:00Z"),
    ]) {
      assert.equal(startedFor(value, component, now), false, value);
    }
  });
});

describe("planAnnouncements", () => {
  const window = {
    components: ["service-json-keys.database"],
    start: "2026-10-20T05:00:00Z",
    end: "2026-10-20T06:30:00Z",
  };
  const titles = (posts) => posts.map((post) => post.message.embeds[0].title);

  it("announces a new downtime, then every reminder still ahead", () => {
    const posts = planAnnouncements({ previous: null, window, now });
    assert.deepEqual(titles(posts), [
      "🗓️ Planned downtime scheduled",
      "⏰ Planned downtime in 1 week",
      "⏰ Planned downtime in 1 day",
      "⏰ Planned downtime in 6 hours",
      "⏰ Planned downtime in 30 minutes",
      "🚧 Planned downtime started",
    ]);
    assert.deepEqual(
      posts.map((post) => post.at),
      [
        now,
        ...[604800, 86400, 21600, 1800, 0].map(
          (ahead) => Date.parse(window.start) / 1000 - ahead,
        ),
      ],
    );
    assert.deepEqual(posts[0].message.allowed_mentions, { parse: [] });
    assert.equal(
      posts[0].message.embeds[0].description,
      [
        `## Starts <t:${Date.parse(window.start) / 1000}:R>`,
        "",
        "**Affects**",
        "- **json-keys** database",
        "",
        "**When**",
        `- **From** <t:${Date.parse(window.start) / 1000}:F>`,
        `- **Back by** <t:${Date.parse(window.end) / 1000}:F> *(expected)*`,
        "-# About 1 h 30 min · shown in your time zone",
      ].join("\n"),
    );
  });

  it("tells an extension from a reschedule", () => {
    const later = { ...window, end: "2026-10-20T07:00:00Z" };
    assert.equal(
      titles(planAnnouncements({ previous: window, window: later, now }))[0],
      "⏩ Planned downtime extended",
    );
    const moved = { ...window, start: "2026-10-21T05:00:00Z" };
    assert.equal(
      titles(planAnnouncements({ previous: window, window: moved, now }))[0],
      "🔁 Planned downtime rescheduled",
    );
  });

  it("counts down to the end once the downtime started", () => {
    const started = Date.parse(window.start) / 1000 + 60;
    const inProgress = planAnnouncements({ previous: null, window, now }).at(-1)
      .message.embeds[0].color;
    // A downtime scheduled to start at once, then one extended while it runs.
    for (const previous of [null, window]) {
      const posts = planAnnouncements({
        previous,
        window: { ...window, end: "2026-10-20T08:00:00Z" },
        now: started,
      });
      assert.equal(posts.length, 1);
      assert.match(
        posts[0].message.embeds[0].description,
        /^## Expected back <t:\d+:R>/,
      );
      assert.equal(posts[0].message.embeds[0].color, inProgress);
    }
  });

  it("ends a started downtime and cancels one ahead", () => {
    assert.deepEqual(
      titles(planAnnouncements({ previous: window, window: null, now })),
      ["✖️ Planned downtime cancelled"],
    );
    const after = Date.parse(window.start) / 1000;
    assert.deepEqual(
      titles(planAnnouncements({ previous: window, window: null, now: after })),
      ["✅ Planned downtime ended"],
    );
    assert.deepEqual(
      planAnnouncements({ previous: null, window: null, now }),
      [],
    );
  });
});

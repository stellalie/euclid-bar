// node --test server/reports/test
import assert from "node:assert/strict";
import { test, beforeEach } from "node:test";
import { DatabaseSync } from "node:sqlite";
import worker, { publishStats } from "../src/reports.js";
import { PingStore, Pings, osMajor, statsMarkdown, validatePing } from "../src/pings.js";

/** node:sqlite behind the Durable Object `sql.exec(query, ...bindings).toArray()` API. */
function fakeSQL() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(q, ...b) {
      const s = db.prepare(q);
      const rows = s.columns().length ? s.all(...b) : (s.run(...b), []);
      return { toArray: () => rows.map((r) => ({ ...r })) };
    },
  };
}

const ping = { id: "0f8e4c1a-2b3d-4e5f-8a9b-0c1d2e3f4a5b", app: "1.3.0", build: "130", channel: "stable", os: "macOS 15.1.0", arch: "arm64" };
const other = { ...ping, id: "1f8e4c1a-2b3d-4e5f-8a9b-0c1d2e3f4a5b", app: "1.2.1", os: "macOS 26.0.1" };

test("accepts only what the app sends", () => {
  assert.deepEqual(validatePing({ ...ping }), ping);
  assert.throws(() => validatePing({ ...ping, email: "a@b.c" }), /unknown field email/);
  assert.throws(() => validatePing({ ...ping, id: "not-a-uuid" }), /id/);
  assert.throws(() => validatePing({ ...ping, id: ping.id.toUpperCase() }), /id/);
  assert.throws(() => validatePing({ ...ping, app: "<script>" }), /app/);
  assert.throws(() => validatePing([]), /not an object/);
  assert.equal(osMajor("macOS 15.1.0"), "macOS 15");
  assert.equal(osMajor("Windows"), "other");
});

test("counts each install once a day, keeps new and active apart", () => {
  const store = new PingStore(fakeSQL());
  store.record(ping, "2026-10-29");
  store.record(ping, "2026-10-30");
  store.record(ping, "2026-10-30"); // same day again: ignored
  store.record(other, "2026-10-31");
  store.record({ ...ping, app: "1.3.1" }, "2026-10-31");
  const s = store.stats("2026-10-31");
  assert.equal(s.installs, 2);
  assert.equal(s.active1, 2);
  assert.equal(s.active7, 2);
  assert.deepEqual(s.days.slice(0, 3), [
    { day: "2026-10-31", active: 2, new: 1 },
    { day: "2026-10-30", active: 1, new: 0 },
    { day: "2026-10-29", active: 1, new: 1 },
  ]);
  assert.equal(s.days.length, 14);
  assert.deepEqual(s.os, [{ name: "macOS 15", n: 1 }, { name: "macOS 26", n: 1 }]);
  // An install that updated counts under both versions it ran this week.
  assert.deepEqual(s.versions.map((v) => v.name).sort(), ["1.2.1", "1.3.0", "1.3.1"]);
  assert.match(statsMarkdown(s), /\*\*2\*\* installs have sent a ping/);
  assert.match(statsMarkdown(s), /\| 2026-10-31 \| 2 \| 1 \|/);
});

test("drops daily rows after 90 days, keeps the install count", () => {
  const store = new PingStore(fakeSQL());
  store.record(ping, "2026-01-01");
  store.prune("2026-10-31");
  const s = store.stats("2026-10-31");
  assert.equal(s.installs, 1);
  assert.equal(s.active30, 0);
});

// The Worker, with the Durable Object running in-process.
let calls;
let issues;
let env;
beforeEach(() => {
  const object = new Pings({ storage: { sql: fakeSQL() } });
  env = {
    GITHUB_REPO: "stellalie/euclid-bar",
    GITHUB_TOKEN: "t",
    PINGS: { idFromName: (n) => n, get: () => ({ fetch: (url, init) => object.fetch(new Request(url, init)) }) },
  };
  calls = [];
  issues = {};
  globalThis.fetch = async (url, init) => {
    const body = init.body && JSON.parse(init.body);
    calls.push({ url, method: init.method, body });
    const number = Number(url.match(/issues\/(\d+)$/)?.[1]);
    if (init.method === "POST") issues[7] = { number: 7, ...body };
    if (init.method === "PATCH") Object.assign(issues[number], body);
    return new Response(JSON.stringify(issues[number] ?? issues[7]), { status: 200 });
  };
});

const post = (body) =>
  worker.fetch(new Request("https://reports.lgtm.ninja/v1/ping", { method: "POST", body: JSON.stringify(body) }), env);

test("a ping is stored and shows up in the stats issue", async () => {
  assert.equal((await post(ping)).status, 204);
  assert.equal((await post({ ...ping, id: "x" })).status, 400);
  assert.equal((await worker.fetch(new Request("https://reports.lgtm.ninja/v1/ping"), env)).status, 405);

  assert.equal(await publishStats(env), "#7 created");
  assert.equal(calls[0].body.title, "Install stats (opt-in usage ping)");
  assert.match(issues[7].body, /\*\*1\*\* installs/);
  assert.equal(await publishStats(env), "#7 unchanged");

  await post(other);
  assert.equal(await publishStats(env), "#7 updated");
  assert.match(issues[7].body, /\*\*2\*\* installs/);
  assert.equal(calls.filter((c) => c.method === "POST").length, 1);
});

// Euclid's opt-in daily usage ping (`[privacy] usage_ping = true`): a random install ID and versions.
// Stored in one SQLite Durable Object; an hourly cron writes the counts to a GitHub issue.
// No IPs are stored. Daily rows older than KEEP_DAYS are deleted; per install only first/last day is kept.

export const KEEP_DAYS = 90;
export const STATS_TITLE = "Install stats (opt-in usage ping)";

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

/** The app's `UsagePing`, checked field by field. Throws on anything else. */
export function validatePing(p) {
  const keys = ["id", "app", "build", "channel", "os", "arch"];
  if (typeof p !== "object" || p === null || Array.isArray(p)) throw new Error("not an object");
  for (const k of Object.keys(p)) if (!keys.includes(k)) throw new Error(`unknown field ${k}`);
  if (typeof p.id !== "string" || !ID.test(p.id)) throw new Error("id");
  for (const k of keys.slice(1)) {
    if (typeof p[k] !== "string" || p[k].length > 60 || !/^[\w .()\-]*$/.test(p[k])) throw new Error(k);
  }
  return p;
}

/** "macOS 15.1.0" → "macOS 15": the minor version isn't needed to count. */
export function osMajor(os) {
  return os.match(/^macOS \d+/)?.[0] ?? "other";
}

export function utcDay(date) {
  return date.toISOString().slice(0, 10);
}

function daysBefore(day, n) {
  return utcDay(new Date(Date.parse(`${day}T00:00:00Z`) - n * 86_400_000));
}

/** The storage and queries, over a Durable Object's `ctx.storage.sql` (or anything with the same `exec`). */
export class PingStore {
  constructor(sql) {
    this.sql = sql;
    sql.exec(`CREATE TABLE IF NOT EXISTS pings (id TEXT, day TEXT, app TEXT, channel TEXT, os TEXT, arch TEXT, PRIMARY KEY (id, day))`);
    sql.exec(`CREATE TABLE IF NOT EXISTS installs (id TEXT PRIMARY KEY, first_day TEXT, last_day TEXT)`);
    sql.exec(`CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)`);
  }

  /** One row per install per day; the first ping of the day wins. */
  record(p, day) {
    this.sql.exec(`INSERT OR IGNORE INTO pings VALUES (?, ?, ?, ?, ?, ?)`, p.id, day, p.app, p.channel, osMajor(p.os), p.arch);
    this.sql.exec(
      `INSERT INTO installs VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET last_day = MAX(last_day, excluded.last_day)`,
      p.id, day, day,
    );
  }

  prune(today) {
    this.sql.exec(`DELETE FROM pings WHERE day < ?`, daysBefore(today, KEEP_DAYS));
  }

  stats(today) {
    const rows = (q, ...b) => this.sql.exec(q, ...b).toArray();
    const active = (days) => rows(`SELECT COUNT(DISTINCT id) AS n FROM pings WHERE day > ?`, daysBefore(today, days))[0].n;
    const since14 = daysBefore(today, 14);
    const daily = new Map();
    for (const r of rows(`SELECT day, COUNT(*) AS n FROM pings WHERE day > ? GROUP BY day`, since14)) daily.set(r.day, { active: r.n, new: 0 });
    for (const r of rows(`SELECT first_day AS day, COUNT(*) AS n FROM installs WHERE first_day > ? GROUP BY first_day`, since14)) {
      daily.set(r.day, { active: daily.get(r.day)?.active ?? 0, new: r.n });
    }
    const days = [];
    for (let i = 0; i < 14; i++) {
      const day = daysBefore(today, i);
      days.push({ day, ...(daily.get(day) ?? { active: 0, new: 0 }) });
    }
    const since7 = daysBefore(today, 7);
    const by = (col) =>
      rows(`SELECT ${col} AS name, COUNT(DISTINCT id) AS n FROM pings WHERE day > ? GROUP BY ${col} ORDER BY n DESC, name LIMIT 10`, since7);
    return {
      today,
      installs: rows(`SELECT COUNT(*) AS n FROM installs`)[0].n,
      active1: active(1),
      active7: active(7),
      active30: active(30),
      days,
      versions: by("app"),
      os: by("os"),
      channels: by("channel"),
      arch: by("arch"),
    };
  }

  get(key) {
    return this.sql.exec(`SELECT value FROM meta WHERE key = ?`, key).toArray()[0]?.value ?? null;
  }

  set(key, value) {
    this.sql.exec(`INSERT INTO meta VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, String(value));
  }
}

/** The GitHub issue body: what Stella reads. */
export function statsMarkdown(s) {
  const table = (rows) => rows.map((r) => `| ${r.name} | ${r.n} |`).join("\n") || "| – | 0 |";
  return [
    `**${s.installs}** installs have sent a ping. Active: **${s.active1}** today · **${s.active7}** in 7 days · **${s.active30}** in 30 days.`,
    "",
    "| Day (UTC) | Active | New |",
    "| --- | ---: | ---: |",
    ...s.days.map((d) => `| ${d.day} | ${d.active} | ${d.new} |`),
    "",
    "Last 7 days, by install:",
    "",
    "| Version | Installs |\n| --- | ---: |\n" + table(s.versions),
    "",
    "| macOS | Installs |\n| --- | ---: |\n" + table(s.os),
    "",
    "| Channel | Installs |\n| --- | ---: |\n" + table(s.channels),
    "",
    "| CPU | Installs |\n| --- | ---: |\n" + table(s.arch),
    "",
    `_Only counts people who turned on \`[privacy] usage_ping\` (off by default). Updated hourly by the reports Worker (server/reports); day ${s.today} is still in progress._`,
  ].join("\n");
}

/** The Durable Object: one instance ("all") holds every ping. */
export class Pings {
  constructor(ctx) {
    this.store = new PingStore(ctx.storage.sql);
  }

  async fetch(request) {
    const { pathname } = new URL(request.url);
    const body = request.method === "POST" ? await request.json() : null;
    const today = utcDay(new Date());
    switch (pathname) {
      case "/record":
        this.store.record(body, today);
        return Response.json({ ok: true });
      case "/stats":
        this.store.prune(today);
        return Response.json(this.store.stats(today));
      case "/meta":
        if (body) this.store.set(body.key, body.value);
        return Response.json({ value: this.store.get(new URL(request.url).searchParams.get("key") ?? body?.key) });
      default:
        return new Response("Not found", { status: 404 });
    }
  }
}

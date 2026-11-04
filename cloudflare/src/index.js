import { Container, getContainer } from "@cloudflare/containers";
import { TripStore } from "./trips.js";

// Settings the container gets from the Worker's vars and secrets (see wrangler.jsonc).
const SETTINGS = [
  "APP_TOKEN",
  "BYD_USERNAME",
  "BYD_PASSWORD",
  "BYD_CONTROL_PIN",
  "BYD_BASE_URL",
  "BYD_COUNTRY_CODE",
  "BYD_LANGUAGE",
  "BYD_TIME_ZONE",
  "BYD_SKIP_COMMAND_GATE",
  "BYD_POLL_MINUTES",
  "BLE_KEY_JSON",
];

// One container runs server.py for a long time: it holds the BYD login and the MQTT
// connection that feeds its cache. The cron trigger below keeps it from idling out.
//
// The same Durable Object also owns the trip log: its SQLite holds the snapshots pulled from
// the container, the trips derived from them, the phones' events, settings and the car lease.
export class BydServer extends Container {
  defaultPort = 8080;
  sleepAfter = "1h";

  constructor(ctx, env) {
    super(ctx, env);
    this.envVars = Object.fromEntries(SETTINGS.filter((k) => env[k] !== undefined).map((k) => [k, env[k]]));
    this.trips = new TripStore(ctx.storage.sql);
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname === "/trips/sync" && request.method === "POST") {
      return Response.json(await this.syncTrips());
    }
    const handled = await this.trips.handle(request);
    return handled ?? super.fetch(request);
  }

  // Pulls new snapshots, prices and (hourly) energy figures from the container into SQLite.
  async syncTrips() {
    // The container checks the same bearer token as the public Worker, so the sync must send it.
    const headers = { Authorization: `Bearer ${this.envVars.APP_TOKEN ?? ""}` };
    const fetchJson = async (path) => {
      try {
        const response = await super.fetch(new Request(`http://container${path}`, { headers }));
        if (!response.ok) return null;
        return await response.json();
      } catch (error) {
        console.log("trip sync", path, String(error));
        return null;
      }
    };
    return this.trips.sync(fetchJson);
  }
}

export default {
  async fetch(request, env) {
    // Reject unauthenticated requests here so they never reach the container.
    if (!env.APP_TOKEN) {
      return Response.json({ detail: "Server not configured" }, { status: 503 });
    }
    if (request.headers.get("Authorization") !== `Bearer ${env.APP_TOKEN}`) {
      return Response.json({ detail: "Bad or missing token" }, { status: 401 });
    }
    return getContainer(env.BYD_SERVER).fetch(request);
  },

  // Keeps the container awake (and starts it after a deploy or an eviction), then pulls the
  // car's latest snapshots and prices into the trip log.
  async scheduled(_event, env) {
    const container = getContainer(env.BYD_SERVER);
    const response = await container.fetch(new Request("http://container/health"));
    console.log("keepalive", response.status, await response.text());
    const sync = await container.fetch(new Request("http://container/trips/sync", { method: "POST" }));
    console.log("trip sync", sync.status, await sync.text());
  },
};

import { Container, getContainer } from "@cloudflare/containers";

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
export class BydServer extends Container {
  defaultPort = 8080;
  sleepAfter = "1h";

  constructor(ctx, env) {
    super(ctx, env);
    this.envVars = Object.fromEntries(SETTINGS.filter((k) => env[k] !== undefined).map((k) => [k, env[k]]));
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

  // Keeps the container awake (and starts it after a deploy or an eviction).
  async scheduled(_event, env) {
    const response = await getContainer(env.BYD_SERVER).fetch(new Request("http://container/health"));
    console.log("keepalive", response.status, await response.text());
  },
};

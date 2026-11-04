import { Container, getContainer } from "@cloudflare/containers";

// One container runs server.py. It holds the BYD login session, so keep a
// single instance and let it sleep after 30 idle minutes (it logs in again on wake).
export class BydServer extends Container {
  defaultPort = 8080;
  sleepAfter = "30m";

  constructor(ctx, env) {
    super(ctx, env);
    this.envVars = {
      APP_TOKEN: env.APP_TOKEN,
      BYD_USERNAME: env.BYD_USERNAME,
      BYD_PASSWORD: env.BYD_PASSWORD,
      BYD_CONTROL_PIN: env.BYD_CONTROL_PIN,
      BYD_BASE_URL: env.BYD_BASE_URL,
      BYD_COUNTRY_CODE: env.BYD_COUNTRY_CODE,
      BYD_LANGUAGE: env.BYD_LANGUAGE,
      BYD_TIME_ZONE: env.BYD_TIME_ZONE,
    };
  }
}

export default {
  async fetch(request, env) {
    // Reject unauthenticated requests here so they never wake the container.
    if (!env.APP_TOKEN) {
      return Response.json({ detail: "Server not configured" }, { status: 503 });
    }
    if (request.headers.get("Authorization") !== `Bearer ${env.APP_TOKEN}`) {
      return Response.json({ detail: "Bad or missing token" }, { status: 401 });
    }
    return getContainer(env.BYD_SERVER).fetch(request);
  },
};

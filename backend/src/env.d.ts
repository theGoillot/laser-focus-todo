declare namespace Cloudflare {
  interface Env {
    STORE: DurableObjectNamespace<import("./store").Store>;
    MAC_TOKEN: string;
    AGENT_TOKEN: string;
    AGENT_NAME: string;
    /** IANA zone that defines "today" for the agent, e.g. America/New_York. */
    TIMEZONE: string;
  }
}
interface Env extends Cloudflare.Env {}

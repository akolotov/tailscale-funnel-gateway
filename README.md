# Shared Tailscale Funnel gateway

This Compose project owns one public Tailscale node for services on its Docker
host. Its local `state/` directory preserves that node's identity, HTTPS
certificate data, and Funnel configuration across container recreation.

## Requirements

- Docker Engine with the Docker Compose plugin;
- a Tailscale tailnet with MagicDNS and HTTPS enabled;
- permission to enable Funnel for the account or tag used by this gateway.

Funnel exposes the service to the public Internet. Configure its permissions in
your tailnet policy before enabling it.

## First start and Tailscale registration

Run these steps on every new Docker host. Do not copy `state/` from another
host: each host must register its own Tailscale node.

1. In the Tailscale admin console, create a reusable, non-ephemeral auth key
   for this persistent gateway.
2. Copy the template and fill in a unique hostname and the auth key:

   ```bash
   cp .env.example .env
   ```

   ```dotenv
   TS_HOSTNAME=my-apps-gateway
   TS_AUTHKEY=tskey-auth-...
   ```

   Keep `.env` private. It contains a credential and is ignored by Git.
3. Start the gateway and wait for the node to connect:

   ```bash
   docker compose up -d
   docker compose logs -f tailscale
   ```

   Press <kbd>Ctrl</kbd>+<kbd>C</kbd> after the logs show that the node is
   connected; this does not stop the containers.
4. Verify registration:

   ```bash
   docker compose exec tailscale tailscale status --self
   ```
5. Enable the root Funnel route to Nginx. Tailscale may print a URL that a
   tailnet administrator must open to approve Funnel:

   ```bash
   docker compose exec tailscale \
     tailscale funnel --bg http://127.0.0.1:8080
   ```
6. Record the public URL and confirm its configuration:

   ```bash
   docker compose exec tailscale tailscale funnel status
   ```

The `.env` auth key is used only when a node with no saved state registers.
With `state/` preserved, later starts reuse the existing node identity.

## Regular start

```bash
docker compose up -d
```

The gateway creates the shared Docker network `tailscale-ingress`. Other
independent Compose projects join this network as `external: true`; only their
public HTTP service should join it.

## Public routing conventions

Funnel forwards its root path to Nginx at `127.0.0.1:8080`. Nginx resolves a
Docker network alias dynamically and forwards to port `8080` of that service:

- `/hooks/<docker-alias>/...` for webhook receivers;
- `/apps/<docker-alias>/...` for interactive web applications.

Examples coupled to this gateway configuration are in `examples/webhook-example/`
and `examples/apps-example/`.

The public base URL is the DNS name shown by `tailscale funnel status`, normally
`https://<TS_HOSTNAME>.<tailnet>.ts.net`. Do not put another machine's hostname
or tailnet name into service configuration.

For a special route that needs its own authentication, rewrite, method policy,
or non-standard port, add an explicit Nginx location and reload after first
checking the syntax:

```bash
docker compose exec proxy nginx -t
docker compose exec proxy nginx -s reload
```

## Operations

Inspect active public routing:

```bash
docker compose exec tailscale tailscale funnel status
```

Do not delete `state/` unless you intentionally want to register a new
Tailscale node and reconfigure Funnel.

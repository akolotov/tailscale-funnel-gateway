# Webhook example service

This independent Compose project publishes no host ports. It joins the shared
`tailscale-ingress` Docker network under the alias `webhook-example`.

The shared gateway needs no per-service route. Its generic template maps
`/hooks/<docker-alias>/...` to port `8080` of that alias. This service is
therefore available at:

```text
https://<gateway-hostname>.<tailnet>.ts.net/hooks/webhook-example/telegram/webhook
```

For a real webhook receiver, set its `WEBHOOK_PUBLIC_BASE_URL` to the common
Funnel hostname and set `WEBHOOK_PATH` to the full template path, for example
`/hooks/my-bot-api/telegram/webhook`. Join its HTTP API service (but not its
database or worker) to `tailscale-ingress` under alias `my-bot-api`.

Start it after the gateway has created the external network:

```bash
docker compose up -d
```

Get the real common Funnel hostname from the gateway with `docker compose exec
tailscale tailscale funnel status`.

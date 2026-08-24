# Apps example service

This independent Compose project publishes no host ports. It joins the shared
`tailscale-ingress` Docker network under the alias `apps-example`.

The shared gateway uses its generic application route, so this service is
available without adding a per-service Nginx rule:

```text
https://<gateway-hostname>.<tailnet>.ts.net/apps/apps-example/
```

For another web application, attach only its HTTP service to
`tailscale-ingress`, give it a unique alias, and use:

```text
https://<gateway-hostname>.<tailnet>.ts.net/apps/<docker-alias>/
```

Get the real base URL from the gateway with `docker compose exec tailscale
tailscale funnel status`.

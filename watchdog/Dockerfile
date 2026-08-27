FROM tailscale/tailscale:stable

RUN apk add --no-cache bind-tools curl jq

COPY funnel-watchdog.sh /usr/local/bin/funnel-watchdog

ENTRYPOINT ["/usr/local/bin/funnel-watchdog"]
CMD ["run"]

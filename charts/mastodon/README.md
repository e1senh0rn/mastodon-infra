# Mastodon Helm chart

Deploys Mastodon's web, streaming and sidekiq processes using the image this
repository builds (`ghcr.io/e1senh0rn/mastodon`). PostgreSQL and Redis are
not included; point the chart at existing ones.

Compared with [upstream's chart](https://github.com/mastodon/helm-charts),
it has fewer settings: anything that isn't listed in `values.yaml` goes in
`mastodon.extraEnv`, using Mastodon's own
[environment variables](https://docs.joinmastodon.org/admin/config/).

## Install

1. Create a database and a user for Mastodon in PostgreSQL. The chart creates
   the schema, but not the database.

2. Create the Secret. Every key in it becomes an environment variable of
   every Mastodon container. Generate Mastodon's own keys with the image:

   ```sh
   image=ghcr.io/e1senh0rn/mastodon:latest
   run() { docker run --rm -e SECRET_KEY_BASE=unused "$image" bundle exec rails "$@"; }
   {
     echo "SECRET_KEY_BASE=$(run secret | tail -n 1)"
     run mastodon:webpush:generate_vapid_key | grep '^VAPID_'
     run db:encryption:init | grep '^ACTIVE_RECORD_ENCRYPTION_'
     echo "DB_PASS=<database password>"
     # As needed:
     # echo "REDIS_PASSWORD=..."
     # echo "AWS_ACCESS_KEY_ID=..."; echo "AWS_SECRET_ACCESS_KEY=..."
     # echo "SMTP_LOGIN=..."; echo "SMTP_PASSWORD=..."
   } > mastodon.env
   kubectl -n mastodon create secret generic mastodon --from-env-file=mastodon.env
   rm mastodon.env
   ```

   Back these values up. The `ACTIVE_RECORD_ENCRYPTION_*` keys encrypt data
   in the database (e.g. two-factor secrets), and federation signatures depend
   on the database and `SECRET_KEY_BASE`. Changing or losing them breaks the
   instance.

3. Install with a values file:

   ```yaml
   mastodon:
     localDomain: social.example.com
     existingSecret: mastodon
     extraEnv:
       SMTP_SERVER: smtp.example.com
       SMTP_PORT: "587"
       SMTP_FROM_ADDRESS: notifications@social.example.com
   postgresql:
     host: postgres.db.svc
     sslMode: require
   redis:
     host: redis.db.svc
   s3:
     enabled: true
     bucket: social-media
     endpoint: https://s3.example.com
     region: us-east-1
     aliasHost: media.social.example.com
   ingress:
     enabled: true
     className: nginx
     tlsSecretName: social-tls
   ```

   ```sh
   helm install mastodon oci://ghcr.io/e1senh0rn/charts/mastodon \
     --version <version> -n mastodon -f values.yaml
   ```

4. Create an owner account (the install notes print this command):

   ```sh
   kubectl -n mastodon exec deploy/mastodon-web -- \
     bin/tootctl accounts create alice --email alice@example.com --confirmed --role Owner
   ```

Pods don't restart when the Secret changes; run
`kubectl rollout restart deploy -l app.kubernetes.io/instance=mastodon`.

## Routing

The web host (`webDomain`, or `localDomain` if unset) serves `/` from the web
service and `/api/v1/streaming` from the streaming service. Enable either
or both of:

- `ingress`: a `networking.k8s.io/v1` Ingress. `tlsSecretName` adds TLS for
  the web host.
- `httpRoute`: a Gateway API HTTPRoute attached to `httpRoute.parentRefs`.
  TLS is configured on the Gateway.

Mastodon only works over HTTPS: it redirects plain HTTP requests unless the
proxy sends `X-Forwarded-Proto: https`.

## Media storage

With `s3.enabled`, media goes to the bucket and is served from `aliasHost`
(a CDN, or the bucket's public website endpoint). Mastodon uploads with a
`public-read` ACL. For stores that reject ACLs, set
`mastodon.extraEnv.S3_PERMISSION: ""`.

Without S3, media goes to a PersistentVolumeClaim, served by the web pods.
Web and sidekiq both write to it, so with several nodes it needs
`ReadWriteMany`, or the pods have to share a node. The claim is kept on
`helm uninstall`.

## Metrics

`metrics.enabled` turns on Mastodon's Prometheus metrics. Each pod serves
`/metrics` on a named port:

| Pod | Port | What |
|---|---|---|
| web | `metrics` (9394) | Puma, plus each worker's memory, GC and database pool. Served by a `prometheus_exporter` sidecar: Mastodon's in-process server would only see the Puma master. The sidecar gets no Mastodon configuration or secrets. |
| sidekiq | `metrics` (9394) | Sidekiq process stats, memory, GC and database pool, from Mastodon's in-process server. |
| streaming | `streaming` (4000) | Connections per channel, Redis and Postgres pool. Always on; not reachable through the Ingress or HTTPRoute, which only route `/api/v1/streaming` there. |

To scrape them:

- `metrics.podMonitor.enabled` creates a Prometheus Operator `PodMonitor`
  (the CRD must be installed). Grafana Alloy, the VictoriaMetrics operator and
  the OpenTelemetry Collector's target allocator read it too. Add the labels
  your Prometheus selects monitors by in `metrics.podMonitor.labels`.
- Collectors driven by annotations (`prometheus.io/*`, Datadog's
  `ad.datadoghq.com/*`) can use `podAnnotations`.

`metrics.from` limits who may connect to these ports (NetworkPolicy); set it
to the collector's namespace. Per-action and per-job metrics are off; turn
them on with `MASTODON_PROMETHEUS_EXPORTER_WEB_DETAILED_METRICS` and
`MASTODON_PROMETHEUS_EXPORTER_SIDEKIQ_DETAILED_METRICS` in
`web.env` and `sidekiq.env`.

## Upgrades

Each install or upgrade runs `db:prepare` before the new pods start and
`db:migrate` after they're up. The first loads the schema into an empty
database, or runs the migrations that are safe while old pods still run. The
second runs the post-deployment migrations. Read the
[release notes](https://github.com/mastodon/mastodon/releases) before a
minor or major upgrade: some need manual steps.

## Security

- All containers run as UID/GID 991 with a read-only root filesystem, no
  capabilities, no privilege escalation, and the `RuntimeDefault` seccomp
  profile. They meet the `restricted` Pod Security Standard (`test/run.sh`
  checks this). `/tmp` is a size-capped emptyDir; a small init container
  makes private `HOME` and `TMPDIR` directories in it, because Ruby refuses
  a world-writable directory without the sticky bit.
- Pods don't mount a service account token. Service links are off; they'd
  inject variables such as `REDIS_PORT=tcp://...` that Mastodon reads.
- Secrets only come from `existingSecret`: they're never part of the values
  or the Helm release, which stores rendered manifests in the cluster.
- NetworkPolicies (on by default) allow inbound traffic only to web and
  streaming, on their ports. Set `networkPolicy.from` to the ingress or
  gateway controller to restrict them further. Outbound traffic isn't
  restricted, because federation talks to arbitrary servers. Policies only
  take effect if the network plugin enforces them.
- Each chart version pins one image by digest (see Releases).
- sidekiq has to run as a single replica (it runs the scheduler) and uses
  the `Recreate` strategy, so two schedulers never overlap.

## Releases

The chart is published to `oci://ghcr.io/e1senh0rn/charts/mastodon` under
its version (e.g. `0.1.0`), and the commit it was released from is tagged
`chart-v<version>` in git. List them with `git tag -l 'chart-v*'`.
`scripts/release-chart.sh` does both. If a release was published but its tag
wasn't pushed, the next release run adds the tag; it never moves an
existing one.

Each chart version pins one image build, `image.tag` (the immutable
`v<mastodon>-<date>.<run>` tag) plus `image.digest`, so it always deploys
exactly the same image. Whenever `build.yml` publishes an image, it pins
the chart to it with `scripts/update-chart.sh`, bumps the version, commits,
and releases:

| Image change | Chart version |
|---|---|
| Rebuild (e.g. nixpkgs fixes), same Mastodon | patch |
| Mastodon patch release | patch |
| Mastodon minor or major release | minor |

That's up to one patch release a day with the daily schedule on.
`helm upgrade` (or Flux, Argo CD, Renovate) to the latest version to pick up
fixes.

Changes to the chart itself need a version bump in `Chart.yaml`: pull
requests fail without one, and `chart.yml` releases the new version once it
reaches `main`. `test/` isn't part of the package, so changes there don't
count.

To run a different image than the pinned one, set `image.tag` and clear
`image.digest`.

## Testing

`test/lint.sh` lints the chart and validates the rendered manifests (CI runs
it on every chart change). `test/run.sh` deploys the chart on a local
OrbStack cluster with throwaway PostgreSQL, Redis and
[Garage](https://garagehq.deuxfleurs.fr/) (for S3). It then checks web,
streaming, media upload to S3, the character limit, sidekiq and the metrics
endpoints through an Ingress, and upgrades the release to an HTTPRoute and
checks routing again. It needs a controller for both, e.g. Traefik:

```sh
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.7.0/standard-install.yaml
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik -n traefik --create-namespace \
  --set providers.kubernetesGateway.enabled=true
nix develop -c charts/mastodon/test/run.sh
```

The instance stays up at https://mastodon.k8s.orb.local (self-signed
certificate) until `kubectl delete ns mastodon-test`.

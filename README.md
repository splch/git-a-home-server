# Home server

A home server that is run by its own git repository. One machine, Docker,
and eight small files.

    git push ──> Forgejo ──> runner ──> docker compose up -d --wait

| A home server needs | Here                                                                                   |
| ------------------- | -------------------------------------------------------------------------------------- |
| Services            | One file, `compose.yaml`. Nothing is edited on the server.                             |
| Deploys             | Pushing to `master` applies the file and waits for every health check.                 |
| Updates             | Renovate opens a pull request for each new image version.                              |
| Tests               | Each pull request boots a throwaway copy of the stack and waits for its health checks. |
| Scheduled jobs      | Workflows with a `schedule`. Backups and cleanup are the two included.                 |
| Backups             | Nightly, encrypted, every Docker volume, taken while the services are paused.          |
| One front door      | Caddy routes `name.domain` to each service. Nothing else publishes a port.             |
| Secrets             | In Forgejo, passed to jobs. None in git.                                               |
| Recovery            | Three commands. See [Restore](#restore).                                               |

## Files

| File                              | Purpose                                                                                            |
| --------------------------------- | -------------------------------------------------------------------------------------------------- |
| `compose.yaml`                    | Every service, its routes, and its configuration.                                                  |
| `bootstrap.sh`                    | Run once. Starts Forgejo and hands the server over to CI.                                          |
| `.forgejo/workflows/deploy.yml`   | On push to `master`, and nightly: apply `compose.yaml`.                                            |
| `.forgejo/workflows/test.yml`     | On pull request: boot a copy, check health, remove it.                                             |
| `.forgejo/workflows/renovate.yml` | Nightly: open pull requests for new versions.                                                      |
| `.forgejo/workflows/cron.yml`     | Nightly: back up, then prune unused images.                                                        |
| `renovate.json`                   | Minor and patch updates merge themselves when the test passes. Major and 0.x updates wait for you. |
| `compose.test.yaml`               | Removes host ports from the copy that `test.yml` boots.                                            |

## Start

You need a Linux machine with Docker, the Compose plugin, and git.

    git clone <this repository> home-server && cd home-server
    ./bootstrap.sh

The script prints two things to keep: your Forgejo password and the backup
password. When it finishes, the server is running, this repository lives in
Forgejo at <http://git.localhost>, and the first deploy has run. From then on,
clone it from Forgejo, change it, and push.

The names `git.localhost` and `hello.localhost` work only on the server
itself. To reach it from other machines, replace `localhost` in
`compose.yaml` with a domain whose `*.` record points at the server.

## Use

**Add a service.** Add a service block and a site block to `compose.yaml`,
with a `healthcheck`. Open a pull request to have it tested first, or push to
`master`.

**Give it a secret.** Add the secret to the repository in Forgejo (Settings,
Actions, Secrets), pass it to the job with `env:` in `deploy.yml`, and list it
under the service's `environment:` as a bare `NAME:`. `restic` and `cron.yml`
do this for the backup password.

**Schedule a job.** Add a job to `cron.yml`. If it needs its own image, define
it as a service with a profile, as `restic` is, and call it with
`docker compose run --rm`.

**Undo a change.** `git revert` it and push.

**Fix CI when CI is broken.** On the server, in any clone of the repository:
`docker compose up -d --wait forgejo runner`.

## Restore

On a new machine, with the backup disk mounted at `/srv/backup` and any clone
of this repository:

    export RESTIC_PASSWORD=<the backup password>
    docker compose run --rm restic restore latest --target /
    docker compose --profile ci up -d

This brings back Forgejo with its repositories and secrets, the runner's
registration, and every other volume. Services that take secrets get them at
the next deploy. The backup run that took the snapshot shows as "running"
until Forgejo times it out.

## Why it is built this way

- **CI talks to Forgejo over the Docker network**, never through Caddy, so a
  broken route or certificate cannot stop a deploy that would fix it.
- **Workflows are plain shell in pinned images.** No actions are downloaded,
  so there is nothing else to trust, update, or lose access to.
- **The runner is outside `docker compose up`.** Replacing it mid-job would
  kill the job. The last step of `deploy.yml` starts a detached container that
  asks it to stop; the runner finishes the job first, then is replaced.
- **Each config is also a label on its service.** Compose does not recreate a
  container when only an inline config changes
  ([docker/compose#11900](https://github.com/docker/compose/issues/11900));
  the label makes it notice.
- **Backups pause the services.** Forgejo's database is SQLite; copying it
  while it is written can produce a file that will not open. Paused, the copy
  is what a power cut would leave, which databases are built to survive. The
  pause lasts as long as the incremental backup, usually seconds.
- **Jobs have root on the server.** The runner hands them the Docker socket;
  that is what lets them deploy. Registration is disabled. Give an account
  only to someone you would give root.

## Not included

These depend on your network or belong to the host, not to this repository.

- **Off-site backups.** `/srv/backup` is a path on the same machine. Mount
  another disk there, or set `RESTIC_REPOSITORY` in `compose.yaml` to a remote
  one.
- **HTTPS.** With public DNS names, remove `http://` from the site blocks,
  change `ROOT_URL` to `https://`, and Caddy obtains certificates.
- **Remote access.** Use a VPN such as WireGuard or Tailscale. Do not forward
  ports from your router.
- **Alerts.** Failed runs show in Forgejo. To get them by email, configure
  Forgejo's mailer and add `enable-email-notifications: true` to a workflow.
- **The host.** Turn on automatic security updates (`unattended-upgrades` on
  Debian and Ubuntu) and log rotation (`"log-driver": "local"` in
  `/etc/docker/daemon.json`).

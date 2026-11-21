#!/bin/sh -eu
# Run once, on the server, from a clone of this repository. It starts the
# services, creates what CI needs, and pushes this repository into Forgejo.
# After that, every change goes through git.

repo=$USER/home-server
fj() { docker compose exec -T -u git forgejo forgejo "$@"; }
api() { docker compose exec -T forgejo curl -fsS -o /dev/null -H "Authorization: token $token" -H "Content-Type: application/json" "http://127.0.0.1:3000/api/v1/$@"; }

# Forgejo, with a key to encrypt the secrets it stores (the image sets none).
docker compose up -d --wait forgejo
key=$(fj generate secret SECRET_KEY)
docker compose exec -T -u git -e FORGEJO__security__SECRET_KEY="$key" forgejo environment-to-ini
docker compose restart forgejo
docker compose up -d --wait

# Your account (this prints its password) and one for Renovate.
fj admin user create --admin --username "$USER" --email "$USER@home.arpa" --random-password
fj admin user create --username renovate --email renovate@home.arpa --random-password --must-change-password=false >/dev/null
token=$(fj admin user generate-access-token --raw --username "$USER")
renovate=$(fj admin user generate-access-token --raw --username renovate --scopes write:repository,write:issue,read:user,read:organization)

# The runner. The first 16 characters of its secret name it (the uuid in
# compose.yaml is those characters in hex); the rest stays on this server.
secret=0000000000000001$(fj forgejo-cli actions generate-secret | cut -c17-)
fj forgejo-cli actions register --secret "$secret"
docker compose run --rm --entrypoint sh runner -c "echo $secret > token"
docker compose up -d runner

# The backup repository.
password=$(fj forgejo-cli actions generate-secret)
RESTIC_PASSWORD=$password docker compose run --rm restic init

# This repository and its secrets. The push triggers the first deploy.
api user/repos -d '{"name": "home-server", "private": true}'
api "repos/$repo/collaborators/renovate" -X PUT -d '{"permission": "write"}'
api "repos/$repo/branch_protections" -d '{"rule_name": "master", "enable_push": true, "enable_status_check": true, "status_check_contexts": ["*test (pull_request)"]}'
api "repos/$repo/actions/secrets/RENOVATE_TOKEN" -X PUT -d "{\"data\": \"$renovate\"}"
api "repos/$repo/actions/secrets/RESTIC_PASSWORD" -X PUT -d "{\"data\": \"$password\"}"
url=$(docker compose exec -T forgejo printenv FORGEJO__server__ROOT_URL)$repo
git -c http.extraHeader="Authorization: token $token" push "$url" HEAD:master

echo "Done: $url"
echo "Backup password (keep a copy off this server): $password"

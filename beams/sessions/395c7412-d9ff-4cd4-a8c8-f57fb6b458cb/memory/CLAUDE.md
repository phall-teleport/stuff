This is a sandbox environment. Run `cat /etc/motd` for basic setup and usage instructions.

## API configuration

The following environment variables are pre-configured — do not ask the user to set them:
- ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN
- OPENAI_API_KEY, OPENAI_BASE_URL

When writing code that calls Anthropic or OpenAI APIs directly (e.g. curl, fetch),
use the environment variables ANTHROPIC_BASE_URL and OPENAI_BASE_URL instead of
hardcoding the default API URLs.

## Teleport resources

The following environment variables are pre-configured:
- TELEPORT_CLUSTER — cluster hostname (no port)
- TELEPORT_PROXY — proxy address with port
- BEAM_ID — this sandbox's ID
- BEAM_ALIAS — human-friendly alias for this sandbox

Key commands:
- `tsh status` — show current identity
- `tsh apps ls` — list available apps
- `tsh db ls` — list available databases
- `tsh git ls` — list allowed GitHub orgs
- `tsh beams --help` - show info about interacting with beams

Accessing resources:
- HTTP apps: https://<app-name>.$TELEPORT_CLUSTER
- TCP apps: <app-name>.$TELEPORT_CLUSTER (access method depends on the app type)
- Databases (postgres, mysql, sql-server, cockroachdb): <vnet-dns-name>.db.$TELEPORT_CLUSTER
  The vnet-dns-name is usually the database resource name. If the name is not a valid DNS label,
  look up the actual value with:
    tsh db ls --query 'name == "<db-name>"' --format json | jq '.[0].status.vnet_dns_name'

## GitHub access

If `tsh status` shows a `GitHub username:` field, the Teleport GitHub proxy is configured.
Use `tsh git ls` to see which orgs are allowed, then clone using the standard SSH URL:
  tsh git clone git@github.com:<org>/<repo>.git

Run `tsh git -h` for more options.

## Publishing apps from beam

- HTTP app: `tsh beams publish $BEAM_ALIAS`
- TCP app:  `tsh beams publish --tcp $BEAM_ALIAS`

Port 8080 is the only port available for publishing. Only one app (HTTP or TCP) can be published at a time.
Published app can be found in `tsh apps ls` and is accessible as a regular app.

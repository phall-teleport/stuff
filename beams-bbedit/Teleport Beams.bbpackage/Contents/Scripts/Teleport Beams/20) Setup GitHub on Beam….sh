#!/bin/bash
# Teleport Beams — Setup GitHub on Beam…
# Configures git identity on the current beam and GitHub access via either the Teleport
# Git proxy (tsh git, no token) or a Personal Access Token (installs the gh CLI), then
# optionally clones a repository. Username/email/auth choice can be remembered in
# ~/.config/teleport-beams-bbedit/config; a PAT is never stored locally.
source "$(cd "$(dirname "$0")" && pwd)/../../Resources/lib/beams-lib.sh" || exit 1

id=$(beams_require) || exit 1

username=$(beams_ask "GitHub username:" "${BEAMS_GITHUB_USERNAME:-}") || exit 0
username=$(printf '%s' "$username" | tr -d '[:space:]')
[ -n "$username" ] || exit 0

email=$(beams_ask "Git commit email:" "${BEAMS_GITHUB_EMAIL:-$username@users.noreply.github.com}") || exit 0
email=$(printf '%s' "$email" | tr -d '[:space:]')
[ -n "$email" ] || email="$username@users.noreply.github.com"

default_auth="Teleport Git Proxy"
[ "${BEAMS_GITHUB_AUTH:-}" = "pat" ] && default_auth="Personal Access Token"
if [ "$default_auth" = "Teleport Git Proxy" ]; then
    auth=$(beams_choose_button "How should the beam authenticate to GitHub?

• Teleport Git Proxy — tsh git, no token needed (recommended)
• Personal Access Token — installs the gh CLI and logs in with your token" "Cancel" "Personal Access Token" "Teleport Git Proxy") || exit 0
else
    auth=$(beams_choose_button "How should the beam authenticate to GitHub?

• Teleport Git Proxy — tsh git, no token needed
• Personal Access Token — installs the gh CLI and logs in with your token" "Cancel" "Teleport Git Proxy" "Personal Access Token") || exit 0
fi

pat=""
if [ "$auth" = "Personal Access Token" ]; then
    pat=$(beams_ask "Paste a GitHub Personal Access Token (sent only to beam “$id”, never stored on this Mac):" "" hidden) || exit 0
    pat=$(printf '%s' "$pat" | tr -d '[:space:]')
    [ -n "$pat" ] || exit 0
fi

repo=$(beams_ask "Repository to clone as owner/repo (leave empty to skip):" "${BEAMS_GITHUB_DEFAULT_REPO:-}") || exit 0
repo=$(printf '%s' "$repo" | tr -d '[:space:]' | sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##; s#/+$##')
clone_dir=""
if [ -n "$repo" ]; then
    if ! printf '%s' "$repo" | grep -qE '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
        beams_die "“$repo” is not in owner/repo form."
        exit 1
    fi
    clone_dir=$(beams_ask "Clone into which directory on the beam?" "$BEAMS_HOME/${repo##*/}") || exit 0
    clone_dir=$(printf '%s' "$clone_dir" | sed 's/[[:space:]]*$//; s#/*$##')
    [ -n "$clone_dir" ] || clone_dir="$BEAMS_HOME/${repo##*/}"
fi

beams_notify "Configuring GitHub on $id…"

q_user=$(beams_shell_quote "$username")
q_email=$(beams_shell_quote "$email")
q_repo=$(beams_shell_quote "$repo")
q_dir=$(beams_shell_quote "$clone_dir")
q_pat=$(beams_shell_quote "$pat")

script="set -e
git config --global user.name $q_user
git config --global user.email $q_email
git config --global pager.branch false
"
if [ "$auth" = "Personal Access Token" ]; then
    script+="
if ! command -v gh >/dev/null 2>&1; then
  echo '>> installing GitHub CLI'
  type -p wget >/dev/null || (sudo apt-get update -qq && sudo apt-get install -y -qq wget)
  sudo mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\" | sudo tee /etc/apt/sources.list.d/github-cli-stable.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq gh
fi
echo '>> logging in to GitHub'
printf '%s' $q_pat | gh auth login -h github.com -p https --with-token
gh auth setup-git
"
    if [ -n "$repo" ]; then
        script+="
if [ -d $q_dir/.git ]; then echo \">> $clone_dir already exists, skipping clone\"; else echo '>> cloning $repo'; gh repo clone $q_repo $q_dir; fi
"
    fi
else
    if [ -n "$repo" ]; then
        script+="
if [ -d $q_dir/.git ]; then echo \">> $clone_dir already exists, skipping clone\"; else echo '>> cloning $repo via Teleport Git proxy'; tsh git clone git@github.com:$repo.git $q_dir; fi
echo '>> configuring Teleport Git proxy for the repository'
(cd $q_dir && tsh git config update)
"
    else
        script+="
tsh git config update 2>/dev/null || echo '>> tsh git config update will run once a repository is cloned'
"
    fi
fi
script+="
echo '>> done'
git config --global --get user.name
git config --global --get user.email
"

output=$(printf '%s\n' "$script" | beams_tsh_raw beams exec "$id" -- bash -s 2>&1)
rc=$?
unset pat q_pat script
clean=$(printf '%s' "$output" | beams_strip_ansi)

if [ $rc -ne 0 ]; then
    beams_die "GitHub setup failed on beam “$id”:

$(printf '%s' "$clean" | tail -20)"
    exit 1
fi

printf '%s\n' "$clean"
remember=$(beams_choose_button "GitHub is set up on beam “$id”.

$(printf '%s' "$clean" | grep '^>>' | tail -8)

Remember username, email and auth method for next time? (The token is never stored.)" "No" "Yes") || exit 0
if [ "$remember" = "Yes" ]; then
    method="tsh-git"
    [ "$auth" = "Personal Access Token" ] && method="pat"
    {
        grep -vE '^BEAMS_GITHUB_(USERNAME|EMAIL|AUTH|DEFAULT_REPO)=' "$BEAMS_CONFIG_FILE" 2>/dev/null
        printf 'BEAMS_GITHUB_USERNAME=%s\n' "$(beams_shell_quote "$username")"
        printf 'BEAMS_GITHUB_EMAIL=%s\n' "$(beams_shell_quote "$email")"
        printf 'BEAMS_GITHUB_AUTH=%s\n' "$method"
        [ -n "$repo" ] && printf 'BEAMS_GITHUB_DEFAULT_REPO=%s\n' "$(beams_shell_quote "$repo")"
    } >"$BEAMS_CONFIG_FILE.tmp" && mv "$BEAMS_CONFIG_FILE.tmp" "$BEAMS_CONFIG_FILE"
fi
exit 0

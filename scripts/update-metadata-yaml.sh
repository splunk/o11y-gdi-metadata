#!/bin/bash -e

# parts copied from https://github.com/open-telemetry/opentelemetry.io/blob/main/scripts/auto-update/version-in-file.sh

GH=gh
GIT=git

if [[ -n "$GITHUB_ACTIONS" ]]; then
  # Ensure that we're starting from a clean state
  git reset --hard origin/main
elif [[ "$1" != "-f" ]]; then
  # Do a dry-run when script it executed locally, unless the
  # force flag is specified (-f).
  echo "Doing a dry-run when run locally. Use -f as the first argument to force execution."
  GH="echo > DRY RUN: gh "
  GIT="echo > DRY RUN: git "
else
  # Local execution with -f flag (force real vs. dry run)
  shift
fi

repo=$1

# pick the highest version number, we are not using the latest release because in splunk-otel-java
# latest release is currently from 1.x branch that does not publish metadata yaml
latest_version=$(gh release list -R signalfx/$repo --json tagName -q ".[].tagName" | sort -r | head -n 1)
#latest_version=$(gh api -q .tag_name "repos/signalfx/$repo/releases/latest")
latest_vers_no_v="${latest_version#v}" # Remove leading 'v'

echo "REPO:            $repo"
echo "LATEST VERSION:  $latest_version"

if ! test -d yaml/$repo; then
  echo "Skipping ${repo} as yaml/${repo} does not exist."
  exit 0
fi

version_file=yaml/$repo/version
echo $latest_version > $version_file 

if git diff --quiet "${version_file}"; then
  echo "Already at the latest version. Exiting"
  exit 0
else
  echo
  echo "Version update necessary:"
  git diff "${version_file}"
  echo
fi

metadata_file_name="${repo}-metadata.yaml"
gh release download ${latest_version} -R signalfx/$repo -p ${metadata_file_name} -O apm/$repo/metadata.yaml --clobber

message="Update $repo version to $latest_version"
body="Update $repo version to \`$latest_version\`.

See https://github.com/signalfx/$repo/releases/tag/$latest_version."

existing_pr_count=$(gh pr list --state all --search "in:title $message" | wc -l)
if [ "$existing_pr_count" -gt 0 ]; then
    echo "PR(s) already exist for '$message'"
    gh pr list --state all --search "\"$message\" in:title"
    echo "So we won't create another. Exiting."
    exit 0
fi

branch="metdatata-update-bot/auto-update-$repo-$latest_version"

$GIT checkout -b "$branch"
$GIT commit -a -m "$message"
$GIT push --set-upstream origin "$branch"

echo "Submitting auto-update PR '$message'."
$GH pr create --title "$message" --body "$body"
#!/bin/bash -e

# parts copied from https://github.com/open-telemetry/opentelemetry.io/blob/main/scripts/auto-update/version-in-file.sh

GH=gh
GIT=git

if [[ -n "$GITHUB_ACTIONS" ]]; then
  # Ensure that we're starting from a clean state
  git fetch origin main
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

release=$(gh api "repos/signalfx/$repo/releases/latest")
latest_version=$(jq -r .tag_name <<<"$release")
latest_vers_no_v="${latest_version#v}" # Remove leading 'v'
metadata_file_name="${repo}-metadata.yaml"
fallback_metadata_file_name="metadata.yaml"

echo "REPO:            $repo"
echo "LATEST VERSION:  $latest_version"

if ! test -d apm/$repo; then
  echo "Skipping ${repo} as ${repo}/metadata.yaml does not exist."
  exit 0
fi

if jq -e --arg name "$metadata_file_name" \
  'any(.assets[]; .name == $name)' <<<"$release" >/dev/null; then
  :
elif jq -e --arg name "$fallback_metadata_file_name" \
  'any(.assets[]; .name == $name)' <<<"$release" >/dev/null; then
  metadata_file_name="$fallback_metadata_file_name"
else
  echo "Skipping ${repo}: release ${latest_version} does not include ${metadata_file_name} or ${fallback_metadata_file_name}."
  exit 0
fi

echo "METADATA FILE:   $metadata_file_name"

version_file=apm/$repo/version
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
if [[ -n "$GITHUB_ACTIONS" ]]; then
  pr_url=$(gh pr create --title "$message" --body "$body")
  echo "Created $pr_url"

  # Check the PR's actual diff against the current remote base. Only the
  # version file and published metadata artifact for the selected APM
  # repository may be auto-approved.
  auto_approve_and_merge=false
  changed_files=$(gh pr diff "$pr_url" --name-only)
  metadata_file="apm/$repo/metadata.yaml"
  case "$repo" in
    splunk-otel-java|splunk-otel-python|splunk-otel-dotnet|splunk-otel-js)
      unexpected_files=$(printf '%s\n' "$changed_files" | \
        awk -v version="$version_file" -v metadata="$metadata_file" \
          '$0 != version && $0 != metadata')
      if [[ -n "$changed_files" ]] &&
         [[ -z "$unexpected_files" ]] &&
         [[ "$(tr -d '\r\n' < "$version_file")" == "$latest_version" ]]; then
        auto_approve_and_merge=true
      fi
      ;;
  esac

  if [[ "$auto_approve_and_merge" == true ]]; then
    if [[ -z "$APPROVAL_TOKEN" ]]; then
      echo "APPROVAL_TOKEN is required to approve and merge published artifact updates."
      exit 1
    fi

    echo "Approving and merging published artifact update."
    GH_TOKEN="$APPROVAL_TOKEN" gh pr review "$pr_url" --approve \
      --body "Automatically approved: this PR only updates ${version_file} and its published metadata artifact."
    GH_TOKEN="$APPROVAL_TOKEN" gh pr merge "$pr_url" --squash --delete-branch
  else
    echo "Leaving $pr_url open for manual review because it changes files other than ${version_file} and ${metadata_file}."
  fi
else
  $GH pr create --title "$message" --body "$body"
fi

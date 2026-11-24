#!/bin/bash -e

# parts copied from https://github.com/open-telemetry/opentelemetry.io/blob/main/scripts/auto-update/version-in-file.sh

GH=gh
GIT=git

if [[ -n "$GITHUB_ACTIONS" ]]; then
  # Ensure that we're starting from a clean state
  git fetch origin main
  git reset --hard origin/main
  target_repository="$GITHUB_REPOSITORY"
  if [[ -z "${APPROVAL_TOKEN:-}" ]]; then
    echo "APPROVAL_TOKEN is required to approve, merge, and close superseded PRs."
    exit 1
  fi
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
latest_published_at=$(jq -r .published_at <<<"$release")
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

close_superseded_prs() {
  current_latest_version=$(gh api "repos/signalfx/$repo/releases/latest" --jq '.tag_name')
  if [[ "$current_latest_version" != "$latest_version" ]]; then
    echo "A newer release ($current_latest_version) now exists; skipping old-PR cleanup."
    return
  fi

  expected_title_prefix="Update $repo version to "
  expected_branch_prefix="metdatata-update-bot/auto-update-$repo-"
  while IFS=$'\t' read -r old_pr_number old_title old_branch; do
    [[ -n "$old_pr_number" ]] || continue
    [[ "$old_title" == "$expected_title_prefix"* ]] || continue
    [[ "$old_branch" == "$expected_branch_prefix"* ]] || continue

    old_version=${old_title#"$expected_title_prefix"}
    close_old_pr=false
    if [[ "$old_version" == "$latest_version" ]]; then
      close_old_pr=true
    elif old_published_at=$(gh api \
      "repos/signalfx/$repo/releases/tags/$old_version" --jq '.published_at'); then
      if [[ "$old_published_at" < "$latest_published_at" ]]; then
        close_old_pr=true
      fi
    fi

    if [[ "$close_old_pr" == true ]]; then
      GH_TOKEN="$APPROVAL_TOKEN" gh pr close "$old_pr_number" \
        --repo "$target_repository" \
        --comment "Closed because release $latest_version has been merged."
    fi
  done < <(GH_TOKEN="$APPROVAL_TOKEN" gh pr list \
    --repo "$target_repository" --state open --limit 100 \
    --json number,title,headRefName \
    --jq '.[] | [.number, .title, .headRefName] | @tsv')
}

version_file="apm/$repo/version"
metadata_file="apm/$repo/metadata.yaml"
echo "$latest_version" > "$version_file"

gh release download "$latest_version" -R "signalfx/$repo" \
  -p "$metadata_file_name" -O "$metadata_file" --clobber

if git diff --quiet -- "$version_file" "$metadata_file"; then
  echo "Version and metadata already match the latest release. Exiting"
  if [[ -n "$GITHUB_ACTIONS" ]]; then
    close_superseded_prs
  fi
  exit 0
fi

echo
echo "Release update necessary:"
git diff -- "$version_file" "$metadata_file"
echo

message="Update $repo version to $latest_version"
body="Update $repo version to \`$latest_version\`.

See https://github.com/signalfx/$repo/releases/tag/$latest_version."

branch="metdatata-update-bot/auto-update-$repo-$latest_version"

if [[ -n "$GITHUB_ACTIONS" ]]; then
  matching_prs=$(gh pr list --repo "$target_repository" --state all \
    --search "\"$message\" in:title" --limit 100 \
    --json number,title,url,state,mergedAt)
  pr_url=$(jq -r --arg title "$message" \
    '[.[] | select(.title == $title and .state == "OPEN")][0].url // empty' \
    <<<"$matching_prs")

  if [[ -n "$pr_url" ]]; then
    echo "Reusing existing PR $pr_url"
  else
    closed_pr_url=$(jq -r --arg title "$message" \
      '[.[] | select(.title == $title and .state == "CLOSED" and .mergedAt == null)][0].url // empty' \
      <<<"$matching_prs")
    merged_pr_url=$(jq -r --arg title "$message" \
      '[.[] | select(.title == $title and .mergedAt != null)][0].url // empty' \
      <<<"$matching_prs")

    if [[ -n "$closed_pr_url" ]]; then
      echo "Reopening existing PR $closed_pr_url"
      gh pr reopen "$closed_pr_url"
      pr_url="$closed_pr_url"
    elif [[ -n "$merged_pr_url" ]]; then
      echo "Release PR $merged_pr_url was already merged, but main no longer matches its artifact."
      echo "Refusing to create a duplicate PR for the same release."
      exit 1
    else
      $GIT checkout -b "$branch"
      $GIT commit -a -m "$message"
      $GIT push --set-upstream origin "$branch"

      echo "Submitting auto-update PR '$message'."
      pr_url=$(gh pr create --title "$message" --body "$body")
      echo "Created $pr_url"
    fi
  fi

  # Pin validation, approval, and merge to one immutable PR head commit.
  pr_number=${pr_url##*/}
  pr_json=$(gh api "repos/$target_repository/pulls/$pr_number")
  head_sha=$(jq -r '.head.sha' <<<"$pr_json")
  base_sha=$(jq -r '.base.sha' <<<"$pr_json")
  head_repository=$(jq -r '.head.repo.full_name' <<<"$pr_json")
  compare_json=$(gh api "repos/$target_repository/compare/${base_sha}...${head_sha}")
  changed_files=$(jq -r '.files[].filename' <<<"$compare_json")

  auto_approve_and_merge=false
  case "$repo" in
    splunk-otel-java|splunk-otel-python|splunk-otel-dotnet|splunk-otel-js)
      unexpected_files=$(printf '%s\n' "$changed_files" | \
        awk -v version="$version_file" -v metadata="$metadata_file" \
          '$0 != version && $0 != metadata')

      expected_version_blob=$(git hash-object "$version_file")
      expected_metadata_blob=$(git hash-object "$metadata_file")
      pr_version_blob=$(gh api \
        "repos/$head_repository/contents/$version_file?ref=$head_sha" --jq '.sha')
      pr_metadata_blob=$(gh api \
        "repos/$head_repository/contents/$metadata_file?ref=$head_sha" --jq '.sha')

      if [[ -n "$changed_files" ]] &&
         [[ -z "$unexpected_files" ]] &&
         [[ "$pr_version_blob" == "$expected_version_blob" ]] &&
         [[ "$pr_metadata_blob" == "$expected_metadata_blob" ]]; then
        auto_approve_and_merge=true
      fi
      ;;
  esac

  if [[ "$auto_approve_and_merge" == true ]]; then
    echo "Approving and merging published artifact update."
    GH_TOKEN="$APPROVAL_TOKEN" gh api --method POST \
      "repos/$target_repository/pulls/$pr_number/reviews" \
      -f event=APPROVE \
      -f commit_id="$head_sha" \
      -f body="Automatically approved: this PR matches release $latest_version."
    GH_TOKEN="$APPROVAL_TOKEN" gh pr merge "$pr_url" --squash --delete-branch \
      --match-head-commit "$head_sha"
    close_superseded_prs
  else
    echo "Leaving $pr_url open: its pinned head does not exactly match release $latest_version."
    exit 1
  fi
else
  $GIT checkout -b "$branch"
  $GIT commit -a -m "$message"
  $GIT push --set-upstream origin "$branch"
  $GH pr create --title "$message" --body "$body"
fi

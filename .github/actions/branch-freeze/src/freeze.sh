#!/usr/bin/env bash
# Upserts a repo-level ruleset that blocks pushes and PR merges on a branch.
# freeze   -> ruleset enabled on the branch
# unfreeze -> same ruleset kept, but disabled
set -euo pipefail

: "${OPERATION:?operation is required}"
: "${REPOSITORY:?repository is required}"
: "${BRANCH:?branch is required}"
: "${GH_TOKEN:?a token with Administration:write on the repo is required}"
: "${ACTOR:?actor is required}"

RULESET_NAME="${RULESET_NAME:-branch-code-freeze}"
BYPASS_USERS="${BYPASS_USERS:-}"

case "$OPERATION" in
  freeze)   enforcement=active ;;
  unfreeze) enforcement=disabled ;;
  *) echo "::error::operation must be freeze or unfreeze, got '$OPERATION'" >&2; exit 1 ;;
esac

# --paginate: without it a repo with many rulesets hides ours and we create a duplicate.
ruleset_id=$(gh api "repos/${REPOSITORY}/rulesets" --paginate \
  --jq ".[] | select(.name == \"${RULESET_NAME}\") | .id" | head -n1)

# A freeze over a live freeze would replace bypass_actors and ref_name wholesale,
# silently locking out whoever froze first or thawing the branch they froze. One
# ruleset per repo cannot hold two freezes, so refuse instead of clobbering.
if [ "$OPERATION" = freeze ] && [ -n "$ruleset_id" ]; then
  # The list endpoint omits bypass_actors and conditions; only the detail one has them.
  existing=$(gh api "repos/${REPOSITORY}/rulesets/${ruleset_id}")

  if [ "$(jq -r '.enforcement' <<<"$existing")" = active ]; then
    frozen_ref=$(jq -r '.conditions.ref_name.include[0] // ""' <<<"$existing")

    if [ "$frozen_ref" != "refs/heads/${BRANCH}" ]; then
      echo "::error::${RULESET_NAME} is already freezing ${frozen_ref}; unfreeze it before freezing ${BRANCH}" >&2
      exit 1
    fi

    actor_id=$(gh api "users/${ACTOR}" --jq '.id') || {
      echo "::error::no such GitHub user '${ACTOR}'" >&2; exit 1; }

    if ! jq -e --argjson id "$actor_id" \
      'any(.bypass_actors[]?; .actor_type == "User" and .actor_id == $id)' <<<"$existing" >/dev/null; then
      owners=$(jq -r '[.bypass_actors[]? | select(.actor_type == "User") | .actor_id] | join(" ")' <<<"$existing")
      for id in $owners; do
        echo "::notice::${BRANCH} is frozen by $(gh api "user/${id}" --jq '.login' || echo "user id ${id}")"
      done
      echo "::error::${BRANCH} is already frozen and ${ACTOR} is not in its bypass list; ask one of the users above to unfreeze" >&2
      exit 1
    fi

    echo "${BRANCH} is already frozen and ${ACTOR} is in the bypass list; refreshing it"
  fi
fi

# BYPASS_USERS is a comma separated list of logins; empty entries are skipped so
# callers can build it by concatenation without worrying about stray commas.
bypass_actors='[]'
seen=''
IFS=',' read -ra logins <<<"$BYPASS_USERS"
for login in ${logins[@]+"${logins[@]}"}; do
  login="${login// /}"
  [ -z "$login" ] && continue
  case " $seen " in *" $login "*) continue ;; esac
  seen="$seen $login"

  # The API wants a numeric user id, but a login is what a human can supply.
  user_id=$(gh api "users/${login}" --jq '.id') || {
    echo "::error::no such GitHub user '${login}'" >&2; exit 1; }
  bypass_actors=$(jq --argjson id "$user_id" \
    '. + [{actor_type: "User", actor_id: $id, bypass_mode: "always"}]' <<<"$bypass_actors")
  echo "Bypass: ${login} (user id ${user_id})"
done

payload=$(jq -n \
  --arg name "$RULESET_NAME" \
  --arg enforcement "$enforcement" \
  --arg ref "refs/heads/${BRANCH}" \
  --argjson bypass "$bypass_actors" \
  '{
    name: $name,
    target: "branch",
    enforcement: $enforcement,
    bypass_actors: $bypass,
    conditions: { ref_name: { include: [$ref], exclude: [] } },
    rules: [ { type: "update" } ]
  }')

if [ -n "$ruleset_id" ]; then
  echo "Updating ruleset ${RULESET_NAME} (#${ruleset_id}) -> ${OPERATION}"
  response=$(gh api -X PUT "repos/${REPOSITORY}/rulesets/${ruleset_id}" --input - <<<"$payload")
else
  if [ "$OPERATION" = unfreeze ]; then
    echo "::warning::no ruleset named ${RULESET_NAME} found, nothing to unfreeze"
    exit 0
  fi
  echo "Creating ruleset ${RULESET_NAME} -> ${OPERATION}"
  response=$(gh api -X POST "repos/${REPOSITORY}/rulesets" --input - <<<"$payload")
fi

echo "ruleset-id=$(jq -r '.id' <<<"$response")" >>"${GITHUB_OUTPUT:-/dev/null}"

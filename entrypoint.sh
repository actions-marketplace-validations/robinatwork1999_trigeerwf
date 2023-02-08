#!/usr/bin/env bash
set -e

GITHUB_API_URL="${API_URL:-https://api.github.com}"
GITHUB_SERVER_URL="${SERVER_URL:-https://github.com}"

validate_args() {
  wait_interval=10 # Waits for 10 seconds
  if [ "${INPUT_WAIT_INTERVAL}" ]
  then
    wait_interval=${INPUT_WAIT_INTERVAL}
  fi

  propagate_failure=true
  if [ -n "${INPUT_PROPAGATE_FAILURE}" ]
  then
    propagate_failure=${INPUT_PROPAGATE_FAILURE}
  fi

  trigger_workflow=true
  if [ -n "${INPUT_TRIGGER_WORKFLOW}" ]
  then
    trigger_workflow=${INPUT_TRIGGER_WORKFLOW}
  fi

  wait_workflow=true
  if [ -n "${INPUT_WAIT_WORKFLOW}" ]
  then
    wait_workflow=${INPUT_WAIT_WORKFLOW}
  fi

  if [ -z "${INPUT_OWNER}" ]
  then
    echo "Error: Owner is a required argument."
    exit 1
  fi

  if [ -z "${INPUT_REPO}" ]
  then
    echo "Error: Repo is a required argument."
    exit 1
  fi

  if [ -z "${INPUT_GITHUB_TOKEN}" ]
  then
    echo "Error: Github token is required. You can head over settings and"
    echo "under developer, you can create a personal access tokens. The"
    echo "token requires repo access."
    exit 1
  fi

  if [ -z "${INPUT_WORKFLOW_FILE_NAME}" ]
  then
    echo "Error: Workflow File Name is required"
    exit 1
  fi

  client_payload=$(echo '{}' | jq -c)
  if [ "${INPUT_CLIENT_PAYLOAD}" ]
  then
    client_payload=$(echo "${INPUT_CLIENT_PAYLOAD}" | jq -c)
  fi

  ref="main"
  if [ "$INPUT_REF" ]
  then
    ref="${INPUT_REF}"
  fi
}

api() {
  path=$1; shift
  if response=$(curl --fail-with-body -sSL \
      "${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/actions/$path" \
      -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -H 'Content-Type: application/json' \
      "$@")
  then
    echo "$response"
  else
    echo >&2 "api failed:"
    echo >&2 "path: $path"
    echo >&2 "response: $response"
    if [[ "$response" == *'"Server Error"'* ]]; then 
      echo "Server error - trying again"
    else
      exit 1
    fi
  fi
}


# Return the ids of the most recent workflow runs, optionally filtered by user
get_workflow_runs() {
  since=${1:?}
  query="event=workflow_dispatch&created=>=$since${INPUT_GITHUB_USER+&actor=}${INPUT_GITHUB_USER}&per_page=100"
  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/runs?${query}" |
  jq -r '.workflow_runs[].id' |
  sort # Sort to ensure repeatable order, and lexicographically for compatibility with join
}

trigger_workflow() {
  START_TIME=$(date +%s)
  SINCE=$(date -u -Iseconds -d "@$((START_TIME - 120))") # Two minutes ago, to overcome clock skew

  OLD_RUNS=$(get_workflow_runs "$SINCE")

  echo >&2 "Triggering workflow:"
  echo >&2 "  workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches"
  echo >&2 "  {\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  api "workflows/${INPUT_WORKFLOW_FILE_NAME}/dispatches" \
    --data "{\"ref\":\"${ref}\",\"inputs\":${client_payload}}"

  NEW_RUNS=$OLD_RUNS
  while [ "$NEW_RUNS" = "$OLD_RUNS" ]
  do
    NEW_RUNS=$(get_workflow_runs "$SINCE")
  done

  # Return new run ids
  join -v2 <(echo "$OLD_RUNS") <(echo "$NEW_RUNS")
}


comment_downstream_link() {
  if response=$(curl --fail-with-body -sSL -X POST \
      "${INPUT_COMMENT_DOWNSTREAM_URL}" \
      -H "Authorization: Bearer ${INPUT_COMMENT_GITHUB_TOKEN}" \
      -H 'Accept: application/vnd.github.v3+json' \
      -d "{\"body\": \"Running downstream job at $1\"}")
  then
    echo "$response"
  else
    echo >&2 "failed to comment to ${INPUT_COMMENT_DOWNSTREAM_URL}:"
  fi
}

wait_for_workflow_to_finish() {
  last_workflow_id=${1:?}
  last_workflow_url="${GITHUB_SERVER_URL}/${INPUT_OWNER}/${INPUT_REPO}/actions/runs/${last_workflow_id}"


  echo "Waiting for workflow to finish:"
  echo "The workflow id is [${last_workflow_id}]."
  echo "The workflow logs can be found at ${last_workflow_url}"
  echo "workflow_id=${last_workflow_id}" >> $GITHUB_OUTPUT
  echo "workflow_url=${last_workflow_url}" >> $GITHUB_OUTPUT
  echo ""

  if [ -n "${INPUT_COMMENT_DOWNSTREAM_URL}" ]; then
    comment_downstream_link ${last_workflow_url}
  fi

  conclusion=null
  status=

  while [[ "${conclusion}" == "null" && "${status}" != "completed" ]]
  do 
    workflow=$(api "runs/$last_workflow_id")
    conclusion=$(echo "${workflow}" | jq -r '.conclusion')
    status=$(echo "${workflow}" | jq -r '.status')
  done

  if [[ "${conclusion}" == "success" && "${status}" == "completed" ]]
  then
    echo "Workflow Completed Successfully"
    echo "Fetching The PR Link"

    if response=$(curl \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${INPUT_COMMENT_GITHUB_TOKEN}"\
    -H "X-GitHub-Api-Version: 2022-11-28" \
    ${GITHUB_API_URL}/repos/${INPUT_OWNER}/${INPUT_REPO}/pulls?state=open | jq -r '.[].html_url')
    then
    echo $response[0]
    else
    echo "PR Link Not Fetched Due To Some Error"
    fi
  else
    echo "Conclusion is not success, it's [${conclusion}]."

    if [ "${propagate_failure}" = true ]
    then
      echo "Propagating failure to upstream job"
      exit 1
    fi
  fi
}

main() {
  validate_args

  if [ "${trigger_workflow}" = true ]
  then
    run_ids=$(trigger_workflow)
  else
    echo "Skipping triggering the workflow."
  fi

  if [ "${wait_workflow}" = true ]
  then
    for run_id in $run_ids
    do
      wait_for_workflow_to_finish "$run_id"
    done
  else
    echo "Skipping waiting for workflow."
  fi
}

main

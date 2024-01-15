#!/bin/bash

BUILDKITE_PLUGIN_AWS_SM_ENDPOINT_URL="${BUILDKITE_PLUGIN_AWS_SM_ENDPOINT_URL:-}"
BUILDKITE_PLUGIN_AWS_SM_REGION="${BUILDKITE_PLUGIN_AWS_SM_REGION:-}"

function strip_quotes() {
  echo "${1}" | sed "s/^[[:blank:]]*//g;s/[[:blank:]]*$//g;s/[\"']//g"
}

function get_secret_value() {
  local secretId="$1"
  local allowBinary="${2:-}"
  local regionFlag=""
  local endpointUrlFlag=""

  # secret is an arn rather than name, deduce the region
  local arnRegex='^arn:aws:secretsmanager:([^:]+):'
  if [[ "${secretId}" =~ $arnRegex ]] ; then
    regionFlag="--region ${BASH_REMATCH[1]}"
  fi

  if [[ -n "${BUILDKITE_PLUGIN_AWS_SM_REGION}" ]] ; then
    regionFlag="--region ${BUILDKITE_PLUGIN_AWS_SM_REGION}"
  fi

  if [[ -n "${BUILDKITE_PLUGIN_AWS_SM_ENDPOINT_URL}" ]] ; then
    endpointUrlFlag="--endpoint-url ${BUILDKITE_PLUGIN_AWS_SM_ENDPOINT_URL}"
  fi

  # Extract the secret string and secret binary
  # the secret is declared local before using it, per http://mywiki.wooledge.org/BashPitfalls#local_varname.3D.24.28command.29
  local secrets;
  echo -e "\033[31m" >&2
  secrets=$(aws secretsmanager get-secret-value \
      --secret-id "${secretId}" \
      --version-stage AWSCURRENT \
      $regionFlag \
      $endpointUrlFlag \
      --output json \
      --query '{SecretString: SecretString, SecretBinary: SecretBinary}')

  local result=$?
  echo -e "\033[0m" >&2
  if [[ $result -ne 0 ]]; then
    exit 1
  fi

  # if the secret binary field has a value, assume it's a binary
  local secretBinary=$(echo "${secrets}" | jq -r '.SecretBinary | select(. != null)')
  if [[ -n "${secretBinary}" ]]; then
    # don't read binary in cases where it's not allowed
    if [[ "${allowBinary}" == "allow-binary" ]]; then
      echo "${secretBinary}" | base64 -d
      return
    fi
    echo -e "\033[31mBinary encoded secret cannot be used in this way (e.g. env var)\033[0m" >&2
    exit 1
  fi

  # assume it's a string
  echo "${secrets}" | jq -r '.SecretString'
}

assume_role() {
  local role_arn="$1"
  local build="$2"

  local role_session_name="aws-sm-buildkite-plugin-session-${build}"
  local duration_seconds="900"

  # Get the role credentials so that we can assume the role
  local role_credentials=$(aws sts assume-role \
    --role-arn "${role_arn}" \
    --role-session-name "${role_session_name}" \
    --duration-seconds "${duration_seconds}" \
    --output json)

  local result=$?
  if [[ $result -ne 0 ]]; then
    echo -e "\033[31mFailed to assume role\033[0m" >&2
    exit 1
  fi

  # Extract the temporary credentials
  local access_key_id=$(echo $role_credentials | jq -r '.Credentials.AccessKeyId')
  local secret_access_key=$(echo $role_credentials | jq -r '.Credentials.SecretAccessKey')
  local session_token=$(echo $role_credentials | jq -r '.Credentials.SessionToken')

  # Retrieve the secret within the subshell, using the temporary credentials
  AWS_ACCESS_KEY_ID=$access_key_id
  AWS_SECRET_ACCESS_KEY=$secret_access_key
  AWS_SESSION_TOKEN=$session_token
}

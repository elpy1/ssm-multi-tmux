#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
#set -x

declare -r BASENAME=${0##*/}

main () {
  local ids k v args=()

  while (( $# )); do
    case $1 in
      -t|--tag)
        (( $# >= 3 )) || die "$(usage)"
        shift; k="$1"
        ;;
      -a|--asg|-v|--value)
        (( $# >= 3 )) || die "$(usage)"
        k="${k:-aws:autoscaling:groupName}"
        shift; v="$1"
        ;;
      -h|--help) help; exit ;;
      --)        shift; break ;;
      -*)        die "$(usage)" ;;
      *)         args+=( "$1" ) ;;
    esac
    shift
  done

  set -- ${args[@]:+"${args[@]}"} "$@"

  (( $# >= 1 )) || die "$(usage)"

  for x in aws tmux session-manager-plugin; do
    has "$x"
  done

  ids="$(get_instances "${k}" "${v}")"
  tmux_ssm_session "${ids}" "sudo $*"
}

tmux_ssm_session () {
  local session instances="$1" ssm_cmd="$2"

  session="${BASENAME%%.*}-$(mktemp -u XXXXXX)"

  tmux new-session -d -s "${session}" >/dev/null
  trap 'tmux kill-session -t "${session}" 2>/dev/null' EXIT

  for i in ${instances}; do
    tmux select-layout -t "${session}:0" tiled
    tmux split-window -t "${session}:0" \
      "aws ssm start-session \
      --document-name AWS-StartInteractiveCommand \
      --parameters command='[\"${ssm_cmd}\"]' \
      --target ${i}"
  done

  tmux kill-pane -t "${session}:0.0"
  tmux select-layout -t "${session}:0" tiled
  tmux select-window -t "${session}:0"
  tmux set-window-option synchronize-panes on 2>/dev/null
  exec tmux attach-session -t "${session}:0"
}

get_instances () {
  local instances k="$1" v="$2"

  instances="$(aws ec2 describe-instances \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --filters Name=tag:"${k}",Values="${v}" \
    Name=instance-state-code,Values=16 \
    --output text)" || die "[${BASENAME}] error: aws: returned status $?"

  if [[ -z ${instances} ]]; then
    die "[${BASENAME}] error: aws: returned no EC2 instances"
  fi

  printf '%s' "${instances}"
}


help () {
  cat <<EOF
Usage: ${BASENAME} [--tag KEY] --value VALUE | --asg NAME [--] COMMAND [ARG ...]
Run an interactive AWS SSM command in synchronised tmux panes on one or more EC2
instances by specifying the autoscaling group name or tag key and value.

 Optional parameters:
  -t, --tag KEY              EC2 instance tag key

 Required parameter:
  -a, --asg NAME             EC2 autoscaling group name; or
  -v, --value VALUE          EC2 instance tag value (if --tag provided)

 Help options:
  -h, --help                 Provide this help output

This script uses EC2 describe-instances to query for the autoscaling group or
tag key and value provided. If successful a local tmux session is created.
COMMAND is run on each returned instance in synchronised tmux panes using AWS
Session Manager plugin. Use -- if COMMAND requires its own arguments.

Examples:

  ${BASENAME} --tag Name --value prod-internal-cms02 -- bash
  ${BASENAME} --asg wordpress-prod htop
  ${BASENAME} --asg drupal-web-asg -- journalctl -f -u httpd
  ${BASENAME} --tag webgroup --value drupal-frontend -- watch -t -n1 date +%s
EOF
}

usage () {
  cat <<EOF
Usage: ${BASENAME} [-h] [-t <key>] -v <value> | -a <asg name> [--] <command>
Try '${BASENAME} --help' for more information.
EOF
}

has () {
  command -vp "$1" &>/dev/null || die "error: executable '${x}' not found"
}

die () { printf '%s\n' "$*" >&2; exit 1; }

main "$@"

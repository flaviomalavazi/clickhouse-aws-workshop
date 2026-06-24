#!/usr/bin/env bash
# generator_ec2.sh — start/stop the workshop generator EC2 to save cost between demos.
#
# Stopping the instance halts all compute billing (you keep only the small EBS
# charge). The ch-generators systemd service is enabled, so on start it boots,
# auto-resumes the generators, and they reconnect to Aurora on their own. This
# script additionally waits for SSM and confirms the service is active.
#
# Usage:
#   ./generator_ec2.sh start     # power on + resume generators (default)
#   ./generator_ec2.sh stop      # power off to save cost
#   ./generator_ec2.sh status    # instance state + generator service status
#   ./generator_ec2.sh restart   # stop, then start
#
# Instance id + region are read from `terraform output` by default. Override with
# the INSTANCE_ID and/or AWS_REGION environment variables.
set -euo pipefail

ACTION="${1:-start}"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"

# Resolve instance id + region from the Terraform SSM-command output
# ("aws ssm start-session --target <id> --region <region>"), falling back to env.
SSM_CMD="$(terraform -chdir="$TF_DIR" output -raw generator_ec2_ssm_command 2>/dev/null || true)"
INSTANCE_ID="${INSTANCE_ID:-$(awk '{for (i=1;i<=NF;i++) if ($i=="--target") print $(i+1)}' <<<"$SSM_CMD")}"
AWS_REGION="${AWS_REGION:-$(awk '{for (i=1;i<=NF;i++) if ($i=="--region") print $(i+1)}' <<<"$SSM_CMD")}"
AWS_REGION="${AWS_REGION:-us-east-1}"

if [ -z "${INSTANCE_ID:-}" ]; then
  echo "ERROR: could not determine the instance id." >&2
  echo "  Run from a checkout where 'terraform output generator_ec2_ssm_command' works," >&2
  echo "  or set INSTANCE_ID (and AWS_REGION) explicitly. Is enable_generator_ec2 = true?" >&2
  exit 1
fi

aws_ec2() { aws ec2 "$@" --region "$AWS_REGION"; }

instance_state() {
  aws_ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].State.Name" --output text
}

# Run a shell snippet on the instance via SSM and print its stdout.
run_remote() {
  local cmd_id
  cmd_id="$(aws ssm send-command --region "$AWS_REGION" --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[$1]" \
    --query Command.CommandId --output text)"
  aws ssm wait command-executed --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$INSTANCE_ID" 2>/dev/null || true
  aws ssm get-command-invocation --region "$AWS_REGION" \
    --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
    --query StandardOutputContent --output text
}

wait_for_ssm() {
  echo "Waiting for the SSM agent to come online..."
  for _ in $(seq 1 36); do   # up to ~3 min
    if [ "$(aws ssm describe-instance-information --region "$AWS_REGION" \
              --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
              --query "InstanceInformationList[0].PingStatus" --output text 2>/dev/null)" = "Online" ]; then
      return 0
    fi
    sleep 5
  done
  echo "  SSM agent didn't report Online in time; the instance is running but you" >&2
  echo "  may need to check the generators manually via Session Manager." >&2
  return 1
}

echo "Instance: $INSTANCE_ID   Region: $AWS_REGION"

case "$ACTION" in
  stop)
    echo "Stopping (saves compute cost)..."
    aws_ec2 stop-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws_ec2 wait instance-stopped --instance-ids "$INSTANCE_ID"
    echo "Stopped. Only EBS storage is billed now. Run '$0 start' to resume."
    ;;

  start)
    echo "Starting..."
    aws_ec2 start-instances --instance-ids "$INSTANCE_ID" >/dev/null
    aws_ec2 wait instance-running --instance-ids "$INSTANCE_ID"
    if wait_for_ssm; then
      echo "Resuming generators..."
      run_remote '"systemctl start ch-generators","sleep 3","systemctl is-active ch-generators","journalctl -u ch-generators -n 8 --no-pager"'
    fi
    echo "Done."
    ;;

  restart)
    bash "$0" stop
    bash "$0" start
    ;;

  status)
    state="$(instance_state)"
    echo "Instance state: $state"
    echo "Connect:        aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION"
    if [ "$state" = "running" ]; then
      run_remote '"systemctl is-active ch-generators","systemctl is-enabled ch-generators","journalctl -u ch-generators -n 8 --no-pager"'
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop|status|restart}" >&2
    exit 2
    ;;
esac

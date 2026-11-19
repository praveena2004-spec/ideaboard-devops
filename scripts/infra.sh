#!/usr/bin/env bash
# One interface for every cloud. Switching cloud = changing the first argument.
#
#   scripts/infra.sh <cloud> <env> <command>
#     cloud    aws | gcp                       (terraform/environments/<cloud>)
#     env      free-tier | production | ...    (<env>.tfvars, also the Terraform workspace)
#     command  plan | apply | destroy | output
#              kubeconfig      fetch the k3s kubeconfig into .secrets/<cloud>-<env>.kubeconfig
#              wait-app        wait until http://<public_ip>/ serves the app
#              deploy-env      print `export` lines for scripts/deploy.sh
#              github-secrets  store KUBE_CONFIG + DB settings in the GitHub environment "<cloud>"
#
# Examples
#   scripts/infra.sh aws free-tier apply
#   scripts/infra.sh aws free-tier kubeconfig
#   scripts/infra.sh aws free-tier github-secrets
#   TF_VAR_project_id=my-proj scripts/infra.sh gcp free-tier apply
set -euo pipefail

CLOUD="${1:?usage: infra.sh <aws|gcp> <env> <command>}"
ENV_NAME="${2:?env (tfvars name) required}"
CMD="${3:?command required}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform/environments/$CLOUD"
VARS="$ENV_NAME.tfvars"
SECRETS_DIR="$ROOT/.secrets"
KEY_FILE="$SECRETS_DIR/$CLOUD-$ENV_NAME.key"
KUBECONFIG_FILE="$SECRETS_DIR/$CLOUD-$ENV_NAME.kubeconfig"
TERRAFORM="${TERRAFORM:-terraform}"
GH="${GH:-gh}"

[[ -d "$TF_DIR" ]] || { echo "Unknown cloud: $CLOUD (no $TF_DIR)"; exit 1; }
[[ -f "$TF_DIR/$VARS" ]] || { echo "No $TF_DIR/$VARS"; exit 1; }
mkdir -p "$SECRETS_DIR"

tf() { "$TERRAFORM" -chdir="$TF_DIR" "$@"; }
out() { tf output -raw "$1"; }
# Free DNS name for the VM's IP (1.2.3.4 -> 1-2-3-4.sslip.io), so the HTTPS edge
# can get a real Let's Encrypt certificate without buying a domain.
public_host() { local ip; ip="$(out public_ip)"; echo "${ip//./-}.sslip.io"; }

init() {
  tf init -input=false >/dev/null
  tf workspace select -or-create "$ENV_NAME" >/dev/null
}

fetch_kubeconfig() {
  local ip user
  ip="$(out public_ip)"
  user="$(out ssh_user)"
  [[ -n "$ip" && "$ip" != "null" ]] || { echo "No public_ip output: managed flavor? Use: $(out kubeconfig_command)"; exit 1; }
  out ssh_private_key > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  local ssh_opts=(-i "$KEY_FILE" -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$SECRETS_DIR/known_hosts" -o ConnectTimeout=10)
  echo "Waiting for k3s on $ip (first boot takes ~2-4 minutes)..."
  for _ in $(seq 1 60); do
    if ssh "${ssh_opts[@]}" "$user@$ip" "sudo test -f /var/lib/ideaboard-bootstrapped && sudo k3s kubectl get --raw /readyz" >/dev/null 2>&1; then
      ssh "${ssh_opts[@]}" "$user@$ip" "sudo cat /etc/rancher/k3s/k3s.yaml" \
        | sed "s#https://127.0.0.1:6443#https://$ip:6443#; s#: default\$#: ideaboard-$CLOUD-$ENV_NAME#" > "$KUBECONFIG_FILE"
      chmod 600 "$KUBECONFIG_FILE"
      echo "Wrote $KUBECONFIG_FILE"
      echo "  export KUBECONFIG=\"$KUBECONFIG_FILE\""
      return 0
    fi
    sleep 10
  done
  echo "k3s did not become ready in time"; exit 1
}

case "$CMD" in
  plan)    init; tf plan -var-file="$VARS" ;;
  apply)   init; tf apply -var-file="$VARS" -auto-approve ;;
  destroy) init; tf destroy -var-file="$VARS" -auto-approve ;;
  output)  init; tf output ;;
  kubeconfig) init; fetch_kubeconfig ;;
  wait-app)
    init; host="$(public_host)"
    for _ in $(seq 1 60); do
      curl -fsS -o /dev/null "https://$host/" && curl -fsS "https://$host/api/version" && { echo; echo "App is up: https://$host/"; exit 0; }
      sleep 10
    done
    echo "App not reachable on https://$host/"; exit 1 ;;
  deploy-env)
    init
    echo "export POSTGRES_HOST='$(out database_host)'"
    echo "export POSTGRES_PORT='$(out database_port)'"
    echo "export POSTGRES_DB='$(out database_name)'"
    echo "export POSTGRES_USER='$(out database_username)'"
    echo "export POSTGRES_PASSWORD='$(out database_password)'"
    echo "export PUBLIC_HOST='$(public_host)'"
    [[ -f "$KUBECONFIG_FILE" ]] && echo "export KUBECONFIG='$KUBECONFIG_FILE'" ;;
  github-secrets)
    # One GitHub environment per cloud; the pipeline deploys to each of them.
    init
    [[ -f "$KUBECONFIG_FILE" ]] || fetch_kubeconfig
    repo="$("$GH" repo view --json nameWithOwner -q .nameWithOwner)"
    "$GH" api -X PUT "repos/$repo/environments/$CLOUD" >/dev/null
    base64 -w0 "$KUBECONFIG_FILE" | "$GH" secret set KUBE_CONFIG --env "$CLOUD"
    out database_host     | "$GH" secret set POSTGRES_HOST --env "$CLOUD"
    out database_name     | "$GH" secret set POSTGRES_DB --env "$CLOUD"
    out database_username | "$GH" secret set POSTGRES_USER --env "$CLOUD"
    out database_password | "$GH" secret set POSTGRES_PASSWORD --env "$CLOUD"
    ip="$(out public_ip)"
    if [[ -n "$ip" && "$ip" != "null" ]]; then
      "$GH" variable set PUBLIC_HOST --env "$CLOUD" --body "$(public_host)"
      "$GH" variable set APP_URL --env "$CLOUD" --body "https://$(public_host)/"
    fi
    echo "GitHub environment '$CLOUD' configured for $repo" ;;
  *) echo "Unknown command: $CMD"; exit 1 ;;
esac

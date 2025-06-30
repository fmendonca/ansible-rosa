#!/bin/bash
set -euo pipefail

log_info()   { echo "ℹ️  [INFO] $*"; }
log_warn()   { echo "⚠️  [WARN] $*"; }
log_error()  { echo "❌ [ERROR] $*"; }

AWS_REGION="${AWS_REGION:?Defina AWS_REGION}"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PROJETOS_TXT="files/projects.txt"
SA_NAME="image-uploader"
KUBECONFIG_SRC="/tmp/kubeconfig_clustersrc"
SRC_AUTH="/tmp/podman-auth-src.json"
DST_AUTH="/tmp/podman-auth-dst.json"

# Usa sudo se não for root
if [[ $(id -u) -eq 0 ]]; then
  PODMAN_BIN="podman"
else
  PODMAN_BIN="sudo podman"
fi

log_info "Gerando kubeconfig temporário com oc whoami..."
TOKEN=$(oc whoami --show-token)
SERVER=$(oc whoami --show-server)
USER=$(oc whoami)

cat > "$KUBECONFIG_SRC" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    insecure-skip-tls-verify: true
    server: $SERVER
  name: src-cluster
contexts:
- context:
    cluster: src-cluster
    user: $USER
  name: src-context
current-context: src-context
users:
- name: $USER
  user:
    token: $TOKEN
EOF

log_info "Garantindo que a rota default-route está habilitada..."
oc --kubeconfig="$KUBECONFIG_SRC" patch configs.imageregistry cluster --type merge -p '{"spec":{"defaultRoute":true}}'

log_info "Aguardando a criação da rota default-route..."
for i in {1..10}; do
  if oc --kubeconfig="$KUBECONFIG_SRC" get route default-route -n openshift-image-registry &>/dev/null; then
    break
  fi
  sleep 2
done

if ! oc --kubeconfig="$KUBECONFIG_SRC" get route default-route -n openshift-image-registry &>/dev/null; then
  log_error "Rota default-route não encontrada após o patch. Abortando."
  exit 1
fi

REG_SRC=$(oc --kubeconfig="$KUBECONFIG_SRC" get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
REG_DST="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log_info "Registry origem: $REG_SRC"
log_info "Registry destino (ECR): $REG_DST"

log_info "Efetuando login no Amazon ECR..."
aws ecr get-login-password --region "$AWS_REGION" | $PODMAN_BIN login --username AWS --password-stdin "$REG_DST" --authfile "$DST_AUTH"

IGNORAR_PROJETOS="openshift kube-system kube-public openshift-monitoring openshift-marketplace openshift-config openshift-config-managed openshift-infra openshift-image-registry"

while read -r projeto || [[ -n "$projeto" ]]; do
  if echo "$IGNORAR_PROJETOS" | grep -qw "$projeto"; then
    log_info "Ignorando projeto sistêmico: $projeto"
    continue
  fi

  log_info "Projeto: $projeto"

  if ! oc --kubeconfig="$KUBECONFIG_SRC" -n "$projeto" get sa "$SA_NAME" &>/dev/null; then
    oc --kubeconfig="$KUBECONFIG_SRC" -n "$projeto" create sa "$SA_NAME"
  fi

  for i in {1..5}; do
    if oc --kubeconfig="$KUBECONFIG_SRC" -n "$projeto" get sa "$SA_NAME" &>/dev/null; then break; fi
    sleep 1
  done

  oc --kubeconfig="$KUBECONFIG_SRC" -n "$projeto" policy add-role-to-user system:image-puller -z "$SA_NAME" >/dev/null || true

  SRC_TOKEN=$(oc --kubeconfig="$KUBECONFIG_SRC" -n "$projeto" create token "$SA_NAME" --duration=15m || true)

  if [[ -z "$SRC_TOKEN" ]]; then
    log_error "Falha ao obter token da SA $SA_NAME. Pulando projeto $projeto..."
    continue
  fi

  log_info "Login no OpenShift (origem) com podman..."
  if ! $PODMAN_BIN login "$REG_SRC" -u "$SA_NAME" -p "$SRC_TOKEN" --authfile "$SRC_AUTH"; then
    log_error "Falha no login de origem com podman. Pulando..."
    continue
  fi

  IS_JSON=$(oc --kubeconfig="$KUBECONFIG_SRC" get is -n "$projeto" -o json || true)
  if ! echo "$IS_JSON" | jq -e '.items | length > 0' >/dev/null; then
    log_warn "Nenhum ImageStream no projeto $projeto. Ignorando."
    continue
  fi

  echo "$IS_JSON" | jq -c '.items[]' | while read -r is_entry; do
    is_name=$(echo "$is_entry" | jq -r '.metadata.name')
    tags=$(echo "$is_entry" | jq -r '.status.tags // [] | .[].tag')

    if [[ -z "$tags" ]]; then
      log_warn "ImageStream $is_name sem tags. Ignorando."
      continue
    fi

    for tag in $tags; do
      log_info "Migrando imagem $is_name:$tag do projeto $projeto"

      SRC_IMAGE="$REG_SRC/$projeto/$is_name:$tag"
      DST_IMAGE="$REG_DST/$projeto-$is_name:$tag"

      log_info "Pull $SRC_IMAGE"
      if ! REGISTRY_AUTH_FILE="$SRC_AUTH" $PODMAN_BIN pull "$SRC_IMAGE"; then
        log_error "Falha ao puxar $SRC_IMAGE"
        continue
      fi

      log_info "Criando repositório ECR (se não existir)..."
      aws ecr describe-repositories --repository-names "$projeto-$is_name" --region "$AWS_REGION" >/dev/null 2>&1 || \
      aws ecr create-repository --repository-name "$projeto-$is_name" --region "$AWS_REGION"

      $PODMAN_BIN tag "$SRC_IMAGE" "$DST_IMAGE"

      log_info "Push $DST_IMAGE"
      if ! REGISTRY_AUTH_FILE="$DST_AUTH" $PODMAN_BIN push "$DST_IMAGE"; then
        log_error "Falha ao enviar $DST_IMAGE"
      fi

      $PODMAN_BIN rmi "$SRC_IMAGE" "$DST_IMAGE" >/dev/null || true
    done
  done
done < "$PROJETOS_TXT"

rm -f "$SRC_AUTH" "$DST_AUTH" "$KUBECONFIG_SRC"
log_info "Migração concluída para o ECR!"

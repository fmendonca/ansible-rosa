#!/bin/bash
set -euo pipefail

# === LOG FUNCTIONS ===
log_info()   { echo "ℹ️  [INFO] $*"; }
log_warn()   { echo "⚠️  [WARN] $*"; }
log_error()  { echo "❌ [ERROR] $*"; }

# === CONFIG ===
SRC_KUBECONFIG="${SRC_KUBECONFIG:?Defina SRC_KUBECONFIG}"
DST_KUBECONFIG="${DST_KUBECONFIG:?Defina DST_KUBECONFIG}"
PROJETOS_TXT="projetos.txt"
SA_NAME="image-uploader"

REG_SRC=$(oc --kubeconfig="$SRC_KUBECONFIG" get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
REG_DST=$(oc --kubeconfig="$DST_KUBECONFIG" get route default-route -n openshift-image-registry --template='{{ .spec.host }}')

log_info "Registry origem: $REG_SRC"
log_info "Registry destino: $REG_DST"

while read -r projeto || [[ -n "$projeto" ]]; do
  log_info "Projeto: $projeto"

  if ! oc --kubeconfig="$DST_KUBECONFIG" get project "$projeto" &>/dev/null; then
    log_info "Criando projeto no destino: $projeto"
    oc --kubeconfig="$DST_KUBECONFIG" new-project "$projeto" >/dev/null
  fi

  for CLUSTER in origem destino; do
    [[ "$CLUSTER" == "origem" ]] && KCFG="$SRC_KUBECONFIG" && ROLE="system:image-puller" || KCFG="$DST_KUBECONFIG" && ROLE="system:image-builder"

    log_info "Garantindo SA $SA_NAME no $CLUSTER..."
    if ! oc --kubeconfig="$KCFG" -n "$projeto" get sa "$SA_NAME" &>/dev/null; then
      oc --kubeconfig="$KCFG" -n "$projeto" create sa "$SA_NAME"
    fi

    for i in {1..5}; do
      if oc --kubeconfig="$KCFG" -n "$projeto" get sa "$SA_NAME" &>/dev/null; then break; fi
      log_info "Aguardando SA $SA_NAME no $CLUSTER..."
      sleep 1
    done

    log_info "Aplicando permissão $ROLE ao $SA_NAME no $CLUSTER..."
    oc --kubeconfig="$KCFG" -n "$projeto" policy add-role-to-user "$ROLE" -z "$SA_NAME" >/dev/null
  done

  log_info "Criando tokens das SAs..."
  SRC_TOKEN=$(oc --kubeconfig="$SRC_KUBECONFIG" -n "$projeto" create token "$SA_NAME" --duration=15m || true)
  DST_TOKEN=$(oc --kubeconfig="$DST_KUBECONFIG" -n "$projeto" create token "$SA_NAME" --duration=15m || true)

  if [[ -z "$SRC_TOKEN" || -z "$DST_TOKEN" ]]; then
    log_error "Falha ao obter tokens no projeto $projeto. Pulando..."
    continue
  fi

  SRC_AUTH="/tmp/podman-auth-src.json"
  DST_AUTH="/tmp/podman-auth-dst.json"

  log_info "Login com podman no cluster origem..."
  if ! podman login "$REG_SRC" -u "$SA_NAME" -p "$SRC_TOKEN" --authfile "$SRC_AUTH"; then
    log_error "Falha no login de origem com podman. Pulando..."
    continue
  fi

  log_info "Login com podman no cluster destino..."
  if ! podman login "$REG_DST" -u "$SA_NAME" -p "$DST_TOKEN" --authfile "$DST_AUTH"; then
    log_error "Falha no login de destino com podman. Pulando..."
    continue
  fi

  IS_JSON=$(oc --kubeconfig="$SRC_KUBECONFIG" get is -n "$projeto" -o json || true)

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
      DST_IMAGE="$REG_DST/$projeto/$is_name:$tag"

      log_info "Pull $SRC_IMAGE"
      if ! REGISTRY_AUTH_FILE="$SRC_AUTH" podman pull "$SRC_IMAGE"; then
        log_error "Falha ao puxar $SRC_IMAGE"
        continue
      fi

      podman tag "$SRC_IMAGE" "$DST_IMAGE"

      log_info "Push $DST_IMAGE"
      if ! REGISTRY_AUTH_FILE="$DST_AUTH" podman push "$DST_IMAGE"; then
        log_error "Falha ao enviar $DST_IMAGE"
      fi

      podman rmi "$SRC_IMAGE" "$DST_IMAGE" >/dev/null || true
    done
  done

done < "$PROJETOS_TXT"

rm -f /tmp/podman-auth-src.json /tmp/podman-auth-dst.json
log_info "Migração concluída!"


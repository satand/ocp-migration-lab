#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIGURAZIONE DI DEFAULT
# (Puoi sovrascriverli via variabili d'ambiente)
# ==========================================
SRC_CONTEXT="${SRC_CONTEXT:-}"
DST_CONTEXT="${DST_CONTEXT:-}"
DEBUG="${DEBUG:-false}"

NAMESPACE=""
SKIP_CONFIRM=false
FORCE_ALL=false
SRC_PATTERNS=()
SRC_PATTERNS_JSON="[]"
CLUSTER_REF_WARNINGS=()
READY_NAMES=()
READY_JSON=()
FAILED_NAMES=()
SKIPPED_NAMES=()

# ==========================================
# FUNZIONI
# ==========================================
usage() {
    cat <<EOF
Uso: $0 [OPZIONI] <secret-name> [secret-name ...]

Migra uno o più Secret da un cluster OpenShift sorgente a uno destinazione.
Nome, namespace, dati, tipo, label e annotazioni non cluster-specifiche vengono preservati.

I Secret gestiti dal cluster (service-account-token, dockercfg, dockerconfigjson)
vengono segnalati e, senza -a, non migrati in modalità non interattiva.
In modalità interattiva viene chiesta conferma per ciascuno.

Opzioni:
  -s <context>    Context oc/kubectl del cluster sorgente (obbligatorio)
  -d <context>    Context oc/kubectl del cluster destinazione (obbligatorio)
  -n <namespace>  Namespace dei Secret
                  (default: progetto corrente del context sorgente)
  -a              Forza la migrazione anche dei Secret gestiti dal cluster
  -y              Salta la conferma interattiva
  -v              Modalità debug
  -h              Mostra questo messaggio di aiuto

Variabili d'ambiente:
  SRC_CONTEXT       Alternativa a -s
  DST_CONTEXT       Alternativa a -d

Esempi:
  $0 -s cluster-a -d cluster-b my-secret
  $0 -s cluster-a -d cluster-b -n my-project secret-a secret-b
  $0 -s cluster-a -d cluster-b -a -y builder-dockercfg-xxxxx
EOF
    exit 1
}

debug() {
    [[ "$DEBUG" == "true" ]] && echo "[DEBUG] $*" >&2
    return 0
}

check_dependencies() {
    local missing=()
    for cmd in oc jq; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "Errore: comandi mancanti: ${missing[*]}" >&2
        exit 1
    fi
}

check_cluster_access() {
    local context="$1" label="$2"
    debug "Verifico accesso al cluster '$context'"
    if ! oc --context "$context" whoami &>/dev/null; then
        echo "Errore: impossibile connettersi al cluster $label (context: $context)." >&2
        echo "Effettua il login e riprova." >&2
        exit 1
    fi
    local user
    user=$(oc --context "$context" whoami)
    echo "✔ Connesso a $label come '$user' (context: $context)"
}

# Imposta NAMESPACE al progetto corrente del context sorgente.
resolve_namespace() {
    local context="$1"
    local ns
    if ! ns=$(oc --context "$context" project -q 2>/dev/null); then
        echo "Errore: impossibile leggere il progetto corrente del context '$context'." >&2
        echo "Specifica il namespace con -n." >&2
        exit 1
    fi
    ns="${ns//$'\r'/}"
    ns="${ns#"${ns%%[![:space:]]*}"}"
    ns="${ns%"${ns##*[![:space:]]}"}"
    if [[ -z "$ns" ]]; then
        echo "Errore: il context '$context' non ha un progetto corrente. Specificalo con -n." >&2
        exit 1
    fi
    NAMESPACE="$ns"
}

common_suffix() {
    local a="$1" b="$2"
    local -a pa pb common
    local i j
    IFS='.' read -r -a pa <<< "$a"
    IFS='.' read -r -a pb <<< "$b"
    i=${#pa[@]}
    j=${#pb[@]}
    common=()
    while (( i > 0 && j > 0 )); do
        i=$((i - 1))
        j=$((j - 1))
        if [[ "${pa[i]}" == "${pb[j]}" ]]; then
            if [[ ${#common[@]} -eq 0 ]]; then
                common=("${pa[i]}")
            else
                common=("${pa[i]}" "${common[@]}")
            fi
        else
            break
        fi
    done
    if (( ${#common[@]} >= 2 )); then
        local IFS='.'
        echo "${common[*]}"
    fi
}

add_pattern() {
    local candidate="$1"
    local existing
    [[ -z "$candidate" || ${#candidate} -lt 3 ]] && return 0
    if [[ ${#SRC_PATTERNS[@]} -gt 0 ]]; then
        for existing in "${SRC_PATTERNS[@]}"; do
            [[ "$existing" == "$candidate" ]] && return 0
        done
    fi
    SRC_PATTERNS+=("$candidate")
}

# Raccoglie hostname API, dominio apps e dominio base del cluster sorgente.
detect_src_patterns() {
    local server host apps base
    SRC_PATTERNS=()

    server=$(oc config view --context "$SRC_CONTEXT" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
    host=$(printf '%s' "$server" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*##; s#:[0-9]+$##')
    apps=$(oc --context "$SRC_CONTEXT" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)

    add_pattern "$host"
    add_pattern "$apps"

    base=""
    if [[ -n "$host" && -n "$apps" ]]; then
        base=$(common_suffix "$host" "$apps" || true)
    elif [[ "$host" == api.* || "$host" == apps.* ]]; then
        base="${host#*.}"
    elif [[ "$apps" == api.* || "$apps" == apps.* ]]; then
        base="${apps#*.}"
    fi
    add_pattern "$base"

    if [[ ${#SRC_PATTERNS[@]} -eq 0 ]]; then
        SRC_PATTERNS_JSON="[]"
        echo "Nessun pattern del cluster sorgente rilevato: il controllo dei riferimenti verrà saltato."
        return 0
    fi

    local sorted="" line
    sorted=$(printf '%s\n' "${SRC_PATTERNS[@]}" | awk '{ print length, $0 }' | sort -nr | cut -d' ' -f2-)
    SRC_PATTERNS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && SRC_PATTERNS+=("$line")
    done <<< "$sorted"

    SRC_PATTERNS_JSON=$(printf '%s\n' "${SRC_PATTERNS[@]}" | jq -R . | jq -s .)
    echo "Pattern del cluster sorgente: $(printf '%s, ' "${SRC_PATTERNS[@]}" | sed 's/, $//')"
    debug "SRC_PATTERNS_JSON=$SRC_PATTERNS_JSON"
}

is_cluster_managed_secret() {
    case "$1" in
        kubernetes.io/service-account-token|kubernetes.io/dockercfg|kubernetes.io/dockerconfigjson)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

clean_secret_json() {
    printf '%s\n' "$1" | jq '
        del(
            .metadata.uid,
            .metadata.resourceVersion,
            .metadata.creationTimestamp,
            .metadata.selfLink,
            .metadata.managedFields,
            .metadata.generation,
            .metadata.ownerReferences,
            .metadata.finalizers,
            .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
            .metadata.annotations["kubernetes.io/service-account.name"],
            .metadata.annotations["kubernetes.io/service-account.uid"],
            .status
        )
        | if (.metadata.annotations // {} | length) == 0 then del(.metadata.annotations) else . end
    '
}

resource_summary() {
    local json="$1"
    local data_count stype labels
    data_count=$(printf '%s\n' "$json" | jq -r '(.data // {}) | length')
    stype=$(printf '%s\n' "$json" | jq -r '.type // "Opaque"')
    labels=$(printf '%s\n' "$json" | jq -r '
        if (.metadata.labels // {} | length) > 0
        then [.metadata.labels | to_entries[] | "\(.key)=\(.value)"] | join(", ")
        else "(nessuna)"
        end
    ')
    echo "  tipo: $stype, chiavi data: $data_count, labels: $labels"
}

# Accumula in CLUSTER_REF_WARNINGS i valori che contengono un pattern del cluster sorgente.
# decode=true per i Secret (data è base64). Non stampa nulla.
collect_cluster_references() {
    local json="$1" rtype="$2" rname="$3" decode="$4"
    [[ "$SRC_PATTERNS_JSON" == "[]" ]] && return 0

    local out row
    if ! out=$(jq -c \
        --argjson patterns "$SRC_PATTERNS_JSON" \
        --argjson decode "$decode" \
        --arg rtype "$rtype" \
        --arg rname "$rname" '
            .data // {}
            | to_entries[]
            | .key as $k
            | (if $decode then (.value | try @base64d catch empty) else (.value // empty) end) as $v
            | select($v != "")
            | first($patterns[] as $p | select($v | contains($p)) | $p) as $p
            | select($p != null)
            | {
                type: $rtype,
                name: $rname,
                key: $k,
                pattern: $p,
                value: (
                    ($v | gsub("\n"; " ") | gsub("\r"; " ")) as $flat
                    | if ($flat | length) > 120 then $flat[0:117] + "..." else $flat end
                )
              }
        ' <<< "$json"); then
        echo "Errore: scansione riferimenti non riuscita per $rtype '$rname'." >&2
        return 0
    fi

    while IFS= read -r row; do
        [[ -n "$row" ]] && CLUSTER_REF_WARNINGS+=("$row")
    done <<< "$out"
}

prepare_secret() {
    local name="$1"
    local raw clean stype

    if oc --context "$DST_CONTEXT" -n "$NAMESPACE" get secret "$name" &>/dev/null; then
        echo "Errore: il Secret '$name' esiste già nel namespace '$NAMESPACE' sul cluster destinazione." >&2
        return 1
    fi

    debug "Esporto Secret '$name' da namespace '$NAMESPACE' (context: $SRC_CONTEXT)"
    if ! raw=$(oc --context "$SRC_CONTEXT" -n "$NAMESPACE" get secret "$name" -o json 2>/dev/null); then
        echo "Errore: Secret '$name' non trovato nel namespace '$NAMESPACE' sul cluster sorgente." >&2
        return 1
    fi

    stype=$(printf '%s\n' "$raw" | jq -r '.type // "Opaque"')
    if is_cluster_managed_secret "$stype"; then
        echo "⚠ Il Secret '$name' è di tipo '$stype' (gestito dal cluster)." >&2
        if [[ "$FORCE_ALL" == "true" ]]; then
            echo "  Migrazione forzata (-a)." >&2
        elif [[ "$SKIP_CONFIRM" == "true" || ! -t 0 ]]; then
            echo "  Saltato. Usa -a per forzare la migrazione." >&2
            SKIPPED_NAMES+=("$name")
            return 0
        else
            local confirm
            read -rp "  Vuoi migrare comunque questo Secret? [s/N] " confirm
            if [[ ! "$confirm" =~ ^[sySY]$ ]]; then
                echo "  Saltato." >&2
                SKIPPED_NAMES+=("$name")
                return 0
            fi
        fi
    fi

    if ! clean=$(clean_secret_json "$raw"); then
        echo "Errore: impossibile pulire il Secret '$name'." >&2
        return 1
    fi

    echo "Secret '$name'"
    resource_summary "$clean"

    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] Definizione Secret pulita (valori oscurati):" >&2
        printf '%s\n' "$clean" | jq '
            if .data then .data |= with_entries(.value = "***") else . end
            | if .stringData then .stringData |= with_entries(.value = "***") else . end
        ' >&2
    fi

    READY_NAMES+=("$name")
    READY_JSON+=("$clean")
}

apply_secret() {
    local name="$1" json="$2"
    debug "oc --context $DST_CONTEXT -n $NAMESPACE apply -f - ($name)"
    if ! printf '%s\n' "$json" | oc --context "$DST_CONTEXT" -n "$NAMESPACE" apply -f - >/dev/null; then
        echo "Errore durante la creazione del Secret '$name'." >&2
        return 1
    fi
    echo "✔ Secret '$name' creato sul cluster destinazione"
    collect_cluster_references "$json" "Secret" "$name" true
}

print_cluster_warnings() {
    local row
    [[ ${#CLUSTER_REF_WARNINGS[@]} -eq 0 ]] && return 0
    echo ""
    echo "⚠ Riferimenti al cluster sorgente rilevati:"
    for row in "${CLUSTER_REF_WARNINGS[@]}"; do
        printf '%s\n' "$row" | jq -r '
            "  \(.type) '\''\(.name)'\'', chiave '\''\(.key)'\'':",
            "      \(.value)",
            "      (pattern: \(.pattern))"
        '
    done
    echo ""
    echo "Verifica e aggiorna manualmente questi valori sul cluster destinazione."
}

# ==========================================
# PARSING ARGOMENTI
# ==========================================
while getopts "s:d:n:ayvh" opt; do
    case "$opt" in
        s) SRC_CONTEXT="$OPTARG" ;;
        d) DST_CONTEXT="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        a) FORCE_ALL=true ;;
        y) SKIP_CONFIRM=true ;;
        v) DEBUG=true ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -eq 0 ]]; then
    echo "Errore: specifica almeno un nome di Secret." >&2
    echo "" >&2
    usage
fi

missing=()
[[ -z "$SRC_CONTEXT" ]] && missing+=("context sorgente (-s)")
[[ -z "$DST_CONTEXT" ]] && missing+=("context destinazione (-d)")
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Errore: parametri mancanti:" >&2
    for m in "${missing[@]}"; do
        echo "  - $m" >&2
    done
    echo "" >&2
    usage
fi

NAMES=()
for name in "$@"; do
    duplicate=false
    if [[ ${#NAMES[@]} -gt 0 ]]; then
        for existing in "${NAMES[@]}"; do
            if [[ "$existing" == "$name" ]]; then
                duplicate=true
                break
            fi
        done
    fi
    if [[ "$duplicate" == "true" ]]; then
        echo "Nome duplicato ignorato: $name" >&2
        continue
    fi
    NAMES+=("$name")
done

# ==========================================
# ESECUZIONE
# ==========================================
check_dependencies

if [[ -z "$NAMESPACE" ]]; then
    resolve_namespace "$SRC_CONTEXT"
    echo "Namespace non specificato: uso '$NAMESPACE' (progetto corrente di $SRC_CONTEXT)"
fi

echo "============================================================"
echo "Migrazione Secret: ${NAMES[*]}"
echo "  Namespace:      $NAMESPACE"
echo "  Sorgente:       $SRC_CONTEXT"
echo "  Destinazione:   $DST_CONTEXT"
echo "============================================================"
echo ""

check_cluster_access "$SRC_CONTEXT" "sorgente"
check_cluster_access "$DST_CONTEXT" "destinazione"

if ! oc --context "$DST_CONTEXT" get namespace "$NAMESPACE" &>/dev/null; then
    echo "Errore: il namespace '$NAMESPACE' non esiste sul cluster destinazione ($DST_CONTEXT)." >&2
    echo "Crealo con: oc --context $DST_CONTEXT new-project $NAMESPACE" >&2
    exit 1
fi
echo "✔ Namespace '$NAMESPACE' presente su entrambi i cluster"
echo ""

detect_src_patterns
echo ""
echo "Risorse da migrare:"

for name in "${NAMES[@]}"; do
    if ! prepare_secret "$name"; then
        FAILED_NAMES+=("$name")
    fi
done

if [[ ${#READY_NAMES[@]} -eq 0 ]]; then
    echo ""
    echo "============================================================"
    echo "Riepilogo: 0 migrati con successo, ${#FAILED_NAMES[@]} errori, ${#SKIPPED_NAMES[@]} saltati"
    if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
        echo "Non migrati:"
        for name in "${FAILED_NAMES[@]}"; do
            echo "  - $name"
        done
    fi
    if [[ ${#SKIPPED_NAMES[@]} -gt 0 ]]; then
        echo "Saltati:"
        for name in "${SKIPPED_NAMES[@]}"; do
            echo "  - $name"
        done
    fi
    echo "============================================================"
    if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
        exit 1
    fi
    exit 0
fi

echo ""
if [[ "$SKIP_CONFIRM" != "true" ]]; then
    read -rp "Procedere con la migrazione di ${#READY_NAMES[@]} Secret? [s/N] " confirm
    if [[ ! "$confirm" =~ ^[sySY]$ ]]; then
        echo "Operazione annullata."
        exit 0
    fi
fi

echo ""
ok_count=0
for i in "${!READY_NAMES[@]}"; do
    if apply_secret "${READY_NAMES[$i]}" "${READY_JSON[$i]}"; then
        (( ok_count++ )) || true
    else
        FAILED_NAMES+=("${READY_NAMES[$i]}")
    fi
done

echo ""
echo "============================================================"
echo "Riepilogo: ${ok_count} migrati con successo, ${#FAILED_NAMES[@]} errori, ${#SKIPPED_NAMES[@]} saltati"
if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
    echo "Non migrati:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
fi
if [[ ${#SKIPPED_NAMES[@]} -gt 0 ]]; then
    echo "Saltati:"
    for name in "${SKIPPED_NAMES[@]}"; do
        echo "  - $name"
    done
fi
print_cluster_warnings
echo "============================================================"

if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
    exit 1
fi

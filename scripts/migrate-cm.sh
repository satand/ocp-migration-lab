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
SRC_PATTERNS=()
SRC_PATTERNS_JSON="[]"
CLUSTER_REF_WARNINGS=()
READY_NAMES=()
READY_JSON=()
FAILED_NAMES=()

# ==========================================
# FUNZIONI
# ==========================================
usage() {
    cat <<EOF
Uso: $0 [OPZIONI] <cm-name> [cm-name ...]

Migra una o più ConfigMap da un cluster OpenShift sorgente a uno destinazione.
Nome, namespace, dati, label e annotazioni non cluster-specifiche vengono preservati.

Opzioni:
  -s <context>    Context oc/kubectl del cluster sorgente (obbligatorio)
  -d <context>    Context oc/kubectl del cluster destinazione (obbligatorio)
  -n <namespace>  Namespace delle ConfigMap
                  (default: progetto corrente del context sorgente)
  -y              Salta la conferma interattiva
  -v              Modalità debug
  -h              Mostra questo messaggio di aiuto

Variabili d'ambiente:
  SRC_CONTEXT       Alternativa a -s
  DST_CONTEXT       Alternativa a -d

Esempi:
  $0 -s cluster-a -d cluster-b my-config
  $0 -s cluster-a -d cluster-b -n my-project cm-a cm-b cm-c
  $0 -s cluster-a -d cluster-b -y my-config
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

export_and_clean_cm() {
    local name="$1"
    local raw
    debug "Esporto ConfigMap '$name' da namespace '$NAMESPACE' (context: $SRC_CONTEXT)"
    if ! raw=$(oc --context "$SRC_CONTEXT" -n "$NAMESPACE" get cm "$name" -o json 2>/dev/null); then
        echo "Errore: ConfigMap '$name' non trovata nel namespace '$NAMESPACE' sul cluster sorgente." >&2
        return 1
    fi

    printf '%s\n' "$raw" | jq '
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
            .status
        )
        | if (.metadata.annotations // {} | length) == 0 then del(.metadata.annotations) else . end
    '
}

resource_summary() {
    local json="$1"
    local data_count binary_count labels
    data_count=$(printf '%s\n' "$json" | jq -r '(.data // {}) | length')
    binary_count=$(printf '%s\n' "$json" | jq -r '(.binaryData // {}) | length')
    labels=$(printf '%s\n' "$json" | jq -r '
        if (.metadata.labels // {} | length) > 0
        then [.metadata.labels | to_entries[] | "\(.key)=\(.value)"] | join(", ")
        else "(nessuna)"
        end
    ')
    echo "  chiavi data: $data_count, binaryData: $binary_count, labels: $labels"
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

prepare_cm() {
    local name="$1"
    local clean

    if oc --context "$DST_CONTEXT" -n "$NAMESPACE" get cm "$name" &>/dev/null; then
        echo "Errore: la ConfigMap '$name' esiste già nel namespace '$NAMESPACE' sul cluster destinazione." >&2
        return 1
    fi

    if ! clean=$(export_and_clean_cm "$name"); then
        return 1
    fi

    echo "ConfigMap '$name'"
    resource_summary "$clean"

    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] Definizione ConfigMap pulita:" >&2
        printf '%s\n' "$clean" | jq . >&2
    fi

    READY_NAMES+=("$name")
    READY_JSON+=("$clean")
}

apply_cm() {
    local name="$1" json="$2"
    debug "oc --context $DST_CONTEXT -n $NAMESPACE apply -f - ($name)"
    if ! printf '%s\n' "$json" | oc --context "$DST_CONTEXT" -n "$NAMESPACE" apply -f - >/dev/null; then
        echo "Errore durante la creazione della ConfigMap '$name'." >&2
        return 1
    fi
    echo "✔ ConfigMap '$name' creata sul cluster destinazione"
    collect_cluster_references "$json" "ConfigMap" "$name" false
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
while getopts "s:d:n:yvh" opt; do
    case "$opt" in
        s) SRC_CONTEXT="$OPTARG" ;;
        d) DST_CONTEXT="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        y) SKIP_CONFIRM=true ;;
        v) DEBUG=true ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -eq 0 ]]; then
    echo "Errore: specifica almeno un nome di ConfigMap." >&2
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
echo "Migrazione ConfigMap: ${NAMES[*]}"
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
    if ! prepare_cm "$name"; then
        FAILED_NAMES+=("$name")
    fi
done

if [[ ${#READY_NAMES[@]} -eq 0 ]]; then
    echo ""
    echo "============================================================"
    echo "Riepilogo: 0 migrate con successo, ${#FAILED_NAMES[@]} errori"
    if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
        echo "Non migrate:"
        for name in "${FAILED_NAMES[@]}"; do
            echo "  - $name"
        done
    fi
    echo "============================================================"
    exit 1
fi

echo ""
if [[ "$SKIP_CONFIRM" != "true" ]]; then
    read -rp "Procedere con la migrazione di ${#READY_NAMES[@]} ConfigMap? [s/N] " confirm
    if [[ ! "$confirm" =~ ^[sySY]$ ]]; then
        echo "Operazione annullata."
        exit 0
    fi
fi

echo ""
ok_count=0
for i in "${!READY_NAMES[@]}"; do
    if apply_cm "${READY_NAMES[$i]}" "${READY_JSON[$i]}"; then
        (( ok_count++ )) || true
    else
        FAILED_NAMES+=("${READY_NAMES[$i]}")
    fi
done

echo ""
echo "============================================================"
echo "Riepilogo: ${ok_count} migrate con successo, ${#FAILED_NAMES[@]} errori"
if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
    echo "Non migrate:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
fi
print_cluster_warnings
echo "============================================================"

if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
    exit 1
fi

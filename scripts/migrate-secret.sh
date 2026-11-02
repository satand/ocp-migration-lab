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
REPLACE_REFS=false
SRC_PATTERNS=()
SRC_PATTERNS_JSON="[]"
DST_DOMAINS=()
REPLACE_MAP_JSON="[]"
CLUSTER_REF_WARNINGS=()
READY_NAMES=()
READY_JSON=()
READY_REPLACE=()
FAILED_NAMES=()
SKIPPED_NAMES=()
REPLACED_NAMES=()

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

Se un Secret esiste già sul cluster destinazione, viene chiesta conferma
per sostituirlo (cancellazione e ricreazione). Con -y la sostituzione è automatica.

Opzioni:
  -s <context>    Context oc/kubectl del cluster sorgente (obbligatorio)
  -d <context>    Context oc/kubectl del cluster destinazione (obbligatorio)
  -n <namespace>  Namespace dei Secret
                  (default: progetto corrente del context sorgente)
  -a              Forza la migrazione anche dei Secret gestiti dal cluster
  -R              Sostituisci automaticamente i riferimenti al dominio del
                  cluster sorgente con quello del cluster destinazione.
                  Senza -R viene chiesta conferma se vengono trovati riferimenti.
  -y              Salta tutte le conferme interattive (inclusa sostituzione
                  di risorse esistenti)
  -v              Modalità debug
  -h              Mostra questo messaggio di aiuto

Variabili d'ambiente:
  SRC_CONTEXT       Alternativa a -s
  DST_CONTEXT       Alternativa a -d

Esempi:
  $0 -s cluster-a -d cluster-b my-secret
  $0 -s cluster-a -d cluster-b -n my-project secret-a secret-b
  $0 -s cluster-a -d cluster-b -a -y builder-dockercfg-xxxxx
  $0 -s cluster-a -d cluster-b -R -y secret-a secret-b
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

detect_cluster_domains() {
    local context="$1"
    local server host apps base

    server=$(oc config view --context "$context" --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
    host=$(printf '%s' "$server" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*##; s#:[0-9]+$##')
    apps=$(oc --context "$context" get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)

    base=""
    if [[ -n "$host" && -n "$apps" ]]; then
        base=$(common_suffix "$host" "$apps" || true)
    elif [[ "$host" == api.* || "$host" == apps.* ]]; then
        base="${host#*.}"
    elif [[ "$apps" == api.* || "$apps" == apps.* ]]; then
        base="${apps#*.}"
    fi

    echo "${host:-}" "${apps:-}" "${base:-}"
}

detect_src_patterns() {
    local domains
    SRC_PATTERNS=()

    domains=($(detect_cluster_domains "$SRC_CONTEXT"))
    local host="${domains[0]:-}" apps="${domains[1]:-}" base="${domains[2]:-}"

    add_pattern "$host"
    add_pattern "$apps"
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

detect_dst_patterns() {
    local domains
    DST_DOMAINS=()

    domains=($(detect_cluster_domains "$DST_CONTEXT"))
    DST_DOMAINS=("${domains[@]}")
    local host="${DST_DOMAINS[0]:-}" apps="${DST_DOMAINS[1]:-}" base="${DST_DOMAINS[2]:-}"

    if [[ -n "$host" || -n "$apps" || -n "$base" ]]; then
        echo "Pattern del cluster destinazione: $(echo "$host $apps $base" | xargs | tr ' ' ', ')"
    fi
}

build_replace_map() {
    [[ "$SRC_PATTERNS_JSON" == "[]" ]] && return 0

    local src_domains dst_domains
    src_domains=($(detect_cluster_domains "$SRC_CONTEXT"))
    dst_domains=("${DST_DOMAINS[@]:-}")

    local src_host="${src_domains[0]:-}" src_apps="${src_domains[1]:-}" src_base="${src_domains[2]:-}"
    local dst_host="${dst_domains[0]:-}" dst_apps="${dst_domains[1]:-}" dst_base="${dst_domains[2]:-}"

    local pairs=()
    [[ -n "$src_apps" && -n "$dst_apps" && "$src_apps" != "$dst_apps" ]] && pairs+=("{\"src\":$(printf '%s' "$src_apps" | jq -R .),\"dst\":$(printf '%s' "$dst_apps" | jq -R .)}")
    [[ -n "$src_host" && -n "$dst_host" && "$src_host" != "$dst_host" ]] && pairs+=("{\"src\":$(printf '%s' "$src_host" | jq -R .),\"dst\":$(printf '%s' "$dst_host" | jq -R .)}")
    [[ -n "$src_base" && -n "$dst_base" && "$src_base" != "$dst_base" ]] && pairs+=("{\"src\":$(printf '%s' "$src_base" | jq -R .),\"dst\":$(printf '%s' "$dst_base" | jq -R .)}")

    if [[ ${#pairs[@]} -eq 0 ]]; then
        REPLACE_MAP_JSON="[]"
        return 0
    fi

    local joined
    joined=$(printf '%s,' "${pairs[@]}")
    joined="${joined%,}"
    REPLACE_MAP_JSON=$(printf '[%s]' "$joined" | jq 'sort_by(-(.src | length))')
    debug "REPLACE_MAP_JSON=$REPLACE_MAP_JSON"
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

collect_cluster_references() {
    local json="$1" rtype="$2" rname="$3" decode="$4"
    [[ "$SRC_PATTERNS_JSON" == "[]" ]] && return 0

    local out row n i
    if ! out=$(jq -c \
        --argjson patterns "$SRC_PATTERNS_JSON" \
        --argjson decode "$decode" \
        --arg rtype "$rtype" \
        --arg rname "$rname" '
            [ .data // {}
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
            ]
        ' <<< "$json"); then
        echo "Errore: scansione riferimenti non riuscita per $rtype '$rname'." >&2
        return 0
    fi

    n=$(printf '%s' "$out" | jq 'length')
    for (( i = 0; i < n; i++ )); do
        row=$(printf '%s' "$out" | jq -c ".[$i]")
        [[ -n "$row" && "$row" != "null" ]] && CLUSTER_REF_WARNINGS+=("$row")
    done
    return 0
}

replace_domain_refs() {
    local json="$1" decode="$2"
    [[ "$REPLACE_MAP_JSON" == "[]" ]] && printf '%s' "$json" && return 0

    printf '%s\n' "$json" | jq --argjson map "$REPLACE_MAP_JSON" --argjson decode "$decode" '
        if $decode then
            .data //= {} | .data |= with_entries(
                .value |= (. as $b64 | try (($b64 | @base64d) as $v |
                    reduce $map[] as $m ($v; gsub($m.src; $m.dst)) | @base64) catch $b64)
            )
        else
            .data //= {} | .data |= with_entries(
                .value |= reduce $map[] as $m (.; gsub($m.src; $m.dst))
            )
        end
    '
}

prepare_secret() {
    local name="$1"
    local raw clean stype exists_on_dst=false

    if oc --context "$DST_CONTEXT" -n "$NAMESPACE" get secret "$name" &>/dev/null; then
        exists_on_dst=true
    fi

    echo "Esporto Secret '$name' dal cluster sorgente..."
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
    if [[ "$exists_on_dst" == "true" ]]; then
        echo "  ⚠ Esiste già sul cluster destinazione"
    fi

    if [[ "$DEBUG" == "true" ]]; then
        echo "[DEBUG] Definizione Secret pulita (valori oscurati):" >&2
        printf '%s\n' "$clean" | jq '
            if .data then .data |= with_entries(.value = "***") else . end
            | if .stringData then .stringData |= with_entries(.value = "***") else . end
        ' >&2
    fi

    READY_NAMES+=("$name")
    READY_JSON+=("$clean")
    READY_REPLACE+=("$exists_on_dst")
}

confirm_replacements() {
    local i name ans
    for i in "${!READY_NAMES[@]}"; do
        [[ "${READY_REPLACE[$i]}" == "true" ]] || continue
        name="${READY_NAMES[$i]}"
        if [[ "$SKIP_CONFIRM" == "true" || ! -t 0 ]]; then
            echo "⚠ Il Secret '$name' esiste già: verrà sostituito."
            continue
        fi
        read -rp "Il Secret '$name' esiste già sul destinazione. Sostituire? [s/N] " ans
        if [[ "$ans" =~ ^[sySY]$ ]]; then
            echo "⚠ Attenzione: la sostituzione eliminerà e ricreerà il Secret '$name'."
        else
            echo "  Saltato."
            SKIPPED_NAMES+=("$name")
            unset "READY_NAMES[$i]" "READY_JSON[$i]" "READY_REPLACE[$i]"
        fi
    done
    local names=() jsons=() replaces=()
    for i in "${!READY_NAMES[@]}"; do
        names+=("${READY_NAMES[$i]}")
        jsons+=("${READY_JSON[$i]}")
        replaces+=("${READY_REPLACE[$i]}")
    done
    if [[ ${#names[@]} -gt 0 ]]; then
        READY_NAMES=("${names[@]}")
        READY_JSON=("${jsons[@]}")
        READY_REPLACE=("${replaces[@]}")
    else
        READY_NAMES=()
        READY_JSON=()
        READY_REPLACE=()
    fi
}

apply_secret() {
    local name="$1" json="$2" do_replace="$3"

    if [[ "$do_replace" == "true" ]]; then
        echo "Elimino Secret esistente '$name' sul cluster destinazione..."
        debug "oc --context $DST_CONTEXT -n $NAMESPACE delete secret $name"
        if ! oc --context "$DST_CONTEXT" -n "$NAMESPACE" delete secret "$name" --wait=true; then
            echo "Errore durante l'eliminazione del Secret '$name' esistente." >&2
            return 1
        fi
        echo "✔ Secret eliminato, ricreo..."
    fi

    echo "Creo Secret '$name' sul cluster destinazione..."
    debug "oc --context $DST_CONTEXT -n $NAMESPACE apply -f - ($name)"
    if ! printf '%s\n' "$json" | oc --context "$DST_CONTEXT" -n "$NAMESPACE" apply -f - >/dev/null; then
        echo "Errore durante la creazione del Secret '$name'." >&2
        return 1
    fi

    if [[ "$do_replace" == "true" ]]; then
        echo "✔ Secret '$name' sostituito sul cluster destinazione"
        REPLACED_NAMES+=("$name")
    else
        echo "✔ Secret '$name' creato sul cluster destinazione"
    fi
}

print_cluster_refs() {
    local row
    [[ ${#CLUSTER_REF_WARNINGS[@]} -eq 0 ]] && return 0
    echo "⚠ Riferimenti al cluster sorgente rilevati:"
    for row in "${CLUSTER_REF_WARNINGS[@]}"; do
        printf '%s\n' "$row" | jq -r '
            "  \(.type) '\''\(.name)'\'', chiave '\''\(.key)'\'':",
            "      \(.value)",
            "      (pattern: \(.pattern))"
        '
    done
}

print_residual_warnings() {
    [[ ${#CLUSTER_REF_WARNINGS[@]} -eq 0 ]] && return 0
    echo ""
    print_cluster_refs
    echo ""
    echo "Verifica e aggiorna manualmente questi valori sul cluster destinazione."
}

print_replace_map() {
    [[ "$REPLACE_MAP_JSON" == "[]" ]] && return 0
    echo "Mapping di sostituzione domini:"
    printf '%s\n' "$REPLACE_MAP_JSON" | jq -r '.[] | "  \(.src) → \(.dst)"'
}

ask_replace_refs() {
    if [[ "$REPLACE_REFS" == "true" ]]; then
        echo "Sostituzione automatica dei riferimenti di dominio attiva (-R)."
        return 0
    fi
    if [[ "$SKIP_CONFIRM" == "true" || ! -t 0 ]]; then
        echo "Riferimenti di dominio lasciati inalterati (usa -R per sostituirli automaticamente)."
        return 1
    fi
    local ans
    read -rp "Sostituire i riferimenti al dominio sorgente con quello destinazione? [s/N] " ans
    [[ "$ans" =~ ^[sySY]$ ]]
}

# ==========================================
# PARSING ARGOMENTI
# ==========================================
while getopts "s:d:n:aRyvh" opt; do
    case "$opt" in
        s) SRC_CONTEXT="$OPTARG" ;;
        d) DST_CONTEXT="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        a) FORCE_ALL=true ;;
        R) REPLACE_REFS=true ;;
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
detect_dst_patterns
build_replace_map
echo ""

for name in "${NAMES[@]}"; do
    if ! prepare_secret "$name"; then
        FAILED_NAMES+=("$name")
    fi
    echo ""
done

if [[ ${#READY_NAMES[@]} -eq 0 ]]; then
    echo "============================================================"
    echo "Riepilogo: 0 migrati, ${#FAILED_NAMES[@]} errori, ${#SKIPPED_NAMES[@]} saltati"
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
    if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then exit 1; fi
    exit 0
fi

confirm_replacements

if [[ ${#READY_NAMES[@]} -eq 0 ]]; then
    echo ""
    echo "============================================================"
    echo "Riepilogo: 0 migrati, ${#FAILED_NAMES[@]} errori, ${#SKIPPED_NAMES[@]} saltati"
    if [[ ${#SKIPPED_NAMES[@]} -gt 0 ]]; then
        echo "Saltati:"
        for name in "${SKIPPED_NAMES[@]}"; do
            echo "  - $name"
        done
    fi
    echo "============================================================"
    exit 0
fi

echo "Analizzo i valori per riferimenti ai domini del cluster sorgente..."
for i in "${!READY_NAMES[@]}"; do
    collect_cluster_references "${READY_JSON[$i]}" "Secret" "${READY_NAMES[$i]}" true
done

if [[ ${#CLUSTER_REF_WARNINGS[@]} -gt 0 ]]; then
    echo ""
    print_cluster_refs
    if [[ "$REPLACE_MAP_JSON" != "[]" ]]; then
        echo ""
        print_replace_map
        echo ""
        if ask_replace_refs; then
            echo "Sostituzione domini in corso..."
            for i in "${!READY_NAMES[@]}"; do
                READY_JSON[$i]=$(replace_domain_refs "${READY_JSON[$i]}" true)
            done
            CLUSTER_REF_WARNINGS=()
            for i in "${!READY_NAMES[@]}"; do
                collect_cluster_references "${READY_JSON[$i]}" "Secret" "${READY_NAMES[$i]}" true
            done
            if [[ ${#CLUSTER_REF_WARNINGS[@]} -eq 0 ]]; then
                echo "✔ Tutti i riferimenti al cluster sorgente sono stati sostituiti."
            else
                echo "⚠ Alcuni riferimenti non sono stati sostituiti (pattern senza mapping)."
            fi
        fi
    else
        echo ""
        echo "Nessun mapping di sostituzione disponibile: i riferimenti andranno aggiornati manualmente."
    fi
else
    echo "✔ Nessun riferimento ai domini del cluster sorgente trovato."
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
    if apply_secret "${READY_NAMES[$i]}" "${READY_JSON[$i]}" "${READY_REPLACE[$i]}"; then
        (( ok_count++ )) || true
    else
        FAILED_NAMES+=("${READY_NAMES[$i]}")
    fi
    echo ""
done

echo "============================================================"
echo "Riepilogo: ${ok_count} migrati con successo (${#REPLACED_NAMES[@]} sostituiti), ${#FAILED_NAMES[@]} errori, ${#SKIPPED_NAMES[@]} saltati"
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
print_residual_warnings
echo "============================================================"

if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
    exit 1
fi

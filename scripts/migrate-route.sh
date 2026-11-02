#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIGURAZIONE DI DEFAULT
# ==========================================
SRC_CONTEXT="${SRC_CONTEXT:-}"
DST_CONTEXT="${DST_CONTEXT:-}"
DEBUG="${DEBUG:-false}"

NAMESPACE=""
SKIP_CONFIRM=false
SRC_APPS_DOMAIN=""
DST_APPS_DOMAIN=""

READY_ITEMS=()
BLOCKED_ITEMS=()
FAILED_NAMES=()
SKIPPED_NAMES=()

# ==========================================
# FUNZIONI
# ==========================================
usage() {
    cat <<EOF
Uso: $0 [OPZIONI] <route-name> [route-name ...]

Migra una o più Route da un cluster OpenShift sorgente a uno destinazione,
insieme al Service associato se non esiste già sul destinazione.
Se una Route esiste già sul destinazione, viene chiesta conferma per
sostituirla (con -y la sostituzione è automatica).

Prima di migrare verifica hostname e, se presente, il certificato esterno:
  - il certificato non deve essere scaduto
  - il certificato deve coprire l'hostname della route
  - il certificato deve restare valido sul cluster destinazione
    (se l'hostname è quello di default OpenShift, sul destinazione cambierà)

Route senza certificato esterno vengono migrate comunque.
Se l'hostname è legato al cluster sorgente viene rimosso, così il
destinazione ne genera uno nuovo.

Opzioni:
  -s <context>    Context oc/kubectl del cluster sorgente (obbligatorio)
  -d <context>    Context oc/kubectl del cluster destinazione (obbligatorio)
  -n <namespace>  Namespace
                  (default: progetto corrente del context sorgente)
  -y              Salta la conferma interattiva
  -v              Modalità debug
  -h              Mostra questo messaggio di aiuto

Variabili d'ambiente:
  SRC_CONTEXT       Alternativa a -s
  DST_CONTEXT       Alternativa a -d

Esempi:
  $0 -s cluster-a -d cluster-b web-route
  $0 -s cluster-a -d cluster-b -n my-project web api
  $0 -s cluster-a -d cluster-b -y web-route
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
    if ! command -v openssl &>/dev/null; then
        echo "⚠ 'openssl' non trovato: le route con certificato esterno non potranno essere validate." >&2
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

detect_apps_domain() {
    local context="$1"
    local domain api_server api_host
    domain=$(oc --context "$context" get ingresses.config.openshift.io cluster \
        -o jsonpath='{.spec.domain}' 2>/dev/null || true)
    if [[ -z "$domain" ]]; then
        api_server=$(oc config view --context "$context" --minify \
            -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
        api_host=$(printf '%s' "$api_server" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*##; s#:[0-9]+$##')
        if [[ "$api_host" == api.* ]]; then
            domain="apps.${api_host#api.}"
        fi
    fi
    printf '%s' "$domain"
}

host_ends_with_domain() {
    local host="$1" domain="$2"
    [[ -n "$domain" && -n "$host" ]] || return 1
    [[ "$host" == "$domain" || "$host" == *".${domain}" ]]
}

analyze_cert() {
    local pem="$1"
    if ! command -v openssl &>/dev/null; then
        echo '{"issuer":"openssl non disponibile","notBefore":"N/A","notAfter":"N/A","sans":[],"wildcard":false,"parseable":false}'
        return 0
    fi

    local issuer not_before not_after san_raw san_list wildcard

    issuer=$(printf '%s' "$pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//' || echo "N/A")
    not_before=$(printf '%s' "$pem" | openssl x509 -noout -startdate 2>/dev/null | sed 's/^notBefore=//' || echo "N/A")
    not_after=$(printf '%s' "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || echo "N/A")

    san_raw=$(printf '%s' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | grep -oE 'DNS:[^, ]+' | sed 's/DNS://g' | tr '\n' ',' | sed 's/,$//' || true)

    if [[ -z "$san_raw" ]]; then
        local cn
        cn=$(printf '%s' "$pem" | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p' | sed 's/,.*//' || true)
        if [[ -n "$cn" ]]; then
            san_list=$(printf '%s' "$cn" | jq -R . | jq -s .)
            if printf '%s' "$cn" | grep -q '^\*\.'; then
                wildcard="true"
            else
                wildcard="false"
            fi
        else
            san_list="[]"
            wildcard="false"
        fi
    else
        san_list=$(printf '%s' "$san_raw" | tr ',' '\n' | sed 's/^ *//' | jq -R . | jq -s .)
        if printf '%s' "$san_raw" | grep -q '\*\.'; then
            wildcard="true"
        else
            wildcard="false"
        fi
    fi

    jq -n \
        --arg issuer "$issuer" \
        --arg notBefore "$not_before" \
        --arg notAfter "$not_after" \
        --argjson sans "$san_list" \
        --argjson wildcard "$wildcard" \
        '{issuer: $issuer, notBefore: $notBefore, notAfter: $notAfter, sans: $sans, wildcard: $wildcard, parseable: true}'
}

cert_covers_host() {
    local host="$1" sans_json="$2"
    printf '%s' "$sans_json" | jq -e --arg host "$host" '
        any(.[];
            if startswith("*.") then
                ($host | endswith(.[1:]))
            else
                . == $host
            end
        )
    ' >/dev/null
}

cert_is_expired() {
    local not_after="$1"
    local epoch now
    epoch=$(date -d "$not_after" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$not_after" +%s 2>/dev/null || true)
    if [[ -z "$epoch" ]]; then
        return 2
    fi
    now=$(date +%s)
    [[ "$now" -gt "$epoch" ]]
}

# Decide se la route può essere migrata. Stampa un oggetto JSON.
decide_route() {
    local route_json="$1" src_domain="$2" dst_domain="$3"
    local name host svc cert host_bound=false dest_host status reason action dns_action drop_host

    name=$(printf '%s' "$route_json" | jq -r '.metadata.name')
    host=$(printf '%s' "$route_json" | jq -r '.spec.host // empty')
    svc=$(printf '%s' "$route_json" | jq -r '.spec.to.name // empty')
    cert=$(printf '%s' "$route_json" | jq -r '.spec.tls.certificate // empty')
    local ns
    ns=$(printf '%s' "$route_json" | jq -r '.metadata.namespace // empty')

    if host_ends_with_domain "$host" "$src_domain"; then
        host_bound=true
    fi

    if [[ "$host_bound" == true ]]; then
        if [[ -n "$dst_domain" && -n "$ns" ]]; then
            dest_host="${name}-${ns}.${dst_domain}"
        else
            dest_host=""
        fi
        drop_host=true
    else
        dest_host="$host"
        drop_host=false
    fi

    status="ready"
    reason=""
    action=""
    dns_action=""

    if [[ -n "$cert" ]]; then
        if ! command -v openssl &>/dev/null; then
            status="blocked"
            reason="certificato esterno presente ma openssl non è disponibile per validarlo"
            action="Installa openssl e rilancia la migrazione"
        else
            local cert_info sans not_after
            cert_info=$(analyze_cert "$cert")
            sans=$(printf '%s' "$cert_info" | jq -c '.sans')
            not_after=$(printf '%s' "$cert_info" | jq -r '.notAfter')

            local expired_rc=0
            cert_is_expired "$not_after" || expired_rc=$?
            if [[ "$expired_rc" -eq 2 ]]; then
                status="blocked"
                reason="impossibile verificare la scadenza del certificato (notAfter: ${not_after})"
                action="Verifica il certificato manualmente prima di migrare"
            elif [[ "$expired_rc" -eq 0 ]]; then
                status="blocked"
                reason="certificato scaduto (scaduto il ${not_after})"
                action="Rinnova il certificato prima di migrare"
            elif ! cert_covers_host "$host" "$sans"; then
                status="blocked"
                reason="il certificato non copre l'hostname '${host}'"
                action="Sostituisci il certificato con uno che copra l'hostname della route"
            elif [[ "$host_bound" == true ]]; then
                if [[ -z "$dest_host" ]] || ! cert_covers_host "$dest_host" "$sans"; then
                    status="blocked"
                    reason="l'hostname di default '${host}' cambierà sul destinazione e il certificato non copre il nuovo host"
                    action="Usa un hostname personalizzato già coperto dal certificato, oppure emetti un certificato per il nuovo hostname"
                fi
            fi
        fi
    fi

    if [[ "$status" == "ready" ]]; then
        if [[ "$host_bound" == true ]]; then
            dns_action="L'hostname di default '${host}' non viene copiato. Il cluster destinazione assegnerà un nuovo hostname. Aggiorna i client che usavano il vecchio URL."
        elif [[ -n "$host" ]]; then
            dns_action="Aggiorna il record DNS di '${host}' per puntare al router del cluster destinazione."
        else
            dns_action="Nessun hostname impostato: il cluster destinazione ne genererà uno."
            drop_host=true
        fi
    fi

    jq -n \
        --arg name "$name" \
        --arg host "$host" \
        --arg destHost "$dest_host" \
        --arg service "$svc" \
        --arg status "$status" \
        --arg reason "$reason" \
        --arg action "$action" \
        --arg dnsAction "$dns_action" \
        --argjson hostClusterBound "$host_bound" \
        --argjson dropHost "$drop_host" \
        --argjson hasExternalCert "$([[ -n "$cert" ]] && echo true || echo false)" \
        '{
            name: $name,
            host: $host,
            destHost: $destHost,
            service: $service,
            status: $status,
            reason: $reason,
            action: $action,
            dnsAction: $dnsAction,
            hostClusterBound: $hostClusterBound,
            dropHost: $dropHost,
            hasExternalCert: $hasExternalCert
        }'
}

clean_route_json() {
    local route_json="$1" drop_host="$2"
    printf '%s' "$route_json" | jq --argjson dropHost "$drop_host" '
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
            .metadata.annotations["openshift.io/host.generated"],
            .status
        )
        | if $dropHost then del(.spec.host) else . end
        | if (.metadata.annotations // {} | length) == 0 then del(.metadata.annotations) else . end
    '
}

clean_service_json() {
    local svc_json="$1"
    printf '%s' "$svc_json" | jq '
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
            .spec.healthCheckNodePort,
            .spec.ipFamilies,
            .spec.ipFamilyPolicy,
            .status
        )
        | if (.spec.clusterIP // "") != "None" then del(.spec.clusterIP, .spec.clusterIPs) else . end
        | if (.metadata.annotations // {} | length) == 0 then del(.metadata.annotations) else . end
    '
}

prepare_route() {
    local name="$1"
    local raw decision

    debug "Esporto route '$name'"
    if ! raw=$(oc --context "$SRC_CONTEXT" -n "$NAMESPACE" get route "$name" -o json 2>/dev/null); then
        echo "Errore: route '$name' non trovata nel namespace '$NAMESPACE' sul cluster sorgente." >&2
        jq -n --arg name "$name" '{name:$name, status:"blocked", reason:"route non trovata sul cluster sorgente", action:"Verifica il nome della route", dnsAction:"", host:"", service:"", hostClusterBound:false, dropHost:false, hasExternalCert:false}'
        return 0
    fi

    if [[ "$(printf '%s' "$raw" | jq -r '.metadata.namespace // empty')" != "$NAMESPACE" ]]; then
        raw=$(printf '%s' "$raw" | jq --arg ns "$NAMESPACE" '.metadata.namespace = $ns')
    fi

    local replace_existing=false
    if oc --context "$DST_CONTEXT" -n "$NAMESPACE" get route "$name" &>/dev/null; then
        if [[ "$SKIP_CONFIRM" == "true" || ! -t 0 ]]; then
            replace_existing=true
            echo "⚠ La route '$name' esiste già sul destinazione: verrà sostituita."
        else
            local ans
            read -rp "La route '$name' esiste già sul destinazione. Sostituire? [s/N] " ans
            if [[ "$ans" =~ ^[sySY]$ ]]; then
                replace_existing=true
            else
                echo "  Saltata."
                SKIPPED_NAMES+=("$name")
                jq -n --arg name "$name" '{name:$name, status:"skipped", reason:"sostituzione rifiutata dall'\''utente", action:"", dnsAction:"", host:"", service:"", hostClusterBound:false, dropHost:false, hasExternalCert:false}'
                return 0
            fi
        fi
    fi

    decision=$(decide_route "$raw" "$SRC_APPS_DOMAIN" "$DST_APPS_DOMAIN")
    local status drop_host
    status=$(printf '%s' "$decision" | jq -r '.status')
    drop_host=$(printf '%s' "$decision" | jq -r '.dropHost')

    if [[ "$status" == "ready" ]]; then
        local cleaned
        cleaned=$(clean_route_json "$raw" "$drop_host")
        printf '%s' "$decision" | jq --argjson route "$cleaned" --argjson rep "$replace_existing" '. + {route: $route, replaceExisting: $rep}'
    else
        printf '%s' "$decision"
    fi
}

migrate_service_if_needed() {
    local svc_name="$1"
    [[ -n "$svc_name" ]] || return 0

    if oc --context "$DST_CONTEXT" -n "$NAMESPACE" get svc "$svc_name" &>/dev/null; then
        echo "  Service '$svc_name' già presente sul destinazione: non lo ricreo."
        return 0
    fi

    local raw cleaned
    if ! raw=$(oc --context "$SRC_CONTEXT" -n "$NAMESPACE" get svc "$svc_name" -o json 2>/dev/null); then
        echo "Errore: service '$svc_name' non trovato sul cluster sorgente." >&2
        return 1
    fi
    cleaned=$(clean_service_json "$raw")
    debug "Creo service '$svc_name' sul destinazione"
    if ! printf '%s\n' "$cleaned" | oc --context "$DST_CONTEXT" -n "$NAMESPACE" apply -f - >/dev/null; then
        echo "Errore durante la creazione del service '$svc_name'." >&2
        return 1
    fi
    echo "  ✔ Service '$svc_name' creato sul cluster destinazione"
}

apply_route_item() {
    local item="$1"
    local name svc route_json do_replace
    name=$(printf '%s' "$item" | jq -r '.name')
    svc=$(printf '%s' "$item" | jq -r '.service')
    route_json=$(printf '%s' "$item" | jq -c '.route')
    do_replace=$(printf '%s' "$item" | jq -r '.replaceExisting // false')

    if ! migrate_service_if_needed "$svc"; then
        return 1
    fi

    if [[ "$do_replace" == "true" ]]; then
        debug "oc --context $DST_CONTEXT -n $NAMESPACE delete route $name"
        if ! oc --context "$DST_CONTEXT" -n "$NAMESPACE" delete route "$name" --wait=true 2>/dev/null; then
            echo "Errore durante l'eliminazione della route '$name' esistente." >&2
            return 1
        fi
    fi

    debug "Creo route '$name' sul destinazione"
    if ! printf '%s\n' "$route_json" | oc --context "$DST_CONTEXT" -n "$NAMESPACE" apply -f - >/dev/null; then
        echo "Errore durante la creazione della route '$name'." >&2
        return 1
    fi

    if [[ "$do_replace" == "true" ]]; then
        echo "✔ Route '$name' sostituita sul cluster destinazione"
    else
        echo "✔ Route '$name' creata sul cluster destinazione"
    fi
}

print_plan() {
    local item
    echo ""
    echo "Route pronte alla migrazione:"
    if [[ ${#READY_ITEMS[@]} -eq 0 ]]; then
        echo "  (nessuna)"
    else
        for item in "${READY_ITEMS[@]}"; do
            printf '%s' "$item" | jq -r '
                "  - \(.name) host=\(.host // "(vuoto)")" +
                (if .hostClusterBound then " [hostname di default: verrà rimosso]" else "" end) +
                (if .hasExternalCert then " [certificato esterno ok]" else "" end) +
                "\n      service: \(.service // "(nessuno)")"
            '
        done
    fi

    echo ""
    echo "Route bloccate:"
    if [[ ${#BLOCKED_ITEMS[@]} -eq 0 ]]; then
        echo "  (nessuna)"
    else
        for item in "${BLOCKED_ITEMS[@]}"; do
            printf '%s' "$item" | jq -r '
                "  - \(.name): \(.reason)\n      → \(.action)"
            '
        done
    fi
}

print_summary() {
    local migrated="$1"
    local item
    echo ""
    echo "============================================================"
    echo "Riepilogo: ${migrated} migrate, ${#BLOCKED_ITEMS[@]} bloccate, ${#SKIPPED_NAMES[@]} saltate, ${#FAILED_NAMES[@]} errori"

    if [[ "$migrated" -gt 0 ]]; then
        echo ""
        echo "Migrate:"
        for item in "${READY_ITEMS[@]}"; do
            local applied
            applied=$(printf '%s' "$item" | jq -r '.applied // false')
            [[ "$applied" == "true" ]] || continue
            printf '%s' "$item" | jq -r '
                "  - \(.name)" +
                (if .hostClusterBound then
                    " (hostname di default: il destinazione assegna un nuovo host)"
                 else
                    " (host personalizzato: \(.host))"
                 end) +
                "\n      → \(.dnsAction)"
            '
        done
    fi

    if [[ ${#BLOCKED_ITEMS[@]} -gt 0 ]]; then
        echo ""
        echo "Bloccate:"
        for item in "${BLOCKED_ITEMS[@]}"; do
            printf '%s' "$item" | jq -r '
                "  - \(.name): \(.reason)\n      → \(.action)"
            '
        done
    fi

    if [[ ${#SKIPPED_NAMES[@]} -gt 0 ]]; then
        echo ""
        echo "Saltate:"
        for item in "${SKIPPED_NAMES[@]}"; do
            echo "  - $item"
        done
    fi

    if [[ ${#FAILED_NAMES[@]} -gt 0 ]]; then
        echo ""
        echo "Errori in apply:"
        for item in "${FAILED_NAMES[@]}"; do
            echo "  - $item"
        done
    fi
    echo "============================================================"
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
    echo "Errore: specifica almeno un nome di route." >&2
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
echo "Migrazione Route: ${NAMES[*]}"
echo "  Namespace:    $NAMESPACE"
echo "  Sorgente:     $SRC_CONTEXT"
echo "  Destinazione: $DST_CONTEXT"
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

SRC_APPS_DOMAIN=$(detect_apps_domain "$SRC_CONTEXT")
DST_APPS_DOMAIN=$(detect_apps_domain "$DST_CONTEXT")
echo "Dominio apps sorgente:     ${SRC_APPS_DOMAIN:-"(non rilevato)"}"
echo "Dominio apps destinazione: ${DST_APPS_DOMAIN:-"(non rilevato)"}"

echo ""
echo "Validazione route..."
for name in "${NAMES[@]}"; do
    item=$(prepare_route "$name")
    status=$(printf '%s' "$item" | jq -r '.status')
    if [[ "$status" == "ready" ]]; then
        READY_ITEMS+=("$item")
    elif [[ "$status" == "skipped" ]]; then
        true
    else
        BLOCKED_ITEMS+=("$item")
    fi
done

print_plan

if [[ ${#READY_ITEMS[@]} -eq 0 ]]; then
    print_summary 0
    exit 1
fi

echo ""
if [[ "$SKIP_CONFIRM" != "true" ]]; then
    read -rp "Procedere con la migrazione di ${#READY_ITEMS[@]} route? [s/N] " confirm
    if [[ ! "$confirm" =~ ^[sySY]$ ]]; then
        echo "Operazione annullata."
        exit 0
    fi
fi

echo ""
ok_count=0
updated_ready=()
for item in "${READY_ITEMS[@]}"; do
    name=$(printf '%s' "$item" | jq -r '.name')
    if apply_route_item "$item"; then
        item=$(printf '%s' "$item" | jq '.applied = true')
        updated_ready+=("$item")
        (( ok_count++ )) || true
    else
        FAILED_NAMES+=("$name")
        updated_ready+=("$item")
    fi
done
READY_ITEMS=("${updated_ready[@]}")

print_summary "$ok_count"

if [[ ${#BLOCKED_ITEMS[@]} -gt 0 || ${#FAILED_NAMES[@]} -gt 0 ]]; then
    exit 1
fi

#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIGURAZIONE
# ==========================================
CONTEXT="${SRC_CONTEXT:-}"
NAMESPACE=""
OUTPUT_FILE=""
DEBUG="${DEBUG:-false}"

# ==========================================
# FUNZIONI BASE
# ==========================================
usage() {
    cat <<EOF
Uso: $0 [OPZIONI]

Scansiona un namespace di un cluster OpenShift e produce un report completo
di workload, secret, configmap, PVC, service e route.

Opzioni:
  -s <context>    Context oc/kubectl del cluster (obbligatorio)
  -n <namespace>  Namespace da scansionare
                  (default: progetto corrente del context)
  -o <file>       Salva il report in formato strutturato
                  (.json per JSON, .yaml/.yml per YAML)
  -v              Modalità debug
  -h              Mostra questo messaggio di aiuto

Variabili d'ambiente:
  SRC_CONTEXT     Alternativa a -s

Esempi:
  $0 -s cluster-a
  $0 -s cluster-a -n my-project
  $0 -s cluster-a -n my-project -o report.json
  $0 -s cluster-a -n my-project -o report.yaml
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
        echo "⚠ 'openssl' non trovato: l'analisi dei certificati delle Route verrà saltata." >&2
    fi
}

resolve_namespace() {
    local ns
    if ! ns=$(oc --context "$CONTEXT" project -q 2>/dev/null); then
        echo "Errore: impossibile leggere il progetto corrente del context '$CONTEXT'." >&2
        echo "Specifica il namespace con -n." >&2
        exit 1
    fi
    ns="${ns//$'\r'/}"
    ns="${ns#"${ns%%[![:space:]]*}"}"
    ns="${ns%"${ns##*[![:space:]]}"}"
    if [[ -z "$ns" ]]; then
        echo "Errore: il context '$CONTEXT' non ha un progetto corrente. Specificalo con -n." >&2
        exit 1
    fi
    NAMESPACE="$ns"
}

# ==========================================
# RACCOLTA DATI DAL CLUSTER
# ==========================================
ALL_WORKLOADS_JSON=""
DC_JSON=""
STORAGE_JSON=""
NETWORK_JSON=""
SRC_APPS_DOMAIN=""

fetch_data() {
    echo "Raccolta dati dal namespace '$NAMESPACE' (context: $CONTEXT)..." >&2

    debug "Fetching deployments, statefulsets, daemonsets, cronjobs, jobs, pods, replicasets"
    ALL_WORKLOADS_JSON=$(oc --context "$CONTEXT" -n "$NAMESPACE" \
        get deployment,statefulset,daemonset,cronjob,job,pod,replicaset -o json 2>/dev/null || echo '{"items":[]}')

    debug "Fetching deploymentconfigs"
    DC_JSON=$(oc --context "$CONTEXT" -n "$NAMESPACE" \
        get dc -o json 2>/dev/null || echo '{"items":[]}')

    debug "Fetching secrets, configmaps, pvcs"
    STORAGE_JSON=$(oc --context "$CONTEXT" -n "$NAMESPACE" \
        get secret,configmap,pvc -o json 2>/dev/null || echo '{"items":[]}')

    debug "Fetching services, routes"
    NETWORK_JSON=$(oc --context "$CONTEXT" -n "$NAMESPACE" \
        get svc,route -o json 2>/dev/null || echo '{"items":[]}')

    debug "Detecting apps domain"
    SRC_APPS_DOMAIN=$(oc --context "$CONTEXT" get ingresses.config.openshift.io cluster \
        -o jsonpath='{.spec.domain}' 2>/dev/null || true)
    if [[ -n "$SRC_APPS_DOMAIN" ]]; then
        debug "Apps domain: $SRC_APPS_DOMAIN"
    else
        local api_server
        api_server=$(oc config view --context "$CONTEXT" --minify \
            -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
        local api_host
        api_host=$(printf '%s' "$api_server" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#/.*##; s#:[0-9]+$##')
        if [[ "$api_host" == api.* ]]; then
            SRC_APPS_DOMAIN="apps.${api_host#api.}"
            debug "Apps domain (inferred from API): $SRC_APPS_DOMAIN"
        fi
    fi

    echo "✔ Dati raccolti" >&2
}

# ==========================================
# JQ: FILTRO WORKLOAD GENERICO
# ==========================================
# Produce un array JSON normalizzato di workload con tutti i campi necessari.
# Input: il JSON grezzo di oc get, il tipo di risorsa, e i ReplicaSet owners (per filtrare pod).
#
# Ogni funzione di sezione lavora su questo formato intermedio.

JQ_PROBE='
def format_probe:
    if . == null then "N/A"
    elif .httpGet then "httpGet \(.httpGet.path // "/"):\(.httpGet.port)"
    elif .tcpSocket then "tcpSocket \(.tcpSocket.port)"
    elif .exec then "exec \(.exec.command | join(" "))"
    elif .grpc then "grpc \(.grpc.port)"
    else "unknown"
    end;
'

JQ_CONTAINER='
def container_refs($volumes):
    . as $c |
    [$c.volumeMounts // [] | .[].name] as $mount_names |

    (([$c.envFrom // [] | .[] | select(.secretRef) | .secretRef.name]) +
     ([$c.env // [] | .[] | select(.valueFrom.secretKeyRef) | .valueFrom.secretKeyRef.name]) +
     ([$volumes[] | select(.name as $vn | $mount_names | index($vn)) |
       select(.secret != null) | .secret.secretName])
    ) | unique as $secrets |

    (([$c.envFrom // [] | .[] | select(.configMapRef) | .configMapRef.name]) +
     ([$c.env // [] | .[] | select(.valueFrom.configMapKeyRef) | .valueFrom.configMapKeyRef.name]) +
     ([$volumes[] | select(.name as $vn | $mount_names | index($vn)) |
       select(.configMap != null) | .configMap.name])
    ) | unique as $configmaps |

    ([$volumes[] | select(.name as $vn | $mount_names | index($vn)) |
      select(.persistentVolumeClaim != null) | .persistentVolumeClaim.claimName]
    ) | unique as $pvcs |

    {secrets: $secrets, configmaps: $configmaps, pvcs: $pvcs};

def format_container($volumes):
    . as $c |
    container_refs($volumes) as $refs |
    {
        name: .name,
        image: (.image // "N/A"),
        requests: {
            cpu:    (.resources.requests.cpu // "N/A"),
            memory: (.resources.requests.memory // "N/A")
        },
        limits: {
            cpu:    (.resources.limits.cpu // "N/A"),
            memory: (.resources.limits.memory // "N/A")
        },
        liveness:  (.livenessProbe  | format_probe),
        readiness: (.readinessProbe | format_probe),
        startup:   (.startupProbe   | format_probe),
        secrets:   $refs.secrets,
        configmaps: $refs.configmaps,
        pvcs:      $refs.pvcs
    };
'

JQ_AFFINITY='
def format_affinity:
    if . == null then "N/A"
    else
        [ if .nodeAffinity then "nodeAffinity" else empty end,
          if .podAffinity then "podAffinity" else empty end,
          if .podAntiAffinity then "podAntiAffinity" else empty end
        ] | if length == 0 then "N/A" else join(", ") end
    end;
'

JQ_TOLERATIONS='
def format_tolerations:
    if . == null or (. | length) == 0 then "N/A"
    else [ .[] | "\(.key // "*")=\(.value // ""):\(.effect // "*")" ] | join(", ")
    end;
'

JQ_NODESELECTOR='
def format_nodeselector:
    if . == null or (. | length) == 0 then "N/A"
    else [ to_entries[] | "\(.key)=\(.value)" ] | join(", ")
    end;
'

JQ_IMAGEPULLSECRETS='
def format_imagepullsecrets:
    if . == null or (. | length) == 0 then []
    else [ .[].name ]
    end;
'

build_workload_jq() {
    cat <<'JQEOF'
${JQ_PROBE}
${JQ_CONTAINER}
${JQ_AFFINITY}
${JQ_TOLERATIONS}
${JQ_NODESELECTOR}
${JQ_IMAGEPULLSECRETS}
JQEOF
}

# ==========================================
# PARSING WORKLOAD
# ==========================================
parse_workloads() {
    local all_json="$1" dc_json="$2"

    local rs_owners
    rs_owners=$(printf '%s' "$all_json" | jq -r '
        [.items[] | select(.kind == "ReplicaSet") | .metadata.ownerReferences // [] | .[] | .name] | unique | .[]
    ')

    local rs_names
    rs_names=$(printf '%s' "$all_json" | jq -r '
        [.items[] | select(.kind == "ReplicaSet") | .metadata.name] | unique | .[]
    ')

    local rc_names
    rc_names=$(printf '%s' "$dc_json" | jq -r '
        [.items[] | .metadata.name] | unique | .[]
    ')

    # Build the combined jq filter with all helper functions inlined
    local jq_filter
    jq_filter="${JQ_PROBE}
${JQ_CONTAINER}
${JQ_AFFINITY}
${JQ_TOLERATIONS}
${JQ_NODESELECTOR}
${JQ_IMAGEPULLSECRETS}"

    # Parse standard workloads (Deployment, StatefulSet, DaemonSet)
    local std_workloads
    std_workloads=$(printf '%s' "$all_json" | jq -r --argjson rs_names "$(printf '%s' "$rs_names" | jq -R . | jq -s .)" \
        "${jq_filter}"'
        [.items[] | select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet") |
            .kind as $kind |
            (if $kind == "DaemonSet" then null else (.spec.replicas // 1) end) as $replicas |
            (.spec.template.spec) as $podspec |
            ($podspec.volumes // []) as $volumes |
            {
                kind: $kind,
                name: .metadata.name,
                replicas: ($replicas // null),
                serviceAccount: ($podspec.serviceAccountName // $podspec.serviceAccount // "default"),
                nodeSelector: ($podspec.nodeSelector | format_nodeselector),
                tolerations: ($podspec.tolerations | format_tolerations),
                affinity: ($podspec.affinity | format_affinity),
                imagePullSecrets: ($podspec.imagePullSecrets | format_imagepullsecrets),
                containers: [($podspec.containers // [])[] | format_container($volumes)],
                initContainers: [($podspec.initContainers // [])[] | format_container($volumes)]
            }
        ]
    ')

    # Parse DeploymentConfigs
    local dc_workloads
    dc_workloads=$(printf '%s' "$dc_json" | jq -r \
        "${jq_filter}"'
        [.items[] | select(.kind == "DeploymentConfig") |
            (.spec.template.spec) as $podspec |
            ($podspec.volumes // []) as $volumes |
            {
                kind: "DeploymentConfig",
                name: .metadata.name,
                replicas: (.spec.replicas // 1),
                serviceAccount: ($podspec.serviceAccountName // $podspec.serviceAccount // "default"),
                nodeSelector: ($podspec.nodeSelector | format_nodeselector),
                tolerations: ($podspec.tolerations | format_tolerations),
                affinity: ($podspec.affinity | format_affinity),
                imagePullSecrets: ($podspec.imagePullSecrets | format_imagepullsecrets),
                containers: [($podspec.containers // [])[] | format_container($volumes)],
                initContainers: [($podspec.initContainers // [])[] | format_container($volumes)]
            }
        ]
    ')

    # Parse CronJobs
    local cron_workloads
    cron_workloads=$(printf '%s' "$all_json" | jq -r \
        "${jq_filter}"'
        [.items[] | select(.kind == "CronJob") |
            (.spec.jobTemplate.spec.template.spec) as $podspec |
            ($podspec.volumes // []) as $volumes |
            {
                kind: "CronJob",
                name: .metadata.name,
                schedule: (.spec.schedule // "N/A"),
                serviceAccount: ($podspec.serviceAccountName // $podspec.serviceAccount // "default"),
                nodeSelector: ($podspec.nodeSelector | format_nodeselector),
                tolerations: ($podspec.tolerations | format_tolerations),
                affinity: ($podspec.affinity | format_affinity),
                imagePullSecrets: ($podspec.imagePullSecrets | format_imagepullsecrets),
                containers: [($podspec.containers // [])[] | format_container($volumes)],
                initContainers: [($podspec.initContainers // [])[] | format_container($volumes)]
            }
        ]
    ')

    # Parse standalone Jobs (not owned by a CronJob)
    local job_workloads
    job_workloads=$(printf '%s' "$all_json" | jq -r \
        "${jq_filter}"'
        [.items[] | select(.kind == "Job") |
            select((.metadata.ownerReferences // []) | map(select(.kind == "CronJob")) | length == 0) |
            (.spec.template.spec) as $podspec |
            ($podspec.volumes // []) as $volumes |
            {
                kind: "Job",
                name: .metadata.name,
                serviceAccount: ($podspec.serviceAccountName // $podspec.serviceAccount // "default"),
                nodeSelector: ($podspec.nodeSelector | format_nodeselector),
                tolerations: ($podspec.tolerations | format_tolerations),
                affinity: ($podspec.affinity | format_affinity),
                imagePullSecrets: ($podspec.imagePullSecrets | format_imagepullsecrets),
                containers: [($podspec.containers // [])[] | format_container($volumes)],
                initContainers: [($podspec.initContainers // [])[] | format_container($volumes)]
            }
        ]
    ')

    # Parse standalone Pods (no ownerReferences at all)
    local pod_workloads
    pod_workloads=$(printf '%s' "$all_json" | jq -r \
        "${jq_filter}"'
        [.items[] | select(.kind == "Pod") |
            select((.metadata.ownerReferences // []) | length == 0) |
            (.spec) as $podspec |
            ($podspec.volumes // []) as $volumes |
            {
                kind: "Pod",
                name: .metadata.name,
                serviceAccount: ($podspec.serviceAccountName // $podspec.serviceAccount // "default"),
                nodeSelector: ($podspec.nodeSelector | format_nodeselector),
                tolerations: ($podspec.tolerations | format_tolerations),
                affinity: ($podspec.affinity | format_affinity),
                imagePullSecrets: ($podspec.imagePullSecrets | format_imagepullsecrets),
                containers: [($podspec.containers // [])[] | format_container($volumes)],
                initContainers: [($podspec.initContainers // [])[] | format_container($volumes)]
            }
        ]
    ')

    # Merge all into one JSON array
    printf '%s\n%s\n%s\n%s\n%s\n' \
        "$std_workloads" "$dc_workloads" "$cron_workloads" "$job_workloads" "$pod_workloads" \
        | jq -s 'add | sort_by(.kind, .name)'
}

# ==========================================
# RACCOLTA RIFERIMENTI DA WORKLOAD
# ==========================================
collect_all_refs() {
    local workloads_json="$1"
    printf '%s' "$workloads_json" | jq '{
        secrets: [.[] | (.containers + .initContainers) | .[]? | .secrets[]?] | unique | sort,
        configmaps: [.[] | (.containers + .initContainers) | .[]? | .configmaps[]?] | unique | sort,
        pvcs: [.[] | (.containers + .initContainers) | .[]? | .pvcs[]?] | unique | sort,
        imagePullSecrets: [.[] | .imagePullSecrets[]?] | unique | sort
    } | .secrets = (.secrets + .imagePullSecrets) | del(.imagePullSecrets) | .secrets |= unique'
}

# ==========================================
# PARSING SECRET
# ==========================================
parse_secrets() {
    local storage_json="$1" refs_json="$2"
    printf '%s' "$storage_json" | jq --argjson refs "$refs_json" '
        [.items[] | select(.kind == "Secret") |
            select(.type != "kubernetes.io/service-account-token"
               and .type != "kubernetes.io/dockercfg"
               and .type != "kubernetes.io/dockerconfigjson") |
            select(.metadata.name |
                (startswith("builder-") or startswith("deployer-") or startswith("default-")) | not) |
            {
                name: .metadata.name,
                type: (.type // "Opaque"),
                keys: ([.data // {} | keys[]] | sort),
                unbounded: ([ .metadata.name ] | inside($refs.secrets) | not)
            }
        ] | sort_by(.name)
    '
}

# ==========================================
# PARSING CONFIGMAP
# ==========================================
parse_configmaps() {
    local storage_json="$1" refs_json="$2"
    printf '%s' "$storage_json" | jq --argjson refs "$refs_json" '
        [.items[] | select(.kind == "ConfigMap") |
            select(.metadata.name != "kube-root-ca.crt"
               and .metadata.name != "openshift-service-ca.crt") |
            {
                name: .metadata.name,
                keys: ([(.data // {} | keys[]), (.binaryData // {} | keys[])] | sort),
                unbounded: ([ .metadata.name ] | inside($refs.configmaps) | not)
            }
        ] | sort_by(.name)
    '
}

# ==========================================
# PARSING PVC
# ==========================================
parse_pvcs() {
    local storage_json="$1" refs_json="$2"
    printf '%s' "$storage_json" | jq --argjson refs "$refs_json" '
        [.items[] | select(.kind == "PersistentVolumeClaim") |
            {
                name: .metadata.name,
                capacity: (.status.capacity.storage // .spec.resources.requests.storage // "N/A"),
                accessModes: (.spec.accessModes // [] | join(", ")),
                storageClass: (.spec.storageClassName // "(default)"),
                unbounded: ([ .metadata.name ] | inside($refs.pvcs) | not)
            }
        ] | sort_by(.name)
    '
}

# ==========================================
# PARSING SERVICE
# ==========================================
parse_services() {
    local network_json="$1"
    printf '%s' "$network_json" | jq '
        [.items[] | select(.kind == "Service") |
            {
                name: .metadata.name,
                type: (.spec.type // "ClusterIP"),
                selector: (if (.spec.selector // {} | length) > 0
                    then [.spec.selector | to_entries[] | "\(.key)=\(.value)"] | join(", ")
                    else "N/A" end),
                ports: [(.spec.ports // [])[] | {
                    port: .port,
                    targetPort: .targetPort,
                    protocol: (.protocol // "TCP"),
                    name: (.name // null)
                }]
            }
        ] | sort_by(.name)
    '
}

# ==========================================
# PARSING ROUTE
# ==========================================
parse_routes() {
    local network_json="$1"
    printf '%s' "$network_json" | jq '
        [.items[] | select(.kind == "Route") |
            (.spec.tls // {}) as $tls |
            {
                name: .metadata.name,
                host: (.spec.host // "N/A"),
                path: (.spec.path // "/"),
                service: (.spec.to.name // "N/A"),
                port: (.spec.port.targetPort // "N/A"),
                tlsTermination: ($tls.termination // "none"),
                externalCert: (if ($tls.certificate // "") != "" then true else false end),
                certPEM: ($tls.certificate // null)
            }
        ] | sort_by(.name)
    '
}

# ==========================================
# ANALISI CERTIFICATO TLS
# ==========================================
analyze_cert() {
    local pem="$1"
    if ! command -v openssl &>/dev/null; then
        echo '{"issuer":"openssl non disponibile","notBefore":"N/A","notAfter":"N/A","sans":[],"wildcard":false}'
        return 0
    fi

    local issuer notBefore notAfter san_raw san_list wildcard

    issuer=$(printf '%s' "$pem" | openssl x509 -noout -issuer 2>/dev/null | sed 's/^issuer= *//' || echo "N/A")
    notBefore=$(printf '%s' "$pem" | openssl x509 -noout -startdate 2>/dev/null | sed 's/^notBefore=//' || echo "N/A")
    notAfter=$(printf '%s' "$pem" | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//' || echo "N/A")

    san_raw=$(printf '%s' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | grep -oE 'DNS:[^,]+' | sed 's/DNS://g' | tr '\n' ',' | sed 's/,$//' || true)

    if [[ -z "$san_raw" ]]; then
        san_list="[]"
        wildcard="false"
    else
        san_list=$(printf '%s' "$san_raw" | tr ',' '\n' | sed 's/^ *//' | jq -R . | jq -s .)
        if printf '%s' "$san_raw" | grep -q '\*\.'; then
            wildcard="true"
        else
            wildcard="false"
        fi
    fi

    local san_count
    san_count=$(printf '%s' "$san_list" | jq 'length')

    jq -n \
        --arg issuer "$issuer" \
        --arg notBefore "$notBefore" \
        --arg notAfter "$notAfter" \
        --argjson sans "$san_list" \
        --argjson wildcard "$wildcard" \
        --argjson dedicatedCert "$([ "$san_count" -eq 1 ] && echo true || echo false)" \
        '{issuer: $issuer, notBefore: $notBefore, notAfter: $notAfter, sans: $sans, wildcard: $wildcard, dedicatedCert: $dedicatedCert}'
}

enrich_routes_with_certs() {
    local routes_json="$1" apps_domain="$2"
    local count i route_entry cert_pem cert_info enriched="[]"

    count=$(printf '%s' "$routes_json" | jq 'length')
    for (( i=0; i<count; i++ )); do
        route_entry=$(printf '%s' "$routes_json" | jq --arg apps_domain "$apps_domain" '
            .[$i] |
            (if $apps_domain != "" then (.host // "" | endswith($apps_domain)) else false end) as $hcb |
            . + {hostClusterBound: $hcb}
        ' --argjson i "$i")
        cert_pem=$(printf '%s' "$route_entry" | jq -r '.certPEM // empty')

        if [[ -n "$cert_pem" ]]; then
            cert_info=$(analyze_cert "$cert_pem")
            route_entry=$(printf '%s' "$route_entry" | jq \
                --argjson ci "$cert_info" \
                --arg apps_domain "$apps_domain" '
                .host as $host |
                ($ci.sans | any(
                    if startswith("*.") then
                        ($host | endswith(.[1:]))
                    else
                        . == $host
                    end
                )) as $match |
                (if $apps_domain != "" then
                    ($ci.sans | any(contains($apps_domain)))
                 else false end) as $cluster_bound |
                . + {certInfo: ($ci + {certMatch: $match, clusterBound: $cluster_bound})} | del(.certPEM)
            ')
        else
            route_entry=$(printf '%s' "$route_entry" | jq 'del(.certPEM)')
        fi

        enriched=$(printf '%s\n%s' "$enriched" "$route_entry" | jq -s '.[0] + [.[1]]')
    done

    printf '%s' "$enriched"
}

# ==========================================
# OUTPUT TESTUALE
# ==========================================
print_text_report() {
    local workloads="$1" secrets="$2" configmaps="$3" pvcs="$4" services="$5" routes="$6"

    local kinds=("Deployment" "DeploymentConfig" "StatefulSet" "DaemonSet" "CronJob" "Job" "Pod")

    for kind in "${kinds[@]}"; do
        local items
        items=$(printf '%s' "$workloads" | jq -c --arg k "$kind" '[.[] | select(.kind == $k)]')
        local cnt
        cnt=$(printf '%s' "$items" | jq 'length')
        [[ "$cnt" -eq 0 ]] && continue

        echo ""
        echo "=== WORKLOAD: $kind ==="

        printf '%s' "$items" | jq -r --arg kind "$kind" '
            .[] |
            "\n  \(.name)" +
                (if $kind == "DaemonSet" or $kind == "CronJob" or $kind == "Job" or $kind == "Pod" then ""
                 else " (replicas: \(.replicas // "N/A"))" end) +
                (if $kind == "CronJob" then " (schedule: \(.schedule))" else "" end) +
            "\n    serviceAccount:  \(.serviceAccount)" +
            "\n    nodeSelector:    \(.nodeSelector)" +
            "\n    tolerations:     \(.tolerations)" +
            "\n    affinity:        \(.affinity)" +
            "\n    Containers:" +
            (.containers | map(
                "\n      [\(.name)] image: \(.image)" +
                "\n        requests:    cpu=\(.requests.cpu), memory=\(.requests.memory)" +
                "\n        limits:      cpu=\(.limits.cpu), memory=\(.limits.memory)" +
                "\n        liveness:    \(.liveness)" +
                "\n        readiness:   \(.readiness)" +
                "\n        startup:     \(.startup)" +
                "\n        secrets:     \(if (.secrets | length) > 0 then .secrets | join(", ") else "N/A" end)" +
                "\n        configmaps:  \(if (.configmaps | length) > 0 then .configmaps | join(", ") else "N/A" end)" +
                "\n        pvcs:        \(if (.pvcs | length) > 0 then .pvcs | join(", ") else "N/A" end)"
            ) | join("")) +
            (if (.initContainers | length) > 0 then
                "\n    Init Containers:" +
                (.initContainers | map(
                    "\n      [\(.name)] image: \(.image)" +
                    "\n        requests:    cpu=\(.requests.cpu), memory=\(.requests.memory)" +
                    "\n        limits:      cpu=\(.limits.cpu), memory=\(.limits.memory)" +
                    "\n        secrets:     \(if (.secrets | length) > 0 then .secrets | join(", ") else "N/A" end)" +
                    "\n        configmaps:  \(if (.configmaps | length) > 0 then .configmaps | join(", ") else "N/A" end)" +
                    "\n        pvcs:        \(if (.pvcs | length) > 0 then .pvcs | join(", ") else "N/A" end)"
                ) | join(""))
            else "" end)
        '
    done

    echo ""
    echo "=== SECRET ==="
    local secret_count
    secret_count=$(printf '%s' "$secrets" | jq 'length')
    if [[ "$secret_count" -eq 0 ]]; then
        echo "  (nessun secret utente trovato)"
    else
        printf '%s' "$secrets" | jq -r '
            .[] |
            "  \(if .unbounded then "[UNBOUNDED] " else "" end)\(.name)" +
            "\n    type: \(.type)" +
            "\n    keys: \(if (.keys | length) > 0 then .keys | join(", ") else "(vuoto)" end)"
        '
    fi

    echo ""
    echo "=== CONFIGMAP ==="
    local cm_count
    cm_count=$(printf '%s' "$configmaps" | jq 'length')
    if [[ "$cm_count" -eq 0 ]]; then
        echo "  (nessuna configmap utente trovata)"
    else
        printf '%s' "$configmaps" | jq -r '
            .[] |
            "  \(if .unbounded then "[UNBOUNDED] " else "" end)\(.name)" +
            "\n    keys: \(if (.keys | length) > 0 then .keys | join(", ") else "(vuoto)" end)"
        '
    fi

    echo ""
    echo "=== PVC ==="
    local pvc_count
    pvc_count=$(printf '%s' "$pvcs" | jq 'length')
    if [[ "$pvc_count" -eq 0 ]]; then
        echo "  (nessun PVC trovato)"
    else
        printf '%s' "$pvcs" | jq -r '
            .[] |
            "  \(if .unbounded then "[UNBOUNDED] " else "" end)\(.name)" +
            "\n    capacity:     \(.capacity)" +
            "\n    accessModes:  \(.accessModes)" +
            "\n    storageClass: \(.storageClass)"
        '
    fi

    echo ""
    echo "=== SERVICE ==="
    local svc_count
    svc_count=$(printf '%s' "$services" | jq 'length')
    if [[ "$svc_count" -eq 0 ]]; then
        echo "  (nessun service trovato)"
    else
        printf '%s' "$services" | jq -r '
            .[] |
            "  \(.name)" +
            "\n    type:     \(.type)" +
            "\n    selector: \(.selector)" +
            "\n    ports:    \(
                if (.ports | length) > 0 then
                    [.ports[] |
                        (if .name then "\(.name):" else "" end) +
                        "\(.port)->\(.targetPort)/\(.protocol)"
                    ] | join(", ")
                else "N/A"
                end
            )"
        '
    fi

    echo ""
    echo "=== ROUTE ==="
    local route_count
    route_count=$(printf '%s' "$routes" | jq 'length')
    if [[ "$route_count" -eq 0 ]]; then
        echo "  (nessuna route trovata)"
    else
        printf '%s' "$routes" | jq -r '
            .[] |
            "  \(.name)" +
            "\n    host:        \(.host)" +
            "\n    path:        \(.path)" +
            "\n    service:     \(.service)" +
            "\n    port:        \(.port)" +
            "\n    tls:         \(.tlsTermination)" +
            "\n    externalCert: \(if .externalCert then "yes" else "no" end)" +
            "\n    host legato al cluster: \(if .hostClusterBound then "SI - hostname generato da OpenShift, cambiera dopo la migrazione" else "no (hostname personalizzato)" end)" +
            (if .certInfo then
                "\n    cert issuer:  \(.certInfo.issuer)" +
                "\n    cert valid:   \(.certInfo.notBefore) - \(.certInfo.notAfter)" +
                "\n    cert SANs:    \(.certInfo.sans | join(", "))" +
                "\n    cert wildcard: \(if .certInfo.wildcard then "yes" else "no" end)" +
                "\n    cert match:   \(if .certInfo.certMatch then "yes" else "MISMATCH" end)" +
                "\n    cert dedicato: \(if .certInfo.dedicatedCert then "yes (1 hostname)" else "no (multi-domain)" end)" +
                "\n    cert legato al cluster: \(if .certInfo.clusterBound then "SI - certificato legato al dominio del cluster sorgente, non valido dopo migrazione" else "no" end)"
            else "" end)
        '
    fi
}

# ==========================================
# OUTPUT STRUTTURATO
# ==========================================
build_structured_report() {
    local workloads="$1" secrets="$2" configmaps="$3" pvcs="$4" services="$5" routes="$6"
    jq -n \
        --argjson workloads "$workloads" \
        --argjson secrets "$secrets" \
        --argjson configmaps "$configmaps" \
        --argjson pvcs "$pvcs" \
        --argjson services "$services" \
        --argjson routes "$routes" \
        --arg namespace "$NAMESPACE" \
        --arg context "$CONTEXT" \
        '{
            context: $context,
            namespace: $namespace,
            workloads: $workloads,
            secrets: $secrets,
            configmaps: $configmaps,
            pvcs: $pvcs,
            services: $services,
            routes: $routes
        }'
}

write_output_file() {
    local report_json="$1" outfile="$2"
    local ext="${outfile##*.}"

    case "$ext" in
        json)
            printf '%s' "$report_json" | jq . > "$outfile"
            echo "Report JSON salvato in: $outfile" >&2
            ;;
        yaml|yml)
            if command -v python3 &>/dev/null && python3 -c "import yaml" 2>/dev/null; then
                printf '%s' "$report_json" | python3 -c '
import sys, json, yaml
data = json.load(sys.stdin)
yaml.dump(data, sys.stdout, default_flow_style=False, allow_unicode=True, sort_keys=False)
' > "$outfile"
                echo "Report YAML salvato in: $outfile" >&2
            else
                local json_fallback="${outfile%.*}.json"
                echo "⚠ python3 con PyYAML non disponibile. Salvo in JSON: $json_fallback" >&2
                printf '%s' "$report_json" | jq . > "$json_fallback"
            fi
            ;;
        *)
            echo "Errore: estensione '$ext' non supportata. Usa .json, .yaml o .yml." >&2
            exit 1
            ;;
    esac
}

# ==========================================
# PARSING ARGOMENTI
# ==========================================
while getopts "s:n:o:vh" opt; do
    case "$opt" in
        s) CONTEXT="$OPTARG" ;;
        n) NAMESPACE="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        v) DEBUG="true" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$CONTEXT" ]]; then
    echo "Errore: specifica il context del cluster (-s)." >&2
    echo "" >&2
    usage
fi

# ==========================================
# ESECUZIONE
# ==========================================
check_dependencies

if [[ -z "$NAMESPACE" ]]; then
    resolve_namespace
    echo "Namespace non specificato: uso '$NAMESPACE' (progetto corrente di $CONTEXT)"
fi

echo "============================================================"
echo "Scansione namespace: $NAMESPACE"
echo "  Context: $CONTEXT"
echo "============================================================"
echo ""

if ! oc --context "$CONTEXT" whoami &>/dev/null; then
    echo "Errore: impossibile connettersi al cluster (context: $CONTEXT)." >&2
    exit 1
fi
echo "✔ Connesso come '$(oc --context "$CONTEXT" whoami)'"

fetch_data

echo ""
echo "Analisi risorse..." >&2

WORKLOADS_JSON=$(parse_workloads "$ALL_WORKLOADS_JSON" "$DC_JSON")
debug "Workload trovati: $(printf '%s' "$WORKLOADS_JSON" | jq 'length')"

REFS_JSON=$(collect_all_refs "$WORKLOADS_JSON")
debug "Refs: $REFS_JSON"

SECRETS_JSON=$(parse_secrets "$STORAGE_JSON" "$REFS_JSON")
CONFIGMAPS_JSON=$(parse_configmaps "$STORAGE_JSON" "$REFS_JSON")
PVCS_JSON=$(parse_pvcs "$STORAGE_JSON" "$REFS_JSON")
SERVICES_JSON=$(parse_services "$NETWORK_JSON")
ROUTES_JSON_RAW=$(parse_routes "$NETWORK_JSON")

debug "Enriching routes with cert info..."
ROUTES_JSON=$(enrich_routes_with_certs "$ROUTES_JSON_RAW" "$SRC_APPS_DOMAIN")

echo "✔ Analisi completata" >&2
echo ""

print_text_report "$WORKLOADS_JSON" "$SECRETS_JSON" "$CONFIGMAPS_JSON" "$PVCS_JSON" "$SERVICES_JSON" "$ROUTES_JSON"

if [[ -n "$OUTPUT_FILE" ]]; then
    echo "" >&2
    REPORT_JSON=$(build_structured_report "$WORKLOADS_JSON" "$SECRETS_JSON" "$CONFIGMAPS_JSON" "$PVCS_JSON" "$SERVICES_JSON" "$ROUTES_JSON")
    write_output_file "$REPORT_JSON" "$OUTPUT_FILE"
fi

echo ""
echo "============================================================"
wl_count=$(printf '%s' "$WORKLOADS_JSON" | jq 'length')
sec_count=$(printf '%s' "$SECRETS_JSON" | jq 'length')
cm_count=$(printf '%s' "$CONFIGMAPS_JSON" | jq 'length')
pvc_count=$(printf '%s' "$PVCS_JSON" | jq 'length')
svc_count=$(printf '%s' "$SERVICES_JSON" | jq 'length')
rt_count=$(printf '%s' "$ROUTES_JSON" | jq 'length')
echo "Totale: ${wl_count} workload, ${sec_count} secret, ${cm_count} configmap, ${pvc_count} PVC, ${svc_count} service, ${rt_count} route"
sec_unb=$(printf '%s' "$SECRETS_JSON" | jq '[.[] | select(.unbounded)] | length')
cm_unb=$(printf '%s' "$CONFIGMAPS_JSON" | jq '[.[] | select(.unbounded)] | length')
pvc_unb=$(printf '%s' "$PVCS_JSON" | jq '[.[] | select(.unbounded)] | length')
if [[ "$sec_unb" -gt 0 || "$cm_unb" -gt 0 || "$pvc_unb" -gt 0 ]]; then
    echo "Unbounded: ${sec_unb} secret, ${cm_unb} configmap, ${pvc_unb} PVC"
fi
rt_host_bound=$(printf '%s' "$ROUTES_JSON" | jq '[.[] | select(.hostClusterBound == true)] | length')
rt_cert_bound=$(printf '%s' "$ROUTES_JSON" | jq '[.[] | select(.certInfo.clusterBound == true)] | length')
if [[ "$rt_host_bound" -gt 0 ]]; then
    echo ""
    echo "⚠ ${rt_host_bound} route con hostname legato al cluster sorgente (dominio: ${SRC_APPS_DOMAIN})"
    echo "  L'hostname cambiera dopo la migrazione. Aggiornare DNS o configurare hostname personalizzati."
    echo "  Route interessate:"
    printf '%s' "$ROUTES_JSON" | jq -r '
        [.[] | select(.hostClusterBound == true)] | .[] |
        "    - \(.name) (host: \(.host))"
    '
fi
if [[ "$rt_cert_bound" -gt 0 ]]; then
    echo ""
    echo "⚠ ${rt_cert_bound} route con certificato legato al cluster sorgente!"
    echo "  Questi certificati contengono nei SAN il dominio '${SRC_APPS_DOMAIN}'"
    echo "  e NON saranno validi dopo la migrazione su un altro cluster."
    echo "  Route interessate:"
    printf '%s' "$ROUTES_JSON" | jq -r '
        [.[] | select(.certInfo.clusterBound == true)] | .[] |
        "    - \(.name) (host: \(.host), SANs: \(.certInfo.sans | join(", ")))"
    '
    echo "  Azione richiesta: rigenerare i certificati per il dominio del cluster destinazione."
fi
echo "============================================================"

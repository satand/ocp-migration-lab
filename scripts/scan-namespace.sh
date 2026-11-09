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
Uso: $0 [OPZIONI] [namespace ...]

Scansiona uno o più namespace di un cluster OpenShift e produce un report
completo di workload, secret, configmap, PVC, service e route.

Se non viene specificato alcun namespace, viene usato il progetto corrente
del context.

Opzioni:
  -s <context>    Context oc/kubectl del cluster (obbligatorio)
  -o <file>       Salva il report in formato strutturato
                  (.json per JSON, .yaml/.yml per YAML)
  -v              Modalità debug
  -h              Mostra questo messaggio di aiuto

Variabili d'ambiente:
  SRC_CONTEXT     Alternativa a -s

Esempi:
  $0 -s cluster-a
  $0 -s cluster-a my-project
  $0 -s cluster-a ns-alpha ns-beta ns-gamma
  $0 -s cluster-a -o report.json ns-alpha ns-beta
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
        echo "Specifica il namespace come argomento posizionale." >&2
        exit 1
    fi
    ns="${ns//$'\r'/}"
    ns="${ns#"${ns%%[![:space:]]*}"}"
    ns="${ns%"${ns##*[![:space:]]}"}"
    if [[ -z "$ns" ]]; then
        echo "Errore: il context '$CONTEXT' non ha un progetto corrente. Specifica il namespace come argomento." >&2
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
        ports: [(.ports // [])[] | {
            name: (.name // null),
            containerPort: .containerPort,
            protocol: (.protocol // "TCP")
        }],
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

# ==========================================
# RILEVAMENTO DIPENDENZE DA CM/SECRET VALUES
# ==========================================
JQ_DETECT_DEPS='
def is_sensitive_key:
  ascii_downcase | test("password|passwd|secret|token|credential|_pass$|_pwd$|private[._]?key|tls[._]?key");

def clean_props:
  with_entries(select(.value != null and .value != ""));

def sibling($entries; $pat):
  [$entries[] | select(.key | ascii_downcase | test($pat))
   | select(.key | is_sensitive_key | not) | .value]
  | if length > 0 then .[0] else null end;

def sibling_pfx($entries; $pfx; $pat):
  [$entries[] | select(.key | ascii_downcase | startswith($pfx))
   | select(.key | ascii_downcase | ltrimstr($pfx) | test("^" + $pat + "$"))
   | select(.key | is_sensitive_key | not) | .value]
  | if length > 0 then .[0] else null end;

def inval($pat):
  ([try capture($pat; "i") catch null] | if length > 0 then .[0].v else null end);

def match_re($s; $pat):
  [try ($s | capture($pat; "i")) catch null] | if length > 0 then .[0] else null end;

# Easy Connect: jdbc:oracle:thin:@//host:port/service[:instance][?params]
#               jdbc:oracle:thin:@tcps://host:port/service[:instance][?params]
def oracle_easy($line):
  match_re($line; "jdbc:oracle:thin:@(?<scheme>//|tcps://)(?<host>[^:/?]+)(?::(?<port>[0-9]+))?/(?<service>[^:/?]+)(?::(?<instance>[^/?]+))?(?:\\?(?<params>[^\\s\"]*))?");

# LDAP: jdbc:oracle:thin:@ldap://host:port[,host:port]/service,context
def oracle_ldap($line):
  match_re($line; "jdbc:oracle:thin:@(?<scheme>ldaps?://)(?<hosts>[^/\\s]+)/(?<service>[^,\\s]+),(?<context>[^\\s\"]+)");

def detect_deps:
  . as $entries |
  [ $entries[] |
    select(.value != null and (.value | type == "string") and (.value | length > 0)) |
    .key as $k | .value as $v |
    (
      # --- Oracle JDBC (Easy Connect e LDAP) ---
      (if ($v | test("jdbc:oracle:thin:"; "i")) then
        ($v | split("\n")[] | select(test("jdbc:oracle:thin:"; "i")) | . as $line |
          oracle_easy($line) as $e | oracle_ldap($line) as $l |
          if $e then
            {type:"jdbc", subtype:"oracle", key:$k,
             url:("jdbc:oracle:thin:@" + $e.scheme + $e.host
                  + (if $e.port then ":" + $e.port else "" end)
                  + "/" + $e.service
                  + (if $e.instance then ":" + $e.instance else "" end)
                  + (if $e.params then "?" + $e.params else "" end)),
             properties:({
               scheme:(if $e.scheme == "tcps://" then "tcps" else "tcp" end),
               host:$e.host,
               port:$e.port,
               service:$e.service,
               instance:$e.instance,
               params:$e.params,
               username:(sibling($entries; "(?:^|[._-])user(?:name)?$") // ($v | inval("(?:username|user)[=: ]+(?<v>[^\\s\"]+)")))
             } | clean_props)}
          elif $l then
            {type:"jdbc", subtype:"oracle", key:$k,
             url:("jdbc:oracle:thin:@" + $l.scheme + $l.hosts + "/" + $l.service + "," + $l.context),
             properties:({
               scheme:(if ($l.scheme | startswith("ldaps")) then "ldaps" else "ldap" end),
               host:$l.hosts,
               service:$l.service,
               context:$l.context,
               username:(sibling($entries; "(?:^|[._-])user(?:name)?$") // ($v | inval("(?:username|user)[=: ]+(?<v>[^\\s\"]+)")))
             } | clean_props)}
          else empty end)
       else empty end),

      # --- JDBC (altri driver) ---
      (if ($v | test("jdbc:"; "i")) then
        ($v | split("\n")[] | select(test("jdbc:"; "i")) | select(test("jdbc:oracle:"; "i") | not) |
          match_re(.; "(?<url>jdbc:(?<sub>[a-z0-9]+):[/]*(?:(?<user>[^:@\\s]+)(?::[^@\\s]*)?@)?(?<host>[^:/\\s;,\"]+)(?::(?<port>[0-9]+))?(?:[/](?<db>[^?;\\s\"]+))?)") as $m |
          if $m then {type:"jdbc", subtype:$m.sub, key:$k, url:$m.url,
            properties:({
              host:$m.host,
              port:($m.port // null),
              database:($m.db // ($v | inval("database[=: ]+(?<v>[^\\s\"]+)")) // sibling($entries; "database|db[._-]?name|dbname")),
              username:($m.user // ($v | inval("(?:username|user)[=: ]+(?<v>[^\\s\"]+)")) // sibling($entries; "username|db[._-]?user"))
            } | clean_props)}
          else empty end)
       else empty end),

      # --- MongoDB (URL) ---
      (if ($v | test("mongodb"; "i")) then
        (try ($v | capture("(?<url>mongodb(?:\\+srv)?://(?:(?<user>[^:@\\s]+)(?::[^@\\s]*)?@)?(?<host>[^:/\\s,\"]+)(?::(?<port>[0-9]+))?(?:[/](?<db>[^?\\s\"]+))?)"; "i")) catch null) as $m |
        if $m then {type:"mongodb", subtype:null, key:$k, url:$m.url,
          properties:({
            host:$m.host, port:($m.port // null),
            database:($m.db // sibling($entries; "database|db[._-]?name")),
            username:($m.user // sibling($entries; "username|user$"))
          } | clean_props)}
        else empty end
       else empty end),

      # --- MongoDB (key-name based: mongo*.host) ---
      (if (($k | ascii_downcase | test("mongo.*[._-]hosts?$")) and ($v | test("^mongodb"; "i") | not)) then
        ([$k | ascii_downcase | capture("(?<pfx>.+[._-])hosts?$")] | if length > 0 then .[0].pfx else null end) as $pfx |
        if $pfx then
          sibling_pfx($entries; $pfx; "port") as $port |
          {type:"mongodb", subtype:null, key:$k,
           url:("mongodb://" + ($v | split(",") | .[0]) + (if $port then ":" + $port else "" end)),
           properties:({
             host:$v,
             port:$port,
             database:sibling_pfx($entries; $pfx; "database"),
             authDatabase:sibling_pfx($entries; $pfx; "authentication-database"),
             username:sibling_pfx($entries; $pfx; "username")
           } | clean_props)}
        else empty end
       else empty end),

      # --- Redis ---
      (if ($v | test("rediss?://"; "i")) then
        (try ($v | capture("(?<url>rediss?://(?:(?<user>[^:@\\s]+)?(?::[^@\\s]*)?@)?(?<host>[^:/\\s\"]+)(?::(?<port>[0-9]+))?(?:[/](?<db>[0-9]+))?)"; "i")) catch null) as $m |
        if $m then {type:"redis", subtype:null, key:$k, url:$m.url,
          properties:({host:$m.host, port:($m.port // null), database:($m.db // null)} | clean_props)}
        else empty end
       else empty end),

      # --- Keycloak (URL con /realms/) ---
      (if ($v | test("[/]realms[/]"; "i")) then
        (try ($v | capture("(?<url>https?://(?<host>[^:/\\s\"]+)(?::(?<port>[0-9]+))?[^\\s\"]*?[/]realms[/](?<realm>[^/\\s\"]+))"; "i")) catch null) as $m |
        if $m then {type:"keycloak", subtype:null, key:$k, url:$m.url,
          properties:({
            host:$m.host, port:($m.port // null), realm:$m.realm,
            clientId:(sibling($entries; "client[._-]?id|resource") // ($v | inval("(?:client-id|resource)[=: ]+(?<v>[^\\s\"]+)")))
          } | clean_props)}
        else empty end
       else empty end),

      # --- Keycloak (hostname keycloak/sso) ---
      (if (($v | test("https?://[^/\\s]*(?:keycloak|sso)"; "i")) and ($v | test("[/]realms[/]"; "i") | not)) then
        (try ($v | capture("(?<url>https?://(?<host>[^:/\\s\"]*(?:keycloak|sso)[^:/\\s\"]*)(?::(?<port>[0-9]+))?)"; "i")) catch null) as $m |
        if $m then {type:"keycloak", subtype:null, key:$k, url:$m.url,
          properties:({
            host:$m.host, port:($m.port // null),
            realm:(sibling($entries; "realm") // ($v | inval("realm[=: ]+(?<v>[^\\s\"]+)"))),
            clientId:(sibling($entries; "client[._-]?id|resource") // ($v | inval("(?:client-id|resource)[=: ]+(?<v>[^\\s\"]+)")))
          } | clean_props)}
        else empty end
       else empty end),

      # --- Kafka (in-value bootstrap-servers) ---
      (if ($v | test("bootstrap[._-]?servers"; "i")) then
        (($v | inval("bootstrap[._-]?servers[=: ]+(?<v>[^\\s\"]+)")) // null) as $bs |
        if $bs then {type:"kafka", subtype:null, key:$k, url:$bs,
          properties:({
            bootstrapServers:$bs,
            topic:(sibling($entries; "topic") // ($v | inval("(?:^|[._-])topics?[=: ]+(?<v>[^\\s\"]+)"))),
            consumerGroup:(sibling($entries; "group[._-]?id|consumer[._-]?group") // ($v | inval("group[._-]?id[=: ]+(?<v>[^\\s\"]+)"))),
            securityProtocol:(sibling($entries; "security[._-]?protocol") // ($v | inval("(?:security[._-])?protocol[=: ]+(?<v>SASL_(?:SSL|PLAINTEXT)|PLAINTEXT|SSL)"))),
            saslMechanism:(sibling($entries; "sasl[._-]?mechanism") // ($v | inval("(?:sasl[._-])?mechanism[=: ]+(?<v>SCRAM-SHA-(?:256|512)|PLAIN|OAUTHBEARER|GSSAPI)"))),
            username:(sibling($entries; "(?:kafka|sasl)[._-]?user(?:name)?$") // ($v | inval("username[=]\"(?<v>[^\"]+)\"")) // ($v | inval("sasl[._-]?(?:jaas[._-]?)?username[=: ]+(?<v>[^\\s\"]+)")))
          } | clean_props)}
        else empty end
       else empty end),

      # --- Kafka (key-name based) ---
      (if (($k | ascii_downcase | test("kafka.*bootstrap|bootstrap.*server|kafka.*broker")) and ($v | test(":[0-9]+")) and ($v | test("jdbc:|https?:|mongo|redis|amqp"; "i") | not)) then
        {type:"kafka", subtype:null, key:$k, url:$v,
          properties:({
            bootstrapServers:($v | gsub("[\\s]+"; "")),
            topic:(sibling($entries; "topic")),
            consumerGroup:(sibling($entries; "group[._-]?id|consumer[._-]?group")),
            securityProtocol:(sibling($entries; "security[._-]?protocol")),
            saslMechanism:(sibling($entries; "sasl[._-]?mechanism")),
            username:(sibling($entries; "(?:kafka|sasl)[._-]?user(?:name)?$"))
          } | clean_props)}
       else empty end),

      # --- AMQP ---
      (if ($v | test("amqps?://"; "i")) then
        (try ($v | capture("(?<url>amqps?://(?:(?<user>[^:@\\s]+)?(?::[^@\\s]*)?@)?(?<host>[^:/\\s\"]+)(?::(?<port>[0-9]+))?)"; "i")) catch null) as $m |
        if $m then {type:"amqp", subtype:null, key:$k, url:$m.url,
          properties:({
            host:$m.host, port:($m.port // null), username:($m.user // null),
            queue:(sibling($entries; "queue|destination")),
            topic:(sibling($entries; "topic"))
          } | clean_props)}
        else empty end
       else empty end),

      # --- ActiveMQ (failover, tcp/ssl con activemq/artemis/61616) ---
      (if ($v | test("failover:\\("; "i")) or
          (($v | test("(?:tcp|ssl)://"; "i")) and
           (($v | test("activemq|artemis|:61616|:61617"; "i")) or ($k | ascii_downcase | test("activemq|artemis|broker|amq|jms"))))
       then
        (try ($v | capture("(?<url>(?:tcp|ssl)://(?<host>[^:/\\s,)\"]+)(?::(?<port>[0-9]+))?)"; "i")) catch null) as $m |
        if $m then {type:"activemq", subtype:null, key:$k, url:$m.url,
          properties:({
            host:$m.host, port:($m.port // null),
            queue:(sibling($entries; "queue|destination") // ($v | inval("(?:queue|destination)[=: ]+(?<v>[^\\s\"]+)")))
          } | clean_props)}
        else empty end
       else empty end),

      # --- Servizio interno (*.svc / *.svc.cluster.local) ---
      (if ($v | test("https?://[^/\\s]*\\.svc"; "i")) then
        (try ($v | capture("(?<url>https?://(?<host>[^:/\\s\"]+\\.svc[^:/\\s\"]*)(?::(?<port>[0-9]+))?(?<path>[/][^\\s\"]*)?)"; "i")) catch null) as $m |
        if $m then {type:"service", subtype:"internal", key:$k, url:$m.url,
          properties:({host:$m.host, port:($m.port // null), path:($m.path // null)} | clean_props)}
        else empty end
       else empty end)
    )
  ] | unique_by(.type + "/" + (.subtype // "") + "/" + .url) | sort_by(.type + "/" + (.subtype // ""));
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
    printf '%s' "$storage_json" | jq --argjson refs "$refs_json" \
        "${JQ_DETECT_DEPS}"'
        [.items[] | select(.kind == "Secret") |
            select(.type != "kubernetes.io/service-account-token"
               and .type != "kubernetes.io/dockercfg"
               and .type != "kubernetes.io/dockerconfigjson") |
            select(.metadata.name |
                (startswith("builder-") or startswith("deployer-") or startswith("default-")) | not) |
            (.data // {} | to_entries |
                map(. + {value: (try (.value | @base64d) catch .value)})) as $data_entries |
            {
                name: .metadata.name,
                type: (.type // "Opaque"),
                keys: ([.data // {} | keys[]] | sort),
                unbounded: ([ .metadata.name ] | inside($refs.secrets) | not),
                dependencies: ($data_entries | detect_deps)
            }
        ] | sort_by(.name)
    '
}

# ==========================================
# PARSING CONFIGMAP
# ==========================================
parse_configmaps() {
    local storage_json="$1" refs_json="$2"
    printf '%s' "$storage_json" | jq --argjson refs "$refs_json" \
        "${JQ_DETECT_DEPS}"'
        [.items[] | select(.kind == "ConfigMap") |
            select(.metadata.name != "kube-root-ca.crt"
               and .metadata.name != "openshift-service-ca.crt") |
            (.data // {} | to_entries) as $data_entries |
            {
                name: .metadata.name,
                keys: ([(.data // {} | keys[]), (.binaryData // {} | keys[])] | sort),
                unbounded: ([ .metadata.name ] | inside($refs.configmaps) | not),
                dependencies: ($data_entries | detect_deps)
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
                def covers($host):
                    if startswith("*.") then ($host | endswith(.[1:]))
                    else . == $host
                    end;
                ($ci.sans | map(select(covers($host)))) as $covering |
                ($covering | length > 0) as $match |
                (if $apps_domain != "" then
                    ($covering | any(contains($apps_domain)))
                 else false end) as $cluster_bound |
                (if $apps_domain != "" then
                    ($ci.sans | any(contains($apps_domain)))
                 else false end) as $has_cluster_san |
                . + {certInfo: ($ci + {certMatch: $match, clusterBound: $cluster_bound, hasClusterSan: $has_cluster_san})} | del(.certPEM)
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
                "\n        ports:       \(if ((.ports // []) | length) > 0 then [.ports[] | (if .name then "\(.name):" else "" end) + "\(.containerPort)/\(.protocol)"] | join(", ") else "N/A" end)" +
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
                    "\n        ports:       \(if ((.ports // []) | length) > 0 then [.ports[] | (if .name then "\(.name):" else "" end) + "\(.containerPort)/\(.protocol)"] | join(", ") else "N/A" end)" +
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
            def fmt_props:
                [to_entries[] | "\(.key): \(.value)"] | join("  ");
            def fmt_deps:
                if (.dependencies // [] | length) == 0 then ""
                else "\n      [deps]" + (.dependencies[] |
                    "\n        \(.type)\(if .subtype then "/\(.subtype)" else "" end) (key: \(.key))" +
                    "\n          \(.properties | fmt_props)")
                end;
            def detail:
                "    \(.name)" +
                "\n      type: \(.type)" +
                "\n      keys: \(if (.keys | length) > 0 then .keys | join(", ") else "(vuoto)" end)" +
                fmt_deps;
            (["BOUNDED", "UNBOUNDED"][]) as $group |
            "\n  [\($group)]",
            (map(select(if $group == "UNBOUNDED" then .unbounded else (.unbounded | not) end))
             | if length == 0 then "    (nessuno)" else (.[] | detail) end)
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
            def fmt_props:
                [to_entries[] | "\(.key): \(.value)"] | join("  ");
            def fmt_deps:
                if (.dependencies // [] | length) == 0 then ""
                else "\n      [deps]" + (.dependencies[] |
                    "\n        \(.type)\(if .subtype then "/\(.subtype)" else "" end) (key: \(.key))" +
                    "\n          \(.properties | fmt_props)")
                end;
            def detail:
                "    \(.name)" +
                "\n      keys: \(if (.keys | length) > 0 then .keys | join(", ") else "(vuoto)" end)" +
                fmt_deps;
            (["BOUNDED", "UNBOUNDED"][]) as $group |
            "\n  [\($group)]",
            (map(select(if $group == "UNBOUNDED" then .unbounded else (.unbounded | not) end))
             | if length == 0 then "    (nessuno)" else (.[] | detail) end)
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
            def detail:
                "    \(.name)" +
                "\n      capacity:     \(.capacity)" +
                "\n      accessModes:  \(.accessModes)" +
                "\n      storageClass: \(.storageClass)";
            (["BOUNDED", "UNBOUNDED"][]) as $group |
            "\n  [\($group)]",
            (map(select(if $group == "UNBOUNDED" then .unbounded else (.unbounded | not) end))
             | if length == 0 then "    (nessuno)" else (.[] | detail) end)
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
                "\n    cert legato al cluster: \(if .certInfo.clusterBound then "SI - l'\''hostname di questa route e'\'' coperto da un nome del dominio cluster" else "no" end)" +
                "\n    SAN del cluster sorgente: \(if .certInfo.hasClusterSan then "yes" else "no" end)"
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
        --arg apps_domain "$SRC_APPS_DOMAIN" \
        '{
            context: $context,
            namespace: $namespace,
            summary: {
                totals: {
                    workloads: ($workloads | length),
                    secrets: ($secrets | length),
                    configmaps: ($configmaps | length),
                    pvcs: ($pvcs | length),
                    services: ($services | length),
                    routes: ($routes | length)
                },
                unbounded: {
                    secrets: ([$secrets[] | select(.unbounded)] | length),
                    configmaps: ([$configmaps[] | select(.unbounded)] | length),
                    pvcs: ([$pvcs[] | select(.unbounded)] | length)
                },
                warnings: (
                    [
                        ([$routes[] | select(.hostClusterBound == true)] |
                            if length > 0 then {
                                type: "hostClusterBound",
                                message: "\(length) route con hostname legato al cluster sorgente (dominio: \($apps_domain))",
                                detail: "L hostname cambiera dopo la migrazione. Aggiornare DNS o configurare hostname personalizzati.",
                                routes: [.[] | {name: .name, host: .host}]
                            } else empty end),
                        ([$routes[] | select(.certInfo.clusterBound == true)] |
                            if length > 0 then {
                                type: "certClusterBound",
                                message: "\(length) route il cui hostname e coperto da certificato legato al dominio cluster \($apps_domain)",
                                detail: "Se l hostname cambiera in migrazione, quel certificato non coprira il nuovo nome. Azione richiesta: rigenerare i certificati.",
                                routes: [.[] | {name: .name, host: .host, sans: .certInfo.sans}]
                            } else empty end),
                        ([$routes[] | select(.certInfo.hasClusterSan == true and (.certInfo.clusterBound | not))] |
                            if length > 0 then {
                                type: "hasClusterSan",
                                message: "\(length) route con SAN del certificato che riferiscono al dominio cluster \($apps_domain), ma l hostname non e direttamente legato",
                                detail: "Il certificato contiene SAN legati al cluster sorgente, anche se l hostname di questa route non e tra quelli.",
                                routes: [.[] | {name: .name, host: .host, sans: .certInfo.sans}]
                            } else empty end),
                        ([$routes[] | select(.certInfo.certMatch == false)] |
                            if length > 0 then {
                                type: "certMismatch",
                                message: "\(length) route il cui certificato NON copre l hostname della route",
                                detail: "Il certificato non e valido per l hostname attuale della route.",
                                routes: [.[] | {name: .name, host: .host, sans: .certInfo.sans}]
                            } else empty end)
                    ]
                ),
                dependencies: (
                    [
                        ($secrets[] | .name as $n | (.dependencies // [])[] | . + {source: {kind: "Secret", name: $n}}),
                        ($configmaps[] | .name as $n | (.dependencies // [])[] | . + {source: {kind: "ConfigMap", name: $n}})
                    ]
                    | group_by(.type + "/" + (.subtype // ""))
                    | map({
                        type: .[0].type,
                        subtype: .[0].subtype,
                        sources: [.[] | {kind: .source.kind, name: .source.name, key: .key}] | unique,
                        properties: (map(.properties) | add // {}),
                        urls: [.[].url] | unique
                    })
                )
            },
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
# SCANSIONE SINGOLO NAMESPACE
# ==========================================
scan_one_namespace() {
    local ns="$1"
    NAMESPACE="$ns"

    echo "============================================================"
    echo "Scansione namespace: $NAMESPACE"
    echo "  Context: $CONTEXT"
    echo "============================================================"
    echo ""

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

    local wl_count sec_count cm_count pvc_count svc_count rt_count
    wl_count=$(printf '%s' "$WORKLOADS_JSON" | jq 'length')
    sec_count=$(printf '%s' "$SECRETS_JSON" | jq 'length')
    cm_count=$(printf '%s' "$CONFIGMAPS_JSON" | jq 'length')
    pvc_count=$(printf '%s' "$PVCS_JSON" | jq 'length')
    svc_count=$(printf '%s' "$SERVICES_JSON" | jq 'length')
    rt_count=$(printf '%s' "$ROUTES_JSON" | jq 'length')

    if [[ $((wl_count + sec_count + cm_count + pvc_count + svc_count + rt_count)) -eq 0 ]]; then
        echo "⚠ Namespace '$NAMESPACE' non contiene risorse da riportare: escluso dal report."
        echo "============================================================"
        return 0
    fi

    print_text_report "$WORKLOADS_JSON" "$SECRETS_JSON" "$CONFIGMAPS_JSON" "$PVCS_JSON" "$SERVICES_JSON" "$ROUTES_JSON"

    # Summary per namespace
    echo ""
    echo "============================================================"
    echo "Totale [$NAMESPACE]: ${wl_count} workload, ${sec_count} secret, ${cm_count} configmap, ${pvc_count} PVC, ${svc_count} service, ${rt_count} route"
    local sec_unb cm_unb pvc_unb
    sec_unb=$(printf '%s' "$SECRETS_JSON" | jq '[.[] | select(.unbounded)] | length')
    cm_unb=$(printf '%s' "$CONFIGMAPS_JSON" | jq '[.[] | select(.unbounded)] | length')
    pvc_unb=$(printf '%s' "$PVCS_JSON" | jq '[.[] | select(.unbounded)] | length')
    if [[ "$sec_unb" -gt 0 || "$cm_unb" -gt 0 || "$pvc_unb" -gt 0 ]]; then
        echo "Unbounded: ${sec_unb} secret, ${cm_unb} configmap, ${pvc_unb} PVC"
    fi
    local rt_host_bound rt_cert_bound
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
        echo "⚠ ${rt_cert_bound} route il cui hostname coperto da certificato legato al dominio cluster"
        echo "  Dominio: ${SRC_APPS_DOMAIN}"
        echo "  Il controllo considera solo il nome della route, non gli altri SAN del certificato."
        echo "  Se l'hostname cambiera in migrazione, quel certificato non coprira il nuovo nome."
        echo "  Route interessate:"
        printf '%s' "$ROUTES_JSON" | jq -r '
            [.[] | select(.certInfo.clusterBound == true)] | .[] |
            "    - \(.name) (host: \(.host), SANs: \(.certInfo.sans | join(", ")))"
        '
        echo "  Azione richiesta: rigenerare i certificati per il dominio del cluster destinazione."
    fi

    # Dipendenze rilevate
    local all_deps
    all_deps=$(printf '%s\n%s' "$SECRETS_JSON" "$CONFIGMAPS_JSON" | jq -s '
        [ (.[0] // [])[] | .name as $n | (.dependencies // [])[] | . + {source: ("Secret/" + $n)} ] +
        [ (.[1] // [])[] | .name as $n | (.dependencies // [])[] | . + {source: ("ConfigMap/" + $n)} ]
        | group_by(.type + "/" + (.subtype // ""))
    ')
    local dep_count
    dep_count=$(printf '%s' "$all_deps" | jq 'length')
    if [[ "$dep_count" -gt 0 ]]; then
        echo ""
        echo "Dipendenze rilevate:"
        printf '%s' "$all_deps" | jq -r '
            .[] | .[0] as $first |
            "  \($first.type)\(if $first.subtype then "/\($first.subtype)" else "" end)" +
            "  ->  " + ([.[].url] | unique | join(", ")) +
            "\n    " + ([.[].properties | to_entries[] | "\(.key): \(.value)"] | unique | join("  ")) +
            "\n    fonte: " + ([.[] | "\(.source) (key: \(.key))"] | unique | join(", "))
        '
    fi
    echo "============================================================"

    # Build structured report for this namespace
    NS_REPORT_JSON=$(build_structured_report "$WORKLOADS_JSON" "$SECRETS_JSON" "$CONFIGMAPS_JSON" "$PVCS_JSON" "$SERVICES_JSON" "$ROUTES_JSON")
    ALL_REPORTS_JSON=$(printf '%s\n%s' "$ALL_REPORTS_JSON" "$NS_REPORT_JSON" | jq -s '.[0] + [.[1]]')
}

# ==========================================
# PARSING ARGOMENTI
# ==========================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -s)  CONTEXT="$2"; shift 2 ;;
        -o)  OUTPUT_FILE="$2"; shift 2 ;;
        -v)  DEBUG="true"; shift ;;
        -h)  usage ;;
        --)  shift; break ;;
        -*)  echo "Opzione sconosciuta: $1" >&2; usage ;;
        *)   break ;;
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

# Raccogli namespace da argomenti posizionali
NAMESPACES=()
if [[ $# -eq 0 ]]; then
    resolve_namespace
    NAMESPACES=("$NAMESPACE")
    echo "Namespace non specificato: uso '$NAMESPACE' (progetto corrente di $CONTEXT)"
else
    for ns in "$@"; do
        duplicate=false
        if [[ ${#NAMESPACES[@]} -gt 0 ]]; then
            for existing in "${NAMESPACES[@]}"; do
                if [[ "$existing" == "$ns" ]]; then
                    duplicate=true
                    break
                fi
            done
        fi
        if $duplicate; then
            echo "⚠ Namespace '$ns' duplicato, ignorato." >&2
        else
            NAMESPACES+=("$ns")
        fi
    done
fi

if ! oc --context "$CONTEXT" whoami &>/dev/null; then
    echo "Errore: impossibile connettersi al cluster (context: $CONTEXT)." >&2
    exit 1
fi
echo "✔ Connesso come '$(oc --context "$CONTEXT" whoami)'"
echo ""

ALL_REPORTS_JSON="[]"

for ns in "${NAMESPACES[@]}"; do
    if ! oc --context "$CONTEXT" get namespace "$ns" &>/dev/null; then
        echo "============================================================"
        echo "⚠ Namespace '$ns' non trovato sul cluster (context: $CONTEXT): escluso dal report."
        echo "============================================================"
        echo ""
        continue
    fi
    scan_one_namespace "$ns"
    echo ""
done

if [[ -n "$OUTPUT_FILE" ]]; then
    write_output_file "$ALL_REPORTS_JSON" "$OUTPUT_FILE"
fi

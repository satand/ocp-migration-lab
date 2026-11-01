#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIGURAZIONE DI DEFAULT
# (Puoi sovrascriverli via variabili d'ambiente)
# ==========================================
SRC_CONTEXT="${SRC_CONTEXT:-}"
DST_CONTEXT="${DST_CONTEXT:-}"
DEBUG="${DEBUG:-false}"

# Immagine usata per i pod temporanei di copia dati
RSYNC_POD_IMAGE="${RSYNC_POD_IMAGE:-registry.access.redhat.com/ubi9/ubi-minimal:latest}"

# Risorse temporanee da ripulire all'uscita
CLEANUP_ITEMS=()
TEMP_DIR=""

# ==========================================
# FUNZIONI
# ==========================================
usage() {
    cat <<EOF
Uso: $0 [OPZIONI] <pvc-name>

Migra un PersistentVolumeClaim da un cluster OpenShift sorgente a uno destinazione.
Nome, namespace, dimensioni, access mode, label e annotazioni non cluster-specifiche
vengono preservati. La StorageClass di destinazione viene risolta in questo ordine:
override esplicito (-c), mapping file (-m), stessa SC del sorgente. Se la SC
scelta non esiste sul cluster destinazione, lo script chiede quale usare
(oppure termina con errore se è attivo -y).

Opzioni:
  -s <context>    Context oc/kubectl del cluster sorgente (obbligatorio)
  -d <context>    Context oc/kubectl del cluster destinazione (obbligatorio)
  -n <namespace>  Namespace del PVC
                  (default: progetto corrente del context sorgente)
  -c <sc>         StorageClass da usare sul cluster destinazione
                  (ha precedenza sul mapping e sulla SC del sorgente)
  -m <file>       File di mapping StorageClass (formato: sc-sorgente=sc-destinazione)
  -C              Copia anche il contenuto (dati) del PVC tramite pod temporanei
  -y              Salta la conferma interattiva
  -v              Modalità debug
  -h              Mostra questo messaggio di aiuto

Variabili d'ambiente:
  SRC_CONTEXT       Alternativa a -s
  DST_CONTEXT       Alternativa a -d
  RSYNC_POD_IMAGE   Immagine per i pod temporanei di copia dati
                    (default: registry.access.redhat.com/ubi9/ubi-minimal:latest)

Esempi:
  # Migra solo la definizione del PVC (namespace = progetto corrente del context sorgente)
  $0 -s cluster-a -d cluster-b my-pvc

  # Namespace esplicito
  $0 -s cluster-a -d cluster-b -n my-project my-pvc

  # Migra con copia dati e StorageClass diversa sul destinazione
  $0 -s cluster-a -d cluster-b -n my-project -c managed-nfs-storage -C my-pvc

  # Mapping StorageClass per migrazioni batch (una coppia per riga: sorgente=destinazione)
  $0 -s cluster-a -d cluster-b -n my-project -m mapping-sc.txt -y my-pvc

  # Senza conferma interattiva (per scripting)
  $0 -s cluster-a -d cluster-b -n my-project -y my-pvc
EOF
    exit 1
}

debug() {
    [[ "$DEBUG" == "true" ]] && echo "[DEBUG] $*" >&2
    return 0
}

cleanup() {
    local exit_code=$?

    for item in "${CLEANUP_ITEMS[@]:-}"; do
        [[ -z "$item" ]] && continue
        IFS='|' read -r type context namespace name <<< "$item"
        case "$type" in
            pod)
                echo "Pulizia: elimino pod temporaneo '$name' (context: $context, ns: $namespace)" >&2
                oc --context "$context" -n "$namespace" delete pod "$name" \
                    --grace-period=0 --force 2>/dev/null || true
                ;;
        esac
    done

    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        debug "Pulizia: rimuovo directory temporanea $TEMP_DIR"
        rm -rf "$TEMP_DIR"
    fi

    return "$exit_code"
}

trap cleanup EXIT

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

# Imposta PVC_NAMESPACE al progetto corrente del context sorgente.
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
    PVC_NAMESPACE="$ns"
}

# Cerca nel mapping file la SC di destinazione corrispondente a src_sc.
# Formato riga: sc-sorgente=sc-destinazione. Righe vuote e commenti (#) ignorati.
# Stampa la SC di destinazione, oppure stringa vuota se non c'è corrispondenza.
load_sc_mapping() {
    local mapping_file="$1" src_sc="$2"
    local line key value

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        [[ "$line" != *=* ]] && continue

        key="${line%%=*}"
        value="${line#*=}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [[ "$key" == "$src_sc" ]]; then
            echo "$value"
            return 0
        fi
    done < "$mapping_file"

    echo ""
}

# Elenca le StorageClass del cluster: una riga "nome|true" oppure "nome|false".
list_storage_classes() {
    local context="$1"
    oc --context "$context" get sc -o json | jq -r '
        .items[]
        | .metadata.name as $name
        | (
            .metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true"
            or .metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true"
          ) as $is_default
        | "\($name)|\(if $is_default then "true" else "false" end)"
    '
}

print_storage_classes() {
    local prefix="$1"
    shift
    local line name is_default
    for line in "$@"; do
        IFS='|' read -r name is_default <<< "$line"
        if [[ "$is_default" == "true" ]]; then
            echo "${prefix}${name} (default)" >&2
        else
            echo "${prefix}${name}" >&2
        fi
    done
}

# Risolve la StorageClass di destinazione e la scrive in RESOLVED_SC.
# Priorità: override -c, mapping -m, SC originale del PVC.
# Se la SC non esiste sul destinazione, chiede all'utente (o esce se -y / non interattivo).
resolve_storage_class() {
    local dst_context="$1" src_sc="$2" dst_sc_override="$3" mapping_file="$4"
    local candidate="" mapped=""

    if [[ -n "$dst_sc_override" ]]; then
        candidate="$dst_sc_override"
        echo "StorageClass: override esplicito '$candidate'"
    elif [[ -n "$mapping_file" && -n "$src_sc" ]]; then
        mapped=$(load_sc_mapping "$mapping_file" "$src_sc")
        if [[ -n "$mapped" ]]; then
            candidate="$mapped"
            echo "StorageClass: mapping '$src_sc' -> '$candidate'"
        fi
    fi

    if [[ -z "$candidate" ]]; then
        if [[ -n "$src_sc" ]]; then
            candidate="$src_sc"
            echo "StorageClass: stessa del sorgente '$candidate'"
        else
            echo "StorageClass: non specificata sul PVC, verrà usata la default del cluster destinazione"
            RESOLVED_SC=""
            return 0
        fi
    fi

    debug "Verifico esistenza della StorageClass '$candidate' su $dst_context"
    if oc --context "$dst_context" get sc "$candidate" -o name &>/dev/null; then
        RESOLVED_SC="$candidate"
        return 0
    fi

    local sc_out=""
    if ! sc_out=$(list_storage_classes "$dst_context"); then
        echo "Errore: impossibile elencare le StorageClass sul cluster destinazione." >&2
        exit 1
    fi

    local sc_lines=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && sc_lines+=("$line")
    done <<< "$sc_out"

    echo "La StorageClass '$candidate' non esiste sul cluster destinazione." >&2

    if [[ ${#sc_lines[@]} -eq 0 ]]; then
        echo "Errore: non ci sono StorageClass disponibili sul cluster destinazione." >&2
        exit 1
    fi

    if [[ "$SKIP_CONFIRM" == "true" || ! -t 0 ]]; then
        echo "Errore: impossibile procedere senza una StorageClass valida." >&2
        echo "StorageClass disponibili:" >&2
        print_storage_classes "  - " "${sc_lines[@]}"
        exit 1
    fi

    echo "StorageClass disponibili:" >&2
    local i=1
    local names=()
    local name is_default
    for line in "${sc_lines[@]}"; do
        IFS='|' read -r name is_default <<< "$line"
        names+=("$name")
        if [[ "$is_default" == "true" ]]; then
            echo "  ${i}) ${name} (default)" >&2
        else
            echo "  ${i}) ${name}" >&2
        fi
        ((i++))
    done

    local choice
    while true; do
        read -rp "Seleziona [1-${#names[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )); then
            RESOLVED_SC="${names[$((choice - 1))]}"
            echo "StorageClass selezionata: $RESOLVED_SC"
            return 0
        fi
        echo "Selezione non valida." >&2
    done
}

# Annotazioni specifiche del cluster sorgente da rimuovere
CLUSTER_ANNOTATIONS=(
    "pv.kubernetes.io/bind-completed"
    "pv.kubernetes.io/bound-by-controller"
    "volume.beta.kubernetes.io/storage-provisioner"
    "volume.kubernetes.io/storage-provisioner"
    "volume.kubernetes.io/selected-node"
    "kubectl.kubernetes.io/last-applied-configuration"
)

export_and_clean_pvc() {
    local context="$1" namespace="$2" pvc_name="$3"

    debug "Esporto PVC '$pvc_name' da namespace '$namespace' (context: $context)"

    local pvc_json
    if ! pvc_json=$(oc --context "$context" -n "$namespace" get pvc "$pvc_name" -o json 2>/dev/null); then
        echo "Errore: PVC '$pvc_name' non trovato nel namespace '$namespace' sul cluster sorgente." >&2
        exit 1
    fi

    echo "$pvc_json" | jq '
        del(
            .metadata.uid,
            .metadata.resourceVersion,
            .metadata.creationTimestamp,
            .metadata.selfLink,
            .metadata.managedFields,
            .metadata.generation,
            .metadata.ownerReferences,
            .metadata.finalizers,
            .metadata.annotations["pv.kubernetes.io/bind-completed"],
            .metadata.annotations["pv.kubernetes.io/bound-by-controller"],
            .metadata.annotations["volume.beta.kubernetes.io/storage-provisioner"],
            .metadata.annotations["volume.kubernetes.io/storage-provisioner"],
            .metadata.annotations["volume.kubernetes.io/selected-node"],
            .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"],
            .spec.volumeName,
            .status
        )
        | if (.metadata.annotations // {} | length) == 0 then del(.metadata.annotations) else . end
    '
}

check_pvc_in_use() {
    local context="$1" namespace="$2" pvc_name="$3"
    local pods
    pods=$(oc --context "$context" -n "$namespace" get pods -o json 2>/dev/null | \
        jq -r --arg pvc "$pvc_name" '
            .items[]
            | select(.status.phase != "Succeeded" and .status.phase != "Failed")
            | select(.spec.volumes[]? .persistentVolumeClaim.claimName == $pvc)
            | .metadata.name
        ' 2>/dev/null) || true

    if [[ -n "$pods" ]]; then
        echo "" >&2
        echo "⚠ Attenzione: il PVC '$pvc_name' è montato da pod attivi:" >&2
        echo "$pods" | sed 's/^/    /' >&2
        echo "  Se il PVC è RWO, i pod temporanei di copia dati potrebbero non avviarsi." >&2
        echo "  Considera di scalare a zero i deployment che lo usano." >&2
        echo "" >&2
        return 1
    fi
    return 0
}

wait_for_pod() {
    local context="$1" namespace="$2" pod_name="$3" timeout="${4:-180}"
    echo "  Attendo che il pod '$pod_name' sia pronto (timeout: ${timeout}s)..." >&2
    if ! oc --context "$context" -n "$namespace" wait pod/"$pod_name" \
        --for=condition=Ready --timeout="${timeout}s" 2>/dev/null; then
        echo "Errore: il pod '$pod_name' non è diventato Ready entro ${timeout}s." >&2
        echo "Verifica con: oc --context $context -n $namespace describe pod $pod_name" >&2
        return 1
    fi
}

create_temp_pod() {
    local context="$1" namespace="$2" pvc_name="$3" pod_suffix="$4"

    local safe_name
    safe_name=$(echo "$pvc_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    local pod_name="migrate-${pod_suffix}-${safe_name}"
    pod_name="${pod_name:0:63}"

    debug "Creo pod temporaneo '$pod_name' (context: $context, ns: $namespace, image: $RSYNC_POD_IMAGE)"

    cat <<EOF | oc --context "$context" -n "$namespace" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ${pod_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/managed-by: migrate-pvc
spec:
  containers:
  - name: data
    image: ${RSYNC_POD_IMAGE}
    command: ["sleep", "infinity"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: ${pvc_name}
  restartPolicy: Never
EOF

    CLEANUP_ITEMS+=("pod|${context}|${namespace}|${pod_name}")
    wait_for_pod "$context" "$namespace" "$pod_name"

    echo "$pod_name"
}

copy_pvc_data() {
    local src_context="$1" dst_context="$2" namespace="$3" pvc_name="$4"

    TEMP_DIR=$(mktemp -d "/tmp/migrate-pvc-XXXXXX")
    debug "Directory temporanea per i dati: $TEMP_DIR"

    echo ""
    echo "--- Fase 1/4: Creo pod temporaneo sul cluster sorgente ---"
    local src_pod
    src_pod=$(create_temp_pod "$src_context" "$namespace" "$pvc_name" "src")
    echo "  ✔ Pod sorgente pronto: $src_pod" >&2

    echo ""  >&2
    echo "--- Fase 2/4: Copio dati dal cluster sorgente al bastion ---" >&2
    debug "oc --context $src_context -n $namespace rsync ${src_pod}:/data/ $TEMP_DIR/"
    oc --context "$src_context" -n "$namespace" rsync "${src_pod}:/data/" "${TEMP_DIR}/"
    local data_size
    data_size=$(du -sh "$TEMP_DIR" 2>/dev/null | cut -f1)
    echo "  ✔ Dati scaricati sul bastion ($data_size)" >&2

    echo "" >&2
    echo "--- Fase 3/4: Creo pod temporaneo sul cluster destinazione ---" >&2
    local dst_pod
    dst_pod=$(create_temp_pod "$dst_context" "$namespace" "$pvc_name" "dst")
    echo "  ✔ Pod destinazione pronto: $dst_pod" >&2

    echo "" >&2
    echo "--- Fase 4/4: Carico dati sul cluster destinazione ---" >&2
    debug "oc --context $dst_context -n $namespace rsync $TEMP_DIR/ ${dst_pod}:/data/"
    oc --context "$dst_context" -n "$namespace" rsync "${TEMP_DIR}/" "${dst_pod}:/data/"
    echo "  ✔ Dati trasferiti al cluster destinazione" >&2
}

# ==========================================
# PARSING ARGOMENTI
# ==========================================
PVC_NAMESPACE=""
DST_SC=""
SC_MAPPING_FILE=""
COPY_DATA=false
SKIP_CONFIRM=false

while getopts "s:d:n:c:m:Cvyh" opt; do
    case "$opt" in
        s) SRC_CONTEXT="$OPTARG" ;;
        d) DST_CONTEXT="$OPTARG" ;;
        n) PVC_NAMESPACE="$OPTARG" ;;
        c) DST_SC="$OPTARG" ;;
        m) SC_MAPPING_FILE="$OPTARG" ;;
        C) COPY_DATA=true ;;
        v) DEBUG="true" ;;
        y) SKIP_CONFIRM=true ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

PVC_NAME="${1:-}"

# Validazione parametri obbligatori
missing=()
[[ -z "$SRC_CONTEXT" ]] && missing+=("context sorgente (-s)")
[[ -z "$DST_CONTEXT" ]] && missing+=("context destinazione (-d)")
[[ -z "$PVC_NAME" ]] && missing+=("nome PVC (argomento posizionale)")

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Errore: parametri mancanti:" >&2
    for m in "${missing[@]}"; do
        echo "  - $m" >&2
    done
    echo "" >&2
    usage
fi

if [[ -n "$SC_MAPPING_FILE" && ! -f "$SC_MAPPING_FILE" ]]; then
    echo "Errore: file di mapping '$SC_MAPPING_FILE' non trovato." >&2
    exit 1
fi

# ==========================================
# ESECUZIONE
# ==========================================
check_dependencies

if [[ -z "$PVC_NAMESPACE" ]]; then
    resolve_namespace "$SRC_CONTEXT"
    echo "Namespace non specificato: uso '$PVC_NAMESPACE' (progetto corrente di $SRC_CONTEXT)"
fi

echo "============================================================"
echo "Migrazione PVC: $PVC_NAME"
echo "  Namespace:      $PVC_NAMESPACE"
echo "  Sorgente:       $SRC_CONTEXT"
echo "  Destinazione:   $DST_CONTEXT"
[[ -n "$DST_SC" ]] && echo "  StorageClass:   $DST_SC (override)"
[[ -n "$SC_MAPPING_FILE" ]] && echo "  Mapping SC:     $SC_MAPPING_FILE"
[[ "$COPY_DATA" == "true" ]] && echo "  Copia dati:     SÌ"
echo "============================================================"
echo ""

check_cluster_access "$SRC_CONTEXT" "sorgente"
check_cluster_access "$DST_CONTEXT" "destinazione"

# Verifica che il namespace esista sul cluster destinazione
if ! oc --context "$DST_CONTEXT" get namespace "$PVC_NAMESPACE" &>/dev/null; then
    echo "Errore: il namespace '$PVC_NAMESPACE' non esiste sul cluster destinazione ($DST_CONTEXT)." >&2
    echo "Crealo con: oc --context $DST_CONTEXT new-project $PVC_NAMESPACE" >&2
    exit 1
fi
echo "✔ Namespace '$PVC_NAMESPACE' presente su entrambi i cluster"

# Verifica che il PVC non esista già sul destinazione
if oc --context "$DST_CONTEXT" -n "$PVC_NAMESPACE" get pvc "$PVC_NAME" &>/dev/null; then
    echo "Errore: il PVC '$PVC_NAME' esiste già nel namespace '$PVC_NAMESPACE' sul cluster destinazione." >&2
    exit 1
fi

# Esporta e pulisci il PVC
echo ""
echo "Esporto PVC dal cluster sorgente..."
CLEAN_PVC=$(export_and_clean_pvc "$SRC_CONTEXT" "$PVC_NAMESPACE" "$PVC_NAME")

SRC_SC=$(echo "$CLEAN_PVC" | jq -r '.spec.storageClassName // empty')
RESOLVED_SC=""
resolve_storage_class "$DST_CONTEXT" "$SRC_SC" "$DST_SC" "$SC_MAPPING_FILE"

if [[ -n "$RESOLVED_SC" ]]; then
    CLEAN_PVC=$(echo "$CLEAN_PVC" | jq --arg sc "$RESOLVED_SC" '.spec.storageClassName = $sc')
else
    CLEAN_PVC=$(echo "$CLEAN_PVC" | jq 'del(.spec.storageClassName)')
fi

# Estrai info per il riepilogo
PVC_SC=$(echo "$CLEAN_PVC" | jq -r '.spec.storageClassName // "(default)"')
PVC_SIZE=$(echo "$CLEAN_PVC" | jq -r '.spec.resources.requests.storage // "N/A"')
PVC_ACCESS=$(echo "$CLEAN_PVC" | jq -r '.spec.accessModes | join(", ")')
PVC_LABELS=$(echo "$CLEAN_PVC" | jq -r '
    if (.metadata.labels // {} | length) > 0
    then [.metadata.labels | to_entries[] | "\(.key)=\(.value)"] | join(", ")
    else "(nessuna)"
    end
')

echo ""
echo "PVC da creare sul cluster destinazione:"
echo "  Nome:            $PVC_NAME"
echo "  Namespace:       $PVC_NAMESPACE"
echo "  StorageClass:    $PVC_SC"
echo "  Dimensione:      $PVC_SIZE"
echo "  Access Modes:    $PVC_ACCESS"
echo "  Labels:          $PVC_LABELS"
echo ""

if [[ "$DEBUG" == "true" ]]; then
    echo "[DEBUG] Definizione PVC pulita:" >&2
    echo "$CLEAN_PVC" | jq . >&2
    echo "" >&2
fi

# Conferma interattiva
if [[ "$SKIP_CONFIRM" != "true" ]]; then
    read -rp "Procedere con la migrazione? [s/N] " confirm
    if [[ ! "$confirm" =~ ^[sySY]$ ]]; then
        echo "Operazione annullata."
        exit 0
    fi
fi

# Crea il PVC sul cluster destinazione
echo ""
echo "Creo PVC sul cluster destinazione..."
echo "$CLEAN_PVC" | oc --context "$DST_CONTEXT" -n "$PVC_NAMESPACE" apply -f - >/dev/null
echo "✔ PVC '$PVC_NAME' creato sul cluster destinazione"

# Copia dati (opzionale)
if [[ "$COPY_DATA" == "true" ]]; then
    echo ""
    echo "============================================================"
    echo "Avvio copia dati"
    echo "============================================================"

    if ! check_pvc_in_use "$SRC_CONTEXT" "$PVC_NAMESPACE" "$PVC_NAME"; then
        if [[ "$SKIP_CONFIRM" != "true" ]]; then
            read -rp "Continuare comunque? [s/N] " confirm
            if [[ ! "$confirm" =~ ^[sySY]$ ]]; then
                echo "Operazione annullata. Il PVC è stato creato ma i dati non sono stati copiati."
                exit 0
            fi
        fi
    fi

    copy_pvc_data "$SRC_CONTEXT" "$DST_CONTEXT" "$PVC_NAMESPACE" "$PVC_NAME"
fi

# Riepilogo finale
echo ""
echo "============================================================"
echo "✔ Migrazione completata con successo!"
echo "  PVC '$PVC_NAME' disponibile su $DST_CONTEXT (ns: $PVC_NAMESPACE)"
[[ "$COPY_DATA" == "true" ]] && echo "  Dati copiati: SÌ"
echo "============================================================"

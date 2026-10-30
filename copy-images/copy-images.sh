#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIGURAZIONE DI DEFAULT
# (Puoi sovrascriverli via variabili d'ambiente)
# ==========================================
SRC_REGISTRY="${SRC_REGISTRY:-default-route-openshift-image-registry.apps.cluster-a.example.com}"
DST_REGISTRY="${DST_REGISTRY:-default-route-openshift-image-registry.apps.cluster-b.example.com}"

# Token di autenticazione OpenShift (Bearer Token)
SRC_TOKEN="${SRC_TOKEN:-}"
DST_TOKEN="${DST_TOKEN:-}"

# Imposta a true se i cluster usano certificati autofirmati o CA interne non presenti nel trust store del bastion
TLS_VERIFY="${TLS_VERIFY:-false}"

# ==========================================
# FUNZIONI
# ==========================================
usage() {
    cat <<EOF
Uso: $0 [OPZIONI] [IMMAGINE ...]

Passa le immagini da copiare direttamente come argomenti, oppure via stdin o file.

Opzioni:
  -f <file>       Leggi la lista di immagini da un file (una per riga, righe vuote e # ignorate)
  -s <registry>   Host/Route del registry sorgente (default: $SRC_REGISTRY)
  -d <registry>   Host/Route del registry destinazione (default: $DST_REGISTRY)
  -k              Disabilita la verifica TLS/SSL (default: $TLS_VERIFY)
  -h              Mostra questo messaggio di aiuto

Esempi:
  # Una o più immagini direttamente sulla riga di comando
  $0 my-project/my-app:v1.0.0
  $0 my-project/app-a:v1 my-project/app-b:latest my-project/app-c:v2

  # Da un file (retrocompatibile)
  $0 -f immagini.txt

  # Via pipe / stdin
  echo "my-project/my-app:v1.0.0" | $0
  oc get is -n my-project -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{..tag}{"\n"}{end}' | $0

  # Con token espliciti
  SRC_TOKEN="\$(oc --context cluster-a whoami -t)" \\
  DST_TOKEN="\$(oc --context cluster-b whoami -t)" \\
    $0 my-project/my-app:v1.0.0
EOF
    exit 1
}

check_dependencies() {
    if ! command -v skopeo &> /dev/null; then
        echo "Errore: 'skopeo' non è installato sul bastion." >&2
        echo "Installalo con: sudo dnf install -y skopeo (su RHEL/CentOS/Fedora) o sudo apt install -y skopeo" >&2
        exit 1
    fi
}

copy_image() {
    local img_path="$1"

    # Rimuove eventuali prefissi di registry se presenti per standardizzare
    img_path="${img_path#$SRC_REGISTRY/}"
    img_path="${img_path#docker://}"

    local src_url="docker://${SRC_REGISTRY}/${img_path}"
    local dst_url="docker://${DST_REGISTRY}/${img_path}"

    echo "------------------------------------------------------------"
    echo "Sorgente:     ${src_url}"
    echo "Destinazione: ${dst_url}"
    echo "------------------------------------------------------------"

    local extra_args=()
    if [[ "$TLS_VERIFY" == "false" ]]; then
        extra_args+=("--src-tls-verify=false" "--dest-tls-verify=false")
    fi

    if [[ -n "$SRC_TOKEN" ]]; then
        extra_args+=("--src-creds=unused:${SRC_TOKEN}")
    fi

    if [[ -n "$DST_TOKEN" ]]; then
        extra_args+=("--dest-creds=unused:${DST_TOKEN}")
    fi

    if skopeo copy "${extra_args[@]}" "${src_url}" "${dst_url}"; then
        echo "✔ Copia completata: ${img_path}"
        return 0
    else
        echo "✘ Errore durante la copia di: ${img_path}" >&2
        return 1
    fi
}

process_line() {
    local line="$1"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" =~ ^# ]] && return 0

    if copy_image "$line"; then
        (( ok_count++ ))
    else
        (( err_count++ ))
        failed_images+=("$line")
    fi
}

# ==========================================
# PARSING ARGOMENTI
# ==========================================
IMAGE_LIST_FILE=""

while getopts "f:s:d:kh" opt; do
    case "$opt" in
        f) IMAGE_LIST_FILE="$OPTARG" ;;
        s) SRC_REGISTRY="$OPTARG" ;;
        d) DST_REGISTRY="$OPTARG" ;;
        k) TLS_VERIFY="false" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

check_dependencies

# Raccogli le immagini da tutte le sorgenti disponibili
IMAGES=()

# 1. Argomenti posizionali sulla riga di comando
IMAGES+=("$@")

# 2. File con lista (opzione -f)
if [[ -n "$IMAGE_LIST_FILE" ]]; then
    if [[ ! -f "$IMAGE_LIST_FILE" ]]; then
        echo "Errore: file '$IMAGE_LIST_FILE' non trovato." >&2
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        IMAGES+=("$line")
    done < "$IMAGE_LIST_FILE"
fi

# 3. Stdin (se è una pipe e non sono stati forniti altri input)
if [[ ${#IMAGES[@]} -eq 0 ]] && [[ ! -t 0 ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        IMAGES+=("$line")
    done
fi

# Verifica che ci sia almeno un'immagine da copiare
if [[ ${#IMAGES[@]} -eq 0 ]]; then
    echo "Errore: nessuna immagine specificata." >&2
    echo ""
    usage
fi

# ==========================================
# ESECUZIONE
# ==========================================
ok_count=0
err_count=0
failed_images=()

for entry in "${IMAGES[@]}"; do
    process_line "$entry"
done

# ==========================================
# RIEPILOGO
# ==========================================
echo ""
echo "============================================================"
echo "Riepilogo: ${ok_count} copiate con successo, ${err_count} errori"
if [[ ${err_count} -gt 0 ]]; then
    echo "Immagini non copiate:"
    for img in "${failed_images[@]}"; do
        echo "  - ${img}"
    done
    echo "============================================================"
    exit 1
fi
echo "============================================================"
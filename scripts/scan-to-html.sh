#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# CONFIGURAZIONE
# ==========================================
OUTPUT_FILE="report.html"

# ==========================================
# FUNZIONI
# ==========================================
usage() {
    cat <<EOF
Uso: $0 [OPZIONI] <file.json> [file.json ...]

Genera un report HTML interattivo e autocontenuto dai file JSON prodotti
da scan-namespace.sh.

Ogni file JSON puo contenere un singolo report (oggetto con campo "namespace")
oppure un array di report. Piu file vengono combinati in un unico report HTML.
Usa '-' per leggere da stdin.

Opzioni:
  -o <file.html>   File HTML di output (default: report.html)
  -h               Mostra questo messaggio di aiuto

Esempi:
  $0 scan.json
  $0 -o my-report.html scan-a.json scan-b.json
  cat scan.json | $0 -o report.html -
  $0 -o combined.html cluster-a.json cluster-b.json
EOF
    exit 1
}

# ==========================================
# PARSING ARGOMENTI
# ==========================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)  OUTPUT_FILE="$2"; shift 2 ;;
        -h)  usage ;;
        --)  shift; break ;;
        -)   break ;;
        -*)  echo "Opzione sconosciuta: $1" >&2; usage ;;
        *)   break ;;
    esac
done

if [[ $# -eq 0 ]]; then
    echo "Errore: specifica almeno un file JSON di input." >&2
    echo "" >&2
    usage
fi

# Check dependencies
if ! command -v jq &>/dev/null; then
    echo "Errore: 'jq' non trovato. Installalo prima di procedere." >&2
    exit 1
fi

# ==========================================
# LETTURA E MERGE JSON
# ==========================================
MERGED_JSON="[]"

for input_file in "$@"; do
    local_json=""
    if [[ "$input_file" == "-" ]]; then
        local_json=$(cat)
    elif [[ ! -f "$input_file" ]]; then
        echo "Errore: file '$input_file' non trovato." >&2
        exit 1
    else
        local_json=$(cat "$input_file")
    fi

    # Determine if input is array or single object, normalize to array
    local_json=$(printf '%s' "$local_json" | jq '
        if type == "array" then .
        elif type == "object" and has("namespace") then [.]
        else error("Input JSON non valido: atteso array o oggetto con campo namespace")
        end
    ')

    MERGED_JSON=$(printf '%s\n%s' "$MERGED_JSON" "$local_json" | jq -s '.[0] + .[1]')
done

ns_count=$(printf '%s' "$MERGED_JSON" | jq 'length')
if [[ "$ns_count" -eq 0 ]]; then
    echo "Errore: nessun report trovato nei file di input." >&2
    exit 1
fi

echo "Report trovati: $ns_count namespace" >&2
printf '%s' "$MERGED_JSON" | jq -r '.[] | "  - \(.namespace) (context: \(.context))"' >&2

# ==========================================
# GENERAZIONE HTML
# ==========================================
{
cat <<'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OCP Migration Lab - Namespace Scan Report</title>
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #f5f6fa; color: #2d3436; line-height: 1.5; padding: 0;
}
.container { max-width: 1200px; margin: 0 auto; padding: 16px; }

/* Header / Toolbar */
.toolbar {
    background: #2d3436; color: #dfe6e9; padding: 16px 20px; position: sticky; top: 0; z-index: 100;
    display: flex; flex-wrap: wrap; align-items: center; gap: 12px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.2);
}
.toolbar h1 { font-size: 18px; font-weight: 600; white-space: nowrap; }
.toolbar-sep { width: 1px; height: 28px; background: #636e72; flex-shrink: 0; }
.toolbar label { font-size: 13px; color: #b2bec3; white-space: nowrap; }
.toolbar select, .toolbar input[type="text"] {
    background: #636e72; color: #dfe6e9; border: 1px solid #b2bec3; border-radius: 4px;
    padding: 4px 8px; font-size: 13px; outline: none;
}
.toolbar select:focus, .toolbar input[type="text"]:focus { border-color: #74b9ff; }
.toolbar input[type="text"] { width: 220px; }
.toolbar-actions { display: flex; gap: 6px; margin-left: auto; }
.btn {
    background: #636e72; color: #dfe6e9; border: 1px solid #b2bec3; border-radius: 4px;
    padding: 4px 10px; font-size: 12px; cursor: pointer; white-space: nowrap;
}
.btn:hover { background: #74b9ff; color: #2d3436; }

/* Namespace sections */
.ns-section { margin-top: 20px; }
.ns-header {
    background: #2d3436; color: #dfe6e9; padding: 10px 16px; border-radius: 6px 6px 0 0;
    font-size: 16px; font-weight: 600; cursor: pointer; user-select: none;
    display: flex; align-items: center; gap: 8px;
}
.ns-header .chevron { transition: transform 0.2s; display: inline-block; font-size: 12px; }
.ns-header .chevron.open { transform: rotate(90deg); }
.ns-body { background: #fff; border: 1px solid #ddd; border-top: none; border-radius: 0 0 6px 6px; padding: 0; }
.ns-body.hidden { display: none; }

/* Section panels inside namespace */
.section-panel { border-bottom: 1px solid #eee; }
.section-panel:last-child { border-bottom: none; }
.section-header {
    background: #dfe6e9; padding: 8px 16px; cursor: pointer; user-select: none;
    display: flex; align-items: center; gap: 8px; font-size: 14px; font-weight: 600;
}
.section-header:hover { background: #b2bec3; }
.section-header .chevron { transition: transform 0.2s; display: inline-block; font-size: 11px; }
.section-header .chevron.open { transform: rotate(90deg); }
.section-header .badge {
    background: #636e72; color: #fff; border-radius: 10px; padding: 1px 8px;
    font-size: 11px; font-weight: 400;
}
.section-body { padding: 0; }
.section-body.hidden { display: none; }

/* Sub-group headers (BOUNDED / UNBOUNDED) */
.subgroup-header {
    background: #f0f0f0; padding: 4px 24px; font-size: 12px; font-weight: 600;
    color: #636e72; text-transform: uppercase; letter-spacing: 0.5px;
}

/* Tree items */
.tree-item { border-top: 1px solid #f0f0f0; }
.tree-item:first-child { border-top: none; }
.item-header {
    padding: 6px 24px; cursor: pointer; user-select: none;
    display: flex; align-items: center; gap: 6px; font-size: 13px;
}
.item-header:hover { background: #f8f9fa; }
.item-header .chevron { font-size: 10px; transition: transform 0.2s; display: inline-block; color: #636e72; }
.item-header .chevron.open { transform: rotate(90deg); }
.item-header .item-name { font-weight: 600; color: #2d3436; }
.item-header .item-kind { color: #636e72; font-size: 12px; }
.item-body { padding: 0 24px 8px 44px; }
.item-body.hidden { display: none; }

/* Key-value rows */
.kv-row {
    display: flex; align-items: baseline; gap: 4px; padding: 2px 0;
    font-size: 13px; line-height: 1.6;
}
.kv-key { color: #636e72; min-width: 140px; flex-shrink: 0; font-size: 12px; }
.kv-val {
    font-family: "SF Mono", "Fira Code", "Fira Mono", Menlo, Consolas, monospace;
    font-size: 12px; color: #2d3436; word-break: break-all;
}
.kv-val.warn { color: #d63031; font-weight: 600; }
.kv-val.warn-orange { color: #e17055; font-weight: 600; }

/* Copy button */
.copy-btn {
    background: none; border: none; cursor: pointer; color: #b2bec3; padding: 0 4px;
    font-size: 13px; vertical-align: middle; position: relative; flex-shrink: 0;
}
.copy-btn:hover { color: #0984e3; }
.copy-btn .tooltip {
    display: none; position: absolute; top: -24px; left: 50%; transform: translateX(-50%);
    background: #2d3436; color: #fff; padding: 2px 8px; border-radius: 3px;
    font-size: 11px; white-space: nowrap; font-family: sans-serif;
}
.copy-btn.copied .tooltip { display: block; }

/* Nested containers */
.nested-group { margin: 4px 0 4px 0; }
.nested-header {
    font-size: 13px; font-weight: 600; color: #636e72; padding: 4px 0;
    cursor: pointer; user-select: none; display: flex; align-items: center; gap: 6px;
}
.nested-header:hover { color: #2d3436; }
.nested-header .chevron { font-size: 10px; transition: transform 0.2s; display: inline-block; }
.nested-header .chevron.open { transform: rotate(90deg); }
.nested-body { padding-left: 16px; }
.nested-body.hidden { display: none; }

/* Container block */
.container-block { border-left: 3px solid #dfe6e9; padding: 4px 0 4px 12px; margin: 4px 0; }
.container-name { font-weight: 600; font-size: 13px; color: #0984e3; margin-bottom: 2px; }

/* Warning badges */
.badge-warn {
    display: inline-block; background: #fdcb6e; color: #2d3436; border-radius: 3px;
    padding: 0 6px; font-size: 11px; font-weight: 600; margin-left: 6px;
}
.badge-err {
    display: inline-block; background: #d63031; color: #fff; border-radius: 3px;
    padding: 0 6px; font-size: 11px; font-weight: 600; margin-left: 6px;
}

/* Highlight for search matches */
.search-highlight { background: #ffeaa7; border-radius: 2px; padding: 0 1px; }

/* Summary panel */
.summary-panel {
    background: #f8f9fa; border-bottom: 2px solid #dfe6e9; padding: 12px 20px;
}
.summary-totals {
    display: flex; flex-wrap: wrap; gap: 12px; margin-bottom: 8px;
}
.summary-stat {
    background: #dfe6e9; border-radius: 4px; padding: 4px 12px; font-size: 13px;
    display: flex; align-items: center; gap: 6px;
}
.summary-stat .stat-count { font-weight: 700; font-size: 16px; color: #2d3436; }
.summary-stat .stat-label { color: #636e72; }
.summary-unbounded {
    font-size: 12px; color: #636e72; margin-bottom: 8px;
}
.summary-warning {
    background: #ffeaa7; border-left: 4px solid #fdcb6e; border-radius: 0 4px 4px 0;
    padding: 8px 12px; margin: 6px 0; font-size: 13px;
}
.summary-warning.error {
    background: #fab1a0; border-left-color: #d63031;
}
.summary-warning .warn-title { font-weight: 600; margin-bottom: 2px; }
.summary-warning .warn-detail { color: #636e72; font-size: 12px; margin-bottom: 4px; }
.summary-warning .warn-routes { font-size: 12px; font-family: monospace; color: #2d3436; }

/* Dependency badges and cards */
.dep-badge {
    display: inline-block; border-radius: 3px; padding: 0 6px;
    font-size: 10px; font-weight: 600; margin-left: 6px; vertical-align: middle;
}
.dep-badge.db { background: #74b9ff; color: #2d3436; }
.dep-badge.cache { background: #00b894; color: #fff; }
.dep-badge.auth { background: #fdcb6e; color: #2d3436; }
.dep-badge.msg { background: #a29bfe; color: #fff; }
.dep-badge.svc { background: #636e72; color: #fff; }
.dep-card {
    background: #f8f9fa; border: 1px solid #dfe6e9; border-radius: 4px;
    padding: 6px 10px; margin: 4px 0; font-size: 12px;
}
.dep-card .dep-type {
    display: inline-block; font-weight: 700; border-radius: 3px;
    padding: 1px 8px; font-size: 11px; margin-right: 8px;
}
.dep-card .dep-type.db { background: #74b9ff; color: #2d3436; }
.dep-card .dep-type.cache { background: #00b894; color: #fff; }
.dep-card .dep-type.auth { background: #fdcb6e; color: #2d3436; }
.dep-card .dep-type.msg { background: #a29bfe; color: #fff; }
.dep-card .dep-type.svc { background: #636e72; color: #fff; }
.dep-card .dep-url { font-family: monospace; font-size: 12px; color: #2d3436; }
.dep-props {
    display: flex; flex-wrap: wrap; gap: 4px 12px; margin-top: 3px;
    font-size: 11px; color: #636e72;
}
.dep-props span { white-space: nowrap; }
.dep-props .prop-key { color: #636e72; }
.dep-props .prop-val { color: #2d3436; font-family: monospace; }

/* Summary deps */
.summary-deps { margin-top: 8px; }
.summary-deps-title { font-weight: 600; font-size: 13px; margin-bottom: 4px; }
.summary-dep-row {
    display: flex; align-items: baseline; gap: 8px; padding: 3px 0;
    font-size: 12px; border-bottom: 1px solid #eee;
}
.summary-dep-row:last-child { border-bottom: none; }
.summary-dep-sources { color: #636e72; font-size: 11px; }

/* No results */
.no-results {
    text-align: center; padding: 40px; color: #636e72; font-size: 15px;
    display: none;
}

/* Print */
@media print {
    .toolbar { position: static; box-shadow: none; }
    .btn, .copy-btn { display: none !important; }
    .ns-body.hidden, .section-body.hidden, .item-body.hidden, .nested-body.hidden { display: block !important; }
    body { background: #fff; }
}
</style>
</head>
<body>

<div class="toolbar">
    <h1>OCP Namespace Scan Report</h1>
    <div class="toolbar-sep"></div>
    <label for="ns-filter">Namespace:</label>
    <select id="ns-filter"><option value="__all__">All</option></select>
    <div class="toolbar-sep"></div>
    <label for="search-box">Search:</label>
    <input type="text" id="search-box" placeholder="Filter by name...">
    <div class="toolbar-actions">
        <button class="btn" id="btn-expand-all">Expand All</button>
        <button class="btn" id="btn-collapse-all">Collapse All</button>
    </div>
</div>

<div class="container" id="app">
    <div class="no-results" id="no-results">No matching results.</div>
</div>

<script>
const REPORT_DATA =
HTMLEOF

printf '%s' "$MERGED_JSON" | jq -c .

cat <<'HTMLEOF'
;

// ========== RENDERING ==========
const app = document.getElementById('app');
const nsFilter = document.getElementById('ns-filter');
const searchBox = document.getElementById('search-box');
const noResults = document.getElementById('no-results');

function esc(s) {
    if (s === null || s === undefined) return 'N/A';
    s = String(s);
    return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function copyBtn(val) {
    return '<button class="copy-btn" onclick="copyVal(this,event)" data-val="' + esc(String(val)).replace(/'/g,'&#39;') + '">&#128203;<span class="tooltip">Copied!</span></button>';
}

function kvRow(key, val, cls) {
    const valStr = (val === null || val === undefined) ? 'N/A' : String(val);
    const extraCls = cls ? ' ' + cls : '';
    return '<div class="kv-row"><span class="kv-key">' + esc(key) + '</span><span class="kv-val' + extraCls + '">' + esc(valStr) + '</span>' + copyBtn(valStr) + '</div>';
}

function chevron(open) {
    return '<span class="chevron' + (open ? ' open' : '') + '">&#9654;</span>';
}

function toggleVis(header) {
    const body = header.nextElementSibling;
    const chev = header.querySelector('.chevron');
    if (body.classList.contains('hidden')) {
        body.classList.remove('hidden');
        if (chev) chev.classList.add('open');
    } else {
        body.classList.add('hidden');
        if (chev) chev.classList.remove('open');
    }
}

window.copyVal = function(btn, ev) {
    if (ev) ev.stopPropagation();
    const val = btn.getAttribute('data-val');
    navigator.clipboard.writeText(val).then(function() {
        btn.classList.add('copied');
        setTimeout(function() { btn.classList.remove('copied'); }, 1200);
    });
};

function renderContainer(c) {
    let h = '<div class="container-block">';
    h += '<div class="container-name">[' + esc(c.name) + ']</div>';
    h += kvRow('image', c.image);
    h += kvRow('requests', 'cpu=' + c.requests.cpu + ', memory=' + c.requests.memory);
    h += kvRow('limits', 'cpu=' + c.limits.cpu + ', memory=' + c.limits.memory);
    if (c.liveness !== undefined) h += kvRow('liveness', c.liveness);
    if (c.readiness !== undefined) h += kvRow('readiness', c.readiness);
    if (c.startup !== undefined) h += kvRow('startup', c.startup);
    const secs = (c.secrets && c.secrets.length > 0) ? c.secrets.join(', ') : 'N/A';
    const cms = (c.configmaps && c.configmaps.length > 0) ? c.configmaps.join(', ') : 'N/A';
    const pvcs = (c.pvcs && c.pvcs.length > 0) ? c.pvcs.join(', ') : 'N/A';
    h += kvRow('secrets', secs);
    h += kvRow('configmaps', cms);
    h += kvRow('pvcs', pvcs);
    h += '</div>';
    return h;
}

function renderContainerGroup(label, containers) {
    if (!containers || containers.length === 0) return '';
    let h = '<div class="nested-group">';
    h += '<div class="nested-header" onclick="toggleVis(this)">' + chevron(false) + ' ' + esc(label) + ' (' + containers.length + ')</div>';
    h += '<div class="nested-body hidden">';
    containers.forEach(function(c) { h += renderContainer(c); });
    h += '</div></div>';
    return h;
}

function renderWorkload(w) {
    let extra = '';
    if (w.replicas !== null && w.replicas !== undefined) extra += ' (replicas: ' + w.replicas + ')';
    if (w.schedule) extra += ' (schedule: ' + esc(w.schedule) + ')';

    let h = '<div class="tree-item" data-name="' + esc(w.name) + '">';
    h += '<div class="item-header" onclick="toggleVis(this)">' + chevron(false);
    h += ' <span class="item-name">' + esc(w.name) + '</span>' + copyBtn(w.name);
    h += ' <span class="item-kind">' + esc(w.kind) + extra + '</span></div>';
    h += '<div class="item-body hidden">';
    h += kvRow('serviceAccount', w.serviceAccount);
    h += kvRow('nodeSelector', w.nodeSelector);
    h += kvRow('tolerations', w.tolerations);
    h += kvRow('affinity', w.affinity);
    h += renderContainerGroup('Containers', w.containers);
    h += renderContainerGroup('Init Containers', w.initContainers);
    h += '</div></div>';
    return h;
}

function depTypeClass(type) {
    if (type === 'jdbc' || type === 'mongodb') return 'db';
    if (type === 'redis') return 'cache';
    if (type === 'keycloak') return 'auth';
    if (type === 'kafka' || type === 'amqp' || type === 'activemq') return 'msg';
    return 'svc';
}

function depLabel(d) {
    return d.type + (d.subtype ? '/' + d.subtype : '');
}

function renderDepBadges(deps) {
    if (!deps || deps.length === 0) return '';
    var types = [];
    deps.forEach(function(d) {
        var lbl = depLabel(d);
        if (types.indexOf(lbl) === -1) types.push(lbl);
    });
    return types.map(function(t) {
        var cls = depTypeClass(t.split('/')[0]);
        return '<span class="dep-badge ' + cls + '">' + esc(t) + '</span>';
    }).join('');
}

function renderDepProps(props) {
    if (!props) return '';
    var h = '<div class="dep-props">';
    Object.keys(props).forEach(function(k) {
        h += '<span><span class="prop-key">' + esc(k) + ':</span> <span class="prop-val">' + esc(props[k]) + '</span>' + copyBtn(props[k]) + '</span>';
    });
    h += '</div>';
    return h;
}

function renderItemDeps(deps) {
    if (!deps || deps.length === 0) return '';
    var h = '<div class="nested-group">';
    h += '<div class="nested-header" onclick="toggleVis(this)">' + chevron(false) + ' Dependencies (' + deps.length + ')</div>';
    h += '<div class="nested-body hidden">';
    deps.forEach(function(d) {
        var cls = depTypeClass(d.type);
        h += '<div class="dep-card">';
        h += '<span class="dep-type ' + cls + '">' + esc(depLabel(d)) + '</span>';
        h += '<span class="dep-url">' + esc(d.url) + '</span>' + copyBtn(d.url);
        h += '<br><span style="color:#636e72;font-size:11px;">key: ' + esc(d.key) + '</span>';
        h += renderDepProps(d.properties);
        h += '</div>';
    });
    h += '</div></div>';
    return h;
}

function renderSecret(s) {
    const keys = (s.keys && s.keys.length > 0) ? s.keys.join(', ') : '(vuoto)';
    const deps = s.dependencies || [];
    let h = '<div class="tree-item" data-name="' + esc(s.name) + '">';
    h += '<div class="item-header" onclick="toggleVis(this)">' + chevron(false);
    h += ' <span class="item-name">' + esc(s.name) + '</span>' + copyBtn(s.name);
    h += ' <span class="item-kind">' + esc(s.type) + '</span>' + renderDepBadges(deps) + '</div>';
    h += '<div class="item-body hidden">';
    h += kvRow('type', s.type);
    h += kvRow('keys', keys);
    h += renderItemDeps(deps);
    h += '</div></div>';
    return h;
}

function renderConfigMap(cm) {
    const keys = (cm.keys && cm.keys.length > 0) ? cm.keys.join(', ') : '(vuoto)';
    const deps = cm.dependencies || [];
    let h = '<div class="tree-item" data-name="' + esc(cm.name) + '">';
    h += '<div class="item-header" onclick="toggleVis(this)">' + chevron(false);
    h += ' <span class="item-name">' + esc(cm.name) + '</span>' + copyBtn(cm.name) + renderDepBadges(deps) + '</div>';
    h += '<div class="item-body hidden">';
    h += kvRow('keys', keys);
    h += renderItemDeps(deps);
    h += '</div></div>';
    return h;
}

function renderPVC(pvc) {
    let h = '<div class="tree-item" data-name="' + esc(pvc.name) + '">';
    h += '<div class="item-header" onclick="toggleVis(this)">' + chevron(false);
    h += ' <span class="item-name">' + esc(pvc.name) + '</span>' + copyBtn(pvc.name) + '</div>';
    h += '<div class="item-body hidden">';
    h += kvRow('capacity', pvc.capacity);
    h += kvRow('accessModes', pvc.accessModes);
    h += kvRow('storageClass', pvc.storageClass);
    h += '</div></div>';
    return h;
}

function renderService(svc) {
    const ports = (svc.ports && svc.ports.length > 0)
        ? svc.ports.map(function(p) {
            return (p.name ? p.name + ':' : '') + p.port + '->' + p.targetPort + '/' + p.protocol;
        }).join(', ')
        : 'N/A';
    let h = '<div class="tree-item" data-name="' + esc(svc.name) + '">';
    h += '<div class="item-header" onclick="toggleVis(this)">' + chevron(false);
    h += ' <span class="item-name">' + esc(svc.name) + '</span>' + copyBtn(svc.name);
    h += ' <span class="item-kind">' + esc(svc.type) + '</span></div>';
    h += '<div class="item-body hidden">';
    h += kvRow('type', svc.type);
    h += kvRow('selector', svc.selector);
    h += kvRow('ports', ports);
    h += '</div></div>';
    return h;
}

function renderRoute(r) {
    let badges = '';
    if (r.hostClusterBound) badges += '<span class="badge-warn">host cluster-bound</span>';
    if (r.certInfo && r.certInfo.clusterBound) badges += '<span class="badge-err">cert cluster-bound</span>';
    if (r.certInfo && r.certInfo.hasClusterSan && !r.certInfo.clusterBound) badges += '<span class="badge-warn">has cluster SAN</span>';
    if (r.certInfo && !r.certInfo.certMatch) badges += '<span class="badge-err">cert MISMATCH</span>';

    let h = '<div class="tree-item" data-name="' + esc(r.name) + '">';
    h += '<div class="item-header" onclick="toggleVis(this)">' + chevron(false);
    h += ' <span class="item-name">' + esc(r.name) + '</span>' + copyBtn(r.name) + badges + '</div>';
    h += '<div class="item-body hidden">';
    h += kvRow('host', r.host);
    h += kvRow('path', r.path);
    h += kvRow('service', r.service);
    h += kvRow('port', r.port);
    h += kvRow('tls', r.tlsTermination);
    h += kvRow('externalCert', r.externalCert ? 'yes' : 'no');

    const hcbVal = r.hostClusterBound ? 'SI - hostname generato da OpenShift' : 'no (hostname personalizzato)';
    h += kvRow('host cluster-bound', hcbVal, r.hostClusterBound ? 'warn-orange' : '');

    if (r.certInfo) {
        h += '<div class="nested-group">';
        h += '<div class="nested-header" onclick="toggleVis(this)">' + chevron(false) + ' Certificate Info</div>';
        h += '<div class="nested-body hidden">';
        h += kvRow('issuer', r.certInfo.issuer);
        h += kvRow('valid from', r.certInfo.notBefore);
        h += kvRow('valid to', r.certInfo.notAfter);
        h += kvRow('SANs', r.certInfo.sans ? r.certInfo.sans.join(', ') : 'N/A');
        h += kvRow('wildcard', r.certInfo.wildcard ? 'yes' : 'no');
        h += kvRow('cert match', r.certInfo.certMatch ? 'yes' : 'MISMATCH', r.certInfo.certMatch ? '' : 'warn');
        h += kvRow('dedicated cert', r.certInfo.dedicatedCert ? 'yes (1 hostname)' : 'no (multi-domain)');
        const cbVal = r.certInfo.clusterBound ? 'SI - hostname coperto da nome del dominio cluster' : 'no';
        h += kvRow('cert cluster-bound', cbVal, r.certInfo.clusterBound ? 'warn' : '');
        h += kvRow('has cluster SAN', r.certInfo.hasClusterSan ? 'yes' : 'no', r.certInfo.hasClusterSan ? 'warn-orange' : '');
        h += '</div></div>';
    }
    h += '</div></div>';
    return h;
}

function renderBoundedSection(items, renderFn) {
    if (!items || items.length === 0) return '<div style="padding:8px 24px;color:#636e72;font-size:13px;">(nessuno)</div>';
    const bounded = items.filter(function(i) { return !i.unbounded; });
    const unbounded = items.filter(function(i) { return i.unbounded; });
    let h = '';
    h += '<div class="subgroup-header">Bounded (' + bounded.length + ')</div>';
    if (bounded.length === 0) h += '<div style="padding:4px 24px;color:#636e72;font-size:12px;">(nessuno)</div>';
    else bounded.forEach(function(i) { h += renderFn(i); });
    h += '<div class="subgroup-header">Unbounded (' + unbounded.length + ')</div>';
    if (unbounded.length === 0) h += '<div style="padding:4px 24px;color:#636e72;font-size:12px;">(nessuno)</div>';
    else unbounded.forEach(function(i) { h += renderFn(i); });
    return h;
}

function renderWorkloadsSection(workloads) {
    if (!workloads || workloads.length === 0) return '<div style="padding:8px 24px;color:#636e72;font-size:13px;">(nessuno)</div>';
    const kinds = ['Deployment','DeploymentConfig','StatefulSet','DaemonSet','CronJob','Job','Pod'];
    let h = '';
    kinds.forEach(function(kind) {
        const items = workloads.filter(function(w) { return w.kind === kind; });
        if (items.length === 0) return;
        h += '<div class="subgroup-header">' + kind + ' (' + items.length + ')</div>';
        items.forEach(function(w) { h += renderWorkload(w); });
    });
    return h;
}

function renderSection(title, count, contentHtml, startOpen) {
    let h = '<div class="section-panel">';
    h += '<div class="section-header" onclick="toggleVis(this)">' + chevron(startOpen);
    h += ' ' + esc(title) + ' <span class="badge">' + count + '</span></div>';
    h += '<div class="section-body' + (startOpen ? '' : ' hidden') + '">' + contentHtml + '</div>';
    h += '</div>';
    return h;
}

function renderSummary(ns) {
    const s = ns.summary;
    if (!s) return '';
    let h = '<div class="summary-panel">';

    // Totals
    h += '<div class="summary-totals">';
    const stats = [
        {count: s.totals.workloads, label: 'workload'},
        {count: s.totals.secrets, label: 'secret'},
        {count: s.totals.configmaps, label: 'configmap'},
        {count: s.totals.pvcs, label: 'PVC'},
        {count: s.totals.services, label: 'service'},
        {count: s.totals.routes, label: 'route'}
    ];
    stats.forEach(function(st) {
        h += '<div class="summary-stat"><span class="stat-count">' + st.count + '</span><span class="stat-label">' + st.label + '</span></div>';
    });
    h += '</div>';

    // Unbounded
    const ub = s.unbounded;
    if (ub && (ub.secrets > 0 || ub.configmaps > 0 || ub.pvcs > 0)) {
        const parts = [];
        if (ub.secrets > 0) parts.push(ub.secrets + ' secret');
        if (ub.configmaps > 0) parts.push(ub.configmaps + ' configmap');
        if (ub.pvcs > 0) parts.push(ub.pvcs + ' PVC');
        h += '<div class="summary-unbounded">Unbounded: ' + parts.join(', ') + '</div>';
    }

    // Warnings
    if (s.warnings && s.warnings.length > 0) {
        s.warnings.forEach(function(w) {
            const cls = (w.type === 'certMismatch') ? 'summary-warning error' : 'summary-warning';
            h += '<div class="' + cls + '">';
            h += '<div class="warn-title">' + esc(w.message) + '</div>';
            h += '<div class="warn-detail">' + esc(w.detail) + '</div>';
            if (w.routes && w.routes.length > 0) {
                h += '<div class="warn-routes">';
                w.routes.forEach(function(r) {
                    h += esc(r.name) + ' (' + esc(r.host) + ')' + copyBtn(r.name) + '<br>';
                });
                h += '</div>';
            }
            h += '</div>';
        });
    }

    // Dependencies
    if (s.dependencies && s.dependencies.length > 0) {
        h += '<div class="summary-deps">';
        h += '<div class="summary-deps-title">Dipendenze rilevate (' + s.dependencies.length + ')</div>';
        s.dependencies.forEach(function(d) {
            var cls = depTypeClass(d.type);
            h += '<div class="summary-dep-row">';
            h += '<span class="dep-type ' + cls + '">' + esc(depLabel(d)) + '</span>';
            var urls = d.urls || [];
            h += '<span class="dep-url">' + esc(urls.join(', ')) + '</span>' + (urls.length > 0 ? copyBtn(urls[0]) : '');
            // Properties
            if (d.properties) {
                var propParts = [];
                Object.keys(d.properties).forEach(function(k) {
                    propParts.push(k + ': ' + d.properties[k]);
                });
                if (propParts.length > 0) {
                    h += '<span class="dep-props" style="display:inline;margin:0;gap:8px;">';
                    propParts.forEach(function(p) {
                        h += ' <span>' + esc(p) + '</span>';
                    });
                    h += '</span>';
                }
            }
            h += '</div>';
            // Sources
            if (d.sources && d.sources.length > 0) {
                h += '<div class="summary-dep-sources" style="padding-left:8px;margin-bottom:4px;">';
                h += 'fonte: ' + d.sources.map(function(src) {
                    return esc(src.kind + '/' + src.name) + ' (key: ' + esc(src.key) + ')';
                }).join(', ');
                h += '</div>';
            }
        });
        h += '</div>';
    }

    h += '</div>';
    return h;
}

function renderNamespace(ns) {
    let h = '<div class="ns-section" data-ns="' + esc(ns.namespace) + '">';
    h += '<div class="ns-header" onclick="toggleVis(this)">' + chevron(true);
    h += ' ' + esc(ns.namespace) + ' <span style="font-weight:400;font-size:13px;color:#b2bec3;">(' + esc(ns.context) + ')</span></div>';
    h += '<div class="ns-body">';

    h += renderSummary(ns);

    h += renderSection('Workloads', ns.workloads ? ns.workloads.length : 0,
        renderWorkloadsSection(ns.workloads), true);
    h += renderSection('Secrets', ns.secrets ? ns.secrets.length : 0,
        renderBoundedSection(ns.secrets, renderSecret), true);
    h += renderSection('ConfigMaps', ns.configmaps ? ns.configmaps.length : 0,
        renderBoundedSection(ns.configmaps, renderConfigMap), true);
    h += renderSection('PVCs', ns.pvcs ? ns.pvcs.length : 0,
        renderBoundedSection(ns.pvcs, renderPVC), true);
    h += renderSection('Services', ns.services ? ns.services.length : 0,
        ns.services && ns.services.length > 0
            ? ns.services.map(renderService).join('')
            : '<div style="padding:8px 24px;color:#636e72;font-size:13px;">(nessuno)</div>', true);
    h += renderSection('Routes', ns.routes ? ns.routes.length : 0,
        ns.routes && ns.routes.length > 0
            ? ns.routes.map(renderRoute).join('')
            : '<div style="padding:8px 24px;color:#636e72;font-size:13px;">(nessuno)</div>', true);

    h += '</div></div>';
    return h;
}

// Build DOM
(function() {
    // Populate namespace filter
    const nsSet = [];
    REPORT_DATA.forEach(function(ns) {
        if (nsSet.indexOf(ns.namespace) === -1) nsSet.push(ns.namespace);
    });
    nsSet.forEach(function(n) {
        const opt = document.createElement('option');
        opt.value = n;
        opt.textContent = n;
        nsFilter.appendChild(opt);
    });

    // Render all namespaces
    let html = '';
    REPORT_DATA.forEach(function(ns) { html += renderNamespace(ns); });
    app.insertAdjacentHTML('beforeend', html);
})();

// ========== FILTERING ==========
function applyFilters() {
    const nsVal = nsFilter.value;
    const query = searchBox.value.toLowerCase().trim();
    const sections = document.querySelectorAll('.ns-section');
    let anyVisible = false;

    sections.forEach(function(sec) {
        const ns = sec.getAttribute('data-ns');
        // Namespace filter
        if (nsVal !== '__all__' && ns !== nsVal) {
            sec.style.display = 'none';
            return;
        }
        sec.style.display = '';

        // Text search within items
        const items = sec.querySelectorAll('.tree-item');
        let sectionHasVisible = false;
        items.forEach(function(item) {
            const name = (item.getAttribute('data-name') || '').toLowerCase();
            if (query === '' || name.indexOf(query) !== -1) {
                item.style.display = '';
                sectionHasVisible = true;
            } else {
                item.style.display = 'none';
            }
        });

        // Hide section panels that have zero visible items
        const panels = sec.querySelectorAll('.section-panel');
        panels.forEach(function(panel) {
            const visibleItems = panel.querySelectorAll('.tree-item:not([style*="display: none"])');
            // Also check if section simply has no tree-items (like empty sections)
            const allItems = panel.querySelectorAll('.tree-item');
            if (allItems.length > 0 && visibleItems.length === 0) {
                panel.style.display = 'none';
            } else {
                panel.style.display = '';
            }
        });

        if (sectionHasVisible || query === '') {
            anyVisible = true;
        } else {
            sec.style.display = 'none';
        }
    });

    noResults.style.display = anyVisible || query === '' ? 'none' : 'block';
}

nsFilter.addEventListener('change', applyFilters);

let searchTimeout;
searchBox.addEventListener('input', function() {
    clearTimeout(searchTimeout);
    searchTimeout = setTimeout(applyFilters, 200);
});

// ========== EXPAND / COLLAPSE ALL ==========
document.getElementById('btn-expand-all').addEventListener('click', function() {
    document.querySelectorAll('.ns-body.hidden, .section-body.hidden, .item-body.hidden, .nested-body.hidden').forEach(function(el) {
        el.classList.remove('hidden');
    });
    document.querySelectorAll('.chevron').forEach(function(el) {
        el.classList.add('open');
    });
});

document.getElementById('btn-collapse-all').addEventListener('click', function() {
    document.querySelectorAll('.item-body, .nested-body').forEach(function(el) {
        el.classList.add('hidden');
    });
    document.querySelectorAll('.item-body + .hidden, .nested-body + .hidden').forEach(function() {});
    // Collapse item and nested chevrons, keep section/ns open
    document.querySelectorAll('.item-header .chevron, .nested-header .chevron').forEach(function(el) {
        el.classList.remove('open');
    });
});

</script>
</body>
</html>
HTMLEOF
} > "$OUTPUT_FILE"

echo "Report HTML salvato in: $OUTPUT_FILE" >&2

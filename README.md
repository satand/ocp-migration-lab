# ocp-migration-lab

Script per inventariare e copiare risorse tra due cluster OpenShift, da un bastion con `oc` già configurato.

Gli script di migrazione usano due context kubeconfig:

- `-s` cluster sorgente, oppure `SRC_CONTEXT`
- `-d` cluster destinazione, oppure `DST_CONTEXT`
- namespace; se omesso, è il progetto corrente del context sorgente

Il namespace deve già esistere sul cluster destinazione.

## Requisiti

- `oc` e `jq`
- `skopeo` per `copy-images.sh`
- `openssl` per l'analisi dei certificati sulle route

## Script

| Script | Cosa fa |
|---|---|
| `scripts/scan-namespace.sh` | Report di workload, Secret, ConfigMap, PVC, Service e Route di uno o più namespace |
| `scripts/scan-to-html.sh` | Genera un report HTML interattivo dai JSON prodotti da `scan-namespace.sh` |
| `scripts/copy-images.sh` | Copia immagini tra i registry interni dei due cluster con `skopeo` |
| `scripts/migrate-pvc.sh` | Crea il PVC sul destinazione; con `-C` copia anche i dati |
| `scripts/migrate-cm.sh` | Copia una o più ConfigMap |
| `scripts/migrate-secret.sh` | Copia uno o più Secret; quelli gestiti dal cluster si saltano, salvo `-a` |
| `scripts/migrate-route.sh` | Copia Route e, se manca, il Service associato |

Ogni script ha l'help con `-h`.

## Scan

```bash
./scripts/scan-namespace.sh -s src-cluster my-project
./scripts/scan-namespace.sh -s src-cluster ns-alpha ns-beta ns-gamma
./scripts/scan-namespace.sh -s src-cluster -o report.json my-project
```

I namespace si passano come argomenti posizionali; se omessi, si usa il progetto corrente del context.

Secret, ConfigMap e PVC sono divisi in `[BOUNDED]` e `[UNBOUNDED]`. Per le route con certificato esterno lo scan indica se l'hostname è coperto dal certificato e se hostname o SAN sono legati al dominio del cluster sorgente.

### Rilevamento dipendenze

Durante la scansione di ConfigMap e Secret, lo script analizza i valori delle singole chiavi alla ricerca di pattern che permettano di individuare dipendenze applicative da middleware e servizi esterni. Vengono riconosciuti:

| Tipo | Pattern riconosciuti | Proprietà estratte |
|---|---|---|
| **JDBC** | `jdbc:postgresql://`, `jdbc:mysql://`, `jdbc:oracle:` … | host, port, database, username |
| **MongoDB** | `mongodb://`, `mongodb+srv://`, chiave con `mongo*.host` | host, port, database, authDatabase, username |
| **Redis** | `redis://`, `rediss://` | host, port, database |
| **Keycloak** | URL con `/realms/`, hostname contenente `keycloak` o `sso` | host, port, realm, clientId |
| **Kafka** | `bootstrap-servers`, `bootstrap.servers`, chiave con `kafka.*bootstrap` | bootstrapServers, topic, consumerGroup, securityProtocol, saslMechanism, username |
| **AMQP** | `amqp://`, `amqps://` | host, port, username, queue, topic |
| **ActiveMQ** | `failover:(`, `tcp://` con activemq/artemis/61616 | host, port, queue |
| **Servizio interno** | `http(s)://*.svc`, `*.svc.cluster.local` | host, port, path |

L'estrazione avviene in due livelli: (1) parsing dei pattern URL/valore e (2) ricerca di chiavi "sorelle" all'interno della stessa ConfigMap o Secret (es. una chiave `db.username` associata a una chiave `db.url`). Le chiavi sensibili (`password`, `token`, `credential`, `private.key` ecc.) non vengono mai estratte.

> ⚠ I risultati sono euristici e potrebbero non essere completi o attendibili. Rappresentano un aiuto nell'analisi, non un inventario esatto delle dipendenze.

Le dipendenze rilevate compaiono:
- nelle sezioni ConfigMap/Secret del report di ciascun namespace
- nella sezione di riepilogo del namespace (totali, warning, dipendenze aggregate)
- nel report HTML, con badge colorati per tipo e card di dettaglio

### Report strutturato (JSON/YAML)

Con `-o report.json` (o `.yaml`) il report include per ogni namespace una sezione `summary` con:

- **totals** — conteggi di workload, secret, configmap, PVC, service, route
- **unbounded** — numero di secret, configmap e PVC non legati al cluster
- **warnings** — route con hostname o certificato legato al cluster sorgente, mismatch certificato
- **dependencies** — dipendenze aggregate per tipo, con URL, proprietà e sorgente (ConfigMap/Secret)

### Report HTML

A partire dal JSON prodotto dallo scan si può generare un report HTML autocontenuto:

```bash
./scripts/scan-to-html.sh -o report.html report.json
```

Il report offre:
- filtro per namespace e ricerca libera case-insensitive su tutti i nomi degli oggetti
- sezioni collassabili con Expand All / Collapse All
- bottone per copiare in clipboard nomi di risorse e valori
- badge di warning sulle route (hostname/certificato cluster-bound)
- pannello di riepilogo con totali, warning e dipendenze rilevate
- badge colorati per tipo di dipendenza (database, cache, auth, messaging, servizio)
- card di dettaglio per ogni dipendenza con URL e proprietà estratte
- layout ottimizzato per la stampa

Si possono combinare più file JSON in un unico report:

```bash
./scripts/scan-to-html.sh -o combined.html scan-a.json scan-b.json
```

## Migrazione

```bash
./scripts/migrate-cm.sh -s src-cluster -d dst-cluster -n my-project app-config
./scripts/migrate-secret.sh -s src-cluster -d dst-cluster -n my-project db-creds
./scripts/migrate-pvc.sh -s src-cluster -d dst-cluster -n my-project -c thin-csi -C data
./scripts/migrate-route.sh -s src-cluster -d dst-cluster -n my-project web
```

### Sostituzione risorse esistenti

Se una risorsa esiste già sul cluster destinazione, tutti gli script `migrate-*` chiedono conferma prima di sostituirla (cancellazione e ricreazione). Con `-y` la sostituzione è automatica:

```bash
./scripts/migrate-cm.sh -s src-cluster -d dst-cluster -y -n my-project app-config
```

### Sostituzione riferimenti al dominio sorgente

`migrate-cm.sh` e `migrate-secret.sh` rilevano i valori che contengono riferimenti al dominio del cluster sorgente (hostname API, dominio apps, dominio base). Prima dell'apply, mostrano i riferimenti trovati e chiedono se sostituirli con i domini del cluster destinazione.

Con `-R` la sostituzione avviene automaticamente senza chiedere:

```bash
./scripts/migrate-cm.sh -s src-cluster -d dst-cluster -R -n my-project app-config
./scripts/migrate-secret.sh -s src-cluster -d dst-cluster -R -y -n my-project db-creds
```

Il mapping viene costruito automaticamente dai domini dei due cluster (es. `apps.ocp4-src.example.com` → `apps.ocp4-dst.example.com`). I riferimenti che non corrispondono a nessun mapping restano inalterati e vengono segnalati nel riepilogo finale.

### Route

`migrate-route.sh` migra una route con certificato esterno solo se il certificato non è scaduto, copre l'hostname della route e resta valido sul destinazione. Se l'hostname è quello generato da OpenShift, non viene copiato. Il riepilogo indica se aggiornare il DNS esterno.

### PVC

Per i PVC, `-c` forza la StorageClass di destinazione e `-m` legge un mapping `sorgente=destinazione`. Se la StorageClass non esiste sul destinazione, lo script chiede quale usare.

## Immagini

I registry si passano senza schema, solo hostname. I token OpenShift si passano con `SRC_TOKEN` e `DST_TOKEN`.

```bash
SRC_TOKEN="$(oc --context src-cluster whoami -t)" \
DST_TOKEN="$(oc --context dst-cluster whoami -t)" \
  ./scripts/copy-images.sh -s "$SRC_REGISTRY" -d "$DST_REGISTRY" my-project/my-app:1.0
```

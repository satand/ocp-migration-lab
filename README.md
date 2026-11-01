# ocp-migration-lab

Script per inventariare e copiare risorse tra due cluster OpenShift, da un bastion con `oc` già configurato.

Gli script di migrazione usano due context kubeconfig:

- `-s` cluster sorgente, oppure `SRC_CONTEXT`
- `-d` cluster destinazione, oppure `DST_CONTEXT`
- `-n` namespace; se omesso, è il progetto corrente del context sorgente

Il namespace deve già esistere sul cluster destinazione.

## Requisiti

- `oc` e `jq`
- `skopeo` per `copy-images.sh`
- `openssl` per l'analisi dei certificati sulle route

## Script

| Script | Cosa fa |
|---|---|
| `scripts/scan-namespace.sh` | Report di workload, Secret, ConfigMap, PVC, Service e Route di un namespace |
| `scripts/copy-images.sh` | Copia immagini tra i registry interni dei due cluster con `skopeo` |
| `scripts/migrate-pvc.sh` | Crea il PVC sul destinazione; con `-C` copia anche i dati |
| `scripts/migrate-cm.sh` | Copia una o più ConfigMap |
| `scripts/migrate-secret.sh` | Copia uno o più Secret; quelli gestiti dal cluster si saltano, salvo `-a` |
| `scripts/migrate-route.sh` | Copia Route e, se manca, il Service associato |

Ogni script ha l'help con `-h`.

## Scan

```bash
./scripts/scan-namespace.sh -s src-cluster -n my-project
./scripts/scan-namespace.sh -s src-cluster -n my-project -o report.json
```

Secret, ConfigMap e PVC sono divisi in `[BOUNDED]` e `[UNBOUNDED]`. Per le route con certificato esterno lo scan indica se l'hostname è coperto dal certificato e se hostname o SAN sono legati al dominio del cluster sorgente.

## Migrazione

```bash
./scripts/migrate-cm.sh -s src-cluster -d dst-cluster -n my-project app-config
./scripts/migrate-secret.sh -s src-cluster -d dst-cluster -n my-project db-creds
./scripts/migrate-pvc.sh -s src-cluster -d dst-cluster -n my-project -c thin-csi -C data
./scripts/migrate-route.sh -s src-cluster -d dst-cluster -n my-project web
```

`migrate-route.sh` migra una route con certificato esterno solo se il certificato non è scaduto, copre l'hostname della route e resta valido sul destinazione. Se l'hostname è quello generato da OpenShift, non viene copiato. Il riepilogo indica se aggiornare il DNS esterno.

Per i PVC, `-c` forza la StorageClass di destinazione e `-m` legge un mapping `sorgente=destinazione`. Se la StorageClass non esiste sul destinazione, lo script chiede quale usare.

## Immagini

I registry si passano senza schema, solo hostname. I token OpenShift si passano con `SRC_TOKEN` e `DST_TOKEN`.

```bash
SRC_TOKEN="$(oc --context src-cluster whoami -t)" \
DST_TOKEN="$(oc --context dst-cluster whoami -t)" \
  ./scripts/copy-images.sh -s "$SRC_REGISTRY" -d "$DST_REGISTRY" my-project/my-app:1.0
```

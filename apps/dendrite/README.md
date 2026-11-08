# Dendrite

> Ancien déploiement de test, remplacé par [Tuwunel](../tuwunel/README.md).
> Ces manifests ne sont plus la source de l'application Argo CD. Les volumes
> Dendrite restent conservés, mais ne sont pas utilisés par Tuwunel.

Serveur Matrix `matrix.muskeg.dev` : les comptes ont la forme
`@alice:matrix.muskeg.dev`. La fédération est active, mais l'inscription publique
et les comptes invités sont désactivés. Le nom du serveur et la clé de signature
sont des identités permanentes : ne pas les changer après la création des comptes.

## Déploiement

L'application root Argo CD découvre automatiquement les applications
[local-path](../../clusters/homelab/apps/local-path.yaml) et
[dendrite](../../clusters/homelab/apps/dendrite.yaml) une fois les changements
poussés sur `main`. Aucun changement à `bootstrap.sh` n'est nécessaire.

1. Dans le coffre 1Password `muskeg-platform`, créer un élément `dendrite` avec
   ces champs :

   | Champ | Contenu |
   |---|---|
   | `postgres-password` | Mot de passe aléatoire, par exemple `openssl rand -hex 32` |
   | `registration-shared-secret` | Une autre valeur `openssl rand -hex 32` |
   | `signing-key` | Le contenu complet du fichier généré ci-dessous, en conservant les sauts de ligne |

   Générer la clé une seule fois, hors de Git, dans un nouveau volume Docker
   temporaire. Si une clé existe déjà, la réutiliser au lieu de la régénérer :

   ```sh
   docker volume create muskeg-dendrite-key
   docker run --rm --mount type=volume,src=muskeg-dendrite-key,dst=/keys \
     --entrypoint /usr/bin/generate-keys \
     ghcr.io/element-hq/dendrite-monolith:v0.15.2 \
     --private-key /keys/matrix_key.pem
   ```

   Copier le fichier dans `_out/` (ignoré par Git), puis importer son contenu
   dans le champ `signing-key` de 1Password par un moyen local sécurisé :

   ```sh
   mkdir -p _out
   docker create --name muskeg-dendrite-key-export \
     --mount type=volume,src=muskeg-dendrite-key,dst=/keys,readonly \
     busybox:1.37.0 true
   docker cp muskeg-dendrite-key-export:/keys/matrix_key.pem _out/dendrite_matrix_key.pem
   docker rm muskeg-dendrite-key-export
   ```

   Ne pas afficher la clé dans des logs, la mettre dans Git, ni la transmettre
   dans le chat. Après avoir vérifié la sauvegarde dans 1Password, supprimer
   uniquement ce volume temporaire et la copie locale :

   ```sh
   docker volume rm muskeg-dendrite-key
   rm _out/dendrite_matrix_key.pem
   ```

2. Vérifier que le DNS Cloudflare de `matrix.muskeg.dev` pointe vers
   `b9946c2a-478d-4b59-bef1-c846a6a6d11c.cfargotunnel.com` (CNAME proxifié).
   Si un CNAME wildcard couvre déjà ce nom, aucun nouvel enregistrement n'est
   nécessaire. Le tunnel existant couvre `*.muskeg.dev` et passe en HTTPS vérifié
   par Traefik avec son certificat wildcard.
3. Ne pas appliquer Cloudflare Access, de challenge interactif ou de cache aux
   API Matrix et aux chemins `/.well-known/matrix/*` sur cet hostname :
   les clients et les autres serveurs doivent pouvoir les appeler sans navigateur.
4. Pousser les manifests sur `main`, puis attendre que les applications Argo CD,
   l'ExternalSecret et les pods soient sains :

   ```sh
   kubectl get storageclass local-path
   kubectl -n dendrite get externalsecret,pvc,pods
   kubectl -n dendrite wait --for=condition=Ready externalsecret/dendrite-config --timeout=5m
   kubectl -n dendrite rollout status deployment/dendrite-postgres --timeout=10m
   kubectl -n dendrite rollout status deployment/dendrite --timeout=10m
   ```

   Les applications se synchronisent indépendamment : les PVC peuvent rester
   en attente tant que le provisioner n'est pas prêt, et les pods tant que
   l'ExternalSecret n'a pas créé le Secret. Consulter leurs événements en cas d'échec.

## Comptes et vérification

Créer le premier administrateur depuis le pod, avec saisie interactive du mot
de passe :

```sh
kubectl -n dendrite exec -it deployment/dendrite -- \
  /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
  --username alice --admin
```

Omettre `--admin` pour les autres comptes. Cet outil affiche un jeton d'accès :
ne pas enregistrer sa sortie dans des logs partagés.

Seuls `/_matrix` et `/.well-known/matrix` sont exposés par l'Ingress. Les API
administratives `/_dendrite` et `/_synapse` restent internes.

```sh
curl -fsS https://matrix.muskeg.dev/_matrix/client/versions
curl -fsS https://matrix.muskeg.dev/.well-known/matrix/client
curl -fsS https://matrix.muskeg.dev/.well-known/matrix/server
curl -fsS https://matrix.muskeg.dev/_matrix/federation/v1/version
curl -fsS https://matrix.muskeg.dev/_matrix/key/v2/server
```

La découverte serveur doit retourner
`{"m.server":"matrix.muskeg.dev:443"}` : la fédération utilise donc le tunnel sur
443, pas un port public 8448. La découverte client doit annoncer
`https://matrix.muskeg.dev`. Vérifier aussi la fédération avec un autre serveur
Matrix avant de considérer le déploiement public comme terminé.

## Stockage et sauvegardes

Le provisioner Rancher utilise `/var/mnt/local-path-provisioner` sur un volume
utilisateur Talos dédié. Ajouter un disque virtuel vierge de 50 GiB à chacune des
VM `shokunin1`, `shokunin2` et `shokunin3` dans Proxmox, sans modifier les disques
système. Chaque VM doit avoir un seul disque non système éligible.

Vérifier que Talos voit les nouveaux disques avant d'appliquer le patch :

```sh
talosctl --talosconfig _out/talosconfig \
  --nodes 192.168.1.41,192.168.1.42,192.168.1.43 get disks
```

Le patch sélectionne un disque non système et provisionne une partition d'au
moins 40 GiB, qui peut grandir pour occuper l'espace disponible. Il est inclus
dans les futures configurations générées par le bootstrap. Pour les nodes déjà
installés, appliquer uniquement ce patch après vérification des disques vierges :

```sh
talosctl --talosconfig _out/talosconfig \
  --nodes 192.168.1.41,192.168.1.42,192.168.1.43 \
  patch mc --patch @talos/patches/local-storage.yaml
talosctl --talosconfig _out/talosconfig \
  --nodes 192.168.1.41,192.168.1.42,192.168.1.43 \
  get volumestatus u-local-path-provisioner
talosctl --talosconfig _out/talosconfig \
  --nodes 192.168.1.41,192.168.1.42,192.168.1.43 \
  get mountstatus u-local-path-provisioner
```

Attendre que les volumes soient `ready` et montés. Le provisioner retente
automatiquement les PVC en attente. Sans ce volume, le répertoire parent
`/var/mnt` est en lecture seule et les helper pods échouent avec `FailedMount`.

Ses helper pods
utilisent des montages hostPath dans le namespace dédié `local-path-storage`,
qui autorise ces pods via la politique de sécurité `privileged`.

Deux PVC utilisent explicitement `local-path` : 10 Gi pour PostgreSQL et 20 Gi
pour les médias et JetStream. Ils peuvent être placés sur des nodes différents.
Les volumes sont liés à leurs nodes : aucun basculement automatique si un node
est indisponible. Les pods sont uniques et utilisés avec la stratégie `Recreate`.
Les tailles déclarées ne sont pas des quotas avec local-path : surveiller
l'espace disque réel, notamment lors de la fédération avec des salons publics.

La StorageClass utilise `Retain` et les PVC sont protégés contre la suppression
par Argo CD. Supprimer une application ne doit pas effacer les données.
Un PVC supprimé manuellement laisse toutefois un PV `Released`, qui doit être
récupéré explicitement : un nouveau PVC ne reprend pas automatiquement ces données.
Ne pas supprimer le namespace `dendrite` pour effectuer une simple mise à jour.

Sauvegarder hors du cluster Proxmox :

- PostgreSQL avec `pg_dump`, par exemple :

  ```sh
  mkdir -p _out/backups
  kubectl -n dendrite exec deployment/dendrite-postgres -- \
    pg_dump -U dendrite -d dendrite -Fc > _out/backups/dendrite.dump
  ```

- Le contenu du PVC `dendrite-data`, y compris les médias et JetStream, via un
  outil de sauvegarde de volumes ou une sauvegarde du disque de la VM Talos.
- La clé de signature et les autres secrets dans 1Password, avec une stratégie
  de récupération indépendante de ce cluster.

Pour une sauvegarde cohérente des deux volumes, arrêter temporairement Dendrite
en désactivant l'auto-sync Argo CD avant de réduire ses réplicas à zéro ; sinon
`selfHeal` le redémarre. Réactiver le déploiement et l'auto-sync après la sauvegarde.
Tester régulièrement une restauration avec la même clé de signature.
Les snapshots Proxmox sur le même stockage ne remplacent pas une sauvegarde externe.

## Changements de configuration

External Secrets actualise le Secret toutes les heures, mais Dendrite charge sa
configuration au démarrage. Après une modification de configuration ou du secret
d'inscription, attendre la synchronisation du Secret puis exécuter :

```sh
kubectl -n dendrite rollout restart deployment/dendrite
kubectl -n dendrite rollout status deployment/dendrite --timeout=10m
```

Changer `postgres-password` dans 1Password ne change pas le mot de passe d'une base
déjà initialisée : coordonner un `ALTER ROLE` dans PostgreSQL, la mise à jour de
1Password et le redémarrage des deux deployments. Ne jamais remplacer la clé de
signature par une nouvelle clé pour résoudre un problème de démarrage.

Dendrite ne fournit pas ici de service TURN ni d'interface web Element.

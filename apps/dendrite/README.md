# Dendrite

Serveur Matrix `matrix.muskeg.dev` : les comptes ont la forme
`@alice:matrix.muskeg.dev`. La federation est active, mais l'inscription publique
et les comptes invites sont desactives. Le nom du serveur et la cle de signature
sont des identites permanentes : ne pas les changer apres la creation des comptes.

## Deploiement

L'application root Argo CD decouvre automatiquement les applications
[local-path](../../clusters/homelab/apps/local-path.yaml) et
[dendrite](../../clusters/homelab/apps/dendrite.yaml) une fois les changements
pousses sur `main`. Aucun changement a `bootstrap.sh` n'est necessaire.

1. Dans le coffre 1Password `muskeg-platform`, creer un element `dendrite` avec
   ces champs :

   | Champ | Contenu |
   |---|---|
   | `postgres-password` | Mot de passe aleatoire, par exemple `openssl rand -hex 32` |
   | `registration-shared-secret` | Une autre valeur `openssl rand -hex 32` |
   | `signing-key` | Le contenu complet du fichier genere ci-dessous, en conservant les sauts de ligne |

   Generer la cle une seule fois, hors de Git, dans un nouveau volume Docker
   temporaire. Si une cle existe deja, la reutiliser au lieu de la regenerer :

   ```sh
   docker volume create muskeg-dendrite-key
   docker run --rm --mount type=volume,src=muskeg-dendrite-key,dst=/keys \
     --entrypoint /usr/bin/generate-keys \
     ghcr.io/element-hq/dendrite-monolith:v0.15.2 \
     --private-key /keys/matrix_key.pem
   ```

   Copier le fichier dans `_out/` (ignore par Git), puis importer son contenu
   dans le champ `signing-key` de 1Password par un moyen local securise :

   ```sh
   mkdir -p _out
   docker create --name muskeg-dendrite-key-export \
     --mount type=volume,src=muskeg-dendrite-key,dst=/keys,readonly \
     busybox:1.37.0 true
   docker cp muskeg-dendrite-key-export:/keys/matrix_key.pem _out/dendrite_matrix_key.pem
   docker rm muskeg-dendrite-key-export
   ```

   Ne pas afficher la cle dans des logs, la mettre dans Git, ni la transmettre
   dans le chat. Apres avoir verifie la sauvegarde dans 1Password, supprimer
   uniquement ce volume temporaire et la copie locale :

   ```sh
   docker volume rm muskeg-dendrite-key
   rm _out/dendrite_matrix_key.pem
   ```

2. Verifier que le DNS Cloudflare de `matrix.muskeg.dev` pointe vers
   `b9946c2a-478d-4b59-bef1-c846a6a6d11c.cfargotunnel.com` (CNAME proxifie).
   Si un CNAME wildcard couvre deja ce nom, aucun nouvel enregistrement n'est
   necessaire. Le tunnel existant couvre `*.muskeg.dev` et passe en HTTPS verifie
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

   Les applications se synchronisent independamment : les PVC peuvent rester
   en attente tant que le provisioner n'est pas pret, et les pods tant que
   l'ExternalSecret n'a pas cree le Secret. Consulter leurs events en cas d'echec.

## Comptes et verification

Creer le premier administrateur depuis le pod, avec saisie interactive du mot
de passe :

```sh
kubectl -n dendrite exec -it deployment/dendrite -- \
  /usr/bin/create-account --config /etc/dendrite/dendrite.yaml \
  --username alice --admin
```

Omettre `--admin` pour les autres comptes. Cet outil affiche un jeton d'acces :
ne pas enregistrer sa sortie dans des logs partages.

Seuls `/_matrix` et `/.well-known/matrix` sont exposes par l'Ingress. Les API
administratives `/_dendrite` et `/_synapse` restent internes.

```sh
curl -fsS https://matrix.muskeg.dev/_matrix/client/versions
curl -fsS https://matrix.muskeg.dev/.well-known/matrix/client
curl -fsS https://matrix.muskeg.dev/.well-known/matrix/server
curl -fsS https://matrix.muskeg.dev/_matrix/federation/v1/version
curl -fsS https://matrix.muskeg.dev/_matrix/key/v2/server
```

La decouverte serveur doit retourner
`{"m.server":"matrix.muskeg.dev:443"}` : la federation utilise donc le tunnel sur
443, pas un port public 8448. La decouverte client doit annoncer
`https://matrix.muskeg.dev`. Verifier aussi la federation avec un autre serveur
Matrix avant de considerer le deploiement public comme termine.

## Stockage et sauvegardes

Le provisioner Rancher utilise `/var/mnt/local-path-provisioner` sur les disques
Talos. Il n'a pas besoin de modifier la configuration Talos. Ses helper pods
utilisent des montages hostPath dans le namespace dedie `local-path-storage`,
qui autorise ces pods via la politique de securite `privileged`.

Deux PVC utilisent explicitement `local-path` : 10 Gi pour PostgreSQL et 20 Gi
pour les medias et JetStream. Ils peuvent etre places sur des nodes differents.
Les volumes sont lies a leurs nodes : aucun basculement automatique si un node
est indisponible. Les pods sont uniques et utilises avec la strategie `Recreate`.
Les tailles declarees ne sont pas des quotas avec local-path : surveiller
l'espace disque reel, notamment lors de la federation avec des salons publics.

La StorageClass utilise `Retain` et les PVC sont proteges contre la suppression
par Argo CD. Supprimer une application ne doit pas effacer les donnees.
Un PVC supprime manuellement laisse toutefois un PV `Released`, qui doit etre
recupere explicitement : un nouveau PVC ne reprend pas automatiquement ces donnees.
Ne pas supprimer le namespace `dendrite` pour effectuer une simple mise a jour.

Sauvegarder hors du cluster Proxmox :

- PostgreSQL avec `pg_dump`, par exemple :

  ```sh
  mkdir -p _out/backups
  kubectl -n dendrite exec deployment/dendrite-postgres -- \
    pg_dump -U dendrite -d dendrite -Fc > _out/backups/dendrite.dump
  ```

- Le contenu du PVC `dendrite-data`, y compris les medias et JetStream, via un
  outil de sauvegarde de volumes ou une sauvegarde du disque de la VM Talos.
- La cle de signature et les autres secrets dans 1Password, avec une strategie
  de recuperation independante de ce cluster.

Pour une sauvegarde coherente des deux volumes, arreter temporairement Dendrite
en desactivant l'auto-sync Argo CD avant de reduire ses replicas a zero ; sinon
`selfHeal` le redemarre. Reactiver le deploiement et l'auto-sync apres la sauvegarde.
Tester regulierement une restauration avec la meme cle de signature.
Les snapshots Proxmox sur le meme stockage ne remplacent pas une sauvegarde externe.

## Changements de configuration

External Secrets actualise le Secret toutes les heures, mais Dendrite charge sa
configuration au demarrage. Apres une modification de configuration ou du secret
d'inscription, attendre la synchronisation du Secret puis executer :

```sh
kubectl -n dendrite rollout restart deployment/dendrite
kubectl -n dendrite rollout status deployment/dendrite --timeout=10m
```

Changer `postgres-password` dans 1Password ne change pas le mot de passe d'une base
deja initialisee : coordonner un `ALTER ROLE` dans PostgreSQL, la mise a jour de
1Password et le redemarrage des deux deployments. Ne jamais remplacer la cle de
signature par une nouvelle cle pour resoudre un probleme de demarrage.

Dendrite ne fournit pas ici de service TURN ni d'interface web Element.

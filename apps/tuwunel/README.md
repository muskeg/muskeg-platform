# Tuwunel

Serveur Matrix `matrix.muskeg.dev`, avec une base RocksDB embarquée et le
Simplified Sliding Sync (MSC4186) utilisé par Element X. Aucun PostgreSQL ni
proxy Sliding Sync séparé n'est nécessaire.

Version épinglée : **v1.9.4**. Références :
[projet](https://tuwunel.chat),
[versions](https://github.com/matrix-construct/tuwunel/releases),
[configuration](https://matrix-construct.github.io/tuwunel/configuration.html).
Les fonctionnalités annoncées ne remplacent pas les tests avec les clients réels.

## Déploiement

L'application Argo CD, le namespace, le deployment, le service et l'Ingress
s'appellent **`tuwunel`**. Le DNS, le tunnel, Traefik et le certificat wildcard
existants servent `matrix.muskeg.dev`. Un enregistrement DNS proxifié doit
pointer vers le tunnel ; les API Matrix ne doivent pas être protégées par
Cloudflare Access ou des challenges interactifs.

Créer le secret 1Password et préparer le stockage avant de publier sur `main`.
L'application root Argo CD découvre automatiquement
[l'application Tuwunel](../../clusters/homelab/apps/tuwunel.yaml).

## Secrets et stockage

Créer un élément **`tuwunel`** dans le coffre 1Password **`muskeg-platform`**
avec le champ **`registration-shared-secret`**, contenant un secret aléatoire
fort (par exemple `openssl rand -hex 32`). Créer cet élément avant la synchronisation
Argo CD : External Secrets lit `tuwunel/registration-shared-secret`.

Les champs `signing-key` et `postgres-password` ne sont pas nécessaires dans
l'élément Tuwunel. Le ClusterSecretStore Kubernetes `onepassword` reste partagé
entre les applications et ne change pas.

**Tuwunel génère sa propre clé de signature dans sa base** au premier démarrage.
Ne pas importer une clé externe, ne pas réinitialiser le volume après mise en
service, et sauvegarder l'ensemble du volume.

Le PVC utilise `local-path` et les volumes utilisateurs Talos existants ; aucune
nouvelle modification Proxmox/Talos n'est nécessaire. Pour un nouveau cluster,
suivre les [prérequis de stockage](#prérequis-de-stockage).
Un seul pod utilise le volume, avec la stratégie `Recreate`. Le volume est lié
au node et n'est pas répliqué. Les 20 Gi déclarés ne sont pas un quota effectif :
surveiller l'espace disponible.
La StorageClass utilise `Retain` et le PVC est protégé par `Prune=false,Delete=false`.

### Prérequis de stockage

Rancher local-path utilise `/var/mnt/local-path-provisioner`, un volume
utilisateur Talos dédié. Chaque VM `shokunin1`, `shokunin2` et `shokunin3` doit
avoir un disque virtuel vierge de 50 GiB en plus du disque système.
Le [patch Talos](../../talos/patches/local-storage.yaml) sélectionne un disque
non système, provisionne au moins 40 GiB et peut grandir dans l'espace disponible.
Il est inclus dans les configurations générées par le bootstrap.

Pour des nodes existants, vérifier qu'un seul disque non système vierge est
éligible par VM, puis appliquer uniquement le patch :

```sh
talosctl --talosconfig _out/talosconfig \
  --nodes 192.168.1.41,192.168.1.42,192.168.1.43 get disks
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

Attendre que les volumes soient `ready` et montés. Sans eux, `/var/mnt` est
en lecture seule pour kubelet et les helper pods échouent avec `FailedMount`.
Ces helper pods utilisent des montages hostPath dans le namespace dédié
`local-path-storage`, autorisés par la politique de sécurité `privileged`.

## Premier administrateur

L'inscription publique reste **désactivée**. Les comptes sont créés par
l'endpoint interne d'inscription à secret partagé ; `/_synapse` et les autres
API administratives ne sont pas exposés par l'Ingress.

Dans un terminal :

```sh
kubectl -n tuwunel port-forward --address 127.0.0.1 service/tuwunel 18008:8008
```

Dans un autre terminal, depuis la racine du dépôt :

```sh
python3 bootstrap/matrix-account.py raph --admin
```

Le script demande le mot de passe, lit le secret via `kubectl`, et ne publie ni
mot de passe ni jeton d'accès. Omettre `--admin` pour un compte ordinaire.
Arrêter le port-forward après utilisation.

Se connecter dans Element X avec `https://matrix.muskeg.dev` et le nouveau
compte `@raph:matrix.muskeg.dev`. L'administrateur reçoit une invitation au salon
administratif. La commande `!admin --help` y liste les commandes disponibles,
notamment `!admin users` et `!admin server`.
Ne pas démarrer un second processus Tuwunel sur la même base via `kubectl exec` :
le verrou RocksDB empêche les accès concurrents.

## Vérification

```sh
kubectl -n argocd get application tuwunel
kubectl -n tuwunel get pods,pvc,externalsecret
kubectl -n tuwunel rollout status deployment/tuwunel --timeout=10m
curl -fsS https://matrix.muskeg.dev/_matrix/client/versions
curl -fsS https://matrix.muskeg.dev/.well-known/matrix/client
curl -fsS https://matrix.muskeg.dev/.well-known/matrix/server
curl -fsS https://matrix.muskeg.dev/_matrix/federation/v1/version
```

Les versions doivent annoncer `org.matrix.simplified_msc3575: true`.
Le pod désactive `enableServiceLinks` : sinon Kubernetes injecte une variable
`TUWUNEL_PORT=tcp://…` pour le service du même nom, qui entre en conflit avec
la configuration Tuwunel. La résolution DNS des services reste disponible.
La découverte serveur doit indiquer `matrix.muskeg.dev:443`. Tester une
connexion dans Element X, un message chiffré, un téléversement de média, un
second appareil et un nouveau salon fédéré. Tester également FluffyChat et
le troisième client souhaité : leur compatibilité exacte dépend des versions.

Le support protocolaire MatrixRTC ne fournit pas à lui seul un service d'appels :
aucun TURN, LiveKit/SFU, service JWT ou interface Element Web n'est déployé ici.
L'authentification reste par mot de passe ; MAS/OIDC n'est pas configuré.

## Maintenance et sauvegardes

Sauvegarder **hors du cluster Proxmox** l'ensemble de `tuwunel-data` :
base, médias et identité de signature. Une copie brute doit se faire avec
Tuwunel arrêté ; désactiver l'auto-sync Argo CD avant de réduire le deployment
à zéro, sinon `selfHeal` le relance. Réactiver ensuite le deployment et l'auto-sync.
Ne pas remplacer cette sauvegarde par les seuls secrets 1Password.
Tester une restauration ; voir les
[instructions amont](https://matrix-construct.github.io/tuwunel/backups.html).

Les changements du ConfigMap redémarrent le pod grâce au hash Kustomize.
Après modification du secret dans 1Password, attendre la synchronisation de
l'ExternalSecret puis redémarrer Tuwunel pour garantir son rechargement :

```sh
kubectl -n tuwunel rollout restart deployment/tuwunel
```

Faire une sauvegarde avant chaque changement de version. Les migrations de
base peuvent empêcher un retour à une ancienne version. Le délai d'arrêt
est de 30 minutes pour permettre un arrêt propre ; ne pas forcer la suppression
du pod pendant une migration.

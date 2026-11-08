# Tuwunel

Serveur Matrix `matrix.muskeg.dev`, avec une base RocksDB embarquée et le
Simplified Sliding Sync (MSC4186) utilisé par Element X. Aucun PostgreSQL ni
proxy Sliding Sync séparé n'est nécessaire.

Version épinglée : **v1.9.4**. Références :
[projet](https://tuwunel.chat),
[versions](https://github.com/matrix-construct/tuwunel/releases),
[configuration](https://matrix-construct.github.io/tuwunel/configuration.html).
Les fonctionnalités annoncées ne remplacent pas les tests avec les clients réels.

## Remplacement de Dendrite

Il s'agit d'une **réinstallation de test**, pas d'une conversion de base.
Les comptes, appareils et salons Dendrite ne sont pas importés. Déconnecter les
anciens clients, recréer les comptes et repartir sur de nouveaux salons.
Ne pas tenter de récupérer les anciennes sessions ou sauvegardes de chiffrement
dans cette nouvelle base.

Le même nom de serveur est conservé parce que les données de test sont jetables.
Si des salons fédérés existent déjà, les serveurs distants peuvent conserver
l'ancienne identité et les anciens événements : ne pas tenter de réutiliser ces
salons. Pour une migration de production, préférer un nouveau nom de serveur ou
un plan de migration explicite.

L'application Argo CD, le namespace, le deployment, le service et l'Ingress
s'appellent **`tuwunel`**. Le DNS, le tunnel, Traefik et le certificat wildcard
restent inchangés.

Après publication sur `main`, l'application root supprime l'ancienne application
`dendrite` et crée `tuwunel`. Le finalizer de l'ancienne application supprime ses
deployments, services, Ingress et secrets gérés. Les PVC `dendrite-data` et
`postgres-data` restent dans le namespace `dendrite` grâce à `Delete=false` ;
ne pas supprimer ce namespace. Le nouveau PVC **`tuwunel-data`**, dans le
namespace `tuwunel`, est indépendant.

Les deux applications se réconcilient indépendamment : une interruption ou
un chevauchement temporaire des routes est possible pendant la bascule.
Attendre la disparition de l'ancienne application et de son Ingress avant de
créer les nouveaux comptes :

```sh
kubectl -n argocd wait --for=delete application/dendrite --timeout=10m
kubectl -n dendrite get ingress
kubectl -n tuwunel rollout status deployment/tuwunel --timeout=10m
```

Pour revenir en arrière avant de commencer à utiliser Tuwunel, retirer
l'application Tuwunel du dépôt et restaurer l'ancien manifeste d'application
Dendrite avec le chemin `apps/dendrite` et le namespace `dendrite`, puis
republier. Les anciennes données et l'élément 1Password doivent rester présents.
Les nouvelles données Tuwunel ne seront pas lisibles par Dendrite.

## Secrets et stockage

Créer un élément **`tuwunel`** dans le coffre 1Password **`muskeg-platform`**
avec le champ **`registration-shared-secret`**, contenant un secret aléatoire
fort (par exemple `openssl rand -hex 32`). Il est possible de copier la valeur
existante depuis l'élément Dendrite. Créer cet élément avant la synchronisation
Argo CD : External Secrets lit `tuwunel/registration-shared-secret`.

L'ancien élément `dendrite` est indépendant et ne sert plus qu'à un éventuel
retour arrière ; ne pas le renommer si cette possibilité doit être conservée.
Les champs `signing-key` et `postgres-password` ne sont pas nécessaires dans
l'élément Tuwunel. Le ClusterSecretStore Kubernetes `onepassword` reste partagé
entre les applications et ne change pas.

**Tuwunel génère sa propre clé de signature dans sa base** au premier démarrage.
Ne pas importer le PEM Dendrite, ne pas réinitialiser le volume après mise en
service, et sauvegarder l'ensemble du volume.

Le PVC utilise `local-path` et les volumes utilisateurs Talos existants ; aucune
nouvelle modification Proxmox/Talos n'est nécessaire. Pour un nouveau cluster,
suivre les [prérequis de stockage](../dendrite/README.md#stockage-et-sauvegardes).
Un seul pod utilise le volume, avec la stratégie `Recreate`. Le volume est lié
au node et n'est pas répliqué. Les 20 Gi déclarés ne sont pas un quota effectif :
surveiller l'espace disponible, y compris celui occupé par les anciens PVC.
La StorageClass utilise `Retain` et le PVC est protégé par `Prune=false,Delete=false`.

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

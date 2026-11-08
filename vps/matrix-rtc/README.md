# MatrixRTC sur le VPS

LiveKit transporte les médias ; `lk-jwt-service` autorise les participants
Matrix ; Caddy sert HTTPS/WebSocket derrière Cloudflare. Cette stack Docker
Compose tourne sur Oracle Linux 9.7 ARM64, **pas dans Argo CD**.
Les trois images épinglées existent pour `linux/arm64`.

Le VPS dispose de 6 GiB de RAM au total et héberge d'autres services.
Environ 4 GiB sont disponibles au moment du dimensionnement ; ce n'est pas
une réservation. LiveKit est limité à 2 GiB, JWT et Caddy à 256 MiB chacun,
soit un plafond cumulé de 2,5 GiB pour cette stack. Préserver de la marge pour
le système et les variations de consommation des autres services.

L'objectif est de supporter jusqu'à 10 participants simultanés, sans garantie
de capacité avant test. La capacité dépend aussi des CPU réellement alloués,
des flux vidéo et de la bande passante. Tester progressivement 2, puis 5,
puis 10 participants avec vidéo, en surveillant CPU, mémoire, réseau, qualité
des appels et impact sur les autres services. Les limites mémoire ne protègent
pas contre la contention CPU ou réseau. Pas d'enregistrement, de transcodage
ni de Redis distribué.

## Réseau et DNS

Créer un enregistrement Cloudflare **A**, nom **`rtc`**, avec l'adresse IPv4
publique du VPS, **proxifié**. Il pointe vers le VPS, pas vers le tunnel
du homelab. Ne pas créer d'AAAA si le VPS ne sert pas ce service en IPv6.
Activer WebSockets, exclure cet hostname du cache, de Cloudflare Access et des
challenges interactifs. Utiliser **Full (strict)** pour la connexion à l'origine.

Le proxy masque l'origine pour HTTPS uniquement. Les clients reçoivent l'IP
publique du VPS pour WebRTC : **l'IP média n'est pas cachée**.

Ouvrir dans les Security Lists/NSG Oracle Cloud et le pare-feu Oracle Linux :

| Port entrant | Usage |
|---|---|
| TCP 443 | HTTPS/WebSocket Caddy |
| TCP 7881 | Repli WebRTC TCP direct |
| UDP 50100–50200 | Médias WebRTC directs |
| UDP 50300–50400 | Allocations du relais TURN |
| UDP 3478 | TURN intégré LiveKit |

Ne pas exposer TCP 7880 ou 8081 : les services écoutent sur `127.0.0.1`.
Le service existant sur 8080 n'est pas modifié. Vérifier les règles existantes
avant de changer le pare-feu ; conserver l'accès SSH.

Si `firewalld` gère le pare-feu, identifier d'abord la zone de l'interface
publique avec `sudo firewall-cmd --get-active-zones`, puis appliquer à cette
zone (remplacer `ZONE`) :

```sh
sudo firewall-cmd --permanent --zone=ZONE --add-port=443/tcp
sudo firewall-cmd --permanent --zone=ZONE --add-port=7881/tcp
sudo firewall-cmd --permanent --zone=ZONE --add-port=50100-50200/udp
sudo firewall-cmd --permanent --zone=ZONE --add-port=50300-50400/udp
sudo firewall-cmd --permanent --zone=ZONE --add-port=3478/udp
sudo firewall-cmd --reload
```

Ne pas installer/activer firewalld par-dessus un autre gestionnaire de règles.
Les règles sortantes doivent permettre HTTPS vers les homeservers Matrix,
DNS et STUN pour découvrir l'IP publique. Vérifier que LiveKit annonce
l'adresse IPv4 publique attendue dans ses logs, pas une adresse privée.

TURN/UDP et WebRTC TCP sont configurés. **TURN/TLS sur 443 n'est pas fourni** :
certains réseaux d'entreprise peuvent donc encore bloquer les appels.
L'ajouter nécessiterait un point d'entrée TLS/L4 adapté ou une autre IP publique.

## Secrets et certificat d'origine

Sur le VPS, cloner le dépôt et se placer dans `vps/matrix-rtc`.
Docker Compose v2 ou supérieur doit être disponible :

```sh
docker compose version
mkdir -p secrets
chmod 700 secrets
```

Dans Cloudflare, créer un **Origin Certificate** couvrant `rtc.muskeg.dev`.
Placer le certificat complet dans `secrets/origin-cert.pem` et la clé privée
dans `secrets/origin-key.pem`. Un certificat Origin CA n'est pas reconnu par
les navigateurs en accès direct : il est destiné à Cloudflare Full (strict).
Surveiller sa date d'expiration et prévoir son renouvellement.

Générer une clé API LiveKit et un secret indépendants, dans un fichier local :

```sh
umask 077
key="$(openssl rand -hex 10)"
secret="$(openssl rand -hex 32)"
printf '%s: %s\n' "$key" "$secret" > secrets/livekit-keys.yaml
unset key secret
sudo chown -R 10001:10001 secrets
sudo chmod 750 secrets
sudo chmod 640 secrets/livekit-keys.yaml secrets/origin-cert.pem secrets/origin-key.pem
```

Le fichier contient une seule paire YAML `clé: secret`, partagée entre LiveKit
et JWT. Sauvegarder les secrets dans un élément 1Password **`matrix-rtc`** ;
ils sont indépendants du secret d'inscription Tuwunel.
Ne jamais les committer ni les transmettre dans le chat.

Les bind mounts utilisent les labels SELinux `z`/`Z` pour Oracle Linux.
Ne pas désactiver SELinux ; si un montage est refusé, consulter les AVC.

## Déploiement et validation

```sh
docker compose config --quiet
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=80 livekit jwt caddy
```

Le service JWT inclut son healthcheck. LiveKit et Caddy doivent rester actifs
sans boucle de redémarrage. Vérifier les listeners :

```sh
sudo ss -lntup
curl -fsS http://127.0.0.1:7880/
curl -fsS https://rtc.muskeg.dev/healthz
```

Pour valider le certificat d'origine localement, télécharger le certificat
racine officiel Cloudflare Origin CA correspondant et utiliser `curl --cacert`
avec `--resolve rtc.muskeg.dev:443:127.0.0.1`. Ne pas contourner la vérification TLS.

Une requête non authentifiée sous `/livekit/rtc/validate` doit atteindre
LiveKit et retourner HTTP 401 faute de jeton, pas une erreur Cloudflare 52x.
La santé HTTP seule ne valide pas les médias UDP.

## Activation dans Tuwunel

**Déployer et vérifier le VPS avant d'activer la découverte dans le homelab.**
Dans [tuwunel.toml](../../apps/tuwunel/tuwunel.toml), sous `[global.well_known]`,
décommenter :

```toml
livekit_url = "https://rtc.muskeg.dev"
```

Publier sur `main` ; Argo CD redémarre Tuwunel via le hash du ConfigMap.
Puis vérifier les deux surfaces de découverte :

```sh
curl -fsS https://matrix.muskeg.dev/.well-known/matrix/client
curl -fsS https://matrix.muskeg.dev/_matrix/client/unstable/org.matrix.msc4143/rtc/transports
```

Elles doivent annoncer le service `https://rtc.muskeg.dev`. Se reconnecter
dans Element X si nécessaire, puis tester un appel entre deux appareils,
dont un sur réseau mobile. Vérifier audio, vidéo et un participant fédéré.
Seuls les utilisateurs de `matrix.muskeg.dev` peuvent créer automatiquement
des salles LiveKit ; les autres peuvent rejoindre celles déjà créées.

Le mode utilisé suit le guide Tuwunel avec le service JWT autonome.
La version JWT épinglée avertit que ce mode est déprécié : elle valide
l'identité OpenID, mais ne vérifie pas l'appartenance au salon dans ce mode.
Ne pas élargir `LIVEKIT_FULL_ACCESS_HOMESERVERS` à `*`. Pour une intégration
avec contrôle d'appartenance et les nouvelles API déléguées, une configuration
d'application service supplémentaire serait nécessaire ; elle n'est pas
configurée ici. MAS n'est pas nécessaire.
Les membres de la même conférence doivent partager le même focus LiveKit.

## Maintenance

Sauvegarder hors du VPS les secrets et la configuration. Cette stack ne stocke
pas les messages Matrix ; leur sauvegarde reste celle du volume Tuwunel.
Une mise à jour ou un redémarrage LiveKit interrompt les appels en cours.
Surveiller RAM, CPU, trafic réseau, expiration du certificat et état des services.
Les logs peuvent contenir des identifiants Matrix : limiter leur accès.

Références :
[MatrixRTC Tuwunel](https://matrix-construct.github.io/tuwunel/calls/matrix_rtc.html),
[LiveKit](https://docs.livekit.io/transport/self-hosting/deployment/),
[service JWT](https://github.com/element-hq/lk-jwt-service).

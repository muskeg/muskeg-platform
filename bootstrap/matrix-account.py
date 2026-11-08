#!/usr/bin/env python3
import argparse
import base64
import getpass
import hashlib
import hmac
import json
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def request_json(url, data=None):
    request = Request(
        url,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type": "application/json"},
    )
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(
        description="Créer un compte Matrix via un port-forward local vers Tuwunel."
    )
    parser.add_argument("username", help="Nom local du compte, sans @ ni domaine")
    parser.add_argument("--admin", action="store_true")
    args = parser.parse_args()
    if not args.username or any(char in args.username for char in "@:\x00"):
        parser.error("Le nom doit être un localpart Matrix, sans @, : ou caractère nul.")
    password = getpass.getpass("Mot de passe : ")
    if not password or "\x00" in password:
        parser.error("Le mot de passe doit être non vide et sans caractère nul.")
    if password != getpass.getpass("Confirmer le mot de passe : "):
        parser.error("Les mots de passe ne correspondent pas.")

    try:
        result = subprocess.run(
            ["kubectl", "-n", "tuwunel", "get", "secret",
             "tuwunel-registration", "-o", "json"],
            capture_output=True, text=True, check=True,
        )
        secret = base64.b64decode(
            json.loads(result.stdout)["data"]["registration-shared-secret"],
            validate=True,
        ).strip()
        if not secret:
            raise ValueError("Le secret d'inscription est vide.")
        url = "http://127.0.0.1:18008/_synapse/admin/v1/register"
        nonce = request_json(url)["nonce"]
        message = "\x00".join(
            [nonce, args.username, password, "admin" if args.admin else "notadmin"]
        ).encode()
        account = request_json(url, {
            "nonce": nonce,
            "username": args.username,
            "password": password,
            "admin": args.admin,
            "mac": hmac.new(secret, message, hashlib.sha1).hexdigest(),
        })
        print(f"Compte créé : {account['user_id']}")
    except subprocess.CalledProcessError as error:
        print(f"Impossible de lire le secret Kubernetes : {error.stderr.strip()}", file=sys.stderr)
        return 1
    except HTTPError as error:
        print(f"Création refusée : HTTP {error.code}. Consulter les logs Tuwunel.", file=sys.stderr)
        return 1
    except URLError as error:
        print(f"Connexion impossible : {error.reason}. Vérifier le port-forward.", file=sys.stderr)
        return 1
    except (ValueError, KeyError) as error:
        print(f"Réponse ou secret invalide : {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

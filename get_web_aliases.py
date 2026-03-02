#!/usr/bin/env python3
"""
ISPConfig API Script - Web Aliase auslesen

Verbindet sich mit der ISPConfig REST/JSON API und listet alle Web-Aliase auf.
Kompatibel mit ISPConfig 3.1+

Verwendung:
  ./get_web_aliases.py                    # Alle Aliase anzeigen
  ./get_web_aliases.py example.com        # Aliase für Domain example.com
  ./get_web_aliases.py --json             # Ausgabe als JSON
"""

import os
import sys
import json
import argparse
from pathlib import Path

import requests
requests.packages.urllib3.disable_warnings()


def load_config():
    """Lädt Konfiguration aus Environment-Variablen oder config.json"""

    # Zuerst Environment-Variablen prüfen
    if all(os.environ.get(var) for var in ['ISPCONFIG_URL', 'ISPCONFIG_USER', 'ISPCONFIG_PASS']):
        return {
            'url': os.environ['ISPCONFIG_URL'],
            'username': os.environ['ISPCONFIG_USER'],
            'password': os.environ['ISPCONFIG_PASS']
        }

    # Fallback: config.json im selben Verzeichnis
    config_path = Path(__file__).parent / 'config.json'
    if config_path.exists():
        with open(config_path) as f:
            config = json.load(f)
            return {
                'url': config['ispconfig_url'],
                'username': config['ispconfig_user'],
                'password': config['ispconfig_pass']
            }

    print("Fehler: Keine Konfiguration gefunden.")
    print("\nOption 1 - Environment-Variablen setzen:")
    print("  export ISPCONFIG_URL='https://server.example.com:8080/remote/json.php'")
    print("  export ISPCONFIG_USER='admin'")
    print("  export ISPCONFIG_PASS='password'")
    print("\nOption 2 - config.json erstellen (siehe config.json.example)")
    sys.exit(1)


class ISPConfigAPI:
    """ISPConfig REST/JSON API Client"""

    def __init__(self, url, username, password):
        # URL auf json.php anpassen falls nötig
        self.url = url.replace('/index.php', '/json.php')
        if not self.url.endswith('/json.php'):
            self.url = self.url.rstrip('/') + '/json.php'

        self.username = username
        self.password = password
        self.session_id = None

    def _call(self, method, **params):
        """Führt einen API-Call aus"""
        # ISPConfig 3.x JSON API: Methode in URL, Parameter als JSON-Body
        url = f"{self.url}?{method}"

        try:
            response = requests.post(
                url,
                json=params,
                verify=False,
                timeout=30
            )
            response.raise_for_status()
            result = response.json()

            if result.get('code') and result.get('code') != 'ok':
                raise Exception(f"API Fehler: {result.get('message', result.get('code'))}")

            return result.get('response')

        except requests.exceptions.RequestException as e:
            raise Exception(f"HTTP Fehler: {e}")

    def login(self):
        """Authentifiziert bei der API"""
        result = self._call('login', username=self.username, password=self.password)
        if isinstance(result, str) and len(result) > 10:
            self.session_id = result
            return True
        raise Exception(f"Login fehlgeschlagen: {result}")

    def logout(self):
        """Beendet die Session"""
        if self.session_id:
            try:
                self._call('logout', session_id=self.session_id)
            except Exception:
                pass

    def get_web_aliases(self):
        """Holt alle Web-Aliase"""
        if not self.session_id:
            raise Exception("Nicht eingeloggt")

        # Hole alle Alias-Domains
        result = self._call(
            'sites_web_aliasdomain_get',
            session_id=self.session_id,
            primary_id={}
        )

        if isinstance(result, list):
            return result
        elif result:
            return [result]
        return []

    def get_websites(self):
        """Holt alle Websites (für Parent-Domain-Namen)"""
        if not self.session_id:
            raise Exception("Nicht eingeloggt")

        result = self._call(
            'sites_web_domain_get',
            session_id=self.session_id,
            primary_id={}
        )

        if isinstance(result, list):
            return result
        elif result:
            return [result]
        return []


def main():
    parser = argparse.ArgumentParser(description='ISPConfig Web-Aliase auslesen')
    parser.add_argument('domain', nargs='?', help='Parent-Domain filtern (z.B. example.com)')
    parser.add_argument('--json', action='store_true', help='Ausgabe als JSON')
    args = parser.parse_args()

    print("ISPConfig Web-Aliase Abfrage")
    print("=" * 40 + "\n")

    config = load_config()

    # URL für Anzeige anpassen
    display_url = config['url'].replace('/index.php', '/json.php')
    print(f"Verbinde mit: {display_url}")
    print(f"Benutzer: {config['username']}\n")

    api = ISPConfigAPI(config['url'], config['username'], config['password'])

    try:
        # Login
        api.login()
        print(f"Login erfolgreich. Session-ID: {api.session_id[:8]}...")

        # Websites holen für Parent-Domain-Namen
        websites = api.get_websites()
        website_map = {}  # ID -> Domain
        domain_to_id = {}  # Domain -> ID
        domain_to_server = {}  # Domain -> server_id
        for site in websites:
            site_id = site.get('domain_id')
            domain = site.get('domain', 'Unbekannt')
            server_id = site.get('server_id')
            if site_id:
                website_map[str(site_id)] = domain
                domain_to_id[domain.lower()] = str(site_id)
                domain_to_server[domain.lower()] = server_id

        # Aliase holen
        aliases = api.get_web_aliases()

        # Nur diese Parent-Domains erkennen (nicht Aliase)
        mep_parents = [
            'mep-www-live-01.micro-epsilon.de',
            'mep-www-stage-01.micro-epsilon.de',
            'mep-www-dev-01.micro-epsilon.de',
            'mep-www-fallback-01.micro-epsilon.de'
        ]

        # Nach Domain filtern wenn angegeben
        if args.domain:
            filter_domain = args.domain.lower()
            # Nur bekannte Parent-Domains als Parent-Filter behandeln
            if filter_domain in [p.lower() for p in mep_parents]:
                parent_id = domain_to_id.get(filter_domain)
                if parent_id:
                    aliases = [a for a in aliases if str(a.get('parent_domain_id', '')) == parent_id]
            else:
                # Nach Alias-Domain-Namen filtern (Substring-Match)
                aliases = [a for a in aliases if filter_domain in a.get('domain', '').lower()]

        # Ausgabe
        print(f"\n{'=' * 60}")
        if args.domain:
            print(f"Aliase für: {args.domain}")
        print(f"Gefundene Web-Aliase: {len(aliases)}")
        print(f"{'=' * 60}\n")

        if not aliases:
            print("Keine Web-Aliase gefunden.")
        else:
            # Aliase nach Parent-Domain gruppieren
            grouped = {}
            for alias in aliases:
                parent_id = str(alias.get('parent_domain_id', ''))
                if parent_id not in grouped:
                    grouped[parent_id] = []
                grouped[parent_id].append(alias)

            # Gruppiert ausgeben (nur MEP-Parents)
            # Wenn Domain-Filter aktiv, nur passende Parent-Domain anzeigen
            if args.domain:
                display_parents = [p for p in mep_parents if p.lower() == args.domain.lower()]
                if not display_parents:
                    # Fallback: zeige Parents die Aliase haben
                    display_parents = [p for p in mep_parents if grouped.get(domain_to_id.get(p.lower()))]
            else:
                display_parents = mep_parents

            for mep_domain in display_parents:
                parent_id = domain_to_id.get(mep_domain.lower())
                parent_server = domain_to_server.get(mep_domain.lower(), 'N/A')
                print("-" * 40)
                print(f"Parent-Domain: {mep_domain} (ID: {parent_id or 'N/A'}, Server: {parent_server})")
                alias_list = grouped.get(parent_id, []) if parent_id else []
                if not alias_list:
                    print("Alias:         (keine Aliase gefunden)")
                else:
                    for alias in alias_list:
                        domain = alias.get('domain', 'N/A')
                        alias_id = alias.get('domain_id', 'N/A')
                        alias_server = alias.get('server_id', 'N/A')
                        alias_groupid = alias.get('sys_groupid', 'N/A')
                        print(f"Alias:         {domain} (ID: {alias_id}, Server: {alias_server}, GroupID: {alias_groupid})")

        # Optional: JSON-Ausgabe
        if args.json:
            print("\n\nJSON-Ausgabe:")
            print(json.dumps(aliases, indent=2, default=str))

        return aliases

    except Exception as e:
        print(f"Fehler: {e}")
        sys.exit(1)

    finally:
        api.logout()
        print("\nLogout erfolgreich.")


if __name__ == '__main__':
    main()

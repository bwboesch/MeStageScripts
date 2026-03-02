#!/usr/bin/env python3
"""
ISPConfig API Script - Aliase von Live auf Fallback umschalten

Verschiebt alle Web-Aliase von mep-www-live-01 auf mep-www-fallback-01.

Verwendung:
  ./switch_to_fallback.py           # Dry-Run (zeigt nur was passieren würde)
  ./switch_to_fallback.py --execute # Führt die Änderungen aus
"""

import os
import sys
import json
import argparse
from pathlib import Path

import requests
requests.packages.urllib3.disable_warnings()

SOURCE_DOMAIN = 'mep-www-live-01.micro-epsilon.de'
TARGET_DOMAIN = 'mep-www-fallback-01.micro-epsilon.de'


def load_config():
    """Lädt Konfiguration aus Environment-Variablen oder config.json"""

    if all(os.environ.get(var) for var in ['ISPCONFIG_URL', 'ISPCONFIG_USER', 'ISPCONFIG_PASS']):
        return {
            'url': os.environ['ISPCONFIG_URL'],
            'username': os.environ['ISPCONFIG_USER'],
            'password': os.environ['ISPCONFIG_PASS']
        }

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
        self.url = url.replace('/index.php', '/json.php')
        if not self.url.endswith('/json.php'):
            self.url = self.url.rstrip('/') + '/json.php'

        self.username = username
        self.password = password
        self.session_id = None

    def _call(self, method, **params):
        """Führt einen API-Call aus"""
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

    def update_alias(self, alias_id, client_id, params):
        """Aktualisiert einen Web-Alias"""
        if not self.session_id:
            raise Exception("Nicht eingeloggt")

        return self._call(
            'sites_web_aliasdomain_update',
            session_id=self.session_id,
            client_id=client_id,
            primary_id=alias_id,
            params=params
        )

    def get_client_id(self, sys_userid):
        """Ermittelt die client_id anhand der sys_userid"""
        if not self.session_id:
            raise Exception("Nicht eingeloggt")

        return self._call(
            'client_get_id',
            session_id=self.session_id,
            sys_userid=sys_userid
        )


def main():
    parser = argparse.ArgumentParser(description=f'Aliase von {SOURCE_DOMAIN} auf {TARGET_DOMAIN} umschalten')
    parser.add_argument('--execute', action='store_true', help='Änderungen tatsächlich ausführen')
    args = parser.parse_args()

    print(f"Alias-Umschaltung: {SOURCE_DOMAIN} -> {TARGET_DOMAIN}")
    print("=" * 60)
    if not args.execute:
        print("DRY-RUN MODUS - keine Änderungen werden durchgeführt")
        print("Verwende --execute um Änderungen auszuführen")
    print()

    config = load_config()
    api = ISPConfigAPI(config['url'], config['username'], config['password'])

    try:
        api.login()
        print(f"Login erfolgreich.\n")

        # Websites holen
        websites = api.get_websites()
        domain_to_id = {}
        for site in websites:
            site_id = site.get('domain_id')
            domain = site.get('domain', 'Unbekannt')
            if site_id:
                domain_to_id[domain.lower()] = str(site_id)

        # Source und Target IDs ermitteln
        source_id = domain_to_id.get(SOURCE_DOMAIN.lower())
        target_id = domain_to_id.get(TARGET_DOMAIN.lower())

        if not source_id:
            print(f"FEHLER: Source-Domain '{SOURCE_DOMAIN}' nicht gefunden!")
            sys.exit(1)
        if not target_id:
            print(f"FEHLER: Target-Domain '{TARGET_DOMAIN}' nicht gefunden!")
            sys.exit(1)

        print(f"Source: {SOURCE_DOMAIN} (ID: {source_id})")
        print(f"Target: {TARGET_DOMAIN} (ID: {target_id})")
        print()

        # Aliase holen
        aliases = api.get_web_aliases()
        source_aliases = [a for a in aliases if str(a.get('parent_domain_id', '')) == source_id]

        print(f"Gefundene Aliase auf {SOURCE_DOMAIN}: {len(source_aliases)}")
        print("-" * 60)

        if not source_aliases:
            print("Keine Aliase zum Umschalten gefunden.")
            return

        for alias in source_aliases:
            alias_domain = alias.get('domain', 'N/A')
            alias_id = alias.get('domain_id')
            sys_userid = alias.get('sys_userid')
            client_id = api.get_client_id(sys_userid)
            print(f"  {alias_domain} (ID: {alias_id}, sys_userid: {sys_userid}, client_id: {client_id})")

            if args.execute and alias_id:
                try:
                    api.update_alias(alias_id, client_id, {'parent_domain_id': target_id})
                    print(f"    -> Umgeschaltet auf {TARGET_DOMAIN}")
                except Exception as e:
                    print(f"    -> FEHLER: {e}")

        if args.execute:
            print(f"\n{len(source_aliases)} Aliase wurden umgeschaltet.")
        else:
            print(f"\nDRY-RUN: {len(source_aliases)} Aliase würden umgeschaltet werden.")
            print("Verwende --execute um die Änderungen durchzuführen.")

    except Exception as e:
        print(f"Fehler: {e}")
        sys.exit(1)

    finally:
        api.logout()
        print("\nLogout erfolgreich.")


if __name__ == '__main__':
    main()

# TinderVault

Multi-comptes isolés pour Tinder sur iOS — sideload, **sans jailbreak**.

Port de [InstaVault](https://github.com/mpoukiarmel21-beep/InstaVault) sur l'IPA
Tinder (`com.cardify.tinder`). Même moteur, mêmes fonctionnalités : chaque
conteneur est un « téléphone » distinct, totalement isolé de l'app réelle et des
autres conteneurs.

> Usage personnel. Le build injecte un dylib dans une copie **déchiffrée** de
> l'IPA fournie par l'utilisateur ; aucun binaire Tinder n'est redistribué dans
> ce dépôt.

## Fonctionnalités

- **Conteneurs isolés** — chaque conteneur = une identité distincte (fichiers,
  keychain, préférences), avec sa propre session Tinder persistante.
- **Isolation atomique triple** (conteneurs non-défaut) : redirection HOME
  (fichiers) + namespace keychain (`IV:<cid>:`) + redirection CFPreferences.
  Les trois réussissent ensemble ou aucune ne s'applique (repli sandbox réel).
- **Spoof d'identité device** (modèle, série, MobileGestalt) — limité à la
  vraie puce, déterministe par conteneur.
- **Spoof locale / fuseau** par conteneur.
- **Spoof GPS** par conteneur (localisation factice + hooks d'autorisation).
- **Bouton flottant** déplaçable + menu de gestion (UI sombre, Liquid Glass).
- **Fermeture auto à l'activation** d'un conteneur (l'isolation/spoof
  s'appliquent au prochain lancement — architecture launch-time).
- **Reset global**. Le conteneur par défaut reste intact comme repli.

## Build (CI uniquement)

Aucun build local (pas de toolchain iOS sous Windows). Tout passe par GitHub
Actions :

1. Onglet **Actions** → workflow **Build TinderVault IPA** → **Run workflow**.
2. Champ `ipa_url` : tag de release (ex. `v1.0-ipa`), URL directe, ou code
   dossier Gofile de l'IPA Tinder **déchiffrée**.
3. Récupérer l'IPA signée ad-hoc dans les artifacts / la release `build-<n>`.
4. Installer via **Sideloadly** (qui applique la signature + les entitlements).

Le dylib est **substrate-free** (fishhook + `method_setImplementation`), donc il
se charge sur appareil non-jailbreaké. Le workflow échoue si le dylib lie
CydiaSubstrate.

## Architecture

Identique à InstaVault — voir `Tweak/Source/` :

- `Bootstrap.m` — point d'entrée `__attribute__((constructor))` : isolation +
  spoofs appliqués une seule fois au lancement.
- `Core/` — modèle conteneur, store, chemins.
- `Isolation/` — HOME, keychain, CFPreferences.
- `Spoof/` — device, identité, locale, localisation.
- `UI/` — bouton flottant, panneaux, pickers (thème sombre / glass).

Le code du tweak est **agnostique de l'app** : les hooks ciblent des API système
(CLLocationManager, sysctl, NSLocale, Security keychain, CFPreferences, HOME). Le
workflow découvre `Payload/*.app` et son exécutable dynamiquement — la même base
sert donc à mettre à jour n'importe quelle version d'IPA fournie.

## Mise à jour d'une nouvelle version d'IPA

Quand Tinder publie une nouvelle version : fournir la nouvelle IPA **déchiffrée**,
relancer le workflow avec la nouvelle `ipa_url`. Le code du tweak ne change pas.

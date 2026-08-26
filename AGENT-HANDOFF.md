# AGENT-HANDOFF — TinderVault

## État actuel
Projet créé le 2026-08-26 comme **port de InstaVault** sur l'IPA Tinder
(`com.cardify.tinder`, v17.30.0, `Payload/Tinder.app`, exécutable `Tinder`,
thin arm64, **cryptid=0 → déchiffrée**). Le code du tweak est repris tel quel
(agnostique de l'app) ; seuls le nom du produit de build, le workflow CI et deux
chaînes UI ont été adaptés.

Adaptations faites :
- `Tweak/Makefile` : `LIBRARY_NAME = TinderVault` (+ préfixes de variables).
- `.github/workflows/build.yml` : nom du workflow, dylib `TinderVault.dylib`,
  sortie `TinderVault.ipa`, artifact `TinderVault-IPA`, release `build-<n>`,
  URL de repli pointant sur `mpoukiarmel21-beep/TinderVault` +
  `com.cardify.tinder_17.30.0_und3fined.ipa`.
- `IVCreateVC.m` / `IVPanelVC.m` : chaînes user-facing « Instagram » → « Tinder ».
- Tout le reste de `Tweak/Source/` est **identique à InstaVault** (isolation,
  spoofs, UI). Le répertoire de contrôle interne reste `~/Documents/InstaVault/`
  et le préfixe keychain `IV:` (identifiants internes conservés ; invisibles et
  sans collision car sandbox d'app distincte).

## En cours
Claude (Opus 4.8) — 2026-08-26. Scaffold local terminé. Étapes sortantes
(création repo GitHub, upload IPA, dispatch build) en cours.

## Prochaine étape
1. `git init` + commit initial (fait dans la foulée du scaffold).
2. Créer le repo GitHub `TinderVault` (**privé par défaut** — héberge une IPA
   copyright). Push `master`.
3. Uploader `D:\IPA APP\com.cardify.tinder_17.30.0_und3fined.ipa` (256 Mo) en
   asset de release `v1.0-ipa` (source de base pour le CI).
4. Dispatcher le workflow avec `ipa_url = v1.0-ipa`.
5. Vérifier le build vert → récupérer `TinderVault.ipa` → Sideloadly.

## Blocages / risques
- **IPA copyright** : le repo est privé par défaut. Ne pas passer public sans
  décision explicite.
- **DRM** : ce build ne marche que sur une IPA déchiffrée. Les futures versions
  Tinder devront être fournies déchiffrées (dump sur appareil réel).
- Pas de toolchain iOS locale → aucune compilation locale possible ; le CI est
  le seul juge de la compilation.
- Entitlements non gérés par le CI (Sideloadly les applique). Pas de
  `tinder.entitlements` créé pour l'instant.

## Journal
### 2026-08-26 — Claude (Opus 4.8)
Création du projet TinderVault. Copie de l'arbre `Tweak/` d'InstaVault (335 Ko,
sans artefacts), du workflow CI, du `.gitignore`, d'`AGENTS.md`/`CLAUDE.md`, des
templates killer-saas et de la décision 001 (substrate-free). Adaptation
Makefile + workflow + 2 chaînes UI. InstaVault laissé propre à build-92 (un
`IVNotifyAuthorized` dupliqué non commité a été reverté — il aurait cassé la
compilation).

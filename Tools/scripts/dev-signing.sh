#!/bin/zsh
# A stable code-signing identity for Debug builds of the input method on this Mac.
#
# Usage: Tools/scripts/dev-signing.sh setup        create the identity (once per Mac)
#        Tools/scripts/dev-signing.sh sign <app>   re-sign <app> with it, keeping its entitlements
#        Tools/scripts/dev-signing.sh status       print whether the identity is ready
#
# Xcode signs Debug builds ad hoc, so every build has a new code hash. macOS ties the Accessibility
# and Input Monitoring grants to the signature the app had when it was allowed, so after each
# install those grants stop applying ("Failed to match existing code requirement") and must be
# reset and given again. A self-signed certificate gives a designated requirement that names the
# certificate instead of the code hash, so one grant lasts across builds.
#
# The identity lives in its own keychain (~/Library/Keychains/duo-dev.keychain-db) with a random
# password kept in ~/Library/Application Support/Duo/dev-signing/, never in the repository, so the
# login keychain and the account password are not involved. The certificate is not trusted by the
# system; codesign and TCC do not need it to be. codesign finds an untrusted identity only through
# the keychain search list, so `sign` adds the keychain to the list for the signature and then puts
# the list back.
set -euo pipefail

NAME="Duo Development"
KEYCHAIN="$HOME/Library/Keychains/duo-dev.keychain-db"
STATE="$HOME/Library/Application Support/Duo/dev-signing"
PASSWORD_FILE="$STATE/keychain-password"

usage() { sed -n '2,6p' "${0:A}" | sed 's/^# \{0,1\}//'; exit 2; }

ready() {
  [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]] || return 1
  security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1
}

unlock() {
  security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
}

setup() {
  if ready; then
    echo "dev-signing: \"$NAME\" is already set up in $KEYCHAIN"
    return 0
  fi
  mkdir -p "$STATE"
  chmod 700 "$STATE"
  local work
  work="$(mktemp -d "$STATE/setup.XXXXXX")"
  trap "rm -rf '$work'" EXIT
  [[ -f "$PASSWORD_FILE" ]] || { (umask 077; /usr/bin/openssl rand -hex 24 > "$PASSWORD_FILE"); }
  local password p12password
  password="$(cat "$PASSWORD_FILE")"
  p12password="$(/usr/bin/openssl rand -hex 16)"

  cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$NAME" \
    -passout "pass:$p12password" -out "$work/identity.p12" 2>/dev/null

  if [[ ! -f "$KEYCHAIN" ]]; then
    # create-keychain adds the keychain to the user's search list; put the list back, so no other
    # app looks into it (codesign gets it with --keychain).
    local -a searched
    searched=("${(@f)$(searched_keychains)}")
    security create-keychain -p "$password" "$KEYCHAIN"
    security list-keychains -d user -s "${searched[@]}"
  fi
  # No auto-lock: install-ime.sh unlocks it before every signature anyway.
  security set-keychain-settings "$KEYCHAIN"
  unlock
  security import "$work/identity.p12" -k "$KEYCHAIN" -P "$p12password" -T /usr/bin/codesign >/dev/null
  # Lets codesign use the key without a keychain prompt.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KEYCHAIN" >/dev/null
  echo "dev-signing: created \"$NAME\" in $KEYCHAIN"
  echo "dev-signing: allow the input method once more (Accessibility, Input Monitoring); later installs keep it"
}

searched_keychains() {
  security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//'
}

sign() {
  local app="$1"
  [[ -d "$app" ]] || { echo "dev-signing: no such app: $app" >&2; exit 1; }
  ready || { echo "dev-signing: not set up (run: Tools/scripts/dev-signing.sh setup)" >&2; exit 1; }
  unlock
  local -a searched
  searched=("${(@f)$(searched_keychains)}")
  trap "security list-keychains -d user -s ${(q)searched[@]}" EXIT
  security list-keychains -d user -s "${searched[@]}" "$KEYCHAIN"
  codesign --force --sign "$NAME" --preserve-metadata=entitlements,flags "$app"
  codesign --verify --strict "$app"
}

case "${1:-}" in
  setup) setup ;;
  sign) [[ $# -eq 2 ]] || usage; sign "$2" ;;
  status) if ready; then echo "ready"; else echo "not set up"; exit 1; fi ;;
  *) usage ;;
esac

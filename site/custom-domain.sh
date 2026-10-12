#!/usr/bin/env bash
# Serve the companion site at factorio.nickwinter.net (Cloudflare Pages project player-of-games), unlisted.
#
#   site/custom-domain.sh check    # read-only: wrangler's account, the zone's account, the project, DNS, live origins
#   site/custom-domain.sh deploy   # build + check the site, deploy the live API Worker, deploy Pages production (main)
#   site/custom-domain.sh attach   # add the custom domain to the Pages project and its CNAME (proxied) in the zone
#   site/custom-domain.sh verify   # the domain answers, noindex holds, the live API accepts the new origin
#
# Run them in that order, from the repo root; each step does only what its name says.
# wrangler steps use wrangler's own login (`npx wrangler login`). The two API calls wrangler has no command for
# (a Pages custom domain, a DNS record) need CF_TOKEN: an API token with Account > Cloudflare Pages > Edit and, for
# the zone nickwinter.net, Zone > DNS > Edit and Zone > Zone > Read. It is named CF_TOKEN, not CLOUDFLARE_API_TOKEN,
# so wrangler keeps using its login.
#
# The site stays unlisted on the new domain: every page has <meta name="robots" content="noindex, nofollow">,
# robots.txt disallows everything and _headers sends X-Robots-Tag (site/README.md); `verify` checks all three.
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN=factorio.nickwinter.net
ZONE=nickwinter.net
PROJECT=player-of-games
API=https://api.cloudflare.com/client/v4
LIVE_API=$(python3 -c 'import json; print(json.load(open("site/config.json"))["live_api_url"])')

cf() {  # cf METHOD PATH [JSON]: one Cloudflare API call with CF_TOKEN; prints the JSON reply
  : "${CF_TOKEN:?set CF_TOKEN (see the header of this script)}"
  curl -sS -X "$1" "$API$2" -H "Authorization: Bearer $CF_TOKEN" -H "Content-Type: application/json" ${3:+--data "$3"}
}
field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {'d': d}))" "$1"; }

zone_info() {  # prints "ZONE_ID ACCOUNT_ID"
  cf GET "/zones?name=$ZONE" | field '" ".join([d["result"][0]["id"], d["result"][0]["account"]["id"]]) if d.get("result") else "none none"'
}

case "${1:-}" in
check)
  echo "== wrangler login (the account that owns $PROJECT)"
  npx wrangler whoami
  npx wrangler pages project list | grep -E "Project Name|$PROJECT|nickwinter" || true
  if [ -n "${CF_TOKEN:-}" ]; then
    read -r zone_id account_id < <(zone_info)
    echo "== zone $ZONE: id $zone_id, account $account_id"
    echo "== project $PROJECT in that account:"
    cf GET "/accounts/$account_id/pages/projects/$PROJECT" | field '"yes, domains: " + ", ".join(d["result"]["domains"]) if d.get("success") else "NO: " + str(d.get("errors"))'
    echo "== DNS records for $DOMAIN (expect none before attach):"
    cf GET "/zones/$zone_id/dns_records?name=$DOMAIN" | field '[(r["type"], r["content"], r["proxied"]) for r in d.get("result", [])]'
  else
    echo "(set CF_TOKEN to also check the zone's account, the project in it, and existing DNS records)"
  fi
  echo "== live API origins (site/worker/wrangler.toml):"
  grep ALLOWED_ORIGINS site/worker/wrangler.toml
  ;;
deploy)
  python3 site/build.py
  python3 site/check.py
  # The live API must accept the new origin before the page moves there (ALLOWED_ORIGINS in wrangler.toml).
  npx wrangler deploy --config site/worker/wrangler.toml
  # Production: the project's production branch is main; this is the deployment the custom domain serves.
  npx wrangler pages deploy site/dist --project-name "$PROJECT" --branch main --commit-dirty=true
  ;;
attach)
  read -r zone_id account_id < <(zone_info)
  [ "$zone_id" != none ] || { echo "zone $ZONE not visible to CF_TOKEN" >&2; exit 1; }
  echo "== add $DOMAIN to Pages project $PROJECT"
  cf POST "/accounts/$account_id/pages/projects/$PROJECT/domains" "{\"name\":\"$DOMAIN\"}" | field 'd["result"]["status"] if d.get("success") else d.get("errors")'
  echo "== CNAME $DOMAIN -> $PROJECT.pages.dev (proxied), unless a record exists"
  existing=$(cf GET "/zones/$zone_id/dns_records?name=$DOMAIN" | field 'len(d.get("result", []))')
  if [ "$existing" = 0 ]; then
    cf POST "/zones/$zone_id/dns_records" \
      "{\"type\":\"CNAME\",\"name\":\"${DOMAIN%%.$ZONE}\",\"content\":\"$PROJECT.pages.dev\",\"proxied\":true,\"ttl\":1,\"comment\":\"companion site (Pages $PROJECT)\"}" \
      | field '"created" if d.get("success") else d.get("errors")'
  else
    echo "a record for $DOMAIN exists; left as it is:"
    cf GET "/zones/$zone_id/dns_records?name=$DOMAIN" | field '[(r["type"], r["content"], r["proxied"]) for r in d["result"]]'
  fi
  echo "== domain status (pending until Cloudflare validates it; usually a minute or two):"
  cf GET "/accounts/$account_id/pages/projects/$PROJECT/domains/$DOMAIN" | field 'd["result"]["status"] if d.get("success") else d.get("errors")'
  ;;
verify)
  echo "== https://$DOMAIN/"
  curl -sSI "https://$DOMAIN/" | grep -i -E "^HTTP|^x-robots-tag" || true
  curl -sS "https://$DOMAIN/" | grep -o '<meta name="robots"[^>]*>' || echo "MISSING robots meta"
  echo "== robots.txt"
  curl -sS "https://$DOMAIN/robots.txt"
  echo "== live API CORS for the new origin (expect Access-Control-Allow-Origin: https://$DOMAIN)"
  curl -sSI "$LIVE_API/v1/state" -H "Origin: https://$DOMAIN" | grep -i "access-control-allow-origin" || echo "NOT ALLOWED: deploy the Worker"
  ;;
*)
  sed -n '2,9p' "$0"; exit 2 ;;
esac

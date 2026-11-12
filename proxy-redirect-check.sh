#!/usr/bin/env bash
#
# proxy-redirect-check.sh
#
# Sends N HEAD requests to a URL through an HTTP proxy and counts which host
# each request gets redirected to (the Location header).
#
# Useful for download sites and mirror pickers that hand out a different
# target per request (often based on the caller's public IP): run it from
# behind your proxy to see every host you can be sent to, then make sure the
# proxy allows all of them.
#
# Only HEAD requests are sent and redirects are NOT followed, so nothing is
# downloaded and the redirect targets are never contacted. Safe for prod.
#
# Usage:
#   ./proxy-redirect-check.sh                 # asks for everything
#   ./proxy-redirect-check.sh -p proxy.example.com -P 8080 \
#       -u https://downloads.example.com/path/to/file
#   ./proxy-redirect-check.sh -n 20 -d 1      # 20 requests, 1s apart
#
# Options:
#   -p HOST   proxy host (e.g. proxy.example.com or http://proxy.example.com)
#   -P PORT   proxy port (e.g. 8080)
#   -u URL    remote URL to request
#   -n COUNT  number of requests (default 10)
#   -d SECS   delay between requests (default 0)
#   -t SECS   per-request timeout (default 15)
#   -h        show this help

set -u

PROXY_HOST=""
PROXY_PORT=""
URL=""
COUNT=10
DELAY=0
TIMEOUT=15

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while getopts ":p:P:u:n:d:t:h" opt; do
  case $opt in
    p) PROXY_HOST=$OPTARG ;;
    P) PROXY_PORT=$OPTARG ;;
    u) URL=$OPTARG ;;
    n) COUNT=$OPTARG ;;
    d) DELAY=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    h) usage 0 ;;
    :) echo "Option -$OPTARG needs a value." >&2; usage 1 ;;
    *) echo "Unknown option -$OPTARG" >&2; usage 1 ;;
  esac
done

# Ask for anything not given as a flag.
[[ -z $PROXY_HOST ]] && read -rp "Proxy host (e.g. proxy.example.com): " PROXY_HOST
[[ -z $PROXY_PORT ]] && read -rp "Proxy port (e.g. 8080): " PROXY_PORT
[[ -z $URL ]]        && read -rp "Remote URL: " URL

# Clean up input: drop a scheme and trailing slash from the proxy host.
PROXY_HOST=${PROXY_HOST#http://}
PROXY_HOST=${PROXY_HOST#https://}
PROXY_HOST=${PROXY_HOST%/}

# Validate.
[[ -n $PROXY_HOST ]] || { echo "Proxy host is required." >&2; exit 1; }
[[ $PROXY_PORT =~ ^[0-9]+$ ]] || { echo "Proxy port must be a number." >&2; exit 1; }
[[ $URL =~ ^https?:// ]] || { echo "URL must start with http:// or https://" >&2; exit 1; }
[[ $COUNT =~ ^[0-9]+$ && $COUNT -gt 0 ]] || { echo "Count must be a positive number." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is not installed." >&2; exit 1; }

PROXY="http://${PROXY_HOST}:${PROXY_PORT}"

# One request: print the redirect host, or why there was no redirect.
probe() {
  local headers status location responses

  # Proxy answers (e.g. "200 Connection established" or a 403) and the
  # remote server's answer both end up here; the last HTTP line wins.
  headers=$(curl -sI --max-time "$TIMEOUT" -x "$PROXY" "$URL" 2>/dev/null | tr -d '\r')

  status=$(awk '/^HTTP\//{s=$2} END{print s}' <<<"$headers")
  responses=$(grep -c '^HTTP/' <<<"$headers")
  location=$(awk 'tolower($1)=="location:"{print $2}' <<<"$headers" | tail -n1)

  if [[ -n $location ]]; then
    awk -F/ '{print $3}' <<<"$location"
  elif [[ -n $status ]]; then
    # For https URLs a working proxy answers the CONNECT first ("200
    # Connection established") and the remote server answers second. Only
    # one non-200 answer means the proxy refused the tunnel itself.
    if [[ $URL == https://* && $responses -eq 1 && $status != 2* ]]; then
      echo "blocked by proxy (HTTP $status)"
    else
      echo "no redirect (HTTP $status)"
    fi
  else
    echo "no response (timeout, DNS or connection error)"
  fi
}

echo "Proxy:    $PROXY"
echo "URL:      $URL"
echo "Requests: $COUNT"
echo

for ((i = 1; i <= COUNT; i++)); do
  probe
  (( i < COUNT )) && [[ $DELAY != 0 ]] && sleep "$DELAY"
done | sort | uniq -c | sort -rn
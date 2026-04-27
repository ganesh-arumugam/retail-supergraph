#!/usr/bin/env bash
# =============================================================================
# Hash-Cascade Test — proves @requires repr-hash invalidation
# =============================================================================
# Tests that shipping/Order (TTL=120s) which @requires shippingAddress from
# users/User (TTL=30s) is correctly invalidated when the address CHANGES after
# User's TTL expires — even though Order's own TTL hasn't expired yet.
#
# Key insight: if shipping is a MISS at t=32s, it can ONLY be a hash cascade,
# not a TTL expiry, because shipping TTL (120s) > users TTL (30s).
#
# Scenarios:
#   A — address UNCHANGED after B expires  → shipping: HIT  (hash stable)
#   B — address CHANGED after B expires    → shipping: MISS (hash cascade)
#   C — address changes WITHIN B's TTL    → both HIT serving stale (staleness window)
#
# Prerequisites:
#   docker compose up -d          (Redis on :6380)
#   npm run dev                   (subgraphs :4001, router :4000)
# =============================================================================

ROUTER="http://localhost:4000"
SUBGRAPHS="http://localhost:4001"
REDIS="docker exec retail-supergraph-redis-1 redis-cli"
PASS=0; FAIL=0

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
dim()   { printf "\033[2m%s\033[0m\n" "$*"; }

check_pass() { green "  ✓ $1"; PASS=$((PASS+1)); }
check_fail() { red   "  ✗ $1"; FAIL=$((FAIL+1)); }

QUERY='{"operationName":"GetOrderShipping","query":"query GetOrderShipping { order(id: \"order:1\") { id shippingCost } }"}'

gql() {
  curl -s -D /tmp/hc_headers.txt -o /tmp/hc_body.json \
    -X POST "$ROUTER" \
    -H "Content-Type: application/json" \
    -d "$QUERY"
}

get_header() {
  grep -i "^$1:" /tmp/hc_headers.txt | sed 's/^[^:]*: *//' | tr -d '\r\n'
}

assert_eq() {
  local actual; actual=$(get_header "$1")
  [ "$actual" = "$2" ] && check_pass "$3" || check_fail "$3 (expected '$2', got '$actual')"
}

set_address() {
  curl -s -X POST "$SUBGRAPHS/__test/set-address" \
    -H "Content-Type: application/json" \
    -d "{\"userId\":\"user:1\",\"address\":\"$1\"}" > /dev/null
  dim "  [control] user:1.shippingAddress = '$1'"
}

flush() {
  $REDIS FLUSHALL > /dev/null
  dim "  [redis] FLUSHALL"
}

shipping_cost() {
  python3 -c 'import json; print(json.load(open("/tmp/hc_body.json"))["data"]["order"]["shippingCost"])'
}

# =============================================================================
bold "\n══ Scenario A — B expires, value UNCHANGED → shipping should HIT ══"
dim   "  users/User TTL=30s   shipping/Order TTL=120s"
dim   "  After users expires and re-fetches the SAME address, the repr hash is"
dim   "  identical → shipping Redis entry is still valid → HIT."
# =============================================================================

set_address "123 Main St"
flush

dim "\nT=0  cold call"
gql
assert_eq "x-response-cache-users"    "miss" "T=0  users: miss"
assert_eq "x-response-cache-shipping" "miss" "T=0  shipping: miss"

dim "\nT=1  warm call"
gql
assert_eq "x-response-cache-users"    "hit"  "T=1  users: hit"
assert_eq "x-response-cache-shipping" "hit"  "T=1  shipping: hit"

dim "\nWaiting 32s for users TTL to expire (shipping TTL=120s, stays alive)..."
sleep 32

dim "\nT=32  users expired, address UNCHANGED"
gql
assert_eq "x-response-cache-users"    "miss" "T=32 users: miss (TTL expired, re-fetched)"
assert_eq "x-response-cache-shipping" "hit"  "T=32 shipping: HIT (repr hash unchanged)"

# =============================================================================
bold "\n══ Scenario B — B expires, value CHANGED → shipping should MISS ══"
dim   "  After users expires and re-fetches a NEW address, the repr hash changes."
dim   "  The old shipping Redis entry has a different key → never served → MISS."
# =============================================================================

set_address "123 Main St"
flush

dim "\nT=0  cold call"
gql
assert_eq "x-response-cache-users"    "miss" "T=0  users: miss"
assert_eq "x-response-cache-shipping" "miss" "T=0  shipping: miss"
COST_BEFORE=$(shipping_cost)
dim "  shippingCost before = $COST_BEFORE"

dim "\nWaiting 32s for users TTL to expire..."
sleep 32

dim "\n[mutate] shippingAddress → '456 Oak Ave Extended' (longer string → higher cost)"
set_address "456 Oak Ave Extended"

dim "\nT=32  users expired, address CHANGED"
gql
assert_eq "x-response-cache-users"    "miss" "T=32 users: miss (TTL expired, new value)"
assert_eq "x-response-cache-shipping" "miss" "T=32 shipping: MISS (repr hash cascade)"
COST_AFTER=$(shipping_cost)
dim "  shippingCost after = $COST_AFTER"

if [ "$COST_BEFORE" != "$COST_AFTER" ]; then
  check_pass "shippingCost recomputed correctly ($COST_BEFORE → $COST_AFTER)"
else
  check_fail "shippingCost should differ when address string length changes"
fi

# =============================================================================
bold "\n══ Scenario C — address changes WITHIN users TTL (staleness window) ══"
dim   "  B's cached entry still has TTL remaining, so A's repr hash matches."
dim   "  Both serve consistent-but-stale data. Staleness clears when B expires."
# =============================================================================

set_address "123 Main St"
flush

dim "\nT=0  cold call"
gql
assert_eq "x-response-cache-users"    "miss" "T=0  users: miss"
assert_eq "x-response-cache-shipping" "miss" "T=0  shipping: miss"
COST_STALE=$(shipping_cost)

dim "\nT=1  warm call"
gql
assert_eq "x-response-cache-users"    "hit"  "T=1  users: hit"
assert_eq "x-response-cache-shipping" "hit"  "T=1  shipping: hit"

dim "\n[mutate at T=1] address changes to '456 Oak Ave Extended' WITHIN users TTL"
set_address "456 Oak Ave Extended"

dim "\nT=2  both still within TTL — expect both HIT serving stale data"
gql
assert_eq "x-response-cache-users"    "hit"  "T=2  users: hit (stale, TTL not expired)"
assert_eq "x-response-cache-shipping" "hit"  "T=2  shipping: hit (stale, old repr matches)"
COST_DURING=$(shipping_cost)

if [ "$COST_STALE" = "$COST_DURING" ]; then
  check_pass "shippingCost stable during staleness window (both = $COST_STALE)"
else
  check_fail "shippingCost should be same stale value (got $COST_STALE vs $COST_DURING)"
fi

dim "\nWaiting 32s for users TTL to expire..."
sleep 32

dim "\nT=33  users expired → fresh address fetched → shipping hash changes"
gql
assert_eq "x-response-cache-users"    "miss" "T=33 users: miss (TTL expired, new address)"
assert_eq "x-response-cache-shipping" "miss" "T=33 shipping: miss (hash cascade on expiry)"
COST_FRESH=$(shipping_cost)

if [ "$COST_STALE" != "$COST_FRESH" ]; then
  check_pass "shippingCost corrected after staleness window ($COST_STALE → $COST_FRESH)"
else
  check_fail "shippingCost should differ after address string length changed"
fi

# Reset to original address
set_address "123 Main St"

# =============================================================================
echo ""
bold "══ Results ══"
green "  Passed: $PASS"
[ $FAIL -gt 0 ] && red "  Failed: $FAIL" || echo "  Failed: 0"

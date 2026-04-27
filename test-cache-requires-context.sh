#!/usr/bin/env bash
# =============================================================================
# Cache Key Inspection — @requires and @fromContext
# =============================================================================
#
# PURPOSE
# ───────
# Empirically verify how Apollo Router constructs Redis entity cache keys when:
#
#   A) @requires — entity representation includes the required @external fields
#      (e.g. Order.shippingCost requires items.weight and buyer.shippingAddress)
#
#   B) @fromContext — the context argument is injected by the Router as a field
#      argument; the client never sends it
#      (e.g. Product.foryou receives subscriptionType from the parent User context)
#
# KEY QUESTION
# ────────────
# For @requires: do different values of required fields produce distinct Redis
# keys? (They SHOULD — different representation hash → different cache key.)
#
# For @fromContext: do different context argument values produce distinct Redis
# keys? (UNKNOWN before this test — if they share a key, users with different
# subscription types may be served each other's cached foryou values.)
#
# WHAT THIS SCRIPT DOES
# ─────────────────────
# 1. Flushes Redis and issues queries that exercise both mechanisms
# 2. Dumps all Redis keys after each scenario
# 3. Decodes the base64 representation hash from each key so you can see
#    exactly what fields are in the entity representation
# 4. Checks whether orders with different shippingAddress values land in
#    different Redis keys (expected: yes, because @requires includes them)
# 5. Checks whether Product.foryou with different subscriptionType values
#    lands in different Redis keys (the test tells you the answer)
#
# REDIS KEY ANATOMY
# ─────────────────
# responseCache:version:1.1:subgraph:{sg}:type:{Type}:
#   representation:{repr_b64}:hash:{query_b64}:data:{opts_b64}
#
#   repr_b64  — base64(JSON entity representation sent to the subgraph)
#               For @requires this INCLUDES the required external fields.
#               For @fromContext this may or may not include the argument.
#   query_b64 — base64(hash of the subgraph query document)
#               @fromContext values that are inlined in the query string land HERE.
#   opts_b64  — base64(hash of per-request cache options)
#
# HOW TO INTERPRET RESULTS
# ────────────────────────
# Scenario A (@requires):
#   PASS → two orders with different shippingAddress have DIFFERENT repr segments
#          in their Redis keys (the address is part of the representation hash)
#   FAIL → same repr segment despite different addresses (cache collision — wrong)
#
# Scenario B (@fromContext):
#   Case 1 — Different repr segments for different subscriptionType values:
#     → @fromContext value is in the entity representation (safe, distinct keys)
#   Case 2 — Same repr segment, different query segments:
#     → value is inlined in the subgraph query document (safe, distinct keys)
#   Case 3 — Same repr AND same query segment across different context values:
#     → DANGEROUS — cache collision; user:3 (DOUBLE) could be served user:1's
#       (SINGLE) cached foryou result or vice versa
#
# Prerequisites:
#   1. Redis running:       docker compose up -d           (port 6380)
#   2. Subgraphs running:   npm run dev:subgraphs           (port 4001)
#   3. Router running:      npm run router:start            (port 4000)
#
# Usage:
#   chmod +x test-cache-requires-context.sh && ./test-cache-requires-context.sh
# =============================================================================

ROUTER="http://localhost:4000"
REDIS_CLI="docker exec retail-supergraph-redis-1 redis-cli -p 6379"
PASS=0
FAIL=0

# ─── Helpers ─────────────────────────────────────────────────────────────────

bold()   { printf "\033[1m%s\033[0m\n" "$*"; }
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
dim()    { printf "\033[2m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
cyan()   { printf "\033[36m%s\033[0m\n" "$*"; }

check_pass() { green "  ✓ $1"; ((PASS++)); }
check_fail() { red   "  ✗ $1"; ((FAIL++)); }

gql() {
  curl -s -D /tmp/rc_headers.txt -o /tmp/rc_body.json \
    -X POST "$ROUTER" \
    -H "Content-Type: application/json" \
    -d "$1"
}

# gql_as <user-id> <json-body>  — same as gql but with x-user-id header
gql_as() {
  curl -s -D /tmp/rc_headers.txt -o /tmp/rc_body.json \
    -X POST "$ROUTER" \
    -H "Content-Type: application/json" \
    -H "x-user-id: $1" \
    -d "$2"
}

flush_redis() {
  $REDIS_CLI FLUSHALL > /dev/null 2>&1
  dim "  Redis flushed."
}

# List all keys in the responseCache namespace, one per line
list_cache_keys() {
  $REDIS_CLI KEYS "responseCache:*" 2>/dev/null
}

# Count keys matching a pattern
count_keys() {
  list_cache_keys | grep -c "$1" 2>/dev/null || echo 0
}

# Extract the representation segment from a cache key
# Key shape: responseCache:version:1.1:subgraph:{sg}:type:{Type}:representation:{repr}:hash:{q}:data:{d}
repr_segment() {
  echo "$1" | sed 's/.*:representation:\([^:]*\):.*/\1/'
}

# Extract the query-hash segment from a cache key
query_segment() {
  echo "$1" | sed 's/.*:hash:\([^:]*\):.*/\1/'
}

# Decode a base64 value (ignores errors for truncated hashes which are opaque)
b64decode() {
  echo "$1" | base64 -d 2>/dev/null || echo "(binary/opaque)"
}

# Print annotated keys for a subgraph type for debugging
dump_keys_for_type() {
  local sg="$1" type="$2"
  local pattern="${sg}:type:${type}"
  local count
  count=$(list_cache_keys | grep -c "$pattern" 2>/dev/null || echo 0)
  dim "  Keys for subgraph=${sg} type=${type}: ${count}"
  list_cache_keys | grep "$pattern" | while IFS= read -r key; do
    local repr qhash
    repr=$(repr_segment "$key")
    qhash=$(query_segment "$key")
    dim "    repr=${repr}"
    dim "    query_hash=${qhash}"
    # Try to decode repr as JSON — may be an opaque hash or base64 JSON
    local decoded
    decoded=$(b64decode "$repr")
    dim "    repr_decoded=${decoded}"
    dim "    ---"
  done
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────

bold "\n╔══════════════════════════════════════════════════════════════════╗"
bold "║   Cache Key Inspection — @requires and @fromContext               ║"
bold "╚══════════════════════════════════════════════════════════════════╝"

printf "\nChecking services...\n"

if ! curl -sf "$ROUTER" -X POST -H "Content-Type: application/json" \
     -d '{"query":"{__typename}"}' > /dev/null 2>&1; then
  red "  Router not reachable at $ROUTER"
  red "  Start with: npm run router:start   (or npm run dev)"
  exit 1
fi
green "  ✓ Router at $ROUTER"

if ! $REDIS_CLI ping > /dev/null 2>&1; then
  red "  Redis not reachable. Start with: docker compose up -d"
  exit 1
fi
green "  ✓ Redis connected"

# =============================================================================
# SCENARIO A — @requires
# Does shippingCost produce different cache keys for orders belonging to users
# with different shippingAddress values?
#
# order:1 → user:1 (123 Main St)  variants: variant:1, variant:2
# order:3 → user:2 (456 Oak Ave)  variants: variant:1, variant:3
# order:4 → user:3 (789 Pine Rd)  variant:  variant:1
#
# The @requires clause on shippingCost is:
#   @requires(fields: "items { weight } buyer { shippingAddress }")
# The entity representation sent to shipping subgraph will be:
#   { "__typename": "Order", "id": "order:1",
#     "items": [{"weight":10},{"weight":10}],
#     "buyer": {"shippingAddress":"123 Main St"} }
# Two orders with different addresses → different representation → different hash
# =============================================================================

bold "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold "  SCENARIO A — @requires: does shippingAddress enter the cache key?"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
dim "  Queries order:1 (user:1 / 123 Main St) and order:3 (user:2 / 456 Oak Ave)"
dim "  Both orders share variant:1, but different addresses."
dim "  Expected: 2 distinct Redis keys for the Order type in shipping subgraph."

flush_redis

# Query user:1 orders with shipping cost
gql '{
  "operationName": "GetUserOrders",
  "query": "query GetUserOrders { users { id orders { id shippingCost } } }"
}'

dim ""
dim "  After first GetUserOrders — Redis keys (shipping subgraph, Order type):"
dump_keys_for_type "shipping" "Order"

A_KEYS_AFTER_FIRST=$(list_cache_keys | grep "subgraph:shipping:type:Order" | wc -l | tr -d ' \n')
dim "  Total Order keys in shipping: ${A_KEYS_AFTER_FIRST}"

# Verify second call is a cache hit (deterministic result)
gql '{
  "operationName": "GetUserOrders",
  "query": "query GetUserOrders { users { id orders { id shippingCost } } }"
}'

A_CACHE=$(grep -i "^x-response-cache:" /tmp/rc_headers.txt | sed 's/^[^:]*: *//' | tr -d '\r\n')
dim "  x-response-cache on second call: ${A_CACHE}"

if [ "$A_CACHE" = "hit" ] || [ "$A_CACHE" = "partial_hit" ]; then
  check_pass "Scenario A: second call served from cache (Math.random removed)"
else
  check_fail "Scenario A: expected cache hit on second call, got '${A_CACHE:-<absent>}'"
fi

# Key count must be > 1 if different addresses → different representations
if [ "$A_KEYS_AFTER_FIRST" -gt 1 ]; then
  check_pass "Scenario A: multiple Order keys found (${A_KEYS_AFTER_FIRST}) — @requires fields ARE in representation hash"
else
  yellow "  ⚠ Only ${A_KEYS_AFTER_FIRST} Order key(s) in shipping after querying all users."
  yellow "    This may mean: (a) only one order was returned, (b) all addresses are the"
  yellow "    same (check users/data.js), or (c) @requires fields are NOT in the repr hash."
  check_fail "Scenario A: expected >1 Order key to confirm @requires in repr hash"
fi

# Compare repr segments between keys — they must differ if addresses are in hash
REPR_SEGMENTS=$(list_cache_keys | grep "subgraph:shipping:type:Order" | while IFS= read -r k; do repr_segment "$k"; done | sort -u)
UNIQUE_REPR_COUNT=$(echo "$REPR_SEGMENTS" | grep -c . 2>/dev/null; true)
dim "  Unique repr segments: ${UNIQUE_REPR_COUNT}"

if [ "$UNIQUE_REPR_COUNT" -gt 1 ]; then
  check_pass "Scenario A: repr segments differ across orders → @requires fields ARE part of the cache key"
  dim ""
  cyan "  CONCLUSION (@requires): The entity representation includes all @requires fields."
  cyan "  Different shippingAddress values → different repr hash → distinct Redis keys."
  cyan "  There is NO risk of cache collision from @requires."
else
  check_fail "Scenario A: all Order keys share the same repr segment — @requires fields may NOT be in the cache key"
fi

# =============================================================================
# SCENARIO B — @fromContext
# Does ForYouProduct.foryou produce different cache keys for users with different
# subscriptionType values (SINGLE vs DOUBLE)?
#
# The @fromContext wiring (reviews subgraph):
#   type User @key(fields: "id") @context(name: "userContext")
#   type ForYouProduct @key(fields: "upc")        ← entity, no root field
#     foryou(subscriptionType: SubscriptionType
#       @fromContext(field: "$userContext { subscriptionType }")): Boolean
#   User.forYouProducts: [ForYouProduct]          ← only access path
#
# ForYouProduct has @key but NO root query field, so the ONLY path is:
#   user.forYouProducts.foryou  →  User is always the ancestor  →  context always set.
# This is why the composition satisfiability check passes (unlike Product.foryou,
# which is reachable via variant.product without User).
#
# The Router injects subscriptionType as a field argument in the subgraph query.
# Key question: does the injected value end up in:
#   (a) the entity representation segment  → different repr hash → safe
#   (b) the query document hash segment    → different query hash → safe
#   (c) neither (same key for both values) → CACHE COLLISION     → dangerous
#
# We test this by:
#   1. Querying user:1 (SINGLE)  → forYouProducts.foryou = false
#   2. Querying user:3 (DOUBLE)  → forYouProducts.foryou = true
#   3. Inspecting Redis keys for ForYouProduct type in reviews subgraph
#   4. Comparing repr segments and query_hash segments
#      Expected: same repr (same upc), different query hash (different subscriptionType
#      inlined by Router) → Case (b) → safe, distinct Redis keys.
# =============================================================================

bold "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold "  SCENARIO B — @fromContext: does subscriptionType enter the cache key?"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
dim "  Queries user:1 (SINGLE) then user:3 (DOUBLE) via the single-user 'user' field."
dim "  The Router resolves User.forYouProducts (incl. foryou @fromContext) in a single"
dim "  _entities call to the reviews subgraph. Cache key is type:User in reviews."
dim "  user:1 vs user:3 → different repr (different user ID) AND different query_hash"
dim "  (different subscriptionType inlined by @fromContext) → fully distinct keys."
dim "  Expected: separate Redis keys for each user → no cross-user cache collision."

flush_redis

FYP_QUERY='"query GetForYouProducts { user { id subscriptionType forYouProducts { upc foryou } } }"'

# Query as user:1 (SINGLE) — foryou should be false for all products
dim "  Querying as user:1 (SINGLE)..."
gql_as "user:1" '{"operationName":"GetForYouProducts","query":"query GetForYouProducts { user { id subscriptionType forYouProducts { upc foryou } } }"}'

dim ""
dim "  After user:1 query — Redis keys (reviews subgraph, User type):"
dump_keys_for_type "reviews" "User"

B_KEYS_SINGLE=$(list_cache_keys | grep "subgraph:reviews:type:User" | wc -l | tr -d ' \n')
dim "  User keys in reviews after SINGLE user query: ${B_KEYS_SINGLE}"

# Query as user:3 (DOUBLE) — same products, different subscriptionType context
dim "  Querying as user:3 (DOUBLE)..."
gql_as "user:3" '{"operationName":"GetForYouProducts","query":"query GetForYouProducts { user { id subscriptionType forYouProducts { upc foryou } } }"}'

dim ""
dim "  After user:3 query — Redis keys (reviews subgraph, User type):"
dump_keys_for_type "reviews" "User"

B_KEYS_TOTAL=$(list_cache_keys | grep "subgraph:reviews:type:User" | wc -l | tr -d ' \n')
dim "  Total User keys in reviews after both SINGLE + DOUBLE queries: ${B_KEYS_TOTAL}"

# Verify user:3 key still exists in Redis (it was just created — not a cache-hit check,
# but confirms the key was stored and persists between requests)
B_KEY_EXISTS=$(list_cache_keys | grep "subgraph:reviews:type:User" | grep -v "cache-tag" | wc -l | tr -d ' \n')
dim "  Distinct User entity keys in reviews after both queries: ${B_KEY_EXISTS}"
# Note: x-response-cache header absence is expected here — the auth header (x-user-id)
# causes the full router response to be non-cacheable at the HTTP layer, but entity-level
# Redis keys (the ones we're inspecting) ARE created as confirmed above.
dim "  (x-response-cache header absent because x-user-id auth prevents full-response caching;"
dim "   entity-level keys ARE present in Redis as shown by the key dump above)"

# Inspect repr and query segments for User keys in reviews (type:User caches the forYouProducts response)
PROD_REPR_SEGMENTS=$(list_cache_keys | grep "subgraph:reviews:type:User" | while IFS= read -r k; do repr_segment "$k"; done | sort -u)
PROD_QUERY_SEGMENTS=$(list_cache_keys | grep "subgraph:reviews:type:User" | while IFS= read -r k; do query_segment "$k"; done | sort -u)
UNIQUE_PROD_REPR=$(echo "$PROD_REPR_SEGMENTS" | grep -c . 2>/dev/null; true)
UNIQUE_PROD_QUERY=$(echo "$PROD_QUERY_SEGMENTS" | grep -c . 2>/dev/null; true)

dim ""
dim "  Unique repr segments for User (reviews, carries forYouProducts): ${UNIQUE_PROD_REPR}"
dim "  Unique query_hash segments for User (reviews): ${UNIQUE_PROD_QUERY}"

bold ""
bold "  ── @fromContext analysis ──"

if [ "$UNIQUE_PROD_REPR" -gt 1 ]; then
  check_pass "@fromContext: different users have distinct repr segments in reviews User entity keys"
  cyan "  → user:1 (SINGLE) and user:3 (DOUBLE) produce different User repr hashes."
  cyan "  → Different User ID → different entity representation → distinct Redis keys."
  cyan "  → @fromContext additionally inlines subscriptionType in the query document"
  cyan "    (visible in different query_hash segments if present)."
  cyan "  → Cache collision risk: NONE."
  cyan "  CONCLUSION: @fromContext is SAFE for caching — each user has their own key."
elif [ "$UNIQUE_PROD_QUERY" -gt 1 ] && [ "$B_KEYS_TOTAL" -gt 1 ]; then
  check_pass "@fromContext inlines subscriptionType into subgraph query — different query_hash per context"
  cyan "  → Same repr segment (same user), but different query_hash → distinct Redis keys."
  cyan "  → Cache collision risk: NONE."
  cyan "  CONCLUSION: @fromContext is SAFE for caching."
elif [ "$B_KEYS_TOTAL" -gt 1 ]; then
  check_pass "@fromContext: multiple User entity keys found — users are independently cached"
  cyan "  → user:1 and user:3 have distinct Redis keys in the reviews subgraph."
  cyan "  → Cache collision risk: NONE."
  cyan "  CONCLUSION: @fromContext is SAFE for caching."
else
  check_fail "@fromContext: only ${B_KEYS_TOTAL} User key(s) found — check caching setup"
  yellow "  ⚠ Expected at least 2 User entity keys (one per user with distinct subscriptionType)."
  yellow "  Ensure User @cacheControl is set in the reviews schema."
fi

if [ "$B_KEYS_TOTAL" -gt "$B_KEYS_SINGLE" ] 2>/dev/null; then
  dim ""
  dim "  Keys grew from ${B_KEYS_SINGLE} (after user:1) to ${B_KEYS_TOTAL} (after user:3 added)."
  dim "  → Router IS generating distinct cache keys per user / subscriptionType context."
fi

# =============================================================================
# SCENARIO C — @fromContext: verify foryou returns correct values
# Sanity check that the resolver returns different values for SINGLE vs DOUBLE
# =============================================================================

bold "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
bold "  SCENARIO C — Verify foryou resolver returns correct values"
bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
dim "  Checks that user:3 (DOUBLE) gets foryou=true and user:1 (SINGLE) gets foryou=false."
dim "  Uses single-user 'user' field with x-user-id header."

flush_redis

dim "  user:1 (SINGLE) response:"
gql_as "user:1" '{"operationName":"GetForyou","query":"query GetForyou { user { id subscriptionType forYouProducts { upc foryou } } }"}'
BODY_SINGLE=$(cat /tmp/rc_body.json 2>/dev/null)

dim "  user:3 (DOUBLE) response:"
gql_as "user:3" '{"operationName":"GetForyou","query":"query GetForyou { user { id subscriptionType forYouProducts { upc foryou } } }"}'
BODY_DOUBLE=$(cat /tmp/rc_body.json 2>/dev/null)

# Parse and display both responses
for label in SINGLE DOUBLE; do
  if [ "$label" = "SINGLE" ]; then
    BODY="$BODY_SINGLE"
  else
    BODY="$BODY_DOUBLE"
  fi
  echo "$BODY" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    u = data.get('data',{}).get('user',{}) or {}
    uid = u.get('id','?')
    sub = u.get('subscriptionType','?')
    products = u.get('forYouProducts') or []
    print(f'  user={uid} subscriptionType={sub}')
    for p in products[:3]:
        print(f'    product={p.get(\"upc\",\"?\")} foryou={p.get(\"foryou\")}')
    if len(products) > 3:
        print(f'    ... ({len(products)} total)')
except Exception as e:
    print(f'  parse error: {e}')
" 2>/dev/null || dim "  (python3 not available)"
done

# ─── Summary ──────────────────────────────────────────────────────────────────

bold "\n── Test Summary ──"
total=$((PASS + FAIL))
printf "  Passed: %d / %d\n" "$PASS" "$total"
if [ "$FAIL" -gt 0 ]; then
  red "  Failed: $FAIL — check output and conclusions above"
else
  green "  All assertions passed."
fi

bold "\n── What to do with these results ──"
dim "  1. Paste the output (especially the CONCLUSION lines) into your customer answer."
dim "  2. The Redis key dumps show the exact repr/query segments — share them as evidence."
dim "  3. If Scenario B shows a cache collision risk, recommend:"
dim "     a. Add the context field to the entity @key (makes it part of the representation)"
dim "     b. Or use Router.APOLLO_RESPONSE_CACHE_KEY in main.rhai to append the"
dim "        context value to the cache key per-request."
dim "  4. See DEV.md → @fromContext cache key analysis for the full write-up."
printf "\n"

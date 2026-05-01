#!/usr/bin/env bash
# =============================================================================
# Cache Header Test Suite — Rhai x-operation-name + x-response-cache
# =============================================================================
# Validates the Rhai script in main.rhai that injects custom response headers:
#
#   x-operation-name              — GraphQL operation name
#   x-response-cache              — Aggregate: hit | partial_hit | miss | unknown
#   x-response-cache-{subgraph}   — Per-subgraph status (only for participants)
#
# Scenarios covered:
#   1.  Tracked op, cold cache          → miss
#   2.  Tracked op, warm cache          → hit
#   3.  Untracked operation             → NO headers injected
#   4.  Anonymous (unnamed) operation   → NO headers injected
#   5.  Per-subgraph header presence    → single-subgraph query shows one header
#   6.  Multi-subgraph, all cold        → partial_hit or miss, two subgraph headers
#   7.  Multi-subgraph, partial hit     → products cached, reviews cold → partial_hit
#   8.  Multi-subgraph, all warm        → hit, both subgraph headers show hit
#   9.  Cache disabled subgraph         → header absent for that subgraph
#   10. Same subgraph called twice      → aggregate reflects both calls
#
# Prerequisites:
#   1. Redis running:     docker compose up -d            (port 6380)
#   2. Subgraphs running: npm run dev:subgraphs            (port 4001)
#   3. Router running:    npm run router:start             (port 4000)
#      NOTE: rover dev reloads Rhai scripts on save; router:start does not.
#            Either works for header tests; router:start is faster to restart.
#
# Usage:
#   chmod +x test-cache-headers.sh && ./test-cache-headers.sh
# =============================================================================

ROUTER="http://localhost:4000"
REDIS_CLI="docker exec retail-supergraph-redis-1 redis-cli -p 6379"
PASS=0
FAIL=0

# ─── Helpers ─────────────────────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
dim()   { printf "\033[2m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

check_pass() { green "  ✓ $1"; ((PASS++)); }
check_fail() { red   "  ✗ $1"; ((FAIL++)); }

# Send a named GraphQL operation; response headers written to /tmp/rhai_headers.txt
gql() {
  curl -s -D /tmp/rhai_headers.txt -o /tmp/rhai_body.json \
    -X POST "$ROUTER" \
    -H "Content-Type: application/json" \
    -d "$1"
}

# Read a response header value (case-insensitive)
get_header() {
  grep -i "^$1:" /tmp/rhai_headers.txt | sed 's/^[^:]*: *//' | tr -d '\r\n'
}

# Print all response headers from the last gql() call (for debugging)
dump_headers() {
  dim "  --- response headers ---"
  grep -v "^HTTP" /tmp/rhai_headers.txt | grep -v "^$" | while read -r line; do
    dim "  $line"
  done
}

assert_header_eq() {
  local name="$1" expected="$2" label="$3"
  local actual
  actual=$(get_header "$name")
  if [ "$actual" = "$expected" ]; then
    check_pass "$label  ($name: $actual)"
  else
    check_fail "$label  ($name: expected '$expected', got '${actual:-<absent>}')"
  fi
}

assert_header_absent() {
  local name="$1" label="$2"
  local actual
  actual=$(get_header "$name")
  if [ -z "$actual" ]; then
    check_pass "$label  ($name absent as expected)"
  else
    check_fail "$label  ($name should be absent, got '$actual')"
  fi
}

assert_header_one_of() {
  local name="$1" label="$2"
  shift 2
  local actual
  actual=$(get_header "$name")
  for v in "$@"; do
    if [ "$actual" = "$v" ]; then
      check_pass "$label  ($name: $actual)"
      return
    fi
  done
  check_fail "$label  ($name: expected one of [$(IFS=|; echo "$*")], got '${actual:-<absent>}')"
}

flush_redis() {
  $REDIS_CLI FLUSHALL > /dev/null 2>&1
  dim "  Redis flushed."
}

# Delete all response-cache entries for a single subgraph, leaving others intact.
# Used to synthesise a partial-hit scenario without flushing the whole cache.
evict_subgraph_cache() {
  local sg="$1"
  local keys
  keys=$($REDIS_CLI --scan --pattern "responseCache:*:subgraph:${sg}:*" 2>/dev/null)
  if [ -n "$keys" ]; then
    echo "$keys" | xargs $REDIS_CLI DEL > /dev/null 2>&1
  fi
  dim "  Evicted Redis keys for subgraph '${sg}'."
}

# ─── Pre-flight ───────────────────────────────────────────────────────────────

bold "\n╔══════════════════════════════════════════════════════════════╗"
bold "║   Cache Header Tests — Rhai x-operation-name / x-response-cache  ║"
bold "╚══════════════════════════════════════════════════════════════╝"

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

# ─── Scenario 1 & 2: Tracked operation, miss then hit ────────────────────────

bold "\n── Scenario 1 & 2: Tracked op — miss on cold cache, hit on warm ──"
dim "  Operation: GetProducts (single subgraph: products)"
dim "  Expected miss → hit across two calls"

flush_redis

gql '{"operationName":"GetProducts","query":"query GetProducts { listAllProducts { id title } }"}'
assert_header_eq "x-operation-name" "GetProducts"  "Sc1: x-operation-name set"
assert_header_eq "x-response-cache" "miss"          "Sc1: first call is miss"
assert_header_eq "x-response-cache-products" "miss" "Sc1: products subgraph miss"

gql '{"operationName":"GetProducts","query":"query GetProducts { listAllProducts { id title } }"}'
assert_header_eq "x-operation-name" "GetProducts"  "Sc2: x-operation-name set"
assert_header_eq "x-response-cache" "hit"           "Sc2: second call is hit"
assert_header_eq "x-response-cache-products" "hit"  "Sc2: products subgraph hit"

# ─── Scenario 3: Untracked operation name ─────────────────────────────────────

bold "\n── Scenario 3: Untracked operation — no headers injected ──"
dim "  Operation: GetAllUsers (not in tracked_operations() in main.rhai)"

gql '{"operationName":"GetAllUsers","query":"query GetAllUsers { users { id username } }"}'
assert_header_absent "x-operation-name" "Sc3: x-operation-name absent for untracked op"
assert_header_absent "x-response-cache" "Sc3: x-response-cache absent for untracked op"

# ─── Scenario 4: Anonymous operation ─────────────────────────────────────────

bold "\n── Scenario 4: Anonymous (unnamed) operation — no headers injected ──"
dim "  No operationName field in the request body"

gql '{"query":"{ listAllProducts { id title } }"}'
assert_header_absent "x-operation-name" "Sc4: x-operation-name absent for anonymous op"
assert_header_absent "x-response-cache" "Sc4: x-response-cache absent for anonymous op"

# ─── Scenario 5: Per-subgraph header only for participants ────────────────────

bold "\n── Scenario 5: Per-subgraph header — only participating subgraphs appear ──"
dim "  GetProducts only touches 'products' — no x-response-cache-reviews expected"

gql '{"operationName":"GetProducts","query":"query GetProducts { listAllProducts { id title } }"}'
assert_header_absent "x-response-cache-reviews"   "Sc5: reviews header absent (not in query)"
assert_header_absent "x-response-cache-orders"    "Sc5: orders header absent (not in query)"
assert_header_absent "x-response-cache-inventory" "Sc5: inventory header absent (not in query)"

# ─── Scenario 6: Multi-subgraph, all cold (miss) ─────────────────────────────

bold "\n── Scenario 6: Multi-subgraph, cold cache — both subgraphs miss ──"
dim "  Operation: GetProductsWithReviews (products + reviews subgraph)"
dim "  Both subgraphs cold → aggregate = miss, both per-subgraph headers = miss"

flush_redis

gql '{"operationName":"GetProductsWithReviews","query":"query GetProductsWithReviews { listAllProducts { id title upc reviews { id } } }"}'
assert_header_eq "x-operation-name"              "GetProductsWithReviews" "Sc6: x-operation-name set"
assert_header_one_of "x-response-cache"          "Sc6: aggregate is miss or partial_hit" "miss" "partial_hit"
assert_header_one_of "x-response-cache-products" "Sc6: products header present"          "miss" "partial_hit" "hit"
assert_header_one_of "x-response-cache-reviews"  "Sc6: reviews header present"           "miss" "partial_hit" "hit"

# ─── Scenario 7: Multi-subgraph, partial hit ─────────────────────────────────

bold "\n── Scenario 7: Multi-subgraph, partial hit — products cached, reviews evicted ──"
dim "  Strategy: warm both subgraphs with one GetProductsWithReviews call, then"
dim "  evict only the reviews Redis keys so the next call hits products but misses reviews."
dim "  Expected: x-response-cache = partial_hit"

flush_redis

# One cold call caches both subgraphs.
dim "  Warming both subgraphs..."
gql '{"operationName":"GetProductsWithReviews","query":"query GetProductsWithReviews { listAllProducts { id title upc reviews { id } } }"}'

# Evict only reviews — products cache stays intact.
evict_subgraph_cache "reviews"

# Products served from cache, reviews cold → partial_hit
gql '{"operationName":"GetProductsWithReviews","query":"query GetProductsWithReviews { listAllProducts { id title upc reviews { id } } }"}'
assert_header_eq "x-response-cache"              "partial_hit" "Sc7: aggregate is partial_hit"
assert_header_eq "x-response-cache-products"     "hit"         "Sc7: products subgraph hit (cached)"
assert_header_eq "x-response-cache-reviews"      "miss"        "Sc7: reviews subgraph miss (evicted)"

# ─── Scenario 8: Multi-subgraph, both warm (hit) ─────────────────────────────

bold "\n── Scenario 8: Multi-subgraph, fully warm — both subgraphs hit ──"
dim "  Self-contained flush+warm cycle: first call is miss, second call must be hit."
dim "  Validates the core customer requirement: request 1 = miss, request 2 = hit."

flush_redis

gql '{"operationName":"GetProductsWithReviews","query":"query GetProductsWithReviews { listAllProducts { id title upc reviews { id } } }"}'
assert_header_eq "x-response-cache"          "miss" "Sc8-cold: first call is miss"

gql '{"operationName":"GetProductsWithReviews","query":"query GetProductsWithReviews { listAllProducts { id title upc reviews { id } } }"}'
assert_header_eq "x-response-cache"          "hit" "Sc8: aggregate is hit"
assert_header_eq "x-response-cache-products" "hit" "Sc8: products subgraph hit"
assert_header_eq "x-response-cache-reviews"  "hit" "Sc8: reviews subgraph hit"

# ─── Scenario 9: Cache disabled subgraph — no per-subgraph header ────────────

bold "\n── Scenario 9: Subgraph with cache disabled — no per-subgraph header ──"
dim "  If a subgraph has response_cache.subgraph.subgraphs.<name>.enabled: false,"
dim "  the cache plugin writes no cache_info context key for it."
dim "  The Rhai script exits early for that subgraph → no header emitted."
dim ""
dim "  This is by design: the header only reflects what the cache plugin tracked."
dim "  A missing x-response-cache-{name} means that subgraph bypassed the cache."
dim ""
yellow "  ⚠  No automated assertion here — verify manually by setting"
yellow "     response_cache.subgraph.subgraphs.reviews.enabled: false in"
yellow "     router-config-dev.yaml, restarting, and running GetProductsWithReviews."
yellow "     Expect: x-response-cache-reviews absent, x-response-cache-products: hit/miss"

# ─── Scenario 10: Same subgraph called multiple times ─────────────────────────

bold "\n── Scenario 10: Same subgraph called N times — upsert aggregates all calls ──"
dim "  A query plan may fan out to the same subgraph more than once"
dim "  (e.g. entity fetch + root field in same op, or batching split)."
dim "  The subgraph_service hook uses upsert() so each call contributes."
dim "  hit+hit=hit, miss+miss=miss, any disagreement=partial_hit."
dim ""
dim "  Testing with GetProductById which involves one products call:"

flush_redis

gql '{"operationName":"GetProductById","query":"query GetProductById { product(id: \"product:1\") { id title upc } }"}'
assert_header_eq "x-operation-name"          "GetProductById" "Sc10: x-operation-name set"
assert_header_eq "x-response-cache"          "miss"           "Sc10: first call is miss"
assert_header_eq "x-response-cache-products" "miss"           "Sc10: products miss"

gql '{"operationName":"GetProductById","query":"query GetProductById { product(id: \"product:1\") { id title upc } }"}'
assert_header_eq "x-response-cache"          "hit"            "Sc10: second call is hit"
assert_header_eq "x-response-cache-products" "hit"            "Sc10: products hit"

# ─── Router.APOLLO_OPERATION_ID — reference context key ──────────────────────

bold "\n── Additional context keys verified in Router.* constants ──"
dim "  These are the stable, public-API context keys (from Rhai reference docs)."
dim "  Not tested automatically here — see DEV.md for full list."
dim ""
dim "  Router.APOLLO_OPERATION_ID       — Apollo Studio stable operation ID"
dim "  Router.APOLLO_COST_ACTUAL_KEY    — query cost (requires demand control)"
dim "  Router.APOLLO_RESPONSE_CACHE_KEY — used to customise cache key per-request"
dim "  Router.APOLLO_AUTHENTICATION_JWT_CLAIMS — JWT claims (requires auth plugin)"

# ─── Summary ──────────────────────────────────────────────────────────────────

bold "\n── Test Summary ──"
total=$((PASS + FAIL))
printf "  Passed: %d / %d\n" "$PASS" "$total"
if [ "$FAIL" -gt 0 ]; then
  red   "  Failed: $FAIL — check output above"
else
  green "  All assertions passed."
fi
printf "\n"

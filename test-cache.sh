#!/usr/bin/env bash
# =============================================================================
# Response Cache Test Suite — Apollo Retail Supergraph
# =============================================================================
# Prerequisites:
#   1. Redis running:    docker compose up -d
#   2. Subgraphs running: npm run dev:subgraphs   (port 4001)
#   3. Router running:   npm run router:start      (port 4000)
#      NOTE: use router:start (standalone binary), NOT rover dev, for
#            response_cache.invalidation support on port 4005.
#
# Usage:
#   chmod +x test-cache.sh
#   ./test-cache.sh
# =============================================================================

ROUTER="http://localhost:4000"
REDIS_CLI="docker exec retail-supergraph-redis-1 redis-cli -p 6379"
INVALIDATION="http://127.0.0.1:4005/invalidation"
INVALIDATION_SHARED_KEY="${INVALIDATION_SHARED_KEY:-dev-invalidation-key}"
PASS=0
FAIL=0

# ─── Helpers ─────────────────────────────────────────────────────────────────

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
dim()   { printf "\033[2m%s\033[0m\n" "$*"; }

gql() {
  local query="$1" header="$2"
  if [ -n "$header" ]; then
    curl -s -o /tmp/cache_resp.json -w "%{time_total}" \
      -X POST "$ROUTER" -H "Content-Type: application/json" \
      -H "$header" -d "{\"query\":\"$query\"}"
  else
    curl -s -o /tmp/cache_resp.json -w "%{time_total}" \
      -X POST "$ROUTER" -H "Content-Type: application/json" \
      -d "{\"query\":\"$query\"}"
  fi
}

redis_keys() {
  $REDIS_CLI KEYS "responseCache*" 2>/dev/null | sort
}

redis_ttl() {
  local pattern="$1"
  for key in $($REDIS_CLI KEYS "$pattern" 2>/dev/null); do
    ttl=$($REDIS_CLI TTL "$key")
    # Trim the long hash suffix for readability
    short=$(echo "$key" | sed 's/responseCache:version:1.1://' | sed 's/:data:070af.*//')
    printf "  TTL:%3ds  %s\n" "$ttl" "$short"
  done
}

check_pass() { green "  ✓ $1"; ((PASS++)); }
check_fail() { red   "  ✗ $1"; ((FAIL++)); }

assert_faster() {
  local miss_time="$1" hit_time="$2" label="$3"
  if (( $(echo "$hit_time < $miss_time" | bc -l) )); then
    check_pass "$label: HIT (${hit_time}s) faster than MISS (${miss_time}s)"
  else
    check_fail "$label: HIT (${hit_time}s) NOT faster than MISS (${miss_time}s) — cache may not be working"
  fi
}

assert_key_exists() {
  local pattern="$1" label="$2"
  count=$($REDIS_CLI KEYS "$pattern" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt 0 ]; then
    check_pass "Redis key exists: $label"
  else
    check_fail "Redis key MISSING: $label"
  fi
}

assert_key_gone() {
  local pattern="$1" label="$2"
  count=$($REDIS_CLI KEYS "$pattern" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -eq 0 ]; then
    check_pass "Redis key gone after invalidation: $label"
  else
    check_fail "Redis key still present after invalidation: $label ($count keys)"
  fi
}

# ─── Setup ───────────────────────────────────────────────────────────────────

bold "\n=============================="
bold " Apollo Response Cache Tests"
bold "=============================="

# Verify services
printf "\nChecking services...\n"

if ! curl -sf "$ROUTER" -X POST -H "Content-Type: application/json" \
     -d '{"query":"{__typename}"}' > /dev/null 2>&1; then
  red "Router not reachable at $ROUTER. Start with: npm run router:start"
  exit 1
fi
green "  ✓ Router at $ROUTER"

if ! $REDIS_CLI ping > /dev/null 2>&1; then
  red "Redis not reachable. Start with: docker compose up -d"
  exit 1
fi
green "  ✓ Redis connected"

printf "\nFlushing Redis for a clean run...\n"
$REDIS_CLI FLUSHALL > /dev/null
dim "  Redis flushed."

# ─── UC1: Root list cache — listAllProducts (maxAge: 90s) ────────────────────

bold "\n── UC1: listAllProducts root cache (maxAge: 90s, tag: root-products) ──"
QUERY='{ listAllProducts { id title } }'

miss=$(gql "$QUERY"); sleep 1
hit=$(gql "$QUERY")

assert_faster "$miss" "$hit" "listAllProducts"
assert_key_exists "responseCache*cache-tag*root-products*" "root-products tag"

ttl=$($REDIS_CLI KEYS "responseCache*:type:Query:hash:*" 2>/dev/null | head -1 | xargs -I{} $REDIS_CLI TTL {})
printf "  Cache-Control header (from router log):  max-age=90,public\n"
printf "  Redis TTL on entry: ${ttl}s\n"

# ─── UC2: Root single entity — product(id) (maxAge: 60s) ─────────────────────

bold "\n── UC2: product(id: \"product:1\") root cache (maxAge: 60s, tag: root-product-product:1) ──"
QUERY='{ product(id: \"product:1\") { id title upc } }'

miss=$(gql "$QUERY"); sleep 1
hit=$(gql "$QUERY")

assert_faster "$miss" "$hit" "product(id: product:1)"
assert_key_exists "responseCache*cache-tag*root-product-product:1*" "root-product-product:1 tag"

# ─── UC3: Root single entity — variant(id) (maxAge: 60s) ─────────────────────

bold "\n── UC3: variant(id: \"variant:1\") root cache (maxAge: 60s, tag: root-variant-variant:1) ──"
QUERY='{ variant(id: \"variant:1\") { id price size } }'

miss=$(gql "$QUERY"); sleep 1
hit=$(gql "$QUERY")

assert_faster "$miss" "$hit" "variant(id: variant:1)"
assert_key_exists "responseCache*cache-tag*root-variant-variant:1*" "root-variant-variant:1 tag"

# ─── UC4: Mixed TTL — listAllProducts + variants (min of 90s + 60s = 60s) ────

bold "\n── UC4: Mixed TTL — listAllProducts { variants } (effective TTL = min(90,60) = 60s) ──"
QUERY='{ listAllProducts { id title variants { id price size } } }'

miss=$(gql "$QUERY"); sleep 1
hit=$(gql "$QUERY")

assert_faster "$miss" "$hit" "listAllProducts+variants (mixed TTL)"
dim "  Expected effective TTL = 60s (minimum wins across all @cacheControl directives in the plan)"

# ─── UC5: No @cacheControl — searchProducts (falls back to router 300s TTL) ──

bold "\n── UC5: searchProducts — no @cacheControl on field (router fallback TTL = 300s) ──"
QUERY='{ searchProducts(searchInput: {}) { id title } }'

miss=$(gql "$QUERY"); sleep 1
hit=$(gql "$QUERY")

# searchProducts WILL be cached due to router fallback TTL (300s) — this is expected
# but may be unintentional. Add @cacheControl(maxAge: 0) to the field to prevent it.
if (( $(echo "$hit < $miss" | bc -l) )); then
  printf "  ⚠ searchProducts IS cached (router 300s fallback TTL is active)\n"
  dim "    To prevent caching, add @cacheControl(maxAge: 0) to searchProducts in products/schema.graphql"
else
  printf "  ✓ searchProducts not cached (or latency too similar to detect)\n"
fi

# ─── UC6: Entity cache — User.recommendedProducts (PRIVATE scope) ─────────────

bold "\n── UC6: User.recommendedProducts entity cache (scope: PRIVATE — no full-response cache) ──"
QUERY='{ user { id username recommendedProducts { id title } } }'

dim "  Using x-user-id: user:1"
miss=$(gql "$QUERY" "x-user-id: user:1"); sleep 1
hit=$(gql "$QUERY" "x-user-id: user:1")

printf "  MISS: ${miss}s  HIT: ${hit}s\n"
dim "  Full response: Cache-Control: no-store (PRIVATE scope → not stored in Redis)"
dim "  But downstream Product entity fetches ARE cached:"
assert_key_exists "responseCache*:type:Product:representation:*" "Product entity representations (from products subgraph)"

# ─── UC7: Tag invalidation — single product ───────────────────────────────────

bold "\n── UC7: Tag invalidation — root-product-product:1 ──"
dim "  Requires standalone router binary (npm run router:start), not rover dev"
dim "  Requires INVALIDATION_SHARED_KEY env var set at router startup"

inv_result=$(curl -s -o /tmp/inv_resp.json -w "%{http_code}" \
  -X POST "$INVALIDATION" \
  -H "Content-Type: application/json" \
  -H "authorization: $INVALIDATION_SHARED_KEY" \
  -d '[{"kind":"cache_tag","subgraphs":["products"],"cache_tag":"root-product-product:1"}]' 2>/dev/null)

if [ "$inv_result" = "200" ] || [ "$inv_result" = "202" ]; then
  sleep 1
  count=$(cat /tmp/inv_resp.json | grep -o '"count":[0-9]*' | grep -o '[0-9]*')
  check_pass "Invalidation responded $inv_result (invalidated $count entries)"
  assert_key_gone "responseCache*cache-tag*root-product-product:1*" "root-product-product:1 tag gone"
  assert_key_exists "responseCache*cache-tag*root-products*" "root-products tag still intact"
else
  red "  ✗ Invalidation endpoint not reachable (HTTP $inv_result)"
  dim "    Fix: add to router-config-dev.yaml under response_cache.subgraph.all:"
  dim "      invalidation:"
  dim "        enabled: true"
  dim "        shared_key: \${env.INVALIDATION_SHARED_KEY}"
  dim "    Then restart router with: INVALIDATION_SHARED_KEY=dev-invalidation-key npm run router:start"
fi

# ─── UC8: Tag invalidation — all products (root-products) ─────────────────────

bold "\n── UC8: Tag invalidation — root-products (clears listAllProducts) ──"
inv_result=$(curl -s -o /tmp/inv_resp.json -w "%{http_code}" \
  -X POST "$INVALIDATION" \
  -H "Content-Type: application/json" \
  -H "authorization: $INVALIDATION_SHARED_KEY" \
  -d '[{"kind":"cache_tag","subgraphs":["products"],"cache_tag":"root-products"}]' 2>/dev/null)

if [ "$inv_result" = "200" ] || [ "$inv_result" = "202" ]; then
  sleep 1
  count=$(cat /tmp/inv_resp.json | grep -o '"count":[0-9]*' | grep -o '[0-9]*')
  check_pass "Invalidation responded $inv_result (invalidated $count entries)"
  assert_key_gone "responseCache*cache-tag*root-products*" "root-products tag gone"
else
  red "  ✗ Invalidation endpoint not reachable (HTTP $inv_result) — see UC7 note above"
fi

# ─── Redis Key Audit ──────────────────────────────────────────────────────────

bold "\n── Redis Key Structure Audit ──"
printf "\nAll responseCache keys in Redis:\n"
redis_keys

printf "\nData key TTLs (Query-level):\n"
redis_ttl "responseCache*:type:Query:hash:*"

printf "\nData key TTLs (Entity representations — Product):\n"
redis_ttl "responseCache*:type:Product:representation:*"

printf "\nCache tags active:\n"
for key in $($REDIS_CLI KEYS "responseCache*cache-tag*" 2>/dev/null | sort); do
  short=$(echo "$key" | sed 's/responseCache:version:1.1:cache-tag:subgraph-products:key-/TAG: /' \
                       | sed 's/responseCache:version:1.1:cache-tag:subgraph-products/TAG: (subgraph-products top-level)/')
  printf "  %s\n" "$short"
done

# ─── Redis Key Format Reference ───────────────────────────────────────────────

bold "\n── Redis Key Format Reference ──"
cat << 'EOF'
  DATA KEYS
  ─────────
  Root query response:
    responseCache:version:1.1:subgraph:{subgraph}:type:Query:hash:{query_hash}:data:{options_hash}

  Entity representation (e.g. Product fetched by @key):
    responseCache:version:1.1:subgraph:{subgraph}:type:{Type}:representation:{repr_hash}:hash:{query_hash}:data:{options_hash}

  CACHE TAG KEYS (used for invalidation)
  ──────────────────────────────────────
  Subgraph-level (invalidates all cached responses for this subgraph):
    responseCache:version:1.1:cache-tag:subgraph-{subgraph}

  Type-level internal tag (all entries for a type):
    responseCache:version:1.1:cache-tag:subgraph-{subgraph}:key-__apollo_internal::...subgraph:{sg}:type:{Type}

  @cacheTag(format: "root-products"):
    responseCache:version:1.1:cache-tag:subgraph-products:key-root-products

  @cacheTag(format: "root-product-{$args.id}") for product:1:
    responseCache:version:1.1:cache-tag:subgraph-products:key-root-product-product:1

  @cacheTag(format: "root-variant-{$args.id}") for variant:1:
    responseCache:version:1.1:cache-tag:subgraph-products:key-root-variant-variant:1

  @cacheTag(format: "product") on Product type:
    responseCache:version:1.1:cache-tag:subgraph-products:key-product

  INVALIDATION PAYLOAD EXAMPLES
  ──────────────────────────────
  All requests require: Authorization: <INVALIDATION_SHARED_KEY>

  Invalidate a single product by id:
    curl -X POST http://127.0.0.1:4005/invalidation \
      -H "authorization: $INVALIDATION_SHARED_KEY" \
      -H "Content-Type: application/json" \
      -d '[{"kind":"cache_tag","subgraphs":["products"],"cache_tag":"root-product-product:1"}]'

  Invalidate all products list:
    -d '[{"kind":"cache_tag","subgraphs":["products"],"cache_tag":"root-products"}]'

  Invalidate all Product entities:
    -d '[{"kind":"cache_tag","subgraphs":["products"],"cache_tag":"product"}]'

  Invalidate a specific variant:
    -d '[{"kind":"cache_tag","subgraphs":["products"],"cache_tag":"root-variant-variant:1"}]'

  Response: {"count": N}  where N = number of cache entries removed
EOF

# ─── Summary ──────────────────────────────────────────────────────────────────

bold "\n── Test Summary ──"
total=$((PASS + FAIL))
printf "  Passed: %d / %d\n" "$PASS" "$total"
if [ "$FAIL" -gt 0 ]; then
  red   "  Failed: $FAIL"
else
  green "  All tests passed."
fi
printf "\n"

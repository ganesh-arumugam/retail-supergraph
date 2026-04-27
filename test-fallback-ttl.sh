#!/usr/bin/env bash
# =============================================================================
# Fallback TTL Proof — Apollo Response Caching
# =============================================================================
# Proves that the Router caches responses using the configured fallback TTL
# (subgraph.all.ttl: 300s) even when a field has NO @cacheControl directive.
#
# Prerequisites:
#   1. docker compose up -d               (Redis on :6380)
#   2. npm run dev:subgraphs              (Subgraphs on :4001)
#   3. npm run router:start              (Router on :4000)
#
# Run: chmod +x test-fallback-ttl.sh && ./test-fallback-ttl.sh
# =============================================================================

ROUTER="http://localhost:4000"
REDIS="docker exec retail-supergraph-redis-1 redis-cli -p 6379"

bold()  { printf "\033[1m%s\033[0m\n" "$*"; }
green() { printf "\033[32m✓ %s\033[0m\n" "$*"; }
red()   { printf "\033[31m✗ %s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m⚠ %s\033[0m\n" "$*"; }
dim()   { printf "\033[2m  %s\033[0m\n" "$*"; }

# Run a GraphQL query, return response time in seconds
gql_time() {
  curl -s -o /tmp/gql_resp.json -w "%{time_total}" \
    -X POST "$ROUTER" \
    -H "Content-Type: application/json" \
    -d "{\"query\":\"$1\"}"
}

gql_body() {
  cat /tmp/gql_resp.json
}

# ── Preflight ─────────────────────────────────────────────────────────────────

bold "\n╔══════════════════════════════════════════════════════╗"
bold "║   Fallback TTL Proof — Apollo Response Caching      ║"
bold "╚══════════════════════════════════════════════════════╝\n"

printf "Checking services...\n"
if ! curl -sf "$ROUTER" -X POST -H "Content-Type: application/json" \
     -d '{"query":"{__typename}"}' > /dev/null 2>&1; then
  red "Router not reachable at $ROUTER"
  dim "Start with: npm run router:start"
  exit 1
fi
green "Router at $ROUTER"

if ! $REDIS ping > /dev/null 2>&1; then
  red "Redis not reachable"
  dim "Start with: docker compose up -d"
  exit 1
fi
green "Redis connected"

printf "\nFlushing Redis for clean test...\n"
$REDIS FLUSHALL > /dev/null
green "Redis flushed\n"

# ── What we're testing ────────────────────────────────────────────────────────

bold "Schema setup (products/schema.graphql):"
dim "listAllProducts: [Product] @cacheControl(maxAge: 90)   ← explicit maxAge"
dim "searchProducts(...): [Product]                          ← NO @cacheControl directive"
printf "\n"
bold "Router config (router-config-dev.yaml):"
dim "response_cache.subgraph.all.ttl: 300s                  ← fallback TTL"
printf "\n"

# ── Test A: Field WITH @cacheControl(maxAge: 90) ─────────────────────────────

bold "── Test A: listAllProducts  (@cacheControl maxAge: 90s) ──────────────────"

printf "  Request 1 (cache MISS)...\n"
miss_a=$(gql_time '{ listAllProducts { id title } }')
sleep 0.5

printf "  Request 2 (cache HIT)...\n"
hit_a=$(gql_time '{ listAllProducts { id title } }')

printf "  MISS: %ss   HIT: %ss\n" "$miss_a" "$hit_a"

# Get TTL from Redis
key_a=$($REDIS KEYS "responseCache*:type:Query:*" 2>/dev/null | head -1)
ttl_a=$($REDIS TTL "$key_a" 2>/dev/null)
printf "  Redis TTL: %ss\n" "$ttl_a"

if [ "$ttl_a" -le 90 ] && [ "$ttl_a" -gt 0 ]; then
  green "TTL ~90s — matches @cacheControl(maxAge: 90)"
else
  red "TTL unexpected: ${ttl_a}s (expected ≤90)"
fi

# ── Flush Redis before next test ──────────────────────────────────────────────
$REDIS FLUSHALL > /dev/null

# ── Test B: Field with NO @cacheControl → should use fallback 300s ────────────

bold "\n── Test B: searchProducts  (NO @cacheControl — fallback TTL) ─────────────"

printf "  Request 1 (cache MISS)...\n"
miss_b=$(gql_time '{ searchProducts(searchInput: {}) { id title } }')
sleep 0.5

printf "  Request 2 (cache HIT)...\n"
hit_b=$(gql_time '{ searchProducts(searchInput: {}) { id title } }')

printf "  MISS: %ss   HIT: %ss\n" "$miss_b" "$hit_b"

# Get TTL from Redis
key_b=$($REDIS KEYS "responseCache*:type:Query:*" 2>/dev/null | head -1)
ttl_b=$($REDIS TTL "$key_b" 2>/dev/null)
printf "  Redis TTL: %ss\n" "$ttl_b"

if [ "$ttl_b" -gt 90 ] && [ "$ttl_b" -le 300 ]; then
  green "TTL ~300s — fallback TTL is active (no @cacheControl on field)"
else
  red "TTL unexpected: ${ttl_b}s (expected ~300)"
fi

# ── Verdict ───────────────────────────────────────────────────────────────────

bold "\n── Verdict ────────────────────────────────────────────────────────────────"

printf "\n  %-35s %10s  %s\n" "Field" "Redis TTL" "Source"
printf "  %-35s %10s  %s\n" "─────────────────────────────────" "─────────" "──────────────────────────────"
printf "  %-35s %10ss  %s\n" "listAllProducts" "$ttl_a" "@cacheControl(maxAge: 90)"
printf "  %-35s %10ss  %s\n" "searchProducts" "$ttl_b" "Router fallback ttl: 300s"
printf "\n"

if [ "$ttl_a" -le 90 ] && [ "$ttl_a" -gt 0 ] && \
   [ "$ttl_b" -gt 90 ] && [ "$ttl_b" -le 300 ]; then
  green "PROVED: Router uses fallback TTL (300s) when no @cacheControl is set."
  green "        @cacheControl(maxAge) takes precedence when present (90s vs 300s)."
else
  yellow "Results inconclusive — check that router is the standalone binary (npm run router:start)"
  dim    "rover dev does NOT support response_cache invalidation / debug features"
fi

# ── Cache-Control Response Header ─────────────────────────────────────────────

bold "\n── Cache-Control response headers ─────────────────────────────────────────"
printf "\n  listAllProducts:\n"
curl -si -X POST "$ROUTER" -H "Content-Type: application/json" \
  -d '{"query":"{ listAllProducts { id title } }"}' 2>/dev/null \
  | grep -i "cache-control" | sed 's/^/    /'

printf "\n  searchProducts:\n"
curl -si -X POST "$ROUTER" -H "Content-Type: application/json" \
  -d '{"query":"{ searchProducts(searchInput: {}) { id title } }"}' 2>/dev/null \
  | grep -i "cache-control" | sed 's/^/    /'

printf "\n"
bold "Done."
printf "\n"

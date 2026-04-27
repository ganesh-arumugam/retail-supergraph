# Local Development Instructions

## Running locally

### Software requirements

* Install the latest LTS version of Node (preferably using [nvm](https://github.com/nvm-sh/nvm))
* Install the latest [Rover CLI](https://www.apollographql.com/docs/rover/getting-started)

### Install dependencies

```shell
npm install
```

### Running the subgraphs and Router

Run the subgraphs and Router, which use [Apollo Server](https://www.apollographql.com/docs/apollo-server/), using `npm`

```shell
npm run dev
```

### Running just subgraphs in production mode
The subgraphs are deployed all together in a single Express app. You can run them all together in production mode with

```shell
npm start
```

---

## Rhai script — `main.rhai`

The Router is customised via `main.rhai`. It adds two response headers and injects them
only for a pre-defined list of GraphQL operation names.

### Headers injected

| Header | Values | Description |
|---|---|---|
| `x-operation-name` | string | GraphQL operation name sent by the client |
| `x-response-cache` | `hit` \| `partial_hit` \| `miss` \| `unknown` | Aggregate cache status across all subgraphs |
| `x-response-cache-{subgraph}` | `hit` \| `partial_hit` \| `miss` | Per-subgraph status — only emitted for subgraphs that participated in the query |

Headers are **only injected for operations listed in `tracked_operations()`** at the top of
`main.rhai`. Anonymous operations and any operation name not in that list are left untouched.

### Adding a new tracked operation

Edit the `tracked_operations()` function in `main.rhai`:

```rhai
fn tracked_operations() {
    [
        "GetProducts",
        "GetProductById",
        "GetProductsWithReviews",
        "MyNewOperation",          // ← add here
        ...
    ]
}
```

The Router picks up Rhai changes on the next request when running via `rover dev`
(hot-reload). With `router:start` (standalone binary), restart the process.

### How it works

#### Execution flow

```
Request arrives at Router
        │
        ▼
┌─────────────────┐
│  router_service │  ← request only: logs HTTP method + path
└────────┬────────┘
         │
         ▼  (query plan executes — subgraphs called)
         │
┌──────────────────────────────────────────────────────────┐
│  subgraph_service  (fires once per subgraph call)        │
│                                                          │
│  Reads internal context key:                             │
│    apollo::router::response_cache::                      │
│      cache_info_subgraph_{name}                          │
│    = { "Order": {hit:3, miss:0}, "Variant": {…} }        │
│                                                          │
│  Sums hit/miss across all entity types for this call     │
│  → per-subgraph status  → context[x_cache_subgraph_{sg}] │
│  → aggregate upsert     → context[x_cache_status]        │
└──────────────────────────────────────────────────────────┘
         │
         ▼  (all subgraph responses complete)
         │
┌──────────────────────────────────────────────────────────┐
│  supergraph_service  (fires once, on the merged response) │
│                                                          │
│  Reads x_cache_status + x_cache_subgraph_* from context  │
│  Writes HTTP response headers:                           │
│    x-operation-name:          GetUserOrders              │
│    x-response-cache:          partial_hit                │
│    x-response-cache-orders:   miss                       │
│    x-response-cache-products: hit                        │
└──────────────────────────────────────────────────────────┘
```

**Operation name** is read from `response.context["apollo::supergraph::operation_name"]`,
a context key the Router's query planner sets automatically. No request-side hook is needed —
it is available in the `supergraph_service` response callback.

**Cache status** is read from the Router's internal context key per subgraph:

```
apollo::router::response_cache::cache_info_subgraph_{name}
```

Shape: `{ "EntityType": { hit: N, miss: N }, ... }`. The `subgraph_service` response callback
runs *after* the cache plugin resolves the response (from Redis on a hit, or from the real
subgraph on a miss), so the key is populated by the time it is read. The per-subgraph status
is then upserted into `x_cache_subgraph_{name}` in context and merged into the aggregate
`x_cache_status`, both of which the `supergraph_service` response callback reads to write the
final headers.

#### Per-call status classification

The script sums `hit` and `miss` counts across all entity types for a single subgraph call:

| `total_hit` | `total_miss` | Classified as |
|---|---|---|
| > 0 | = 0 | `hit` |
| > 0 | > 0 | `partial_hit` |
| = 0 | > 0 | `miss` |
| key absent | — | *(skipped — cache not active for this subgraph)* |

#### Upsert merge rule

`subgraph_service` can fire **multiple times for the same subgraph** within a single operation
(e.g. the query plan fans out to `products` twice — once for variants, once for product
details). Each call upserts into context using this merge table:

| Existing value | New call value | Result |
|---|---|---|
| `hit` | `hit` | `hit` |
| `miss` | `miss` | `miss` |
| anything | anything else | `partial_hit` |

The same merge logic applies when rolling up across different subgraphs into the request-level
`x_cache_status` aggregate. Any disagreement between subgraphs collapses to `partial_hit`.

> ⚠️ `apollo::supergraph::operation_name` and `cache_info_subgraph_*` are internal Router
> context keys — not part of the public API. They are referenced by the Router's own telemetry
> selectors (`supergraph_operation_name`, `response_cache_status`) so they are stable in
> practice, but should be re-tested after Router version upgrades.

#### Configuration requirements

`response_cache.debug: true` must be set in `router-config-dev.yaml`. Without it the Router
may not populate the internal `cache_info_subgraph_*` context key that the Rhai script reads.
Remove or set to `false` in production (it adds overhead). The `apollo.router.response.cache`
Prometheus metric (also configured in `router-config-dev.yaml`) is the version-stable
alternative for production observability — it does not require `debug: true`.

**Publicly documented context keys** (accessible as `Router.*` constants in any Rhai script):

| Constant | When available | Description |
|---|---|---|
| `Router.APOLLO_AUTHENTICATION_JWT_CLAIMS` | supergraph request | JWT claims object from the auth plugin |
| `Router.APOLLO_OPERATION_ID` | supergraph response | Apollo Studio stable operation ID (hash of the normalised op) |
| `Router.APOLLO_PERSISTED_QUERY_ID_KEY` | supergraph request | Persisted query ID (only if client sent one) |
| `Router.APOLLO_RESPONSE_CACHE_KEY` | supergraph request | Modify the cache key (for tenant/locale segmentation) |
| `Router.APOLLO_COST_ESTIMATED_KEY` | supergraph response | Estimated query cost (requires demand control config) |
| `Router.APOLLO_COST_ACTUAL_KEY` | supergraph response | Actual query cost after execution |
| `Router.APOLLO_COST_RESULT_KEY` | supergraph response | `COST_OK` \| `COST_ESTIMATED_TOO_EXPENSIVE` \| etc. |
| `Router.APOLLO_ENTITY_CACHE_KEY` | subgraph response | Entity cache key computed for this subgraph response |

### Cache status scenarios

| Query shape | `x-response-cache` | Per-subgraph headers |
|---|---|---|
| Single subgraph, all entities in Redis | `hit` | `x-response-cache-products: hit` |
| Single subgraph, all entities cold | `miss` | `x-response-cache-products: miss` |
| Single subgraph, some entities cached | `partial_hit` | `x-response-cache-products: partial_hit` |
| Multi-subgraph, all cached | `hit` | `x-response-cache-products: hit` + `x-response-cache-reviews: hit` |
| Multi-subgraph, one cached one cold | `partial_hit` | `x-response-cache-products: hit` + `x-response-cache-reviews: miss` |
| Entity chain (orders → products), mixed | `partial_hit` | `x-response-cache-orders: miss` + `x-response-cache-products: hit` |
| Same subgraph called twice, mixed results | `partial_hit` | `x-response-cache-products: partial_hit` |
| Subgraph with `enabled: false` | reflects only cached subgraphs | No header for the disabled subgraph |
| Redis unavailable (required_to_start: false) | `miss` or `unknown` | All participating subgraphs show `miss` |

### Testing

```shell
chmod +x test-cache-headers.sh && ./test-cache-headers.sh
```

Prerequisites: Redis (`docker compose up -d`), subgraphs (`npm run dev:subgraphs`), and
Router (`npm run router:start` or `npm run dev`) all running.

The script covers scenarios 1–10 from the table above with automated assertions.
Scenario 9 (disabled subgraph) requires a manual router-config change — instructions are
printed inline.

---

## Entity cache key anatomy and `@requires` / `@fromContext` analysis

### Redis key structure

Every cached entity response lands in a key with this shape:

```
responseCache:version:1.1:subgraph:{sg}:type:{Type}:
  representation:{repr_hash}:hash:{query_hash}:data:{opts_hash}
```

| Segment | What it hashes |
|---|---|
| `representation` | The entity representation JSON sent to the subgraph — `__typename` + `@key` fields + any `@requires` fields |
| `hash` | The subgraph query document text (including inlined argument values) |
| `data` | Per-request cache options (TTL, namespace, etc.) |

Two requests share a Redis key only when **all three segments match**. If any segment differs, they get distinct keys and there is no collision.

---

### `@requires` — confirmed safe

`@requires` fields are part of the entity representation sent to the subgraph. The Router serialises the full representation (including the required external fields) and hashes it into the `representation` segment.

**Example** — `Order.shippingCost @requires(fields: "items { weight } buyer { shippingAddress }")`:

| Order | shippingAddress | repr hash |
|---|---|---|
| order:1 | 123 Main St | `abc123…` |
| order:3 | 456 Oak Ave | `def456…` |
| order:4 | 789 Pine Rd | `ghi789…` |

Different addresses → different representation JSON → different `repr_hash` → **distinct Redis keys**. There is zero risk of a collision from `@requires`.

You can verify this empirically:

```shell
chmod +x test-cache-requires-context.sh && ./test-cache-requires-context.sh
```

Scenario A in that script queries `Order.shippingCost` for all three users (with intentionally different `shippingAddress` values in `users/data.js`) and asserts that the number of distinct `representation` segments in Redis equals the number of distinct orders.

---

### `@fromContext` — placement determines safety

`@fromContext` injects a value from a parent context type as a field argument. The client never sends it — the Router resolves it and passes it to the subgraph. The key question is **where in the subgraph query does the value appear**?

#### How the Router handles it

The Router inlines `@fromContext` argument values directly into the subgraph query document it constructs. For example, for a user with `subscriptionType: DOUBLE` the subgraph receives:

```graphql
query($representations: [_Any!]!) {
  _entities(representations: $representations) {
    ... on Product {
      foryou(subscriptionType: DOUBLE)   # ← inlined, not a variable
    }
  }
}
```

Because the value is **inlined in the query text** (not passed as a variable), it changes the query document hash. The `hash` segment of the Redis key therefore differs between `SINGLE` and `DOUBLE` — even though the `representation` segment (just `{ "__typename": "Product", "upc": "..." }`) is identical.

| User | subscriptionType | repr hash | query hash |
|---|---|---|---|
| user:1 | SINGLE | `same` | `hash-A` |
| user:3 | DOUBLE | `same` | `hash-B` |

Different query hash → **distinct Redis keys** → no collision. `@fromContext` is **safe with the Router's entity cache**.

> ⚠️ This is internal Router behaviour, not a documented guarantee. If the Router implementation changes to pass `@fromContext` values as query variables instead of inlining them, two users with different context values could share a cache key and receive each other's data. Re-run `test-cache-requires-context.sh` after Router version upgrades to confirm.

> **Known Federation 2.12 bug**: Adding `@cacheControl` directly to a type that also uses `@fromContext` in one of its fields causes an `INTERNAL_ERROR` during composition ("context never set") because the cache-tag validator incorrectly fails the context-path check. Workaround: omit `@cacheControl` on the type itself and rely on the owning subgraph's `@cacheControl` (e.g. `products` subgraph already marks `Product @cacheControl(maxAge: 60)`). The `@fromContext` field still caches correctly at runtime via that TTL.

#### What to do if you see a collision

If Scenario B of the test script reports that repr and query hash are both identical across different context values, add the context field to the entity `@key` — this moves the value into the representation and makes the distinction structural:

```graphql
# users subgraph — extend @key to include subscriptionType
type User @key(fields: "id") @key(fields: "id subscriptionType") { ... }

# reviews subgraph — match the composite key
type User @key(fields: "id subscriptionType", resolvable: false) {
  id: ID!
  subscriptionType: SubscriptionType @external
}
```

Or use `Router.APOLLO_RESPONSE_CACHE_KEY` in `main.rhai` to append the context value to the cache key per-request — see the [Router cache key customisation docs](https://www.apollographql.com/docs/router/configuration/entity-caching).

---

### Running the empirical verification

```shell
# Prerequisites: Redis, subgraphs, and Router all running (see top of this file)
chmod +x test-cache-requires-context.sh && ./test-cache-requires-context.sh
```

The script covers three scenarios:

| Scenario | What it tests |
|---|---|
| A | `@requires` fields (shippingAddress) appear in the repr hash → distinct keys per order |
| B | `@fromContext` value (subscriptionType) appears in the query hash → distinct keys per user |
| C | Resolver sanity — user:3 (DOUBLE) gets `foryou=true`, user:1 (SINGLE) gets `foryou=false` |

The script prints the raw Redis key segments (decoded where possible) so you can inspect exactly what is and is not in each cache key.

// =============================================================================
// main.rhai — Apollo Router customization for the retail-supergraph demo
// =============================================================================
//
// Custom response headers (only for operations in tracked_operations()):
//
//   x-operation-name              — GraphQL operation name
//   x-response-cache              — Aggregate: hit | partial_hit | miss | unknown
//   x-response-cache-{subgraph}   — Per-subgraph status (only for subgraphs
//                                   that participated in the query)
//
// Example for a query spanning orders + products:
//   x-operation-name:           GetOrdersWithProducts
//   x-response-cache:           partial_hit
//   x-response-cache-orders:    miss
//   x-response-cache-products:  hit
//
// Key design decisions
// ────────────────────
// • Operation name is read from response.context["apollo::supergraph::operation_name"]
//   — set by the Router's query planner, available on the response path with no
//   request-side hook needed. Same key as the telemetry supergraph_operation_name
//   selector.
//
// • Cache info is read from the Router's internal context key per subgraph:
//     "apollo::router::response_cache::cache_info_subgraph_{name}"
//   Shape: { "EntityType": #{ hit: N, miss: N }, ... }
//   The subgraph_service response callback runs AFTER the cache plugin resolves
//   the response, so this key is populated by the time we read it.
//
// • Per-subgraph status is stored in context as "x_cache_subgraph_{name}" by
//   subgraph_service, then read in supergraph_service to emit per-subgraph headers.
//   Only subgraphs that actually participated in the query emit a header.
//
// ⚠️  "apollo::supergraph::operation_name" and "cache_info_subgraph_*" are
//     internal Router context keys, not part of the public API. They are stable
//     in practice but should be re-tested after Router version upgrades.
//     For a version-stable alternative, use the response_cache_status telemetry
//     selector in router-config-dev.yaml.
// =============================================================================


// ─── Operation allow-list ─────────────────────────────────────────────────────
// Headers are injected ONLY for operations whose names appear here.
// Queries not in this list are completely unaffected.
fn tracked_operations() {
    [
        "GetProducts",
        "GetProductById",
        "GetProductsWithReviews",  // multi-subgraph: products + reviews
        "GetInventory",
        "GetOrders",
        "GetUserOrders",
        "GetOrderShipping"
    ]
}

// ─── Subgraph list ────────────────────────────────────────────────────────────
// All subgraphs that may participate in a cached query.
// Used to emit per-subgraph x-response-cache-{name} headers in supergraph_service.
// Only subgraphs that actually ran for a given query will produce a header.
fn cacheable_subgraphs() {
    [
        "products",
        "reviews",
        "inventory",
        "users",
        "orders",
        "checkout",
        "shipping",
        "discovery"
    ]
}


// ─── router_service ───────────────────────────────────────────────────────────
// Earliest stage — raw HTTP, no parsed GraphQL. Used for request logging only.
fn router_service(service) {
    service.map_request(|request| {
        log_info(`Router request: method=${request.method} path=${request.uri.path}`);
        return request;
    });
}


// ─── supergraph_service ───────────────────────────────────────────────────────
// Response-only hook. By the time this fires, all subgraph_service response
// callbacks have completed, so x_cache_status and x_cache_subgraph_* are fully
// populated in context.
fn supergraph_service(service) {
    service.map_response(|response| {
        // Guards against deferred/subscription chunk responses where
        // response.headers is unavailable.
        if !response.is_primary() {
            return;
        }

        // ── Operation name ────────────────────────────────────────────────────
        let op = response.context["apollo::supergraph::operation_name"];

        // Skip entirely for anonymous operations or those not in the allow-list.
        if op == () || op == "" {
            return;
        }
        if !tracked_operations().contains(op) {
            return;
        }

        // ── x-operation-name ─────────────────────────────────────────────────
        response.headers["x-operation-name"] = op;

        // ── x-response-cache (aggregate) ─────────────────────────────────────
        // Rolled up from all subgraphs by the subgraph_service hook below.
        //   hit         — every entity across every subgraph came from Redis
        //   partial_hit — mix of cached and live-fetched entities
        //   miss        — nothing served from cache
        //   unknown     — cache not active or no subgraphs involved
        let cache_status = response.context["x_cache_status"];
        response.headers["x-response-cache"] = if cache_status == () {
            "unknown"
        } else {
            cache_status
        };

        // ── x-response-cache-{subgraph} (per-subgraph) ───────────────────────
        // Only emitted for subgraphs that actually participated in this query.
        // Subgraphs that weren't called produce no header, keeping the response
        // clean and making it immediately obvious which leg caused a miss.
        //
        // Example output for GetOrdersWithProducts:
        //   x-response-cache-orders:   miss
        //   x-response-cache-products: hit
        for sg in cacheable_subgraphs() {
            let sg_status = response.context[`x_cache_subgraph_${sg}`];
            if sg_status != () {
                response.headers[`x-response-cache-${sg}`] = sg_status;
            }
        }
    });
}


// ─── subgraph_service ─────────────────────────────────────────────────────────
// Called once per subgraph call per operation (may fire multiple times for the
// same subgraph if the query plan fans out to it more than once).
//
// For each call it:
//   1. Reads the cache plugin's hit/miss counts for this subgraph from context
//   2. Classifies them as hit / partial_hit / miss
//   3. Stores the per-subgraph status in context (x_cache_subgraph_{name})
//   4. Upserts the request-level aggregate (x_cache_status)
//
// The upsert merge rule:
//   hit + hit         → hit
//   miss + miss       → miss
//   anything else     → partial_hit
//
// This correctly handles all multi-subgraph and multi-call-to-same-subgraph
// combinations — any disagreement between calls collapses to partial_hit.
fn subgraph_service(service, subgraph) {
    let sg = subgraph;

    service.map_response(|response| {
        // Internal key written by the response_cache plugin for this subgraph.
        // Shape: { "EntityType": #{ hit: N, miss: N }, ... }
        let cache_key = `apollo::router::response_cache::cache_info_subgraph_${sg}`;

        try {
            let cache_info = response.context[cache_key];

            // Key absent = cache not active for this subgraph.
            if cache_info == () {
                return;
            }

            // Sum hit/miss counts across all entity types for this subgraph call.
            // Guard each field access: on a full cache hit some Router versions omit
            // the "miss" key entirely (e.g. { hit: 1 } instead of { hit: 1, miss: 0 }),
            // which would cause a type error if added to an integer directly.
            let total_hit  = 0;
            let total_miss = 0;
            for v in cache_info.values() {
                let h = v["hit"];
                let m = v["miss"];
                if h != () { total_hit  += h; }
                if m != () { total_miss += m; }
            }

            // Both counts being zero means cache_info existed but carried no data
            // (e.g. cache not active for this entity type). Skip rather than
            // misreporting as "miss".
            if total_hit == 0 && total_miss == 0 {
                return;
            }

            let sg_status = if total_hit > 0 && total_miss == 0 {
                "hit"
            } else if total_hit > 0 && total_miss > 0 {
                "partial_hit"
            } else {
                "miss"
            };

            // ── Per-subgraph context key ──────────────────────────────────────
            // If this subgraph is called more than once (e.g. the query plan fans
            // out to products twice), upsert so both calls contribute.
            let captured = sg_status;
            response.context.upsert(`x_cache_subgraph_${sg}`, |current| {
                if current == () { captured }
                else if current == "hit" && captured == "hit" { "hit" }
                else if current == "miss" && captured == "miss" { "miss" }
                else { "partial_hit" }
            });

            // ── Request-level aggregate ───────────────────────────────────────
            response.context.upsert("x_cache_status", |current| {
                if current == () { captured }
                else if current == "hit" && captured == "hit" { "hit" }
                else if current == "miss" && captured == "miss" { "miss" }
                else { "partial_hit" }
            });

        } catch(err) {
            // Cache disabled for this subgraph or internal key changed in a
            // newer Router version — fail silently.
            log_debug(`[cache-header] subgraph '${sg}' cache info unavailable: ${err}`);
        }
    });
}

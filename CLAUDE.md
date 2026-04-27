# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Install dependencies
npm install

# Run subgraphs (nodemon, port 4001) + Router (rover dev, port 4000) together
npm run dev

# Run subgraphs only (production mode)
npm start

# Run MCP server (port 8000) + subgraphs + Router via rover dev
npm run mcp

# Validate: TypeScript compile check + supergraph composition
npm test

# Compose supergraph schema locally (outputs supergraph.graphql)
npm run test:compose

# Start Redis (required for response cache and query plan cache)
docker compose up -d

# Publish all subgraph schemas to GraphOS
./publish_subgraphs.sh
```

## Architecture

This is an Apollo Federation supergraph for a retail demo. All 8 subgraphs run as a **single Express monolith** locally on port 4001 at distinct paths (e.g., `/products/graphql`, `/users/graphql`). The GraphOS Router runs on port 4000 and federates them.

### Subgraph structure

Each subgraph under `subgraphs/<name>/` follows the same pattern:
- `schema.graphql` — federated GraphQL schema
- `resolvers.js` — resolver implementations
- `data.js` — in-memory mock data
- `subgraph.js` — builds the subgraph schema via `buildSubgraphSchema` and exports `get<Name>Schema()`

`subgraphs/subgraphs.js` is the monolith entry point — it imports all `get<Name>Schema()` functions and mounts each as an Apollo Server instance on the shared Express app.

### Key entity relationships

- **Product** (`@key: id, upc`) → has Variants; owned by `products` subgraph
- **Variant** (`@key: id`) → belongs to Product; referenced by `orders` and `inventory`
- **User** (`@key: id`) → owns Orders and PaymentMethods; `users` subgraph uses `@context(name: "userContext")` to propagate user data downstream
- **Order** (`@key: id`) → references User and Variant (both `resolvable: false` stubs)

### Schema tags (contracts)

Tags control schema visibility across contract variants:
- `@tag(name: "internal")` — fields like `fraudScore`, `AdminUser`, `internalId`
- `@tag(name: "partner")` — `Product` type exposed to partners
- `@tag(name: "experimental")` — `socialAccounts` on User

### Response caching

Configured in `router-config-dev.yaml` using Redis (port 6380). The `products` subgraph uses `@cacheControl(maxAge)` and `@cacheTag(format: "...")` for tag-based cache invalidation. Cache invalidation endpoint listens at `localhost:4005/invalidation`.

### MCP Server

`mcp.yaml` configures the Apollo MCP Server (port 8000) pointing at the Router. Operations exposed as MCP tools live in `operations/`. Auth uses Auth0 with `streamable_http` transport.

### Router customization

`router-config-dev.yaml` configures the Router with:
- Redis-backed query plan cache and response cache
- OTLP tracing to `localhost:4317`, Prometheus metrics at `localhost:9090`
- Rhai script (`main.rhai`) that logs all incoming requests at `router_service` level
- All request headers propagated to subgraphs

### Environment variables

`APOLLO_KEY` and `APOLLO_GRAPH_REF` are required for `rover dev` and `publish_subgraphs.sh`. They are hardcoded in `package.json` scripts for local dev — replace with your own graph credentials when working against a different GraphOS graph.

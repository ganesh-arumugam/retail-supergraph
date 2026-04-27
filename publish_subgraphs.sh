#!/bin/bash

# Configuration
APOLLO_KEY="service:ganesh-resp-caching:5KeANQMIb2eORFSdKkROMQ"
GRAPH_REF="ganesh-resp-caching@current"
ROUTING_URL_BASE="http://localhost:4001"

# List of subgraphs
SUBGRAPHS=("checkout" "discovery" "inventory" "orders" "products" "reviews" "shipping" "users")

echo "Publishing subgraphs to $GRAPH_REF..."

for subgraph in "${SUBGRAPHS[@]}"; do
  echo "--------------------------------------------------"
  echo "Publishing subgraph: $subgraph"
  
  rover subgraph publish "$GRAPH_REF" \
    --schema "./subgraphs/$subgraph/schema.graphql" \
    --name "$subgraph" \
    --routing-url "$ROUTING_URL_BASE/$subgraph/graphql" || exit 1
    
  echo "Successfully published $subgraph"
done

echo "--------------------------------------------------"
echo "All subgraphs published successfully!"

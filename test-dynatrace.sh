#!/usr/bin/env bash
# test-dynatrace.sh — Verify Apollo Router → OTel Collector → Dynatrace pipeline
#
# What this checks:
#   1. OTel collector container is running (docker compose --profile dynatrace)
#   2. Router is reachable at :4000
#   3. Sends a few GraphQL requests through the router to generate telemetry
#   4. Confirms collector received OTLP data (via its self-metrics endpoint)
#   5. (Optional) Queries the Dynatrace Metrics API to confirm ingest if
#      DT_ENVIRONMENT_ID and DT_API_TOKEN are set
#
# Usage:
#   export DT_ENVIRONMENT_ID=abc12345
#   export DT_API_TOKEN=dt0c01.XXXXX
#   ./test-dynatrace.sh

set -euo pipefail

ROUTER_URL="${ROUTER_URL:-http://localhost:4000}"
ROUTER_HEALTH_URL="${ROUTER_HEALTH_URL:-http://127.0.0.1:8088/health}"
COLLECTOR_METRICS_URL="http://localhost:8888/metrics"
PASS="✅"
FAIL="❌"
WARN="⚠️ "

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Apollo Router → Dynatrace telemetry test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: OTel collector health ──────────────────────────────────────────
echo "1. Checking OTel collector (docker compose --profile dynatrace)..."

COLLECTOR_RUNNING=$(docker compose --profile dynatrace ps --services --filter "status=running" 2>/dev/null | grep otel-collector || true)
if [ -n "$COLLECTOR_RUNNING" ]; then
  echo "   $PASS otel-collector container is running"
else
  echo "   $FAIL otel-collector container is NOT running"
  echo "      Start it with: docker compose --profile dynatrace up -d"
  echo "      (requires DT_ENVIRONMENT_ID and DT_API_TOKEN env vars)"
  exit 1
fi

# ── Step 2: Router health ──────────────────────────────────────────────────
echo ""
echo "2. Checking Apollo Router at $ROUTER_URL..."

ROUTER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$ROUTER_HEALTH_URL" 2>/dev/null || echo "000")
if [ "$ROUTER_STATUS" = "200" ]; then
  echo "   $PASS Router is healthy (HTTP 200)"
else
  echo "   $FAIL Router not reachable at $ROUTER_URL (HTTP $ROUTER_STATUS)"
  echo "      Start the router with: npm run dev"
  exit 1
fi

# ── Step 3: Send test GraphQL requests ────────────────────────────────────
echo ""
echo "3. Sending test GraphQL requests to generate telemetry..."

GQL_QUERY='{"query":"{ listAllProducts { id } }"}'
ERRORS=0
for i in 1 2 3 4 5; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "$ROUTER_URL" \
    -H "Content-Type: application/json" \
    -d "$GQL_QUERY" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    printf "   . "
  else
    printf "   $FAIL HTTP $HTTP_CODE "
    ERRORS=$((ERRORS + 1))
  fi
done
echo ""
if [ "$ERRORS" -eq 0 ]; then
  echo "   $PASS 5/5 requests returned HTTP 200"
else
  echo "   $WARN $ERRORS request(s) returned non-200 status"
fi

# Send a mutation too (different operation type)
curl -s -o /dev/null \
  -X POST "$ROUTER_URL" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ __typename }"}' || true

# Allow the batch processor to flush (scheduled_delay: 5s in config)
echo ""
echo "   Waiting 6s for OTLP batch flush..."
sleep 6

# ── Step 4: Collector self-metrics ────────────────────────────────────────
echo ""
echo "4. Checking OTel collector self-metrics at $COLLECTOR_METRICS_URL..."

COLLECTOR_METRICS=$(curl -s "$COLLECTOR_METRICS_URL" 2>/dev/null || echo "")
if [ -z "$COLLECTOR_METRICS" ]; then
  echo "   $WARN Could not reach collector metrics endpoint ($COLLECTOR_METRICS_URL)"
  echo "      Port 8888 may not be exposed — check docker-compose.yaml"
else
  # Check spans received
  SPANS_RECEIVED=$(echo "$COLLECTOR_METRICS" | grep 'otelcol_receiver_accepted_spans' | grep -v '#' | awk '{print $2}' | head -1 || echo "0")
  METRICS_RECEIVED=$(echo "$COLLECTOR_METRICS" | grep 'otelcol_receiver_accepted_metric_points' | grep -v '#' | awk '{print $2}' | head -1 || echo "0")
  EXPORT_ERRORS=$(echo "$COLLECTOR_METRICS" | grep 'otelcol_exporter_send_failed' | grep -v '#' | awk '{sum += $2} END {print sum}' || echo "0")

  echo "   Spans received  : ${SPANS_RECEIVED:-0}"
  echo "   Metric points   : ${METRICS_RECEIVED:-0}"
  echo "   Export errors   : ${EXPORT_ERRORS:-0}"

  if [ "${SPANS_RECEIVED:-0}" != "0" ] || [ "${METRICS_RECEIVED:-0}" != "0" ]; then
    echo "   $PASS Collector is receiving OTLP data from the Router"
  else
    echo "   $WARN No OTLP data seen yet — check that the Router's otlp exporter points to :4317"
  fi

  if [ "${EXPORT_ERRORS:-0}" != "0" ] && [ "${EXPORT_ERRORS:-0}" != "" ]; then
    echo "   $FAIL Export errors detected ($EXPORT_ERRORS). Check DT_API_TOKEN permissions."
    echo "      Required token scopes: metrics.ingest, traces.ingest, logs.ingest"
  else
    echo "   $PASS No export errors from collector"
  fi
fi

# ── Step 5: Dynatrace Metrics API (optional) ──────────────────────────────
echo ""
echo "5. Querying Dynatrace Metrics API to confirm ingest..."

if [ -z "${DT_ENVIRONMENT_ID:-}" ] || [ -z "${DT_API_TOKEN:-}" ]; then
  echo "   $WARN DT_ENVIRONMENT_ID or DT_API_TOKEN not set — skipping Dynatrace API check"
  echo "      Set them and re-run to verify end-to-end delivery"
else
  DT_BASE="https://${DT_ENVIRONMENT_ID}.live.dynatrace.com"
  DT_METRICS_URL="${DT_BASE}/api/v2/metrics/query?metricSelector=ext:apollo.router.http.requests.total:fold:sum&resolution=1h"

  HTTP_STATUS=$(curl -s -o /tmp/dt_response.json -w "%{http_code}" \
    -H "Authorization: Api-Token ${DT_API_TOKEN}" \
    "$DT_METRICS_URL" 2>/dev/null || echo "000")

  if [ "$HTTP_STATUS" = "200" ]; then
    DATA_POINTS=$(python3 -c "
import json, sys
try:
    d = json.load(open('/tmp/dt_response.json'))
    pts = sum(len(r.get('data', {}).get('result', [])) for r in d.get('resolution', {}).get('series', []))
    total = sum(len(s.get('values', [])) for r in d.get('result', []) for s in [r])
    print(total)
except:
    print(0)
" 2>/dev/null || echo "0")
    echo "   $PASS Dynatrace API reachable (HTTP 200)"
    echo "   Data points returned: $DATA_POINTS"
    if [ "$DATA_POINTS" != "0" ]; then
      echo "   $PASS Metrics are appearing in Dynatrace!"
    else
      echo "   $WARN No data points yet — metrics may take 1-2 minutes to appear in Dynatrace"
    fi
  elif [ "$HTTP_STATUS" = "401" ]; then
    echo "   $FAIL Unauthorized (HTTP 401) — check DT_API_TOKEN and required scopes"
    echo "      Required: metrics.ingest, traces.ingest, logs.ingest"
  elif [ "$HTTP_STATUS" = "404" ]; then
    echo "   $WARN Metric ext:apollo.router.http.requests.total not found yet (HTTP 404)"
    echo "      External metrics can take a few minutes to be registered after first ingest"
  else
    echo "   $WARN Unexpected HTTP $HTTP_STATUS from Dynatrace API"
    cat /tmp/dt_response.json 2>/dev/null | head -5 || true
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done. Next steps:"
echo "  • Import dynatrace-dashboard.json via:"
echo "    curl -X POST https://\$DT_ENVIRONMENT_ID.live.dynatrace.com/api/v2/dashboards \\"
echo "      -H 'Authorization: Api-Token \$DT_API_TOKEN' \\"
echo "      -H 'Content-Type: application/json' \\"
echo "      -d @dynatrace-dashboard.json"
echo ""
echo "  • Dynatrace Distributed Traces:"
echo "    https://\$DT_ENVIRONMENT_ID.live.dynatrace.com/ui/distributed-traces"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

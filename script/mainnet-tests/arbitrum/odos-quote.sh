#!/bin/bash
# Usage: odos-quote.sh <tokenIn> <amountIn> <tokenOut> <fromAddr>
# Outputs: assembled Odos transaction JSON (for vm.parseJsonUint / vm.parseJsonBytes)
set -e

TOKEN_IN=$1
AMOUNT=$2
TOKEN_OUT=$3
FROM=$4

# Step 1: Get quote → capture pathId in bash (never exposed to Forge)
PATHID=$(curl -s -X POST 'https://api.odos.xyz/sor/quote/v2' \
  -H 'Content-Type: application/json' \
  -d "{\"chainId\":42161,\"inputTokens\":[{\"tokenAddress\":\"$TOKEN_IN\",\"amount\":\"$AMOUNT\"}],\"outputTokens\":[{\"tokenAddress\":\"$TOKEN_OUT\",\"proportion\":1}],\"slippageLimitPercent\":0.5,\"userAddr\":\"$FROM\",\"referralCode\":0,\"disableRFQs\":false,\"compact\":true}" \
  | node -e "let d='';process.stdin.on('data',c=>d+=c).on('end',()=>process.stdout.write(JSON.parse(d).pathId))")

# Step 2: Assemble → output full JSON (starts with '{', Forge treats as raw bytes)
curl -s -X POST 'https://api.odos.xyz/sor/assemble' \
  -H 'Content-Type: application/json' \
  -d "{\"userAddr\":\"$FROM\",\"pathId\":\"$PATHID\",\"simulate\":false}"

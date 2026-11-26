pq() { curl -s localhost:9090/api/v1/query --data-urlencode "query=$1" | python3 -m json.tool; }
lq() { curl -s -G localhost:3100/loki/api/v1/query_range --data-urlencode "query=$1" \
       --data-urlencode "limit=${2:-20}" --data-urlencode "since=${3:-30m}" | python3 -m json.tool; }

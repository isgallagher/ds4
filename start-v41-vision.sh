#!/bin/bash
# DeepSeek V4.1 Flash Vision — 512k context, SSD-streamed (365 GiB model on 128 GiB M5 Max).
# V4.1: no DSpark/MTP. Vision encoder is Metal-only.
#./ds4-server --ctx 524288 --port 8080 --host 0.0.0.0 \
./ds4-server --ctx 1048576 --port 8080 --host 0.0.0.0 \
  -m gguf/DeepSeek-V4.1-Flash-Q2.gguf \
  --ssd-streaming \
  --vision gguf/DeepSeek-V4.1-Flash-Vision.gguf \
  --kv-disk-dir ~/.ds4/kv-cache \
  --kv-disk-space-mb 32768 \
  --kv-cache-cold-max-tokens 60000 \
  --kv-cache-continued-interval-tokens 5000 \
  --warm-weights \
  --tool-memory-max-ids 32768 \
  --cors \
  --tokens 524288 \
  --kv-cache-min-tokens 4096 \
  --kv-cache-continued-interval-tokens 32768 \
  --kv-cache-cold-max-tokens 150000 \
  --prefill-chunk 8192 \
  --kv-cache-reject-different-quant \
  --kv-cache-boundary-trim-tokens 0 \
  --kv-cache-boundary-align-tokens 4096

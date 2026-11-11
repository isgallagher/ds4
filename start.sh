#!/bin/bash
./ds4-server --ctx 300000 --port 8080 --host 0.0.0.0 \
  --vision gguf/DeepSeek-V4-Flash-Vision-Encoder.gguf --dspark --mtp-model gguf/DeepSeek-V4-Flash-Vision-Exp-DSpark-support.gguf \
  --kv-disk-dir ~/.ds4/kv-cache \
  --kv-disk-space-mb 32768 \
  --kv-cache-cold-max-tokens 60000 \
  --kv-cache-continued-interval-tokens 5000 \
  --warm-weights \
  --tool-memory-max-ids 32768 \
  --cors \
  --tokens 32768 \
  --kv-cache-min-tokens 4096 \
  --kv-cache-continued-interval-tokens 32768 \
  --kv-cache-cold-max-tokens 150000 \
  --prefill-chunk 8192 \
  --kv-cache-reject-different-quant \
  --kv-cache-boundary-trim-tokens 0 \
  --kv-cache-boundary-align-tokens 4096

#  --dspark --mtp $HOME/repos/ds4/gguf/DeepSeek-V4-Flash-DSpark-support-0731.gguf \
#   --kv-cache-cold-max-tokens 393216 \


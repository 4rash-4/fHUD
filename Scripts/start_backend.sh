#!/bin/bash
# Launch Parakeet and Gemma servers with memory limits
ulimit -v 2097152  # 2GB cap
python python/main_server.py &
PID=$!
./Scripts/monitor_memory.sh &
wait $PID

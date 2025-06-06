#!/bin/bash
# Simple helper to display memory pressure statistics every few seconds.
while true; do
    vm_stat | grep -E "Pages (free|active|inactive|speculative|wired)"
    echo "---"
    sleep 5
done

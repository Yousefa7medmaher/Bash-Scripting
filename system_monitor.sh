#!/bin/bash

CPU_THRESHOLD=1
MEMORY_THRESHOLD=1
DISK_THRESHOLD=1

# Function to check CPU usage
check_cpu_usage() {
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    cpu_usage=$(printf "%.2f" "$cpu_usage")  # format to 2 decimals
    if (( $(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l) )); then
        echo "High CPU usage: $cpu_usage%"
    fi
}

# Function to check memory usage
check_memory_usage() {
    memory_usage=$(free | grep Mem | awk '{printf "%.2f", $3/$2 * 100}')
    if (( $(echo "$memory_usage > $MEMORY_THRESHOLD" | bc -l) )); then
        echo "High memory usage: $memory_usage%"
    fi
}

# Function to check disk usage (root partition)
check_disk_usage() {
    disk_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ "$disk_usage" -gt "$DISK_THRESHOLD" ]; then
        echo "High disk usage: $disk_usage%"
    fi
}

# Run checks
check_cpu_usage
check_memory_usage
check_disk_usage

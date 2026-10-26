#!/usr/bin/env bash
# Compatibility entry point: retired commands must never launch a worker.
printf '%s\n' 'Autonomous task execution is retired. Use task-next, task-finalize, and task-implement.' >&2
exit 1

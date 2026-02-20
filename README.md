# Job Efficiency (Standalone)

This is a standalone Open OnDemand/Sinatra app extracted from `tufts-jobmonitor`.

## Features

- 7-day and 30-day efficiency summaries
- Requested resource stats (CPU/GPU/Memory/Runtime): min, median, max
- Efficiency distributions:
  - CPU allocation efficiency
  - Memory efficiency
  - Runtime vs requested walltime
- State filter:
  - Completed
  - Total (All States)

## API

- `GET /api/job-efficiency-summary?state_filter=completed|total`
- `GET /health`

## Run locally

```bash
cd /Users/yucheng/Documents/GitHub/tufts-jobmonitor/job-efficiency
bundle exec ruby app.rb
```

## Slurm dependencies

Requires `sacct` command access for the current user.

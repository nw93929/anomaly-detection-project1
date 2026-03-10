# Testing Log

## Phase 0: Verify Existing App Runs Locally

### Test 0.1: App starts and /health responds
**How:**
```bash
export BUCKET_NAME=test-bucket
cd /mnt/c/Users/wanns/OneDrive/Desktop/Coding/MSDS/ds5220cloud/anomaly-detection-project1
fastapi dev app.py
# Then open http://localhost:8000/health in browser
```
**Result:** PASS - `{"status":"ok","bucket":"test-bucket","timestamp":"2026-03-10T16:48:24.096523"}`

### Test 0.2: /docs shows all 5 endpoints
**How:**
```bash
# With app running, open http://localhost:8000/docs in browser
```
**Result:** PASS - All 5 endpoints visible (POST /notify, GET /anomalies/recent, GET /anomalies/summary, GET /baseline/current, GET /health)

---

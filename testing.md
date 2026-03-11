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

## Phase 1: Add Logging

### Test 1.1: Log file created and contains startup message
**How:**
```bash
cat /mnt/c/Users/wanns/OneDrive/Desktop/Coding/MSDS/ds5220cloud/anomaly-detection-project1/anomaly_detection.log
```
**Result:** PASS - Log file created with entries: `2026-03-10 21:54:34,951 INFO app App starting with BUCKET_NAME=test-bucket` plus uvicorn startup messages

### Test 1.2: /health still responds after logging changes
**How:** Open http://localhost:8000/health in browser
**Result:** PASS - `{"status":"ok","bucket":"test-bucket","timestamp":"2026-03-11T01:57:29.018009"}`

---

## Phase 2: Add Error Handling

### Test 2.1: /health still works after error handling changes
**How:** Open http://localhost:8000/health in browser
**Result:** PASS - `{"status":"ok","bucket":"test-bucket","timestamp":"2026-03-11T02:05:54.700744"}`

### Test 2.2: Error handling returns graceful error (not crash)
**How:** Open http://localhost:8000/anomalies/recent (with fake bucket "test-bucket")
**Result:** PASS - Returns `{"detail":"An error occurred (AccessDenied)..."}` — app did NOT crash

---

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

## Phase 4: CloudFormation Stack Deployment

### Test 4.1: Stack creates successfully
**How:** `aws cloudformation describe-stacks --stack-name anomaly-detection --query 'Stacks[0].StackStatus'`
**Result:** PASS - `CREATE_COMPLETE`

### Test 4.2: /health responds via Elastic IP
**How:** `curl http://3.215.93.129:8000/health`
**Result:** PASS - `{"status":"ok","bucket":"anomaly-detection-s3bucket-ajvymm13wcon","timestamp":"2026-03-11T02:29:37.270951"}`

### Test 4.3: SNS subscription confirmed
**How:** `aws sns list-subscriptions-by-topic --topic-arn arn:aws:sns:us-east-1:193389677831:ds5220-dp1`
**Result:** PASS - SubscriptionArn shows full ARN (confirmed, not pending)

---

## Phase 5: End-to-End Integration Test

### Test 5.1: Upload test CSV triggers full pipeline
**How:**
```bash
aws s3 cp sensors_20260224T001051.csv s3://anomaly-detection-s3bucket-ajvymm13wcon/raw/test_manual.csv
```
**Result:** PASS - All S3 paths populated:
- `processed/test_manual.csv` (12754 bytes) + `test_manual_summary.json` (329 bytes)
- `state/baseline.json` (574 bytes)
- `logs/anomaly_detection.log` (10446 bytes)

### Test 5.2: /anomalies/recent returns detected anomalies
**How:** `curl http://3.215.93.129:8000/anomalies/recent`
**Result:** PASS - 6 anomalies detected with Z-score flags (wind_speed, pressure, humidity) and IsolationForest flags

---

## Phase 6: 60-Minute Unattended Run

### Test 6.1: Test producer uploaded sufficient files
**How:** `aws s3 ls s3://anomaly-detection-s3bucket-ajvymm13wcon/raw/ | wc -l`
**Result:** PASS - 123 files uploaded (exceeds 60 minimum)

### Test 6.2: Baseline has sufficient observations
**How:** `cat submit/baseline.json`
**Result:** PASS - 12,300 observations per channel (123 x 100 rows). All channels mature (well above 30 threshold). Mean values: temp=22.03, humidity=55.00, pressure=1012.98, wind_speed=9.99

### Test 6.3: Log file collected from S3
**How:** `aws s3 cp s3://anomaly-detection-s3bucket-ajvymm13wcon/logs/anomaly_detection.log submit/anomaly_detection.log`
**Result:** PASS - Log file downloaded to submit/

---

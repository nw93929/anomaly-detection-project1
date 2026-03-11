# Graduate Questions

## 1. Technical Challenges (CloudFormation to Terraform)

The greatest challenge in translating the CloudFormation template to Terraform was handling the S3 bucket notification configuration. In CloudFormation, the notification configuration is defined inline as a property of the `AWS::S3::Bucket` resource (`build.yaml` lines 29-39). In Terraform, this must be a separate `aws_s3_bucket_notification` resource, which makes the dependency between the S3 bucket and the SNS topic more explicit but also requires careful ordering with `depends_on` to avoid the circular dependency — the bucket notification needs the SNS topic to exist, and the SNS topic policy needs to reference the bucket.

A secondary challenge was the difference in reference syntax. CloudFormation uses intrinsic functions like `!Ref`, `!Sub`, and `!GetAtt` to wire resources together. Terraform uses direct attribute references like `aws_s3_bucket.app_bucket.arn` and `aws_sns_topic.ds5220_dp1.arn`, which are more readable but require knowing the exact exported attribute names from the provider documentation. The UserData handling also differs — CloudFormation uses `Fn::Base64` with `!Sub` for variable interpolation, while Terraform uses `base64encode()` with `templatefile()` and a separate template file (`userdata.sh.tftpl`), which separates the script from the infrastructure definition.

## 2. Access Permissions

The SNS subscription permission to send messages to the API is granted by the `AWS::SNS::Subscription` resource in `submit/build.yaml` at lines 158-163. This resource creates an HTTP subscription that tells SNS to POST messages to `http://<ElasticIP>:8000/notify`. When SNS first creates this subscription, it sends a `SubscriptionConfirmation` message to the endpoint.

The confirmation handshake is handled in `app.py` at lines 42-46. The code checks for `msg_type == "SubscriptionConfirmation"`, extracts the `SubscribeURL` from the message body, and visits that URL with `requests.get(confirm_url)`. This confirms the subscription with SNS, after which SNS is authorized to deliver `Notification` messages to the endpoint. Without this confirmation step, SNS would never deliver actual event notifications.

## 3. Event Flow and Reliability

**Event trace for a single CSV upload:**

1. A CSV file is uploaded to `s3://bucket/raw/sensors_*.csv` (e.g., by `test_producer.py`)
2. The S3 bucket has a notification configuration (`build.yaml` lines 29-39) that fires on `s3:ObjectCreated:*` events filtered to prefix `raw/` and suffix `.csv`
3. S3 publishes the event to the SNS topic `ds5220-dp1` (permitted by the SNS topic policy at `build.yaml` lines 140-155)
4. SNS delivers the event as an HTTP POST to `http://<ElasticIP>:8000/notify` (the subscription at `build.yaml` lines 158-163)
5. `app.py` line 48 parses the notification, extracts the S3 key from the event records (lines 50-55)
6. If the key matches `raw/*.csv`, it dispatches `process_file()` as a FastAPI background task (line 55)
7. `processor.py` downloads the CSV, updates the baseline, runs detection, writes scored output to `processed/`, saves baseline, syncs logs, and writes a summary JSON

**If EC2 is down or `/notify` returns an error:**

SNS uses a delivery retry policy for HTTP endpoints. By default, SNS retries failed HTTP deliveries 3 times with exponential backoff (delays of 20s, 20s, 20s for the default HTTP policy). If all retries fail, the message is lost unless a dead-letter queue (DLQ) is configured.

**For production-grade reliability, I would:**
- Use HTTPS instead of HTTP for the subscription endpoint (with a proper TLS certificate)
- Add an SQS dead-letter queue to the SNS subscription so failed messages are preserved
- Consider using SQS as the subscription protocol instead of HTTP — the EC2 instance would poll the queue, eliminating the need for an open HTTP endpoint and handling backpressure naturally
- Add CloudWatch alarms on SNS delivery failures and SQS DLQ depth

## 4. IAM and Least Privilege

**S3 operations actually performed by the application:**

| Operation | Where Used | Purpose |
|-----------|-----------|---------|
| `s3:GetObject` | `processor.py` line 24, `baseline.py` line 26, `app.py` lines 80, 87, 104 | Download raw CSVs, load baseline.json, read processed files and summaries |
| `s3:PutObject` | `processor.py` lines 49, 63, 85, `baseline.py` line 40 | Write scored CSVs, sync logs, write summaries, save baseline |
| `s3:ListBucket` | `app.py` lines 65-66, 80-81 (via paginator `list_objects_v2`) | List processed files and summaries for query endpoints |

The current policy (`build.yaml` lines 67-76) grants `s3:*` on the bucket, which includes operations the app never uses: `s3:DeleteObject`, `s3:DeleteBucket`, `s3:PutBucketPolicy`, etc.

**A minimal policy would look like:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::BUCKET_NAME/*"
    },
    {
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::BUCKET_NAME"
    }
  ]
}
```

Note that `s3:ListBucket` applies to the bucket ARN (without `/*`), while `s3:GetObject` and `s3:PutObject` apply to the objects within the bucket (`/*`). This follows the principle of least privilege by granting only the three operations the application actually needs.

## 5. Architecture and Scaling

**Scaling to 100x the current load introduces several challenges:**

**Baseline consistency (the biggest problem):** The current design has a read-modify-write pattern on `state/baseline.json` in `processor.py` (lines 30-39, 57). With a single instance processing one file at a time, this works fine. With multiple instances or concurrent processing, two processes could read the same baseline, update it with different batches, and the last write wins — losing one batch's contribution to the statistics. Solutions include:
- Replace `baseline.json` with a DynamoDB table using atomic `UpdateItem` operations (adding count/mean/M2 deltas rather than overwriting)
- Use S3 conditional writes (If-Match ETags) with retry logic to implement optimistic locking
- Designate a single "baseline updater" service that receives update requests via a queue

**Concurrent processing:** The current SNS-to-HTTP design sends notifications directly to a single EC2 instance. At 100x load, this instance becomes a bottleneck. Instead:
- Replace the SNS HTTP subscription with an SQS queue subscribed to the SNS topic
- Use an Auto Scaling Group of EC2 instances (or Lambda functions) that poll the SQS queue
- SQS provides natural backpressure — if processors are slow, messages wait in the queue rather than being lost

**Tradeoffs:**
- DynamoDB adds cost and a new dependency but eliminates the baseline race condition
- SQS adds latency (polling interval) but provides durability and automatic retry
- Auto Scaling increases infrastructure complexity but handles variable load
- An alternative approach would be to move to a streaming architecture (e.g., Kinesis) where baseline updates are applied in order, but this fundamentally changes the batch-file design

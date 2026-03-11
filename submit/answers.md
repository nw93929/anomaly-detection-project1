# Graduate Questions

## 1. Technical Challenges (CloudFormation to Terraform)

The hardest part was transfering the S3 bucket notifications. In CloudFormation you just define it inline as a property on the bucket resource (`build.yaml` lines 29-39), but in Terraform it has to be its own separate `aws_s3_bucket_notification` resource. This meant I had to use `depends_on` to get the ordering right so the notifications, SNS topic, and bucket can all properly communicate with eachother. The other thing that could have been tricky was the syntax differences. CloudFormation has `!Ref`, `!Sub`, `!GetAtt` for wiring resources together, while Terraform uses `aws_s3_bucket.app_bucket.arn` style references. I used AI to assist me so it wasn't as much of a problem as it could have been but was harder to visually verify that everything was right for sure.

## 2. Access Permissions

The `AWS::SNS::Subscription` resource in `submit/build.yaml` at lines 158-163 is what grants SNS permission to send messages to the API. It creates an HTTP subscription pointing to `http://<ElasticIP>:8000/notify`, which tells SNS to POST event messages to that URL.

## 3. Event Flow and Reliability

The path a CSV takes through the system is:

1. CSV gets uploaded to `s3://bucket/raw/sensors_*.csv` (from `test_producer.py` or manually)
2. S3 event notification fires (`build.yaml` lines 29-39) — scoped to `raw/` prefix and `.csv` suffix
3. S3 publishes the event to SNS topic `ds5220-dp1` (allowed by the topic policy at `build.yaml` lines 140-155)
4. SNS sends an HTTP POST to `http://<ElasticIP>:8000/notify` (subscription at `build.yaml` lines 158-163)
5. `app.py` line 52 parses the notification and pulls out the S3 key (lines 54-56)
6. If the key matches `raw/*.csv`, it kicks off `process_file()` as a background task (line 59)
7. `processor.py` handles the rest — downloads the CSV, updates baseline, runs z-score + IsolationForest detection, writes the scored CSV to `processed/`, saves the baseline, syncs logs, and writes a summary JSON

If the EC2 instance is down or `/notify` returns an error, SNS retries the HTTP delivery 3 times and if all retries fail the message is just lost.

For production you would probably want a few changes, like switching to HTTPS (S means security) and adding a dead-letter queue as per the question so failed messages don't just disappear. This means you don't lose valuable data that helps your future anomaly detections or skew the detections from not being able to use the data since we have a rolling statistical baseline setup.

## 4. IAM and Least Privilege

Reviewing the scripts with AI, only three S3 operations are ever used:

| Operation | Where | What for |
|-----------|-------|----------|
| `s3:GetObject` | `processor.py` line 24, `baseline.py` line 26, `app.py` lines 94, 122 | Downloading raw CSVs, loading baseline.json, reading processed files and summaries |
| `s3:PutObject` | `processor.py` lines 49, 63, 85, `baseline.py` line 40 | Writing scored CSVs, syncing logs, writing summaries, saving baseline |
| `s3:ListBucket` | `app.py` lines 79-80, 115-116 (the paginator calls) | Listing processed files and summaries for the query endpoints |

Right now the policy in `build.yaml` lines 67-76 grants `s3:*` which includes stuff like `s3:DeleteObject`, `s3:DeleteBucket`, `s3:PutBucketPolicy` that are never used.

A tighter policy would be:

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

## 5. Architecture and Scaling

Scaling this to 100x brings up a few problems. Right now `processor.py` reads `state/baseline.json`, update the stats, and saves it back. With one instance processing one file at a time that's fine. But with multiple instances or concurrent processing, two processes could read the same baseline, each update it with their own batch, and whoever writes last overwrites the other's work. You'd lose data from one batch's contribution to the statistics. Also, the current design sends SNS notifications directly to one EC2 instance. At 100x that one singular instance may not be able to keep up.

To fix the baseline race a suggested fix is to use DynamoDB with atomic updates so processes add deltas instead of overwriting. However, since we are introducing a whole new service, we have the tradeoff of considering how to integrate and manage it, and the cost of doing so.

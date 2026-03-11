#!/usr/bin/env python3
import json
import io
import logging
import boto3
import pandas as pd
from datetime import datetime

from baseline import BaselineManager
from detector import AnomalyDetector

logger = logging.getLogger(__name__)

s3 = boto3.client("s3")


NUMERIC_COLS = ["temperature", "humidity", "pressure", "wind_speed"]  # students configure this

def process_file(bucket: str, key: str):
    try:
        logger.info(f"Processing: s3://{bucket}/{key}")

        # 1. Download raw file
        response = s3.get_object(Bucket=bucket, Key=key)
        df = pd.read_csv(io.BytesIO(response["Body"].read()))

        logger.info(f"Loaded {len(df)} rows, columns: {list(df.columns)}")

        # 2. Load current baseline
        baseline_mgr = BaselineManager(bucket=bucket)
        baseline = baseline_mgr.load()

        # 3. Update baseline with values from this batch BEFORE scoring
        #    (use only non-null values for each channel)
        for col in NUMERIC_COLS:
            if col in df.columns:
                clean_values = df[col].dropna().tolist()
                if clean_values:
                    baseline = baseline_mgr.update(baseline, col, clean_values)

        # 4. Run detection
        detector = AnomalyDetector(z_threshold=3.0, contamination=0.05)
        scored_df = detector.run(df, NUMERIC_COLS, baseline, method="both")

        # 5. Write scored file to processed/ prefix
        output_key = key.replace("raw/", "processed/")
        csv_buffer = io.StringIO()
        scored_df.to_csv(csv_buffer, index=False)
        s3.put_object(
            Bucket=bucket,
            Key=output_key,
            Body=csv_buffer.getvalue(),
            ContentType="text/csv"
        )

        # 6. Save updated baseline back to S3
        baseline_mgr.save(baseline)
        logger.info("Baseline updated and saved to S3")

        # 6b. Sync log file to S3
        try:
            with open("anomaly_detection.log", "rb") as f:
                s3.put_object(Bucket=bucket, Key="logs/anomaly_detection.log",
                              Body=f.read(), ContentType="text/plain")
            logger.info("Synced log file to S3")
        except Exception as e:
            logger.error(f"Failed to sync log to S3: {e}")

        # 7. Build and return a processing summary
        anomaly_count = int(scored_df["anomaly"].sum()) if "anomaly" in scored_df else 0
        summary = {
            "source_key": key,
            "output_key": output_key,
            "processed_at": datetime.utcnow().isoformat(),
            "total_rows": len(df),
            "anomaly_count": anomaly_count,
            "anomaly_rate": round(anomaly_count / len(df), 4) if len(df) > 0 else 0,
            "baseline_observation_counts": {
                col: baseline.get(col, {}).get("count", 0) for col in NUMERIC_COLS
            }
        }

        # Write summary JSON alongside the processed file
        summary_key = output_key.replace(".csv", "_summary.json")
        s3.put_object(
            Bucket=bucket,
            Key=summary_key,
            Body=json.dumps(summary, indent=2),
            ContentType="application/json"
        )

        logger.info(f"Done: {anomaly_count}/{len(df)} anomalies flagged for {key}")
        return summary

    except Exception as e:
        logger.error(f"Failed to process {key}: {e}", exc_info=True)

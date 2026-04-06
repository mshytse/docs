# AWS CMEK impersonation (test setup)

Set env vars once (example values):

| Variable | Meaning |
|----------|---------|
| `CMEK_AWS_ACCOUNT_ID` | AWS account where the CMK and role live |
| `SCALR_AWS_ACCOUNT_ID` | Scalr account that calls `sts:AssumeRole` (preview-saas: `615271354814`) |
| `CMEK_EXTERNAL_ID` | Same in trust policy and Scalr CMEK config |
| `CMEK_ROLE_NAME` | IAM role name |
| `CMEK_KMS_REGION` | Primary MRK region (`create-key`, `replicate-key` called here) |
| `CMEK_KMS_REPLICA_REGION` | Second region for the MRK replica |
| `CMEK_KMS_KEY_ARN` | Primary MRK ARN (step 1) |
| `CMEK_KMS_REPLICA_KEY_ARN` | Replica MRK ARN (step 1) |
| `CMEK_KMS_KEY_ID` | Shared KeyId for primary + replica (cleanup) |

```bash
export CMEK_AWS_ACCOUNT_ID=123456789012
export SCALR_AWS_ACCOUNT_ID=615271354814
export CMEK_EXTERNAL_ID='replace-me'
export CMEK_ROLE_NAME=scalr-cmek-test
export CMEK_KMS_REGION=us-east-1
export CMEK_KMS_REPLICA_REGION=us-west-2
```

---

## 1

```bash
# Multi-Region symmetric CMK (cannot turn a single-Region key into MRK later)
export CMEK_KMS_KEY_ARN=$(aws kms create-key \
  --region "${CMEK_KMS_REGION}" \
  --description "Scalr CMEK impersonation test (MRK primary)" \
  --key-usage ENCRYPT_DECRYPT \
  --key-spec SYMMETRIC_DEFAULT \
  --multi-region \
  --query KeyMetadata.Arn --output text)
export CMEK_KMS_KEY_ID="${CMEK_KMS_KEY_ARN##*/}"

# Replica in another region (same KeyId, different ARN)
export CMEK_KMS_REPLICA_KEY_ARN=$(aws kms replicate-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --replica-region "${CMEK_KMS_REPLICA_REGION}" \
  --description "Scalr CMEK impersonation test (MRK replica)" \
  --query ReplicaKeyMetadata.Arn --output text)
```

---

## 2

```bash
# Writes trust.json (${SCALR_AWS_ACCOUNT_ID}, ${CMEK_EXTERNAL_ID} expand; keep external ID JSON-safe)
cat > trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${SCALR_AWS_ACCOUNT_ID}:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "${CMEK_EXTERNAL_ID}"
        }
      }
    }
  ]
}
EOF
```

---

## 3

```bash
# Creates role; trust = trust.json
aws iam create-role \
  --role-name "${CMEK_ROLE_NAME}" \
  --assume-role-policy-document file://trust.json

# After editing trust.json (existing role)
aws iam update-assume-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-document file://trust.json
```

---

## 4

```bash
# IAM: allow KMS calls on primary + replica ARNs (same KeyId)
cat > kms-inline.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt"
      ],
      "Resource": [
        "${CMEK_KMS_KEY_ARN}",
        "${CMEK_KMS_REPLICA_KEY_ARN}"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-name scalr-cmek-kms-test \
  --policy-document file://kms-inline.json
```

---

## 5

```bash
# Role ARN for Scalr
aws iam get-role --role-name "${CMEK_ROLE_NAME}" --query Role.Arn --output text

# Primary MRK ARN (same KeyId as replica)
aws kms describe-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --query KeyMetadata.Arn --output text

# Replica MRK ARN
aws kms describe-key \
  --region "${CMEK_KMS_REPLICA_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --query KeyMetadata.Arn --output text
```

---

## 6

Scalr CMEK profile: `aws-role-arn` = `get-role` output · `aws-external-id` = `$CMEK_EXTERNAL_ID` (must match `trust.json`). CMK: use the MRK ARN for the **region Scalr uses** (primary `describe-key` or replica `describe-key` above; or `$CMEK_KMS_KEY_ARN` / `$CMEK_KMS_REPLICA_KEY_ARN`).

---

## 7 (optional)

```bash
# From credentials in SCALR_AWS_ACCOUNT_ID only
aws sts assume-role \
  --role-arn "arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:role/${CMEK_ROLE_NAME}" \
  --role-session-name cmek-test \
  --external-id "${CMEK_EXTERNAL_ID}"
```

---

## Cleanup

Run in `CMEK_AWS_ACCOUNT_ID` after you remove the CMEK profile / nothing should assume the role.

MRK: you **cannot** schedule primary deletion while a replica still exists. Schedule replica deletion first; after AWS finishes deleting the replica (after the pending window), schedule primary deletion.

```bash
# 1) Replica region first (minimum pending window 7 days)
aws kms schedule-key-deletion \
  --region "${CMEK_KMS_REPLICA_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --pending-window-in-days 7

# 2) After replica is fully deleted, primary region
aws kms schedule-key-deletion \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --pending-window-in-days 7

aws iam delete-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-name scalr-cmek-kms-test

aws iam delete-role --role-name "${CMEK_ROLE_NAME}"

rm -f trust.json kms-inline.json
```

```bash
# Unset (optional)
unset CMEK_KMS_KEY_ARN CMEK_KMS_REPLICA_KEY_ARN CMEK_KMS_KEY_ID
```

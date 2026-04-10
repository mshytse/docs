# AWS CMEK impersonation (test setup)

## Table of contents

- [1 · MRKs](#1--mrks)
- [2 · Trust](#2--trust)
- [3 · Roles](#3--roles)
- [4 · IAM KMS](#4--iam-kms)
- [5 · ARNs](#5--arns)
- [6 · Scalr](#6--scalr)
- [Cleanup · Tear down](#cleanup--tear-down)

Set env vars once (example values):

| Variable | Meaning |
|----------|---------|
| `CMEK_AWS_ACCOUNT_ID` | AWS account where the CMK and roles live |
| `SCALR_AWS_ACCOUNT_ID` | Scalr account that calls `sts:AssumeRole` (preview-saas: `615271354814`) |
| `CMEK_EXTERNAL_ID` | Same in trust policy and Scalr CMEK config |
| `CMEK_ROLE_NAME` | Primary IAM role name |
| `CMEK_ROLE_NAME_SECONDARY` | Secondary IAM role name |
| `CMEK_KMS_REGION` | Region where both MRK primaries are created |
| `CMEK_KMS_KEY_ARN` | Primary MRK ARN (step 1) |
| `CMEK_KMS_KEY_ID` | Primary MRK KeyId |
| `CMEK_MRK_KEY_2_ARN` | Second multi-Region key primary ARN (step 1) |
| `CMEK_MRK_KEY_2_ID` | Second MRK KeyId |

```bash
export CMEK_AWS_ACCOUNT_ID=123456789012
export SCALR_AWS_ACCOUNT_ID=615271354814
export CMEK_EXTERNAL_ID='replace-me'
export CMEK_ROLE_NAME=scalr-cmek-test
export CMEK_ROLE_NAME_SECONDARY=scalr-cmek-test-secondary
export CMEK_KMS_REGION=us-east-1
```

---

## 1 · MRKs

```bash
export CMEK_KMS_KEY_ARN=$(aws kms create-key \
  --region "${CMEK_KMS_REGION}" \
  --description "Scalr CMEK impersonation test (primary MRK)" \
  --key-usage ENCRYPT_DECRYPT \
  --key-spec SYMMETRIC_DEFAULT \
  --multi-region \
  --query KeyMetadata.Arn --output text)
export CMEK_KMS_KEY_ID="${CMEK_KMS_KEY_ARN##*/}"

export CMEK_MRK_KEY_2_ARN=$(aws kms create-key \
  --region "${CMEK_KMS_REGION}" \
  --description "Scalr CMEK impersonation test (MRK 2)" \
  --key-usage ENCRYPT_DECRYPT \
  --key-spec SYMMETRIC_DEFAULT \
  --multi-region \
  --query KeyMetadata.Arn --output text)
export CMEK_MRK_KEY_2_ID="${CMEK_MRK_KEY_2_ARN##*/}"
```

---

## 2 · Trust

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

## 3 · Roles

```bash
# Primary + secondary roles (same trust)
aws iam create-role \
  --role-name "${CMEK_ROLE_NAME}" \
  --assume-role-policy-document file://trust.json

aws iam create-role \
  --role-name "${CMEK_ROLE_NAME_SECONDARY}" \
  --assume-role-policy-document file://trust.json

# After editing trust.json (existing roles)
aws iam update-assume-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-document file://trust.json

aws iam update-assume-role-policy \
  --role-name "${CMEK_ROLE_NAME_SECONDARY}" \
  --policy-document file://trust.json
```

---

## 4 · IAM KMS

```bash
# Primary + second MRK on both roles
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
        "${CMEK_MRK_KEY_2_ARN}"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-name scalr-cmek-kms-test \
  --policy-document file://kms-inline.json

aws iam put-role-policy \
  --role-name "${CMEK_ROLE_NAME_SECONDARY}" \
  --policy-name scalr-cmek-kms-test \
  --policy-document file://kms-inline.json
```

---

## 5 · ARNs

```bash
# Role ARNs for Scalr
aws iam get-role --role-name "${CMEK_ROLE_NAME}" --query Role.Arn --output text
aws iam get-role --role-name "${CMEK_ROLE_NAME_SECONDARY}" --query Role.Arn --output text

# Primary + MRK 2 primary ARNs
aws kms describe-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --query KeyMetadata.Arn --output text

aws kms describe-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_MRK_KEY_2_ID}" \
  --query KeyMetadata.Arn --output text
```

---

## 6 · Scalr

Scalr CMEK profile: `aws-role-arn` = primary or secondary `get-role` line above · `aws-external-id` = `$CMEK_EXTERNAL_ID` (must match `trust.json`). CMK: `describe-key` above or `$CMEK_KMS_KEY_ARN` / `$CMEK_MRK_KEY_2_ARN`.

---

## Cleanup · Tear down

Run in `CMEK_AWS_ACCOUNT_ID` after you remove the CMEK profile / nothing should assume the roles.

If you later added **replicas** on either MRK, delete those replicas before scheduling deletion of that key’s primary.

```bash
aws kms schedule-key-deletion \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --pending-window-in-days 7

aws kms schedule-key-deletion \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_MRK_KEY_2_ID}" \
  --pending-window-in-days 7

aws iam delete-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-name scalr-cmek-kms-test

aws iam delete-role-policy \
  --role-name "${CMEK_ROLE_NAME_SECONDARY}" \
  --policy-name scalr-cmek-kms-test

aws iam delete-role --role-name "${CMEK_ROLE_NAME}"
aws iam delete-role --role-name "${CMEK_ROLE_NAME_SECONDARY}"

rm -f trust.json kms-inline.json
```

```bash
# Unset (optional)
unset CMEK_KMS_KEY_ARN CMEK_KMS_KEY_ID CMEK_MRK_KEY_2_ARN CMEK_MRK_KEY_2_ID
```

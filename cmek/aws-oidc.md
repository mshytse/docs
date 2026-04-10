# AWS CMEK OIDC (test setup)

## Table of contents

- [1 · OIDC IdP](#1--oidc-idp)
- [2 · MRK](#2--mrk)
- [3 · Primary role](#3--primary-role)
- [4 · Key policy](#4--key-policy)
- [5 · Scalr](#5--scalr)
- [6 · Second role](#6--second-role)
- [7 · Second MRK](#7--second-mrk)
- [8 · Rotation](#8--rotation)
- [9 · Negatives](#9--negatives)
- [Cleanup · Tear down](#cleanup--tear-down)

Uses the same shell vars as `cmek-aws-impersonation.md` where shared: `CMEK_AWS_ACCOUNT_ID`, `CMEK_KMS_REGION`. OIDC MRK and provider use `CMEK_OIDC_*` so impersonation `CMEK_KMS_KEY_*` / `CMEK_MRK_KEY_2_*` stay untouched.

JWT (trust policy): `iss` = `https://<host>` · `aud` = Scalr `aws-audience` · `sub` = `account:<scalr-account-name>` (name, not UUID).

| Variable | Meaning |
|----------|---------|
| `CMEK_AWS_ACCOUNT_ID` | Your AWS account (KMS + IAM) |
| `CMEK_KMS_REGION` | MRK home region (all `kms` CLI here) |
| `CMEK_SCALR_HOSTNAME` | Scalr UI host only, no `https://` |
| `CMEK_OIDC_ISSUER_URL` | `https://${CMEK_SCALR_HOSTNAME}` |
| `CMEK_OIDC_PROVIDER_ARN` | IAM OIDC provider ARN |
| `CMEK_OIDC_THUMBPRINT` | TLS SHA-1 thumbprint for issuer |
| `CMEK_OIDC_ROLE_NAME` | Primary IAM role (default `scalr-cmek-oidc-test-role`) |
| `CMEK_OIDC_ROLE_NAME_SECONDARY` | Second role (default `scalr-cmek-oidc-test-role-b`) |
| `CMEK_OIDC_AUDIENCE_A` | Primary audience / OIDC client id |
| `CMEK_OIDC_AUDIENCE_B` | Second audience |
| `CMEK_SCALR_ACCOUNT_NAME` | For trust `sub` (without `account:`) |
| `CMEK_OIDC_KMS_KEY_ID` | OIDC MRK KeyId (`mrk-...`) |
| `CMEK_OIDC_KMS_KEY_ARN` | OIDC MRK ARN |
| `CMEK_OIDC_MRK_KEY_2_ID` | Optional second MRK for OIDC paths |
| `CMEK_OIDC_MRK_KEY_2_ARN` | Optional second MRK ARN |

Scalr expects an MRK ARN (`.../key/mrk-...`). Put `put-key-policy` after the role exists (KMS validates principals).

```bash
export CMEK_AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export CMEK_KMS_REGION="us-east-1"
export CMEK_SCALR_HOSTNAME="your-env.scalr.io"
export CMEK_OIDC_ISSUER_URL="https://${CMEK_SCALR_HOSTNAME}"
export CMEK_OIDC_ROLE_NAME="scalr-cmek-oidc-test-role"
export CMEK_OIDC_ROLE_NAME_SECONDARY="scalr-cmek-oidc-test-role-b"
export CMEK_OIDC_AUDIENCE_A="scalr-cmek-aws-oidc-test"
export CMEK_OIDC_AUDIENCE_B="scalr-cmek-aws-oidc-test-b"
export CMEK_SCALR_ACCOUNT_NAME="your-scalr-account-name"
export CMEK_OIDC_THUMBPRINT="<40-char-hex>"
```

---

## 1 · OIDC IdP

```bash
# TLS leaf cert SHA-1 thumbprint for $CMEK_SCALR_HOSTNAME (paste into CMEK_OIDC_THUMBPRINT / create-open-id-connect-provider)
echo | openssl s_client -servername "$CMEK_SCALR_HOSTNAME" -connect "${CMEK_SCALR_HOSTNAME}:443" 2>/dev/null \
  | openssl x509 -fingerprint -noout -sha1 | sed 's/^.*=//;s/://g'
```

```bash
aws iam create-open-id-connect-provider \
  --url "$CMEK_OIDC_ISSUER_URL" \
  --client-id-list "${CMEK_OIDC_AUDIENCE_A}" \
  --thumbprint-list "$CMEK_OIDC_THUMBPRINT"
```

```bash
export CMEK_OIDC_PROVIDER_ARN="$(aws iam list-open-id-connect-providers --query \
  "OpenIDConnectProviderList[?contains(Arn, '${CMEK_SCALR_HOSTNAME}')].Arn | [0]" --output text)"
echo "$CMEK_OIDC_PROVIDER_ARN"
```

```bash
# List every account OIDC IdP: issuer URL -> ARN (pick the ARN that matches $CMEK_OIDC_ISSUER_URL)
for arn in $(aws iam list-open-id-connect-providers --query OpenIDConnectProviderList[].Arn --output text); do
  url="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" --query Url --output text)"
  echo "$url  ->  $arn"
done
```

---

## 2 · MRK

```bash
export CMEK_OIDC_KMS_KEY_ID="$(
  aws kms create-key \
    --region "${CMEK_KMS_REGION}" \
    --description "Scalr CMEK AWS OIDC test" \
    --key-usage ENCRYPT_DECRYPT \
    --origin AWS_KMS \
    --multi-region \
    --query KeyMetadata.KeyId \
    --output text
)"

export CMEK_OIDC_KMS_KEY_ARN="$(aws kms describe-key --region "${CMEK_KMS_REGION}" --key-id "${CMEK_OIDC_KMS_KEY_ID}" --query KeyMetadata.Arn --output text)"
echo "$CMEK_OIDC_KMS_KEY_ARN"
```

```bash
export CMEK_OIDC_KMS_KEY_ID="${CMEK_OIDC_KMS_KEY_ARN##*/}"
```

```bash
# Browse CMKs in $CMEK_KMS_REGION (KeyId, ARN, Description) when you need to find an existing MRK by hand
for id in $(aws kms list-keys --region "${CMEK_KMS_REGION}" --query 'Keys[].KeyId' --output text); do
  aws kms describe-key --region "${CMEK_KMS_REGION}" --key-id "$id" \
    --query 'KeyMetadata.[KeyId,Arn,Description]' --output text
done
```

---

## 3 · Primary role

Trust: `${CMEK_SCALR_HOSTNAME}:aud` / `${CMEK_SCALR_HOSTNAME}:sub`. Pick **one** of the two `cat` blocks.

```bash
cat > /tmp/trust-policy-oidc.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${CMEK_OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${CMEK_SCALR_HOSTNAME}:aud": "${CMEK_OIDC_AUDIENCE_A}",
        "${CMEK_SCALR_HOSTNAME}:sub": "account:${CMEK_SCALR_ACCOUNT_NAME}"
      }
    }
  }]
}
EOF
```

```bash
cat > /tmp/trust-policy-oidc.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${CMEK_OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${CMEK_SCALR_HOSTNAME}:aud": "${CMEK_OIDC_AUDIENCE_A}",
        "${CMEK_SCALR_HOSTNAME}:sub": [
          "account:${CMEK_SCALR_ACCOUNT_NAME}",
          "account:demo",
          "account:sandbox"
        ]
      }
    }
  }]
}
EOF
```

```bash
aws iam create-role \
  --role-name "${CMEK_OIDC_ROLE_NAME}" \
  --assume-role-policy-document file:///tmp/trust-policy-oidc.json
```

```bash
# Existing role: after you change /tmp/trust-policy-oidc.json, re-apply trust
aws iam update-assume-role-policy \
  --role-name "${CMEK_OIDC_ROLE_NAME}" \
  --policy-document file:///tmp/trust-policy-oidc.json
```

```bash
cat > /tmp/kms-role-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
    "Resource": "${CMEK_OIDC_KMS_KEY_ARN}"
  }]
}
EOF

aws iam put-role-policy \
  --role-name "${CMEK_OIDC_ROLE_NAME}" \
  --policy-name cmek-kms-minimal \
  --policy-document file:///tmp/kms-role-policy.json
```

```bash
aws iam get-role --role-name "${CMEK_OIDC_ROLE_NAME}" --query Role.Arn --output text
export CMEK_OIDC_ROLE_ARN_PRIMARY="$(aws iam get-role --role-name "${CMEK_OIDC_ROLE_NAME}" --query Role.Arn --output text)"
```

---

## 4 · Key policy

```bash
cat > /tmp/kms-key-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccountAdmins",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCmekRolePrimary",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:role/${CMEK_OIDC_ROLE_NAME}" },
      "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
      "Resource": "*"
    }
  ]
}
EOF

aws kms put-key-policy \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_OIDC_KMS_KEY_ID}" \
  --policy-name default \
  --policy file:///tmp/kms-key-policy.json
```

---

## 5 · Scalr

| Field | Value |
|--------|--------|
| `aws-credentials-type` | `oidc` |
| `aws-kms-key-arn` | `$CMEK_OIDC_KMS_KEY_ARN` |
| `aws-role-arn` | `arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:role/${CMEK_OIDC_ROLE_NAME}` |
| `aws-audience` | `$CMEK_OIDC_AUDIENCE_A` |

| Scalr field | CLI / var |
|-------------|-----------|
| `aws-role-arn` (primary) | `get-role` → `${CMEK_OIDC_ROLE_NAME}` or `$CMEK_OIDC_ROLE_ARN_PRIMARY` |
| `aws-role-arn` (second) | `get-role` → `${CMEK_OIDC_ROLE_NAME_SECONDARY}` |
| `aws-kms-key-arn` | `describe-key` → MRK ARN |
| Trust `Principal.Federated` | `$CMEK_OIDC_PROVIDER_ARN` |

---

## 6 · Second role

```bash
aws iam add-client-id-to-open-id-connect-provider \
  --open-id-connect-provider-arn "$CMEK_OIDC_PROVIDER_ARN" \
  --client-id "${CMEK_OIDC_AUDIENCE_B}"
```

```bash
cat > /tmp/trust-policy-oidc-b.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${CMEK_OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${CMEK_SCALR_HOSTNAME}:aud": "${CMEK_OIDC_AUDIENCE_B}",
        "${CMEK_SCALR_HOSTNAME}:sub": [
          "account:${CMEK_SCALR_ACCOUNT_NAME}",
          "account:demo",
          "account:sandbox"
        ]
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name "${CMEK_OIDC_ROLE_NAME_SECONDARY}" \
  --assume-role-policy-document file:///tmp/trust-policy-oidc-b.json
```

```bash
# Existing role: after you change /tmp/trust-policy-oidc-b.json, re-apply trust
aws iam update-assume-role-policy \
  --role-name "${CMEK_OIDC_ROLE_NAME_SECONDARY}" \
  --policy-document file:///tmp/trust-policy-oidc-b.json
```

(If section 3 used single-`sub` trust, set `"${CMEK_SCALR_HOSTNAME}:sub"` to `"account:${CMEK_SCALR_ACCOUNT_NAME}"` in this JSON instead of the array.)

```bash
aws iam put-role-policy \
  --role-name "${CMEK_OIDC_ROLE_NAME_SECONDARY}" \
  --policy-name cmek-kms-minimal \
  --policy-document file:///tmp/kms-role-policy.json
```

```bash
cat > /tmp/kms-key-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccountAdmins",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCmekRolePrimary",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:role/${CMEK_OIDC_ROLE_NAME}" },
      "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
      "Resource": "*"
    },
    {
      "Sid": "AllowCmekRoleSecondary",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:role/${CMEK_OIDC_ROLE_NAME_SECONDARY}" },
      "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
      "Resource": "*"
    }
  ]
}
EOF

aws kms put-key-policy \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_OIDC_KMS_KEY_ID}" \
  --policy-name default \
  --policy file:///tmp/kms-key-policy.json
```

| Field | Value |
|--------|--------|
| `aws-role-arn` | `arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:role/${CMEK_OIDC_ROLE_NAME_SECONDARY}` |
| `aws-audience` | `$CMEK_OIDC_AUDIENCE_B` |

Same `aws-kms-key-arn` as section 5 unless you point at another key.

```bash
aws iam get-role --role-name "${CMEK_OIDC_ROLE_NAME}" --query Role.Arn --output text
aws iam get-role --role-name "${CMEK_OIDC_ROLE_NAME_SECONDARY}" --query Role.Arn --output text
export CMEK_OIDC_ROLE_ARN_PRIMARY="$(aws iam get-role --role-name "${CMEK_OIDC_ROLE_NAME}" --query Role.Arn --output text)"
export CMEK_OIDC_ROLE_ARN_SECONDARY="$(aws iam get-role --role-name "${CMEK_OIDC_ROLE_NAME_SECONDARY}" --query Role.Arn --output text 2>/dev/null || true)"
```

---

## 7 · Second MRK

Create another MRK only after every IAM role that will use it exists. `put-key-policy` on the new key: same shape as section **4** (one role) or **6** (both roles).

```bash
export CMEK_OIDC_MRK_KEY_2_ID="$(
  aws kms create-key \
    --region "${CMEK_KMS_REGION}" \
    --description "Scalr CMEK AWS OIDC test (second MRK)" \
    --key-usage ENCRYPT_DECRYPT \
    --origin AWS_KMS \
    --multi-region \
    --query KeyMetadata.KeyId \
    --output text
)"
export CMEK_OIDC_MRK_KEY_2_ARN="$(aws kms describe-key --region "${CMEK_KMS_REGION}" --key-id "${CMEK_OIDC_MRK_KEY_2_ID}" --query KeyMetadata.Arn --output text)"
```

```bash
export CMEK_OIDC_MRK_KEY_2_ID="mrk-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export CMEK_OIDC_MRK_KEY_2_ARN="$(aws kms describe-key --region "${CMEK_KMS_REGION}" --key-id "${CMEK_OIDC_MRK_KEY_2_ID}" --query KeyMetadata.Arn --output text)"
echo "$CMEK_OIDC_MRK_KEY_2_ARN"
```

```bash
export CMEK_OIDC_MRK_KEY_2_ARN="arn:aws:kms:us-east-1:123456789012:key/mrk-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export CMEK_OIDC_MRK_KEY_2_ID="${CMEK_OIDC_MRK_KEY_2_ARN##*/}"
```

```bash
cat > /tmp/kms-role-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
    "Resource": [ "${CMEK_OIDC_KMS_KEY_ARN}", "${CMEK_OIDC_MRK_KEY_2_ARN}" ]
  }]
}
EOF

aws iam put-role-policy \
  --role-name "${CMEK_OIDC_ROLE_NAME}" \
  --policy-name cmek-kms-minimal \
  --policy-document file:///tmp/kms-role-policy.json
```

```bash
aws iam put-role-policy \
  --role-name "${CMEK_OIDC_ROLE_NAME_SECONDARY}" \
  --policy-name cmek-kms-minimal \
  --policy-document file:///tmp/kms-role-policy.json
```

(Only run the second `put-role-policy` if section 6 was done.)

---

## 8 · Rotation

Primary MRK home region = `$CMEK_KMS_REGION`. On-demand rotation on the **primary** only.

```bash
aws kms rotate-key-on-demand \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_OIDC_KMS_KEY_ID}"
```

```bash
aws kms list-key-rotations \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_OIDC_KMS_KEY_ID}"
```

```bash
aws kms get-key-rotation-status \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_OIDC_KMS_KEY_ID}"
```

```bash
aws kms enable-key-rotation \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_OIDC_KMS_KEY_ID}"
```

Quotas: [KMS quotas](https://docs.aws.amazon.com/kms/latest/developerguide/requests-per-second-quota.html) · On-demand: [rotating-keys-on-demand](https://docs.aws.amazon.com/kms/latest/developerguide/rotating-keys-on-demand.html).

---

## 9 · Negatives

- Wrong `aws-audience` → `AssumeRoleWithWebIdentity` fails.
- Wrong `sub` / account name → deny.
- Role policy `Resource` wrong key ARN → deny.

---

## Cleanup · Tear down

Re-export `CMEK_KMS_REGION`, `CMEK_AWS_ACCOUNT_ID`, `CMEK_OIDC_PROVIDER_ARN`, `CMEK_OIDC_KMS_KEY_ID`, and `CMEK_OIDC_MRK_KEY_2_ID` if used.

```bash
aws iam delete-role-policy --role-name "${CMEK_OIDC_ROLE_NAME_SECONDARY}" --policy-name cmek-kms-minimal
aws iam delete-role --role-name "${CMEK_OIDC_ROLE_NAME_SECONDARY}"
```

(Run the block above only if section 6 was done.)

```bash
aws iam delete-role-policy --role-name "${CMEK_OIDC_ROLE_NAME}" --policy-name cmek-kms-minimal
aws iam delete-role --role-name "${CMEK_OIDC_ROLE_NAME}"
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$CMEK_OIDC_PROVIDER_ARN"
```

```bash
aws kms schedule-key-deletion --region "${CMEK_KMS_REGION}" --key-id "${CMEK_OIDC_MRK_KEY_2_ID}" --pending-window-in-days 7
```

(Only if section 7 was used.)

```bash
aws kms schedule-key-deletion --region "${CMEK_KMS_REGION}" --key-id "${CMEK_OIDC_KMS_KEY_ID}" --pending-window-in-days 7
```

```bash
rm -f /tmp/kms-key-policy.json /tmp/trust-policy-oidc.json /tmp/trust-policy-oidc-b.json /tmp/kms-role-policy.json
```

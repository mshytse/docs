# AWS OIDC CMEK: minimal testing setup

## What Scalr puts in the JWT

Scalr issues the token used as the web identity token. Claims relevant to IAM trust policies:

| Claim | Value |
|--------|--------|
| `iss` | Scalr endpoint URL: `https://<your-scalr-host>` (scheme + host from Scalr config) |
| `aud` | Whatever you configure as `aws-audience` on the CMEK profile (must match the IAM OIDC provider client IDs and the role trust policy) |
| `sub` | `account:<scalr-account-name>` (your Scalr account **name**, not UUID) |
| `scalr_account_id` | Scalr account id |
| `scalr_account_name` | Same as the account name in `sub` |

The **initial** setup below uses one IAM role and audience `scalr-cmek-aws-oidc-test`. You can **expand** later to a second role and audience without recreating the KMS key.

---

## Prerequisites

- One AWS account and one region for the key (multi-region key still has a **home** region in the ARN you store in Scalr).
- Scalr hostname you actually use in the browser (must match `iss` / OIDC provider URL).
- Edit the **`sub` arrays** in the trust JSON files if your Scalr account names differ from `account:test`, `account:demo`, `account:sandbox`.

Scalr requires a **multi-region KMS key**; the ARN must look like `arn:aws:kms:...:key/mrk-...`.

**Why `put-key-policy` comes after the role:** KMS validates IAM principals. Applying a key policy that references a role ARN **before** that role exists returns `MalformedPolicyDocumentException` / invalid principals.

**Hardcoded names (edit in the JSON files if you rename things):**

| Item | Value |
|------|--------|
| Primary IAM role | `scalr-cmek-oidc-test-role` |
| Primary audience (OIDC client id + trust `aud` + Scalr `aws-audience`) | `scalr-cmek-aws-oidc-test` |
| Second IAM role (expansion only) | `scalr-cmek-oidc-test-role-b` |
| Second audience (expansion only) | `scalr-cmek-aws-oidc-test-b` |

---

## 1. Variables (minimal)

Only these need exporting; everything else is hardcoded in the snippets below.

```bash
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export SCALR_HOSTNAME="your-env.scalr.io"   # no scheme; must match Scalr UI URL host
export OIDC_ISSUER_URL="https://${SCALR_HOSTNAME}"
```

Trust policy condition keys use the **host** as prefix: `${SCALR_HOSTNAME}:aud` and `${SCALR_HOSTNAME}:sub`. **`StringEquals`** with a **JSON array** for `sub` allows multiple Scalr accounts (logical OR).


### IAM role ARNs (hardcoded role names from this guide)

Primary (`aws-role-arn` for the first CMEK profile):

```bash
aws iam get-role --role-name scalr-cmek-oidc-test-role --query Role.Arn --output text
```

Second role, if you completed section 8 (`scalr-cmek-oidc-test-role-b`):

```bash
aws iam get-role --role-name scalr-cmek-oidc-test-role-b --query Role.Arn --output text
```

Export for reuse:

```bash
export ROLE_ARN_PRIMARY="$(aws iam get-role --role-name scalr-cmek-oidc-test-role --query Role.Arn --output text)"
export ROLE_ARN_SECONDARY="$(aws iam get-role --role-name scalr-cmek-oidc-test-role-b --query Role.Arn --output text 2>/dev/null || true)"
```

### OIDC provider ARN

If `contains(Arn, hostname)` fails (URL in the ARN is percent-encoded), list URLs and pick the one that matches `https://${SCALR_HOSTNAME}`:

```bash
for arn in $(aws iam list-open-id-connect-providers --query OpenIDConnectProviderList[].Arn --output text); do
  url="$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" --query Url --output text)"
  echo "$url  ->  $arn"
done
```

Or when the hostname appears literally in the ARN:

```bash
export OIDC_PROVIDER_ARN="$(aws iam list-open-id-connect-providers --query \
  "OpenIDConnectProviderList[?contains(Arn, '${SCALR_HOSTNAME}')].Arn | [0]" --output text)"
echo "$OIDC_PROVIDER_ARN"
```

### KMS key id and key ARN

If you still have the **key id** (starts with `mrk-` for multi-region keys):

```bash
export KMS_KEY_ID="mrk-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export KMS_KEY_ARN="$(aws kms describe-key --region "$AWS_REGION" --key-id "$KMS_KEY_ID" --query KeyMetadata.Arn --output text)"
echo "$KMS_KEY_ARN"
```

If you only have the **full key ARN**, the id is the last path segment:

```bash
export KMS_KEY_ARN="arn:aws:kms:us-east-1:123456789012:key/mrk-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export KMS_KEY_ID="${KMS_KEY_ARN##*/}"
```

To **browse** keys in the region (find by `Description` such as `Scalr CMEK AWS OIDC test`):

```bash
for id in $(aws kms list-keys --region "$AWS_REGION" --query 'Keys[].KeyId' --output text); do
  aws kms describe-key --region "$AWS_REGION" --key-id "$id" \
    --query 'KeyMetadata.[KeyId,Arn,Description]' --output text
done
```

### Quick map to Scalr fields

| Scalr / doc field | CLI / value |
|-------------------|-------------|
| `aws-role-arn` (primary) | Output of `get-role` for `scalr-cmek-oidc-test-role` |
| `aws-role-arn` (second profile) | Output of `get-role` for `scalr-cmek-oidc-test-role-b` |
| `aws-kms-key-arn` | `describe-key` → `KeyMetadata.Arn` (must contain `mrk-`) |
| Trust JSON `Principal.Federated` | `OIDC_PROVIDER_ARN` from the loop or `list-open-id-connect-providers` |

---

## 3. IAM OIDC provider (single audience)

Start with **one** client ID; add the second later when you expand.

```bash
# Replace with the TLS thumbprint of $OIDC_ISSUER_URL (console can compute it when you create the provider)
export OIDC_THUMBPRINT="<40-char-hex>"

aws iam create-open-id-connect-provider \
  --url "$OIDC_ISSUER_URL" \
  --client-id-list scalr-cmek-aws-oidc-test \
  --thumbprint-list "$OIDC_THUMBPRINT"
```

Thumbprint helper:

```bash
echo | openssl s_client -servername "$SCALR_HOSTNAME" -connect "${SCALR_HOSTNAME}:443" 2>/dev/null \
  | openssl x509 -fingerprint -noout -sha1 | sed 's/^.*=//;s/://g'
```

```bash
export OIDC_PROVIDER_ARN="$(aws iam list-open-id-connect-providers --query \
  "OpenIDConnectProviderList[?contains(Arn, '${SCALR_HOSTNAME}')].Arn | [0]" --output text)"
```

---

## 4. Multi-region KMS key (create only)

Create the key and capture the ARN. **Do not** set a custom key policy yet (default policy allows account root; you will replace it after the role exists).

```bash
export KMS_KEY_ID="$(
  aws kms create-key \
    --region "$AWS_REGION" \
    --description "Scalr CMEK AWS OIDC test" \
    --key-usage ENCRYPT_DECRYPT \
    --origin AWS_KMS \
    --multi-region \
    --query KeyMetadata.KeyId \
    --output text
)"

export KMS_KEY_ARN="$(aws kms describe-key --region "$AWS_REGION" --key-id "$KMS_KEY_ID" --query KeyMetadata.Arn --output text)"
```

---

## 5. IAM role — primary (`scalr-cmek-oidc-test-role`)

Trust policy `aud` is `scalr-cmek-aws-oidc-test` (must match Scalr `aws-audience` and the OIDC provider client id). Edit the `sub` list if needed.

```bash
cat > /tmp/trust-policy-oidc.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${SCALR_HOSTNAME}:aud": "scalr-cmek-aws-oidc-test",
        "${SCALR_HOSTNAME}:sub": [
          "account:test",
          "account:demo",
          "account:sandbox"
        ]
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name scalr-cmek-oidc-test-role \
  --assume-role-policy-document file:///tmp/trust-policy-oidc.json
```

Inline policy: allow KMS on this key only.

```bash
cat > /tmp/kms-role-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
    "Resource": "${KMS_KEY_ARN}"
  }]
}
EOF

aws iam put-role-policy \
  --role-name scalr-cmek-oidc-test-role \
  --policy-name cmek-kms-minimal \
  --policy-document file:///tmp/kms-role-policy.json
```

Update trust later:

```bash
aws iam update-assume-role-policy \
  --role-name scalr-cmek-oidc-test-role \
  --policy-document file:///tmp/trust-policy-oidc.json
```

---

## 6. KMS key policy (after the primary role exists)

Now the role ARN is valid. Lock the key: account root for admin, primary role for crypto only.

```bash
cat > /tmp/kms-key-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccountAdmins",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCmekRolePrimary",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/scalr-cmek-oidc-test-role" },
      "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
      "Resource": "*"
    }
  ]
}
EOF

aws kms put-key-policy \
  --region "$AWS_REGION" \
  --key-id "$KMS_KEY_ID" \
  --policy-name default \
  --policy file:///tmp/kms-key-policy.json
```

---

## 7. Configure Scalr — single profile

| Field | Value |
|--------|--------|
| `aws-credentials-type` | `oidc` |
| `aws-kms-key-arn` | `$KMS_KEY_ARN` (must contain `mrk-`) |
| `aws-role-arn` | `arn:aws:iam::<AWS_ACCOUNT_ID>:role/scalr-cmek-oidc-test-role` |
| `aws-audience` | `scalr-cmek-aws-oidc-test` |

Then run your CMEK validation path (enable BYOK / rotate DEK as required for your environment).

---

## 8. Expand to a second role and audience (optional)

Use this when you need another CMEK profile with a different `aws-audience` / IAM role pair on the **same** KMS key and issuer.

### 8a. Register the second audience on the OIDC provider

```bash
aws iam add-client-id-to-open-id-connect-provider \
  --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" \
  --client-id scalr-cmek-aws-oidc-test-b
```

### 8b. Create the second role and inline policy

Pick **one** of the trust snippets below. The JWT `sub` claim is always `account:<scalr-account-name>` (see the table at the top).

**Option A — single Scalr account**

Set the account **name** (same string Scalr uses in `sub`, without the `account:` prefix), or skip the export and edit the JSON to a literal such as `"account:prod"`.

```bash
export SCALR_ACCOUNT_NAME="your-scalr-account-name"
```

```bash
cat > /tmp/trust-policy-oidc-b.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${SCALR_HOSTNAME}:aud": "scalr-cmek-aws-oidc-test-b",
        "${SCALR_HOSTNAME}:sub": "account:${SCALR_ACCOUNT_NAME}"
      }
    }
  }]
}
EOF
```

**Option B — multiple Scalr accounts**

Same pattern as section 5: a JSON array under `StringEquals` for `sub` (logical OR across accounts).

```bash
cat > /tmp/trust-policy-oidc-b.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "${OIDC_PROVIDER_ARN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${SCALR_HOSTNAME}:aud": "scalr-cmek-aws-oidc-test-b",
        "${SCALR_HOSTNAME}:sub": [
          "account:test",
          "account:demo",
          "account:sandbox"
        ]
      }
    }
  }]
}
EOF
```

Then create the role (same for both options):

```bash
aws iam create-role \
  --role-name scalr-cmek-oidc-test-role-b \
  --assume-role-policy-document file:///tmp/trust-policy-oidc-b.json
```

```bash
aws iam put-role-policy \
  --role-name scalr-cmek-oidc-test-role-b \
  --policy-name cmek-kms-minimal \
  --policy-document file:///tmp/kms-role-policy.json
```

(Same `kms-role-policy.json` as section 5 — still one key ARN.)

### 8c. Update the KMS key policy to allow both roles

Replace the default policy on **the same** `KMS_KEY_ID` so both role principals can use the key.

```bash
cat > /tmp/kms-key-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowAccountAdmins",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowCmekRolePrimary",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/scalr-cmek-oidc-test-role" },
      "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
      "Resource": "*"
    },
    {
      "Sid": "AllowCmekRoleSecondary",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${AWS_ACCOUNT_ID}:role/scalr-cmek-oidc-test-role-b" },
      "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
      "Resource": "*"
    }
  ]
}
EOF

aws kms put-key-policy \
  --region "$AWS_REGION" \
  --key-id "$KMS_KEY_ID" \
  --policy-name default \
  --policy file:///tmp/kms-key-policy.json
```

### 8d. Configure Scalr — second profile

| Field | Value |
|--------|--------|
| `aws-role-arn` | `arn:aws:iam::<AWS_ACCOUNT_ID>:role/scalr-cmek-oidc-test-role-b` |
| `aws-audience` | `scalr-cmek-aws-oidc-test-b` |

Same `aws-kms-key-arn` as the first profile unless you use another key.

---

## 9. Additional KMS key (optional)

Create another MRK **after** every IAM role that should use it already exists.

1. Create the key and set `KMS_KEY_ID_2` / `KMS_KEY_ARN_2` (same `create-key` block as section 4).

2. **`put-key-policy`** on `KMS_KEY_ID_2`:
   - **Single-role setup:** same shape as **section 6** (root + `scalr-cmek-oidc-test-role` only).
   - **After section 8:** same shape as **section 8c** (root + both roles).

3. **Update** each role’s inline policy so `Resource` lists every key ARN this role should use, for example:

```bash
cat > /tmp/kms-role-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [ "kms:Encrypt", "kms:Decrypt", "kms:DescribeKey" ],
    "Resource": [ "${KMS_KEY_ARN}", "${KMS_KEY_ARN_2}" ]
  }]
}
EOF

aws iam put-role-policy \
  --role-name scalr-cmek-oidc-test-role \
  --policy-name cmek-kms-minimal \
  --policy-document file:///tmp/kms-role-policy.json
```

If you completed section 8, run the same `put-role-policy` for `scalr-cmek-oidc-test-role-b`.

---

## 10. KMS key material rotation (on-demand and status)

Use the key’s **primary** (home) region (`$AWS_REGION`). **Automatic key rotation** (e.g. yearly) runs on AWS’s schedule; to add a **new backing material version immediately**, use **on-demand rotation**. Scalr’s configured key ARN stays `.../key/mrk-...`; existing ciphertext remains decryptable.

**Permissions:** caller needs `kms:RotateKeyOnDemand`, `kms:ListKeyRotations`, and `kms:GetKeyRotationStatus` as appropriate. **Multi-Region keys:** call on-demand rotation only on the **primary** key.

### Trigger on-demand rotation now

```bash
aws kms rotate-key-on-demand \
  --region "$AWS_REGION" \
  --key-id "$KMS_KEY_ID"
```

### List rotation events (verify `ON_DEMAND` / `AUTOMATIC`)

```bash
aws kms list-key-rotations \
  --region "$AWS_REGION" \
  --key-id "$KMS_KEY_ID"
```

A row with **`RotationType`: `ON_DEMAND`** and **`KeyMaterialState`: `CURRENT`** means that version is active. If **`Truncated`** is true, paginate with `--starting-token` / `--max-items` per the CLI help.

### Automatic rotation toggle (yearly schedule, not “rotate now”)

```bash
aws kms get-key-rotation-status \
  --region "$AWS_REGION" \
  --key-id "$KMS_KEY_ID"
```

To enable the periodic schedule (separate from on-demand):

```bash
aws kms enable-key-rotation \
  --region "$AWS_REGION" \
  --key-id "$KMS_KEY_ID"
```

**Limits:** on-demand rotation is capped per key (see [AWS KMS quotas](https://docs.aws.amazon.com/kms/latest/developerguide/requests-per-second-quota.html)); symmetric encryption CMKs only (not asymmetric / HMAC / unsupported custom stores). Details: [On-demand key rotation](https://docs.aws.amazon.com/kms/latest/developerguide/rotating-keys-on-demand.html).

---

## 11. Quick negative checks (optional)

- Wrong `aws-audience` in Scalr: STS should deny (`AssumeRoleWithWebIdentity` fails).
- Wrong Scalr account name in trust `sub`: deny.
- Role policy `Resource` pointing at another key ARN: deny.

---

## Cleanup

Re-export `AWS_REGION`, `AWS_ACCOUNT_ID`, `OIDC_PROVIDER_ARN`, `KMS_KEY_ID` (and `KMS_KEY_ID_2` if used) in a new shell.

**After single-role setup only:**

```bash
aws iam delete-role-policy --role-name scalr-cmek-oidc-test-role --policy-name cmek-kms-minimal
aws iam delete-role --role-name scalr-cmek-oidc-test-role
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN"
aws kms schedule-key-deletion --region "$AWS_REGION" --key-id "$KMS_KEY_ID" --pending-window-in-days 7
```

**If you added the second role (section 8), also:**

```bash
aws iam delete-role-policy --role-name scalr-cmek-oidc-test-role-b --policy-name cmek-kms-minimal
aws iam delete-role --role-name scalr-cmek-oidc-test-role-b
```

```bash
rm -f /tmp/kms-key-policy.json /tmp/trust-policy-oidc.json /tmp/trust-policy-oidc-b.json /tmp/kms-role-policy.json
```

---

## Reference

- Internal OpenAPI: `aws-audience` is the OIDC token audience for `AssumeRoleWithWebIdentity` ([`taco/openapi/openapi-internal.yml`](taco/openapi/openapi-internal.yml)).
- Token claims: [`taco/app/encryption/service/oidc.py`](taco/app/encryption/service/oidc.py) (`issue_server_token`).

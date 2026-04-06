# GCP KMS test setups for Scalr CMEK (BYOK)

This doc walks through **example resource names** you can recreate in **your** GCP project and AWS account. Replace placeholders and run sections in order.

**Requirements for Scalr Google CMEK**

- Symmetric key: `--purpose=encryption` with `--default-algorithm=google-symmetric-encryption`.
- Key resource name shape (no `/cryptoKeyVersions/...` suffix):  
  `projects/${GCP_PROJECT_ID}/locations/global/keyRings/{RING}/cryptoKeys/{KEY}`

**IAM**

- Customer service accounts: bind **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** on the **crypto key** (or tighter custom roles with only encrypt/decrypt usage if you prefer).

Run **Setup 1** before **Setup 2** (Setup 2 grants the second SA on both keys).

---

## Variables (you set these first)

Only **inputs you choose or look up** belong here. **Do not** put KMS key ids from `create-key` in this block; those are set in Part 2 after each key is created.

```bash
# GCP: project where you create key rings, crypto keys, and BYOK test service accounts
export GCP_PROJECT_ID=your-gcp-project-id

# AWS (set account id from the same profile you use for KMS)
export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_IAM_USER_NAME=scalr-cmek-byok-test
export AWS_KMS_ALIAS_NAME=scalr-cmek-test-mrk
```

**MRK key ids** (`mrk-...`): exported in **Part 2** immediately after each `aws kms create-key`, then used for ARNs, IAM policy, and alias commands.

---

## Prerequisite

```bash
gcloud config set project $GCP_PROJECT_ID
```

---

## Setup 1: One KMS key + new SA (access to this key only)

| Resource | Name |
|----------|------|
| Key ring | `byok-1-ring` |
| Crypto key | `byok-1-key` |
| Service account | `byok-1-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com` |
| SA key file (local) | `byok-1-sa-key.json` |

### Commands

```bash
gcloud kms keyrings create byok-1-ring --location=global --project=$GCP_PROJECT_ID
```

```bash
gcloud kms keys create byok-1-key --location=global --keyring=byok-1-ring --purpose=encryption --default-algorithm=google-symmetric-encryption --project=$GCP_PROJECT_ID
```

```bash
gcloud iam service-accounts create byok-1-sa --display-name="BYOK setup 1" --project=$GCP_PROJECT_ID
```

```bash
gcloud kms keys add-iam-policy-binding byok-1-key --location=global --keyring=byok-1-ring --member=serviceAccount:byok-1-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --project=$GCP_PROJECT_ID
```

```bash
gcloud iam service-accounts keys create byok-1-sa-key.json --iam-account=byok-1-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --project=$GCP_PROJECT_ID
```

### Key name for Scalr API (`google-kms-key-name`)

`projects/${GCP_PROJECT_ID}/locations/global/keyRings/byok-1-ring/cryptoKeys/byok-1-key`

Use **`byok-1-sa-key.json`** as `google-sa-key-json`.

---

## Setup 2: Second KMS key + SA that can use **both** keys

The same service account is granted **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** on **`byok-1-key`** and **`byok-2-key`**.

| Resource | Name |
|----------|------|
| Key ring | `byok-2-ring` |
| Crypto key | `byok-2-key` |
| Service account | `byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com` |
| SA key file (local) | `byok-2-sa-key.json` |

### Commands

```bash
gcloud kms keyrings create byok-2-ring --location=global --project=$GCP_PROJECT_ID
```

```bash
gcloud kms keys create byok-2-key --location=global --keyring=byok-2-ring --purpose=encryption --default-algorithm=google-symmetric-encryption --project=$GCP_PROJECT_ID
```

```bash
gcloud iam service-accounts create byok-2-sa --display-name="BYOK setup 2 dual-key" --project=$GCP_PROJECT_ID
```

```bash
gcloud kms keys add-iam-policy-binding byok-2-key --location=global --keyring=byok-2-ring --member=serviceAccount:byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --project=$GCP_PROJECT_ID
```

```bash
gcloud kms keys add-iam-policy-binding byok-1-key --location=global --keyring=byok-1-ring --member=serviceAccount:byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --project=$GCP_PROJECT_ID
```

```bash
gcloud iam service-accounts keys create byok-2-sa-key.json --iam-account=byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --project=$GCP_PROJECT_ID
```

### Key names for Scalr

- Setup 1 key:  
  `projects/${GCP_PROJECT_ID}/locations/global/keyRings/byok-1-ring/cryptoKeys/byok-1-key`
- Setup 2 key:  
  `projects/${GCP_PROJECT_ID}/locations/global/keyRings/byok-2-ring/cryptoKeys/byok-2-key`

Use **`byok-2-sa-key.json`** as `google-sa-key-json` when testing either key with this SA.

---

## Cleanup (GCP): remove entities separately

Pick only what you need. **Suggested order** when undoing a setup end to end: stop using keys in Scalr, delete **user-managed SA keys** (so nothing can call KMS with those credentials), **remove KMS IAM bindings**, then **schedule destruction** of KMS key versions if you want key material gone. Delete the **service account** last (after its user-managed keys are gone).

### User-managed keys on a service account

Created with `gcloud iam service-accounts keys create ...`. Listing shows each key’s id (not the local filename). **USER_MANAGED** rows are the ones you delete; do not try to delete Google-managed keys.

List keys for an account:

```bash
gcloud iam service-accounts keys list --iam-account=byok-1-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --project=$GCP_PROJECT_ID
```

```bash
gcloud iam service-accounts keys list --iam-account=byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --project=$GCP_PROJECT_ID
```

Delete one key (replace `KEY_ID` with the **Key ID** column from the list):

```bash
gcloud iam service-accounts keys delete KEY_ID --iam-account=byok-1-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --project=$GCP_PROJECT_ID
```

Same pattern for `byok-2-sa@...`. Remove or shred local copies (**e.g.** `byok-1-sa-key.json`, `byok-2-sa-key.json`) yourself; GCP does not track those files.

### Service accounts

Only after user-managed keys are deleted (or you only use accounts with no user-managed keys):

```bash
gcloud iam service-accounts delete byok-1-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --project=$GCP_PROJECT_ID
```

```bash
gcloud iam service-accounts delete byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --project=$GCP_PROJECT_ID
```

### IAM bindings on a crypto key

Remove the same **member** and **role** you added with `add-iam-policy-binding`. Repeat per binding.

**`byok-1-key`** (`keyring` `byok-1-ring`):

```bash
gcloud kms keys remove-iam-policy-binding byok-1-key --location=global --keyring=byok-1-ring --member=serviceAccount:byok-1-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --project=$GCP_PROJECT_ID
```

```bash
gcloud kms keys remove-iam-policy-binding byok-1-key --location=global --keyring=byok-1-ring --member=serviceAccount:byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --project=$GCP_PROJECT_ID
```

**`byok-2-key`** (`keyring` `byok-2-ring`):

```bash
gcloud kms keys remove-iam-policy-binding byok-2-key --location=global --keyring=byok-2-ring --member=serviceAccount:byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --project=$GCP_PROJECT_ID
```

**`byok-wrong-alg-key`** (optional negative test, `keyring` `byok-invalid-ring`):

```bash
gcloud kms keys remove-iam-policy-binding byok-wrong-alg-key --location=global --keyring=byok-invalid-ring --member=serviceAccount:byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --project=$GCP_PROJECT_ID
```

### Crypto key versions (schedule destruction)

You do not delete the **CryptoKey** name; you **destroy versions**. That schedules removal of key material (default **24 hours**; see `gcloud kms keys versions destroy` help). Data encrypted with that version becomes **unrecoverable** after destruction completes. List versions, then run `destroy` per version id:

```bash
gcloud kms keys versions list --location=global --keyring=KEY_RING --key=KEY_NAME --project=$GCP_PROJECT_ID
```

```bash
gcloud kms keys versions destroy VERSION --location=global --keyring=KEY_RING --key=KEY_NAME --project=$GCP_PROJECT_ID
```

Examples: `KEY_RING`/`KEY_NAME` pairs used in this doc — `byok-1-ring` / `byok-1-key`, `byok-2-ring` / `byok-2-key`, `byok-invalid-ring` / `byok-wrong-alg-key`.

### Key rings

**Key rings cannot be deleted** in Cloud KMS. They remain after all versions of all keys on the ring are destroyed.

---

## Optional: asymmetric key (negative test)

Not valid for Scalr’s symmetric `encrypt` / `decrypt` DEK flow; use to verify error handling.

```bash
gcloud kms keyrings create byok-invalid-ring --location=global --project=$GCP_PROJECT_ID
```

```bash
gcloud kms keys create byok-wrong-alg-key --location=global --keyring=byok-invalid-ring --purpose=asymmetric-encryption --default-algorithm=rsa-decrypt-oaep-2048-sha1 --project=$GCP_PROJECT_ID
```

### Key resource name (`google-kms-key-name` for API tests)

`projects/${GCP_PROJECT_ID}/locations/global/keyRings/byok-invalid-ring/cryptoKeys/byok-wrong-alg-key`

(No `/cryptoKeyVersions/...` suffix.)

### IAM: grant `byok-2-sa` encrypt/decrypt on this key

So KMS calls succeed with **`byok-2-sa-key.json`** while the key type remains invalid for Scalr’s symmetric DEK flow:

```bash
gcloud kms keys add-iam-policy-binding byok-wrong-alg-key --location=global --keyring=byok-invalid-ring --member=serviceAccount:byok-2-sa@${GCP_PROJECT_ID}.iam.gserviceaccount.com --role=roles/cloudkms.cryptoKeyEncrypterDecrypter --project=$GCP_PROJECT_ID
```

---

# Part 2: AWS KMS (Scalr CMEK BYOK)

Scalr expects:

- **Symmetric multi-region key (MRK)**. Key id in the ARN must look like **`mrk-...`**.
- **Key ARN**, not an alias ARN: `arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/mrk-...` (use the ids returned by AWS).
- **IAM access key** for a principal that can **`kms:Encrypt`**, **`kms:Decrypt`**, and usually **`kms:DescribeKey`** on that key ARN.

Use **`$AWS_REGION`** and **`$AWS_ACCOUNT_ID`** from Variables. If `AWS_ACCOUNT_ID` is empty, set it explicitly:

```bash
aws sts get-caller-identity --query Account --output text
```

---

## One-time: IAM user for API tests

Create a dedicated user (name is arbitrary; match **`AWS_IAM_USER_NAME`**):

```bash
aws iam create-user --user-name $AWS_IAM_USER_NAME
```

---

## Multi-region keys (happy path + rotation)

### MRK A (primary profile, credential rotation, DELETE)

Create the key and **capture the key id** (must start with **`mrk-`**):

```bash
AWS_MRK_A_KEY_ID=$(aws kms create-key \
  --region $AWS_REGION \
  --description "Scalr CMEK MRK A" \
  --key-spec SYMMETRIC_DEFAULT \
  --key-usage ENCRYPT_DECRYPT \
  --multi-region \
  --query KeyMetadata.KeyId \
  --output text)
echo "MRK A KeyId: $AWS_MRK_A_KEY_ID"
```

Full key ARN (for Scalr and IAM):

`arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/${AWS_MRK_A_KEY_ID}`

Confirm:

```bash
aws kms describe-key --region $AWS_REGION --key-id arn:aws:kms:$AWS_REGION:$AWS_ACCOUNT_ID:key/$AWS_MRK_A_KEY_ID
```

### MRK B (second key for PATCH “change KMS key ARN”)

```bash
AWS_MRK_B_KEY_ID=$(aws kms create-key \
  --region $AWS_REGION \
  --description "Scalr CMEK MRK B" \
  --key-spec SYMMETRIC_DEFAULT \
  --key-usage ENCRYPT_DECRYPT \
  --multi-region \
  --query KeyMetadata.KeyId \
  --output text)
echo "MRK B KeyId: $AWS_MRK_B_KEY_ID"
```

`arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/${AWS_MRK_B_KEY_ID}`

Use the second key’s ARN in the PATCH test.

### IAM policy on both MRKs (encrypt/decrypt for your test user)

Write valid JSON with your current shell values (no hand-editing of ids):

```bash
cat > cmek-kms-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ScalrCMEKUseMRK",
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": [
        "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/${AWS_MRK_A_KEY_ID}",
        "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/${AWS_MRK_B_KEY_ID}"
      ]
    }
  ]
}
EOF
```

```bash
aws iam put-user-policy --user-name $AWS_IAM_USER_NAME --policy-name scalr-cmek-kms-use --policy-document file://cmek-kms-policy.json
```

### Access key pair for `POST` / `PATCH`

```bash
aws iam create-access-key --user-name $AWS_IAM_USER_NAME
```

Use **`AccessKeyId`** as `aws-access-key`, **`SecretAccessKey`** as `aws-secret-access-key` in JSON:API. Store the secret once; rotate with `aws iam create-access-key` + `delete-access-key` when testing “new credentials, same ARN”.

---

## Single-region key (negative: not MRK)

```bash
aws kms create-key --region $AWS_REGION --description "Scalr CMEK non-MRK negative" --key-spec SYMMETRIC_DEFAULT --key-usage ENCRYPT_DECRYPT
```

From the output, **`KeyId`** will **not** start with **`mrk-`**. The ARN still looks like `arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/<uuid>` but fails Scalr’s **`mrk-`** validation. Optionally attach the same user policy **`Resource`** to that key’s ARN if you want KMS to deny for a different reason after validation passes (usually you never get past 422 for non-MRK).

---

## Alias ARN (negative: alias not allowed)

Run this **after** MRK A exists (`$AWS_MRK_A_KEY_ID` is set):

```bash
aws kms create-alias --region $AWS_REGION --alias-name alias/$AWS_KMS_ALIAS_NAME --target-key-id arn:aws:kms:$AWS_REGION:$AWS_ACCOUNT_ID:key/$AWS_MRK_A_KEY_ID
```

Use this in `POST` (invalid):

`arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:alias/${AWS_KMS_ALIAS_NAME}`

---

## Malformed ARN (negative)

Send a string that is not `arn:aws:kms:...:key/...`, for example `not-an-arn` or wrong service name.

---

## Wrong credentials / inaccessible key (negative 400)

- Use a valid MRK ARN with **wrong** access key id or secret, or
- Use a key ARN from **another** account, or
- Remove **`kms:Encrypt` / `kms:Decrypt`** from the user policy for that key and retry.

Expect **400** from Scalr with the generic “Could not access the specified key…” message.

---

## JSON:API attributes (reference)

| Attribute | Example |
|-----------|---------|
| `provider-type` | `2` (`aws_kms` enum in API) |
| `aws-kms-key-arn` | `arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_ID}:key/mrk-...` (your MRK id from AWS) |
| `aws-access-key` | IAM user access key id |
| `aws-secret-access-key` | IAM user secret |

Confirm `provider-type` in your client schema (`tacolib` / OpenAPI); use the same value as in component tests if unsure.

---

## Checklist → configuration mapping

| Test | What to configure |
|------|-------------------|
| **Happy POST / GET** | MRK A + IAM user policy on MRK A + access keys; `GET` should mask secret. |
| **Happy PATCH credentials only** | Same MRK A ARN; create **second** access key on same user, `PATCH` with new pair; revoke old key after test if desired. |
| **Happy PATCH change ARN** | MRK A and MRK B both in policy; `PATCH` body changes **`aws-kms-key-arn`** from A to B (credentials unchanged or merged). |
| **Happy DELETE** | After profile exists; `DELETE` then confirm DEK falls back (DB / app behavior). |
| **422 alias** | Use **`alias/...`** ARN from **Alias ARN** section. |
| **422 non-MRK** | Use single-region key ARN without **`mrk-`**. |
| **422 malformed** | Literal invalid string. |
| **422 missing fields** | Omit each required attribute alone. |
| **400 inaccessible** | Wrong secret or policy denied on key. |
| **Edge PATCH partial creds** | Send only secret or only access key; merge behavior per `_merge_update_data`. |
| **Edge PATCH ARN only** | Send new ARN + omit both creds so current keys apply. |
| **Edge AWS → Google** | Requires valid Google CMEK setup from Part 1; `PATCH` with `provider-type` change triggers provider swap in service (full disable/enable cycle). |

---

## Cleanup (optional)

```bash
aws iam delete-access-key --user-name $AWS_IAM_USER_NAME --access-key-id AKIA...
```

```bash
aws kms schedule-key-deletion --region $AWS_REGION --key-id "$AWS_MRK_A_KEY_ID" --pending-window-in-days 7
```

Repeat for MRK B or other keys with their ids. Delete user policy and user when finished:

```bash
aws iam delete-user-policy --user-name $AWS_IAM_USER_NAME --policy-name scalr-cmek-kms-use
```

```bash
aws iam delete-user --user-name $AWS_IAM_USER_NAME
```

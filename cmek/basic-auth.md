# GCP KMS test setups for Scalr CMEK (BYOK)

## Table of contents

- [Variables (you set these first)](#variables-you-set-these-first)
- [Prerequisite](#prerequisite)
- [Setup 1: One KMS key + new SA (access to this key only)](#setup-1-one-kms-key--new-sa-access-to-this-key-only)
- [Setup 2: Second KMS key + SA that can use **both** keys](#setup-2-second-kms-key--sa-that-can-use-both-keys)
- [Cleanup (GCP): remove entities separately](#cleanup-gcp-remove-entities-separately)
- [Part 2: AWS KMS (Scalr CMEK BYOK)](#part-2-aws-kms-scalr-cmek-byok)
- [One-time: IAM user for API tests](#one-time-iam-user-for-api-tests)
- [Multi-region keys (happy path + rotation)](#multi-region-keys-happy-path--rotation)
- [Single-region key (negative: not MRK)](#single-region-key-negative-not-mrk)
- [Alias ARN (negative: alias not allowed)](#alias-arn-negative-alias-not-allowed)
- [Malformed ARN (negative)](#malformed-arn-negative)
- [Wrong credentials / inaccessible key (negative 400)](#wrong-credentials--inaccessible-key-negative-400)
- [Checklist → configuration mapping](#checklist--configuration-mapping)
- [Cleanup (optional)](#cleanup-optional)

This doc walks through **example resource names** you can recreate in **your** GCP project and AWS account. Replace placeholders and run sections in order.

**Variable names** match `cmek-gcp-impersonation.md` and `cmek-gcp-oidc.md` for GCP, and `cmek-aws-impersonation.md` for AWS MRKs, so one shell block can be reused across those guides.

**Requirements for Scalr Google CMEK**

- Symmetric key: `--purpose=encryption` with `--protection-level=software` (or `--default-algorithm=google-symmetric-encryption` where you prefer explicit algorithm).
- Key resource name shape (no `/cryptoKeyVersions/...` suffix):  
  `projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/{RING}/cryptoKeys/{KEY}`

**IAM**

- Customer service accounts: bind **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** on the **crypto key** (or tighter custom roles with only encrypt/decrypt usage if you prefer).

Run **Setup 1** before **Setup 2** (Setup 2 grants the second SA on both keys). Both setups use the **same** key ring (`CMEK_GCP_KEY_RING`), like the impersonation doc.

If you already created the ring or crypto keys from **`cmek-gcp-impersonation.md`** with the same `CMEK_GCP_KEY_RING` / `CMEK_GCP_KEY_ID` / `CMEK_GCP_KEY_ID_2`, skip the duplicate `gcloud kms keyrings create` / `gcloud kms keys create` lines and continue from the SA / IAM binding steps (or point exports at different ids for an isolated BYOK project).

---

## Variables (you set these first)

Only **inputs you choose or look up** belong here. **Do not** put AWS KMS key ids from `create-key` in this block; those are set in Part 2 immediately after each `aws kms create-key`, then exported as `CMEK_KMS_KEY_ID` / `CMEK_MRK_KEY_2_ID` (and ARNs if you need them).

### GCP (shared with `cmek-gcp-impersonation.md` / `cmek-gcp-oidc.md`)

```bash
export CMEK_GCP_PROJECT="your-gcp-project-id"
export CMEK_GCP_KEY_RING="scalr-cmek-ring"
export CMEK_GCP_KEY_ID="scalr-cmek-key"
export CMEK_GCP_KEY_ID_2="scalr-cmek-key-b"
export CMEK_GCP_SA_CUSTOMER_NAME="cmek-byok-sa"
export CMEK_GCP_SA_CUSTOMER="${CMEK_GCP_SA_CUSTOMER_NAME}@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com"
export CMEK_GCP_SA_CUSTOMER_NAME_2="cmek-byok-sa-b"
export CMEK_GCP_SA_CUSTOMER_2="${CMEK_GCP_SA_CUSTOMER_NAME_2}@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com"
export CMEK_GCP_KMS_KEY_NAME="projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/${CMEK_GCP_KEY_RING}/cryptoKeys/${CMEK_GCP_KEY_ID}"
export CMEK_GCP_KMS_KEY_NAME_2="projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/${CMEK_GCP_KEY_RING}/cryptoKeys/${CMEK_GCP_KEY_ID_2}"
# Optional asymmetric negative test (vars + commands): see `cmek-edge-cases.md` (GCP asymmetric section).
# Local files for google-sa-key-json (BYOK only)
export CMEK_GCP_BYOK_SA_KEY_JSON_1="${CMEK_GCP_SA_CUSTOMER_NAME}-key.json"
export CMEK_GCP_BYOK_SA_KEY_JSON_2="${CMEK_GCP_SA_CUSTOMER_NAME_2}-key.json"
```

### AWS (shared with `cmek-aws-impersonation.md`)

```bash
export CMEK_KMS_REGION=us-east-1
export CMEK_AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export CMEK_AWS_BYOK_IAM_USER_NAME=scalr-cmek-byok-test
export CMEK_AWS_KMS_ALIAS_NAME=scalr-cmek-test-mrk
```

After **Part 2** key creation, also export (same pattern as the AWS impersonation guide):

- `CMEK_KMS_KEY_ID`, `CMEK_KMS_KEY_ARN` — first MRK  
- `CMEK_MRK_KEY_2_ID`, `CMEK_MRK_KEY_2_ARN` — second MRK  

---

## Prerequisite

```bash
gcloud config set project "${CMEK_GCP_PROJECT}"
```

---

## Setup 1: One KMS key + new SA (access to this key only)

| Resource | Variable / value |
|----------|------------------|
| Key ring | `${CMEK_GCP_KEY_RING}` |
| Crypto key | `${CMEK_GCP_KEY_ID}` |
| Service account | `${CMEK_GCP_SA_CUSTOMER}` |
| SA key file (local) | `${CMEK_GCP_BYOK_SA_KEY_JSON_1}` |

### Commands

```bash
gcloud kms keyrings create "${CMEK_GCP_KEY_RING}" \
  --location=global \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud kms keys create "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --purpose=encryption \
  --protection-level=software \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud iam service-accounts create "${CMEK_GCP_SA_CUSTOMER_NAME}" \
  --display-name="BYOK setup 1" \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud iam service-accounts keys create "${CMEK_GCP_BYOK_SA_KEY_JSON_1}" \
  --iam-account="${CMEK_GCP_SA_CUSTOMER}" \
  --project="${CMEK_GCP_PROJECT}"
```

### Key name for Scalr API (`google-kms-key-name`)

`$CMEK_GCP_KMS_KEY_NAME`

Use **`${CMEK_GCP_BYOK_SA_KEY_JSON_1}`** as `google-sa-key-json`.

---

## Setup 2: Second KMS key + SA that can use **both** keys

The same service account is granted **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** on **`${CMEK_GCP_KEY_ID}`** and **`${CMEK_GCP_KEY_ID_2}`** (same ring).

| Resource | Variable / value |
|----------|------------------|
| Key ring | `${CMEK_GCP_KEY_RING}` (already exists) |
| Crypto key | `${CMEK_GCP_KEY_ID_2}` |
| Service account | `${CMEK_GCP_SA_CUSTOMER_2}` |
| SA key file (local) | `${CMEK_GCP_BYOK_SA_KEY_JSON_2}` |

### Commands

```bash
gcloud kms keys create "${CMEK_GCP_KEY_ID_2}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --purpose=encryption \
  --protection-level=software \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud iam service-accounts create "${CMEK_GCP_SA_CUSTOMER_NAME_2}" \
  --display-name="BYOK setup 2 dual-key" \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID_2}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud iam service-accounts keys create "${CMEK_GCP_BYOK_SA_KEY_JSON_2}" \
  --iam-account="${CMEK_GCP_SA_CUSTOMER_2}" \
  --project="${CMEK_GCP_PROJECT}"
```

### Key names for Scalr

- Setup 1 key: `$CMEK_GCP_KMS_KEY_NAME`
- Setup 2 key: `$CMEK_GCP_KMS_KEY_NAME_2`

Use **`${CMEK_GCP_BYOK_SA_KEY_JSON_2}`** as `google-sa-key-json` when testing either key with this SA.

---

## Cleanup (GCP): remove entities separately

Pick only what you need. **Suggested order** when undoing a setup end to end: stop using keys in Scalr, delete **user-managed SA keys** (so nothing can call KMS with those credentials), **remove KMS IAM bindings**, then **schedule destruction** of KMS key versions if you want key material gone. Delete the **service account** last (after its user-managed keys are gone).

### User-managed keys on a service account

Created with `gcloud iam service-accounts keys create ...`. Listing shows each key’s id (not the local filename). **USER_MANAGED** rows are the ones you delete; do not try to delete Google-managed keys.

List keys for an account:

```bash
gcloud iam service-accounts keys list \
  --iam-account="${CMEK_GCP_SA_CUSTOMER}" \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud iam service-accounts keys list \
  --iam-account="${CMEK_GCP_SA_CUSTOMER_2}" \
  --project="${CMEK_GCP_PROJECT}"
```

Delete one key (replace `KEY_ID` with the **Key ID** column from the list):

```bash
gcloud iam service-accounts keys delete KEY_ID \
  --iam-account="${CMEK_GCP_SA_CUSTOMER}" \
  --project="${CMEK_GCP_PROJECT}"
```

Same pattern for `${CMEK_GCP_SA_CUSTOMER_2}`. Remove or shred local copies (**e.g.** `${CMEK_GCP_BYOK_SA_KEY_JSON_1}`, `${CMEK_GCP_BYOK_SA_KEY_JSON_2}`) yourself; GCP does not track those files.

### Service accounts

Only after user-managed keys are deleted (or you only use accounts with no user-managed keys):

```bash
gcloud iam service-accounts delete "${CMEK_GCP_SA_CUSTOMER}" \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud iam service-accounts delete "${CMEK_GCP_SA_CUSTOMER_2}" \
  --project="${CMEK_GCP_PROJECT}"
```

### IAM bindings on a crypto key

Remove the same **member** and **role** you added with `add-iam-policy-binding`. Repeat per binding.

**`${CMEK_GCP_KEY_ID}`** on ring **`${CMEK_GCP_KEY_RING}`**:

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

**`${CMEK_GCP_KEY_ID_2}`**:

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID_2}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

**Asymmetric negative-test key** (optional; only if you created it per **`cmek-edge-cases.md`** — ring / key ids **`CMEK_GCP_NEGATIVE_KEY_RING`** / **`CMEK_GCP_NEGATIVE_KEY_ID`**):

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_NEGATIVE_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_NEGATIVE_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

### Crypto key versions (schedule destruction)

Full walkthrough (**`versions destroy`**, **`versions restore`** to cancel pending destruction, optional **`versions delete`** / **`keys delete`**) using **`$CMEK_GCP_KMS_KEY_NAME`**: see **`cmek-edge-cases.md`** → **GCP Cloud KMS: schedule and cancel version destruction**.

Repeat the same pattern for **`${CMEK_GCP_KEY_ID_2}`** / **`$CMEK_GCP_KMS_KEY_NAME_2`**, and for the asymmetric negative-test key use **`${CMEK_GCP_NEGATIVE_KEY_RING}`** / **`${CMEK_GCP_NEGATIVE_KEY_ID}`** if you created it.

### Key rings

**Key rings cannot be deleted** in Cloud KMS. They remain after all versions of all keys on the ring are destroyed.

---

# Part 2: AWS KMS (Scalr CMEK BYOK)

Scalr expects:

- **Symmetric multi-region key (MRK)**. Key id in the ARN must look like **`mrk-...`**.
- **Key ARN**, not an alias ARN: `arn:aws:kms:${CMEK_KMS_REGION}:${CMEK_AWS_ACCOUNT_ID}:key/mrk-...` (use the ids returned by AWS).
- **IAM access key** for a principal that can **`kms:Encrypt`**, **`kms:Decrypt`**, and usually **`kms:DescribeKey`** on that key ARN.

Use **`${CMEK_KMS_REGION}`** and **`${CMEK_AWS_ACCOUNT_ID}`** from Variables. If `CMEK_AWS_ACCOUNT_ID` is empty, set it explicitly:

```bash
aws sts get-caller-identity --query Account --output text
```

---

## One-time: IAM user for API tests

Create a dedicated user (name is arbitrary; match **`CMEK_AWS_BYOK_IAM_USER_NAME`**):

```bash
aws iam create-user --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}"
```

---

## Multi-region keys (happy path + rotation)

### First MRK (primary profile, credential rotation, DELETE)

Create the key and **capture the key id** (must start with **`mrk-`**). Names match `cmek-aws-impersonation.md`:

```bash
export CMEK_KMS_KEY_ID="$(aws kms create-key \
  --region "${CMEK_KMS_REGION}" \
  --description "Scalr CMEK MRK (BYOK test A)" \
  --key-spec SYMMETRIC_DEFAULT \
  --key-usage ENCRYPT_DECRYPT \
  --multi-region \
  --query KeyMetadata.KeyId \
  --output text)"
export CMEK_KMS_KEY_ARN="arn:aws:kms:${CMEK_KMS_REGION}:${CMEK_AWS_ACCOUNT_ID}:key/${CMEK_KMS_KEY_ID}"
echo "CMEK_KMS_KEY_ID=${CMEK_KMS_KEY_ID}"
```

Full key ARN (for Scalr and IAM): `$CMEK_KMS_KEY_ARN`

Confirm:

```bash
aws kms describe-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ARN}"
```

### Second MRK (PATCH “change KMS key ARN”)

```bash
export CMEK_MRK_KEY_2_ID="$(aws kms create-key \
  --region "${CMEK_KMS_REGION}" \
  --description "Scalr CMEK MRK (BYOK test B)" \
  --key-spec SYMMETRIC_DEFAULT \
  --key-usage ENCRYPT_DECRYPT \
  --multi-region \
  --query KeyMetadata.KeyId \
  --output text)"
export CMEK_MRK_KEY_2_ARN="arn:aws:kms:${CMEK_KMS_REGION}:${CMEK_AWS_ACCOUNT_ID}:key/${CMEK_MRK_KEY_2_ID}"
echo "CMEK_MRK_KEY_2_ID=${CMEK_MRK_KEY_2_ID}"
```

`$CMEK_MRK_KEY_2_ARN` — use in the PATCH test when changing **`aws-kms-key-arn`**.

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
        "${CMEK_KMS_KEY_ARN}",
        "${CMEK_MRK_KEY_2_ARN}"
      ]
    }
  ]
}
EOF
```

```bash
aws iam put-user-policy \
  --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}" \
  --policy-name scalr-cmek-kms-use \
  --policy-document file://cmek-kms-policy.json
```

### Access key pair for `POST` / `PATCH`

```bash
aws iam create-access-key --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}"
```

Use **`AccessKeyId`** as `aws-access-key`, **`SecretAccessKey`** as `aws-secret-access-key` in JSON:API. Store the secret once; rotate with `aws iam create-access-key` + `delete-access-key` when testing “new credentials, same ARN”.

---

## Single-region key (negative: not MRK)

```bash
aws kms create-key \
  --region "${CMEK_KMS_REGION}" \
  --description "Scalr CMEK non-MRK negative" \
  --key-spec SYMMETRIC_DEFAULT \
  --key-usage ENCRYPT_DECRYPT
```

From the output, **`KeyId`** will **not** start with **`mrk-`**. The ARN still looks like `arn:aws:kms:${CMEK_KMS_REGION}:${CMEK_AWS_ACCOUNT_ID}:key/<uuid>` but fails Scalr’s **`mrk-`** validation for BYOK paths that require MRK. Optionally attach the same user policy **`Resource`** to that key’s ARN if you want KMS to deny for a different reason after validation passes (usually you never get past 422 for non-MRK).

---

## Alias ARN (negative: alias not allowed)

Run this **after** the first MRK exists (`${CMEK_KMS_KEY_ID}` is set):

```bash
aws kms create-alias \
  --region "${CMEK_KMS_REGION}" \
  --alias-name "alias/${CMEK_AWS_KMS_ALIAS_NAME}" \
  --target-key-id "${CMEK_KMS_KEY_ARN}"
```

Use this in `POST` (invalid):

`arn:aws:kms:${CMEK_KMS_REGION}:${CMEK_AWS_ACCOUNT_ID}:alias/${CMEK_AWS_KMS_ALIAS_NAME}`

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

## Checklist → configuration mapping

| Test | What to configure |
|------|-------------------|
| **Happy POST / GET** | First MRK (`CMEK_KMS_KEY_ARN`) + IAM user policy + access keys; `GET` should mask secret. |
| **Happy PATCH credentials only** | Same MRK ARN; create **second** access key on same user, `PATCH` with new pair; revoke old key after test if desired. |
| **Happy PATCH change ARN** | Both MRKs in policy; `PATCH` body changes **`aws-kms-key-arn`** from `CMEK_KMS_KEY_ARN` to `CMEK_MRK_KEY_2_ARN` (credentials unchanged or merged). |
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
aws iam delete-access-key \
  --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}" \
  --access-key-id AKIA...
```

```bash
aws kms schedule-key-deletion \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --pending-window-in-days 7
```

Repeat for `${CMEK_MRK_KEY_2_ID}` or other keys with their ids. Delete user policy and user when finished:

```bash
aws iam delete-user-policy \
  --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}" \
  --policy-name scalr-cmek-kms-use
```

```bash
aws iam delete-user --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}"
```

To **undo** scheduled AWS key deletion before the window ends: `aws kms cancel-key-deletion --region "${CMEK_KMS_REGION}" --key-id "${CMEK_KMS_KEY_ID}"` (and the same for `${CMEK_MRK_KEY_2_ID}` if needed), then `aws kms enable-key` with the same flags.

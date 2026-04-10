# CMEK edge cases (test setup)

## Table of contents

- [Single-region key in `us-east-1` (not multi-Region)](#single-region-key-in-us-east-1-not-multi-region)
- [Wrong key usage / algorithm (negative test)](#wrong-key-usage--algorithm-negative-test)
- [IAM user access keys (BYOK)](#iam-user-access-keys-byok)
- [GCP Cloud KMS: remove `cryptoKeyEncrypterDecrypter` from a service account](#gcp-cloud-kms-remove-cryptokeyencrypterdecrypter-from-a-service-account)
- [GCP Cloud KMS: disable and enable a key (`${CMEK_GCP_KEY_ID}`)](#gcp-cloud-kms-disable-and-enable-a-key-cmek_gcp_key_id)
- [GCP Cloud KMS: schedule and cancel version destruction (`$CMEK_GCP_KMS_KEY_NAME`)](#gcp-cloud-kms-schedule-and-cancel-version-destruction-cmek_gcp_kms_key_name)
- [GCP Cloud KMS: asymmetric key (wrong algorithm, negative test)](#gcp-cloud-kms-asymmetric-key-wrong-algorithm-negative-test)
- [GCP Cloud KMS (regional location, not `global`)](#gcp-cloud-kms-regional-location-not-global)
- [GCP Workload Identity: second runtime service account (Option B)](#gcp-workload-identity-second-runtime-service-account-option-b)
- [GCP Workload Identity: second OIDC provider (same pool)](#gcp-workload-identity-second-oidc-provider-same-pool)

Companion to `cmek-aws-impersonation.md`, `cmek-gcp-impersonation.md`, and `cmek-kms-basics.md`. Use the same shell variable names as those guides so you can reuse exports.

Sections are **AWS** first, then **GCP** (IAM bindings, disable/enable versions, schedule/cancel version destruction, asymmetric negative-test key, regional keys, a second OIDC provider in the same workload identity pool).

## Single-region key in `us-east-1` (not multi-Region)

Use this when you want a normal symmetric CMK in `us-east-1` instead of an MRK. Scalr still needs the key ARN to be in **`us-east-1` or `us-east-2`** (latency guard in API validation). The key ID in the ARN may be a UUID or an `mrk-…` form; single-region keys use the UUID-style id from `create-key`.

`CMEK_EXTERNAL_ID` does **not** attach to the KMS key. It appears in the IAM role **trust policy** (who may call `sts:AssumeRole`) and in the Scalr CMEK profile next to `aws-role-arn`. Access to encrypt/decrypt is granted with an **inline IAM policy on the role** (and the usual CMK key policy for your account, if you have customized it).

### Reuse from impersonation doc

Set the same base vars as in `cmek-aws-impersonation.md` (table at the top): `CMEK_AWS_ACCOUNT_ID`, `SCALR_AWS_ACCOUNT_ID`, `CMEK_EXTERNAL_ID`, `CMEK_ROLE_NAME`, and use `CMEK_KMS_REGION=us-east-1`.

Complete **§2 Trust** and **§3 Roles** from `cmek-aws-impersonation.md` first so `${CMEK_ROLE_NAME}` exists and trusts `arn:aws:iam::${SCALR_AWS_ACCOUNT_ID}:root` with `sts:ExternalId` = `${CMEK_EXTERNAL_ID}`.

### 1 · Create a single-region CMK

Omit `--multi-region`. Everything else can match the impersonation MRK example.

```bash
export CMEK_KMS_REGION=us-east-1

export CMEK_KMS_KEY_ARN=$(aws kms create-key \
  --region "${CMEK_KMS_REGION}" \
  --description "Scalr CMEK test (single-region CMK)" \
  --key-usage ENCRYPT_DECRYPT \
  --key-spec SYMMETRIC_DEFAULT \
  --query KeyMetadata.Arn --output text)
export CMEK_KMS_KEY_ID="${CMEK_KMS_KEY_ARN##*/}"
```

`CMEK_MRK_KEY_2_*` from the main impersonation guide are optional there; for this edge case you can skip a second key entirely.

### 2 · IAM KMS access for `${CMEK_ROLE_NAME}`

Same pattern as impersonation **§4 · IAM KMS**, but `Resource` is only the single key ARN.

```bash
cat > kms-inline-single.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt"
      ],
      "Resource": "${CMEK_KMS_KEY_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-name scalr-cmek-kms-test \
  --policy-document file://kms-inline-single.json
```

If you also use `CMEK_ROLE_NAME_SECONDARY`, duplicate the `put-role-policy` with that role name and the same document (or merge both ARNs into one `Resource` array).

If your CMK **key policy** does not already allow this role or account-root delegation, add a `Principal` for `arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:role/${CMEK_ROLE_NAME}` with at least `kms:Encrypt`, `kms:Decrypt` (same idea as `cmek-aws-oidc.md` **§4 · Key policy**, but for impersonation you often rely on the default account-admin statement).

### 3 · ARNs for Scalr

```bash
aws iam get-role --role-name "${CMEK_ROLE_NAME}" --query Role.Arn --output text

aws kms describe-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --query KeyMetadata.Arn --output text
```

### 4 · Scalr CMEK profile

| Field | Value |
|--------|--------|
| `aws-credentials-type` | `assume-role` (impersonation) |
| `aws-role-arn` | Output of `get-role` for `${CMEK_ROLE_NAME}` |
| `aws-external-id` | `${CMEK_EXTERNAL_ID}` (must match trust policy) |
| `aws-kms-key-arn` | `${CMEK_KMS_KEY_ARN}` or `describe-key` output |

### Cleanup

After removing the CMEK profile from Scalr:

```bash
aws iam delete-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-name scalr-cmek-kms-test

aws kms schedule-key-deletion \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --pending-window-in-days 7

rm -f kms-inline-single.json
```

No replica keys to delete before scheduling deletion (unlike MRKs with replicas).

### Undo scheduled deletion

If the key is `PendingDeletion` and you want it usable again (same vars as cleanup, or pass the raw KeyId):

```bash
aws kms cancel-key-deletion \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}"
```

After cancel, KMS typically leaves the key **disabled**; turn it back on:

```bash
aws kms enable-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}"
```

Check state:

```bash
aws kms describe-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_KMS_KEY_ID}" \
  --query 'KeyMetadata.{KeyState:KeyState,Enabled:Enabled}' \
  --output table
```

Expect `KeyState` = `Enabled` and `Enabled` = `true`.

---

## Wrong key usage / algorithm (negative test)

Scalr’s AWS CMEK path expects a **symmetric** key with **`ENCRYPT_DECRYPT`**. Use a CMK with a **different `KeyUsage` / `KeySpec`** (for example HMAC or RSA **sign-only**) to exercise KMS-side failures while IAM still allows the role to call `Encrypt` / `Decrypt` on the ARN (KMS returns **`InvalidKeyUsageException`** or similar, not access denied, once policies allow the principal).

Reuse **`CMEK_KMS_REGION`**, **`CMEK_ROLE_NAME`**, **`CMEK_AWS_ACCOUNT_ID`**, trust, and Scalr **`aws-external-id`** / **`aws-role-arn`** from `cmek-aws-impersonation.md` as for other edge cases.

### 1 · Create a non-symmetric key (example: HMAC)

```bash
export CMEK_WRONG_KMS_KEY_ID="$(aws kms create-key \
  --region "${CMEK_KMS_REGION}" \
  --description "Scalr CMEK negative wrong key usage (HMAC)" \
  --key-spec HMAC_384 \
  --key-usage GENERATE_VERIFY_MAC \
  --query KeyMetadata.KeyId \
  --output text)"

export CMEK_WRONG_KMS_KEY_ARN="$(aws kms describe-key \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_WRONG_KMS_KEY_ID}" \
  --query KeyMetadata.Arn \
  --output text)"
echo "${CMEK_WRONG_KMS_KEY_ARN}"
```

Other examples: **`--key-spec RSA_4096 --key-usage SIGN_VERIFY`** (sign only); asymmetric **`ENCRYPT_DECRYPT`** (different client expectations than symmetric envelope).

### 2 · IAM on `${CMEK_ROLE_NAME}`

Use a **separate** inline policy name so you do not overwrite **`scalr-cmek-kms-test`** from the main impersonation flow.

```bash
cat > kms-inline-wrong-key.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:DescribeKey"
      ],
      "Resource": "${CMEK_WRONG_KMS_KEY_ARN}"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-name scalr-cmek-kms-wrong-key-test \
  --policy-document file://kms-inline-wrong-key.json
```

If the CMK **key policy** does not delegate to IAM for this role, add **`arn:aws:iam::${CMEK_AWS_ACCOUNT_ID}:role/${CMEK_ROLE_NAME}`** on the key (same pattern as `cmek-aws-oidc.md` **§4 · Key policy**).

### 3 · Scalr

| Field | Value |
|--------|--------|
| `aws-kms-key-arn` | `${CMEK_WRONG_KMS_KEY_ARN}` |
| Other fields | Same as impersonation (`assume-role`, role ARN, external ID) |

### Cleanup

```bash
aws iam delete-role-policy \
  --role-name "${CMEK_ROLE_NAME}" \
  --policy-name scalr-cmek-kms-wrong-key-test

aws kms schedule-key-deletion \
  --region "${CMEK_KMS_REGION}" \
  --key-id "${CMEK_WRONG_KMS_KEY_ID}" \
  --pending-window-in-days 7

rm -f kms-inline-wrong-key.json
```

---

## IAM user access keys (BYOK)

For **`aws-credentials-type`** access keys (`cmek-kms-basics.md`), the principal is an IAM **user** (`CMEK_AWS_BYOK_IAM_USER_NAME`). User access keys have **no TTL**; they work until **inactive**, **deleted**, or the user is removed. AWS allows **at most two** keys per user (`CreateAccessKey` fails with `LimitExceeded` if both slots are used).

### List keys

```bash
aws iam list-access-keys \
  --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}" \
  --query 'AccessKeyMetadata[*].[AccessKeyId,Status,CreateDate]' \
  --output table
```

### Deactivate (inactive) or reactivate

**Inactive** stops the key from working until you set **Active** again (or delete the key).

```bash
aws iam update-access-key \
  --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}" \
  --access-key-id AKIAxxxxxxxxxxxxxxxx \
  --status Inactive
```

```bash
aws iam update-access-key \
  --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}" \
  --access-key-id AKIAxxxxxxxxxxxxxxxx \
  --status Active
```

### Delete a key

```bash
aws iam delete-access-key \
  --user-name "${CMEK_AWS_BYOK_IAM_USER_NAME}" \
  --access-key-id AKIAxxxxxxxxxxxxxxxx
```

There is **no** API to set an expiration date at creation time; use automation (`update-access-key` / `delete-access-key` on a schedule) or prefer **STS assumed roles** with **`DurationSeconds`** when you need bounded lifetime (see AWS STS docs for minimum and maximum session length).

---

## GCP Cloud KMS: remove `cryptoKeyEncrypterDecrypter` from a service account

If you granted **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** with `gcloud kms keys add-iam-policy-binding` (see `cmek-kms-basics.md` or `cmek-gcp-impersonation.md`), remove it with **`remove-iam-policy-binding`** using the **same** `--location`, `--keyring`, `--key`, `--member`, and `--role` you used when adding.

### Global key (vars from `cmek-kms-basics.md`)

**Setup 1** service account on **`${CMEK_GCP_KEY_ID}`**:

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

**Setup 2** second SA on the first key (if you added it):

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

**Second crypto key** (`${CMEK_GCP_KEY_ID_2}`), for whichever members you bound:

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID_2}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

Adjust **`--member`** if your binding used a different principal (for example another SA email).

### Add permissions back (same keys / members)

Use **`add-iam-policy-binding`** with the **same** flags as in `cmek-kms-basics.md` / `cmek-gcp-impersonation.md` (inverse of **`remove-iam-policy-binding`** above).

**Setup 1** — **`${CMEK_GCP_SA_CUSTOMER}`** on **`${CMEK_GCP_KEY_ID}`**:

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

**Setup 2** — **`${CMEK_GCP_SA_CUSTOMER_2}`** on **`${CMEK_GCP_KEY_ID}`**:

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

**Second crypto key** (`${CMEK_GCP_KEY_ID_2}`):

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID_2}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

If **`cmek-kms-basics.md` Setup 2** also bound **`${CMEK_GCP_SA_CUSTOMER}`** on **`${CMEK_GCP_KEY_ID_2}`**, restore that binding the same way with **`--member="serviceAccount:${CMEK_GCP_SA_CUSTOMER}"`**.

---

## GCP Cloud KMS: disable and enable a key (`${CMEK_GCP_KEY_ID}`)

In Cloud KMS you do not flip a single “disabled” flag on the **CryptoKey** name alone; you **disable or enable crypto key versions**. Cryptographic use (encrypt/decrypt) targets an **enabled** primary version (or the version you specify). Disable the active version(s) to block use; **`enable`** brings a version back if it is still **disabled** (not destroyed).

### List versions (find `VERSION` id)

```bash
gcloud kms keys versions list \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --project="${CMEK_GCP_PROJECT}"
```

Use the **`name`** suffix or **`version id`** column (often **`1`** for the first symmetric version). Replace **`VERSION`** below with that id.

### Disable

```bash
gcloud kms keys versions disable VERSION \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --project="${CMEK_GCP_PROJECT}"
```

### Enable again

```bash
gcloud kms keys versions enable VERSION \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --project="${CMEK_GCP_PROJECT}"
```

If you have **several** enabled versions and only some should be off, repeat per version id. After **`destroy`**, you cannot **`enable`** that version; create a new version or use another key.

### Regional key (`CMEK_GCP_NON_GLOBAL_*`)

Same commands; use **`--location="${CMEK_GCP_NON_GLOBAL_KMS_LOCATION}"`**, **`--keyring="${CMEK_GCP_NON_GLOBAL_KEY_RING}"`**, **`--key="${CMEK_GCP_NON_GLOBAL_KEY_ID}"`**.

### Scalr

A disabled version typically surfaces as a **`BadRequest`** with type **`KEY_DISABLED`** in the provider (see `taco/database/encryption.py`), not the generic auth message.

---

## GCP Cloud KMS: schedule and cancel version destruction (`$CMEK_GCP_KMS_KEY_NAME`)

Google Cloud KMS does **not** mirror AWS’s single **`schedule-key-deletion`** on a CMK. You **schedule destruction per crypto key version** with **`gcloud kms keys versions destroy`**. That puts the version in a **pending destruction** state for the configured **pending window** (often **24 hours**; see `gcloud kms keys versions destroy --help`). While pending, you can **`restore`** that version to **cancel** scheduled destruction. After the window completes, the version becomes **`DESTROYED`** and **`restore`** no longer applies.

**`$CMEK_GCP_KMS_KEY_NAME`** is the full resource name without a version suffix (from **`cmek-kms-basics.md`** / **`cmek-gcp-impersonation.md`**):  
`projects/.../locations/global/keyRings/${CMEK_GCP_KEY_RING}/cryptoKeys/${CMEK_GCP_KEY_ID}`.  
The CLI below uses **`--location`**, **`--keyring`**, **`--key`**, and **`--project`**; they must match that name. For the second BYOK key, use **`$CMEK_GCP_KMS_KEY_NAME_2`** / **`${CMEK_GCP_KEY_ID_2}`** the same way.

### List versions

```bash
echo "${CMEK_GCP_KMS_KEY_NAME}"

gcloud kms keys versions list \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --project="${CMEK_GCP_PROJECT}"
```

Use the **version id** (often **`1`**) in the next commands.

### Schedule destruction (same as “schedule this version for deletion”)

```bash
gcloud kms keys versions destroy 1 \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --project="${CMEK_GCP_PROJECT}"
```

Replace **`1`** if your primary version id differs. Confirm state shows **destruction scheduled** / pending in **`versions list`** or **`gcloud kms keys versions describe`**.

### Cancel scheduled destruction (**`restore`**)

Run **before** the pending window finishes and the version is **`DESTROYED`**:

```bash
gcloud kms keys versions restore 1 \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --project="${CMEK_GCP_PROJECT}"
```

**`restore`** cancels pending destruction but does not always leave the version **enabled** for encrypt/decrypt (for example if it was **disabled** before **`destroy`**). Turn it back on with **`enable`**:

```bash
gcloud kms keys versions enable 1 \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --project="${CMEK_GCP_PROJECT}"
```

### After the version is `DESTROYED`

Optional tidy-up (**`versions delete`**, then **`gcloud kms keys delete`**) is the same flow as **`cmek-gcp-impersonation.md`** cleanup; see [Delete Cloud KMS resources](https://cloud.google.com/kms/docs/delete-kms-resources).

### Regional / other keys

Use **`${CMEK_GCP_NON_GLOBAL_*}`** or **`${CMEK_GCP_NEGATIVE_*}`** ring/key flags with the same **`destroy`** / **`restore`** / **`enable`** pattern.

---

## GCP Cloud KMS: asymmetric key (wrong algorithm, negative test)

Not valid for Scalr’s symmetric `encrypt` / `decrypt` DEK flow; use to verify error handling (often **`BadRequest`** / **`CRYPTO_SCHEME_MISMATCH`** in `taco/database/encryption.py`).

You need **`CMEK_GCP_PROJECT`** and the second BYOK service account (**`${CMEK_GCP_SA_CUSTOMER_2}`**, **`${CMEK_GCP_BYOK_SA_KEY_JSON_2}`**) from **`cmek-kms-basics.md`** Setup 2 so IAM allows KMS calls while the key type stays wrong for Scalr.

### Variables (separate ring / key ids)

```bash
export CMEK_GCP_NEGATIVE_KEY_RING="cmek-invalid-ring"
export CMEK_GCP_NEGATIVE_KEY_ID="cmek-wrong-alg-key"
export CMEK_GCP_NEGATIVE_KMS_KEY_NAME="projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/${CMEK_GCP_NEGATIVE_KEY_RING}/cryptoKeys/${CMEK_GCP_NEGATIVE_KEY_ID}"
```

### Create key ring and asymmetric key

```bash
gcloud kms keyrings create "${CMEK_GCP_NEGATIVE_KEY_RING}" \
  --location=global \
  --project="${CMEK_GCP_PROJECT}"

gcloud kms keys create "${CMEK_GCP_NEGATIVE_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_NEGATIVE_KEY_RING}" \
  --purpose=asymmetric-encryption \
  --default-algorithm=rsa-decrypt-oaep-2048-sha1 \
  --project="${CMEK_GCP_PROJECT}"
```

### Key resource name (`google-kms-key-name` for API tests)

`$CMEK_GCP_NEGATIVE_KMS_KEY_NAME`

(No `/cryptoKeyVersions/...` suffix.)

### IAM

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_NEGATIVE_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_NEGATIVE_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

### Cleanup

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_NEGATIVE_KEY_ID}" \
  --location=global \
  --keyring="${CMEK_GCP_NEGATIVE_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

Then **`gcloud kms keys versions list`** → **`versions destroy`** on **`${CMEK_GCP_NEGATIVE_KEY_RING}`** / **`${CMEK_GCP_NEGATIVE_KEY_ID}`** (same flow as **`cmek-kms-basics.md`** GCP cleanup). The **key ring** cannot be deleted.

---

## GCP Cloud KMS (regional location, not `global`)

In Cloud KMS, **`global`** is a valid **location** for key rings (see other docs). To create a symmetric key in a **regional** location (for example **`us-central1`**, **`europe-west1`**), set **`--location`** on both the key ring and the crypto key to the **same** region id.

### Variables (separate from global CMEK exports)

These names avoid clobbering **`CMEK_GCP_KEY_RING`**, **`CMEK_GCP_KEY_ID`**, and **`CMEK_GCP_KMS_KEY_NAME`** from `cmek-kms-basics.md` / `cmek-gcp-impersonation.md` when you reuse the same shell. Only **`CMEK_GCP_PROJECT`** is shared.

```bash
export CMEK_GCP_PROJECT="your-gcp-project-id"
export CMEK_GCP_NON_GLOBAL_KMS_LOCATION="us-central1"
export CMEK_GCP_NON_GLOBAL_KEY_RING="scalr-cmek-regional-ring"
export CMEK_GCP_NON_GLOBAL_KEY_ID="scalr-cmek-regional-key"
export CMEK_GCP_NON_GLOBAL_KMS_KEY_NAME="projects/${CMEK_GCP_PROJECT}/locations/${CMEK_GCP_NON_GLOBAL_KMS_LOCATION}/keyRings/${CMEK_GCP_NON_GLOBAL_KEY_RING}/cryptoKeys/${CMEK_GCP_NON_GLOBAL_KEY_ID}"
```

Pick **`CMEK_GCP_NON_GLOBAL_KMS_LOCATION`** from [Cloud KMS locations](https://cloud.google.com/kms/docs/locations) (regional or dual-regional ids; not `global` here).

### Create key ring and crypto key

```bash
gcloud config set project "${CMEK_GCP_PROJECT}"

gcloud kms keyrings create "${CMEK_GCP_NON_GLOBAL_KEY_RING}" \
  --location="${CMEK_GCP_NON_GLOBAL_KMS_LOCATION}" \
  --project="${CMEK_GCP_PROJECT}"

gcloud kms keys create "${CMEK_GCP_NON_GLOBAL_KEY_ID}" \
  --location="${CMEK_GCP_NON_GLOBAL_KMS_LOCATION}" \
  --keyring="${CMEK_GCP_NON_GLOBAL_KEY_RING}" \
  --purpose=encryption \
  --protection-level=software \
  --project="${CMEK_GCP_PROJECT}"
```

Full **`google-kms-key-name`** shape (no `/cryptoKeyVersions/...` suffix):

`$CMEK_GCP_NON_GLOBAL_KMS_KEY_NAME`

Example: `projects/my-project/locations/us-central1/keyRings/scalr-cmek-regional-ring/cryptoKeys/scalr-cmek-regional-key`.

### Scalr API

Validation requires **`locations/global`** in the key resource name. A regional name is **rejected** with a message to use a **global** key ring (see `validate_google_kms_key_name` in `taco/app/encryption/apis/validators.py`). Use a regional key for **GCP-only** tests, negative API tests, or non-Scalr tooling—not for a valid Scalr CMEK profile as shipped today.

### Cleanup (versions, then optional key delete)

Same idea as other GCP cleanup docs: destroy key versions, then delete the crypto key when versions are `DESTROYED`; the **key ring** still cannot be deleted in Cloud KMS.

### Remove `cryptoKeyEncrypterDecrypter` from a service account

Same as the **global** remove examples at the top of this doc, but with **`CMEK_GCP_NON_GLOBAL_*`** and the matching **`--location`**:

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_NON_GLOBAL_KEY_ID}" \
  --location="${CMEK_GCP_NON_GLOBAL_KMS_LOCATION}" \
  --keyring="${CMEK_GCP_NON_GLOBAL_KEY_RING}" \
  --member="serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role=roles/cloudkms.cryptoKeyEncrypterDecrypter \
  --project="${CMEK_GCP_PROJECT}"
```

---

## GCP Workload Identity: second runtime service account (Option B)

Use this when you already followed **`cmek-gcp-oidc.md`** Option **B** for **`${CMEK_GCP_SA_RUNTIME}`** and want **another** GCP service account that can do the same KMS work **for the same workload principal** (same **`${CMEK_GCP_WIF_PRINCIPAL_SINGLE}`**, **`${CMEK_GCP_PROJECT_NUMBER}`**, **`${CMEK_GCP_POOL_ID}`** as in that guide).

### 1 · Create the additional runtime SA

```bash
export CMEK_GCP_SA_RUNTIME_2="cmek-wif-2@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com"

gcloud iam service-accounts create cmek-wif-2 \
  --project "${CMEK_GCP_PROJECT}" \
  --display-name "Scalr CMEK WIF runtime (second)"
```

Adjust **`cmek-wif-2`** / **`CMEK_GCP_SA_RUNTIME_2`** to your naming; keep **`${CMEK_GCP_PROJECT}`** consistent with the key and the first runtime SA.

### 2 · Same KMS binding as the first runtime SA

Same role and key as **`cmek-gcp-oidc.md`** (and the snippet you use for **`${CMEK_GCP_SA_RUNTIME}`**), but **`--member`** is the new SA:

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_RUNTIME_2}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

### 3 · Same WIF principal on the new SA

Reuse **`${CMEK_GCP_WIF_PRINCIPAL_SINGLE}`** from **`cmek-gcp-oidc.md`** (built from **`${CMEK_GCP_PROJECT_NUMBER}`**, **`${CMEK_GCP_POOL_ID}`**, and your Scalr account slug). Grant it on **`${CMEK_GCP_SA_RUNTIME_2}`**:

```bash
gcloud iam service-accounts add-iam-policy-binding "${CMEK_GCP_SA_RUNTIME_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --role roles/iam.workloadIdentityUser \
  --member "${CMEK_GCP_WIF_PRINCIPAL_SINGLE}"
```

### 4 · Scalr CMEK profile

Keep **`google-kms-key-name`** and **`google-workload-provider-name`** unchanged. Set **`google-service-account-email`** to **`${CMEK_GCP_SA_RUNTIME_2}`** (the new address) for the profile that should use this SA.

### Cleanup (remove the second SA path)

```bash
gcloud iam service-accounts remove-iam-policy-binding "${CMEK_GCP_SA_RUNTIME_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --role roles/iam.workloadIdentityUser \
  --member "${CMEK_GCP_WIF_PRINCIPAL_SINGLE}"

gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_RUNTIME_2}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter

gcloud iam service-accounts delete "${CMEK_GCP_SA_RUNTIME_2}" \
  --project "${CMEK_GCP_PROJECT}"
```

---

## GCP Workload Identity: second OIDC provider (same pool)

Use this when **`${CMEK_GCP_POOL_ID}`** and **`${CMEK_GCP_PROJECT_NUMBER}`** from **`cmek-gcp-oidc.md`** stay as-is, but you want **another** OIDC provider in that pool (a second **`…/providers/<id>`** resource). **`${CMEK_GCP_SA_RUNTIME}`** and **`${CMEK_GCP_SA_RUNTIME_2}`** stay the same; only Scalr’s **`google-workload-provider-name`** (and the provider’s allowed audience) point at the new provider.

Within one pool, **provider ids must be unique**. You cannot add a second provider with the same id as **`${CMEK_GCP_PROVIDER_ID}`**; pick a new id (example: **`scalr-cmek-oidc-2`** for **`${CMEK_GCP_PROVIDER_ID_2}`**).

Federated IAM principals use **`…/workloadIdentityPools/${CMEK_GCP_POOL_ID}/subject/…`**, not the provider id. If **`google.subject`** mapping and Scalr JWTs match the first provider, **`${CMEK_GCP_WIF_PRINCIPAL_SINGLE}`** already on **`${CMEK_GCP_SA_RUNTIME}`** / **`${CMEK_GCP_SA_RUNTIME_2}`** continues to apply. Add extra **`workloadIdentityUser`** bindings only if you change mapping so **`google.subject`** (or the effective principal) differs.

Use **`--project="${CMEK_GCP_PROJECT}"`** on **`gcloud iam workload-identity-pools providers …`** when the pool lives in the same project as the rest of **`cmek-gcp-oidc.md`** (project id string, not **`${CMEK_GCP_PROJECT_NUMBER}`** alone). If the pool is in another GCP project, substitute that project’s id.

### 1 · Second provider id

```bash
export CMEK_GCP_PROVIDER_ID_2="scalr-cmek-oidc-2"
```

### 2 · Create the OIDC provider

Same shape as **`${CMEK_GCP_WORKLOAD_PROVIDER_NAME}`** / **`${CMEK_GCP_OIDC_AUDIENCE}`** in **`cmek-gcp-oidc.md`**, with **`${CMEK_GCP_PROVIDER_ID_2}`**. Reuse **`${CMEK_SCALR_ISSUER}`** and the same attribute mapping as **`${CMEK_GCP_PROVIDER_ID}`** unless you intentionally diverge.

```bash
export CMEK_GCP_WORKLOAD_PROVIDER_NAME_2="projects/${CMEK_GCP_PROJECT_NUMBER}/locations/global/workloadIdentityPools/${CMEK_GCP_POOL_ID}/providers/${CMEK_GCP_PROVIDER_ID_2}"
export CMEK_GCP_OIDC_AUDIENCE_2="//iam.googleapis.com/${CMEK_GCP_WORKLOAD_PROVIDER_NAME_2}"

gcloud iam workload-identity-pools providers create-oidc "${CMEK_GCP_PROVIDER_ID_2}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location=global \
  --workload-identity-pool="${CMEK_GCP_POOL_ID}" \
  --issuer-uri="${CMEK_SCALR_ISSUER}" \
  --allowed-audiences="${CMEK_GCP_OIDC_AUDIENCE_2}" \
  --attribute-mapping="google.subject=assertion.sub,attribute.scalr_account_id=assertion.scalr_account_id,attribute.scalr_account_name=assertion.scalr_account_name,attribute.aud=assertion.aud"
```

### 3 · Scalr CMEK profile

Set **`google-workload-provider-name`** to **`${CMEK_GCP_WORKLOAD_PROVIDER_NAME_2}`** (same field shape as **`${CMEK_GCP_WORKLOAD_PROVIDER_NAME}`** in **`cmek-gcp-oidc.md`**). Keep **`google-service-account-email`** and **`google-kms-key-name`** as for the first provider. OIDC tokens must use **`aud`** = **`${CMEK_GCP_OIDC_AUDIENCE_2}`**, parallel to **`${CMEK_GCP_OIDC_AUDIENCE}`**.

### Cleanup

Delete only the extra provider (the pool and existing **`${CMEK_GCP_PROVIDER_ID}`** provider stay):

```bash
gcloud iam workload-identity-pools providers delete "${CMEK_GCP_PROVIDER_ID_2}" \
  --project="${CMEK_GCP_PROJECT}" \
  --location=global \
  --workload-identity-pool="${CMEK_GCP_POOL_ID}" \
  --quiet
```

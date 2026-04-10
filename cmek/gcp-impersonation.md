# GCP CMEK impersonation (test setup)

## Table of contents

- [Part A · First customer SA + first key](#part-a--first-customer-sa--first-key)
- [1 · Key ring + crypto key](#1--key-ring--crypto-key)
- [2 · Customer SA + KMS](#2--customer-sa--kms)
- [3 · Scalr → customer SA (impersonation)](#3--scalr--customer-sa-impersonation)
- [4 · Scalr](#4--scalr)
- [5 · Encrypt / decrypt (smoke test, data-access audit logs)](#5--encrypt--decrypt-smoke-test-data-access-audit-logs)
- [Part B · Second key + second customer SA (both SAs on both keys)](#part-b--second-key--second-customer-sa-both-sas-on-both-keys)
- [6 · Second crypto key](#6--second-crypto-key)
- [7 · Second customer SA + KMS (both SAs on both keys)](#7--second-customer-sa--kms-both-sas-on-both-keys)
- [8 · Scalr → second customer SA (impersonation)](#8--scalr--second-customer-sa-impersonation)
- [9 · Scalr (second CMEK profile)](#9--scalr-second-cmek-profile)
- [10 · Encrypt / decrypt (second key; smoke test)](#10--encrypt--decrypt-second-key-smoke-test)
- [Cleanup · Part B (second key + second SA)](#cleanup--part-b-second-key--second-sa)
- [Cleanup · Part A (first key + first SA)](#cleanup--part-a-first-key--first-sa)

Scalr calls KMS as your **customer service account** by impersonation. Scalr's GCP identity needs **`roles/iam.serviceAccountTokenCreator`** on that SA. The customer SA needs **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** (or tighter) on the key.

On GKE **Workload Identity**, instance metadata may show **`email`** as `{project-id}.svc.id.goog` (the workload pool namespace), not a `...@…iam.gserviceaccount.com`. For IAM bindings, use the **principal** or **Google service account** below, not that synthetic value.

KMS key resource name (no version suffix):

`projects/{PROJECT_ID}/locations/global/keyRings/{RING}/cryptoKeys/{KEY}`

Aligns with `cmek-aws-impersonation.md`: shared idea of `CMEK_*` env vars in the same shell if you like; GCP-specific names below.

| Variable | Meaning |
|----------|---------|
| `CMEK_GCP_PROJECT` | GCP project id for the KMS key |
| `CMEK_GCP_KEY_RING` | Key ring id (`global`) |
| `CMEK_GCP_KEY_ID` | First CryptoKey id |
| `CMEK_GCP_KEY_ID_2` | Second CryptoKey id (same ring; both customer SAs get crypto on **both** keys after Part B) |
| `CMEK_GCP_SA_CUSTOMER` | First customer SA email (KMS + impersonation target) |
| `CMEK_GCP_SA_CUSTOMER_2` | Second customer SA email |
| `CMEK_SCALR_GCP_SA` | Scalr **Google service account** email for `serviceAccount:…` IAM members (staging / prod; see table below) |
| `CMEK_SCALR_PREVIEW_WI_SUBJECT_NAMESPACE` | Kubernetes namespace for **preview** only; completes the Workload Identity subject (`ns/…/sa/preview-saas`) |

### Scalr runtime identity for `roles/iam.serviceAccountTokenCreator`

Grant **Token Creator** on your customer SA to the member that matches **your** Scalr environment.

| Environment | IAM member to use |
|-------------|-------------------|
| **Preview** (GKE Workload Identity) | `principal://iam.googleapis.com/projects/205578254527/locations/global/workloadIdentityPools/scalr-dev.svc.id.goog/subject/ns/${CMEK_SCALR_PREVIEW_WI_SUBJECT_NAMESPACE}/sa/preview-saas` |
| **Staging** | `serviceAccount:vm-instance@main-scalr-dev.iam.gserviceaccount.com` |
| **Production** | `serviceAccount:vm-instance@scalr-iacp-saas.iam.gserviceaccount.com` |

Replace `${CMEK_SCALR_PREVIEW_WI_SUBJECT_NAMESPACE}` with the namespace where the `preview-saas` Kubernetes ServiceAccount runs (confirm with SRE if unsure). Staging and production use **service account emails** as `serviceAccount:…` members, not `principal://` workload URLs.

```bash
export CMEK_GCP_PROJECT="your-project-id"
export CMEK_GCP_KEY_RING="scalr-cmek-ring"
export CMEK_GCP_KEY_ID="scalr-cmek-key"
export CMEK_GCP_KEY_ID_2="scalr-cmek-key-b"
export CMEK_GCP_SA_CUSTOMER_NAME="cmek-sa"
export CMEK_GCP_SA_CUSTOMER="${CMEK_GCP_SA_CUSTOMER_NAME}@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com"
export CMEK_GCP_SA_CUSTOMER_NAME_2="cmek-sa-b"
export CMEK_GCP_SA_CUSTOMER_2="${CMEK_GCP_SA_CUSTOMER_NAME_2}@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com"
# Staging or prod smoke tests: pick the matching Scalr runtime SA
export CMEK_SCALR_GCP_SA="vm-instance@main-scalr-dev.iam.gserviceaccount.com"
# Preview only: set the K8s namespace, then build the principal for gcloud --member (see §3)
export CMEK_SCALR_PREVIEW_WI_SUBJECT_NAMESPACE="your-preview-namespace"
export CMEK_GCP_KMS_KEY_NAME="projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/${CMEK_GCP_KEY_RING}/cryptoKeys/${CMEK_GCP_KEY_ID}"
export CMEK_GCP_KMS_KEY_NAME_2="projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/${CMEK_GCP_KEY_RING}/cryptoKeys/${CMEK_GCP_KEY_ID_2}"
```

---

## Part A · First customer SA + first key

## 1 · Key ring + crypto key

```bash
gcloud kms keyrings create "${CMEK_GCP_KEY_RING}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global
```

```bash
gcloud kms keys create "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --purpose encryption \
  --protection-level software
```

```bash
# Key resource name for Scalr
echo "${CMEK_GCP_KMS_KEY_NAME}"
```

---

## 2 · Customer SA + KMS

```bash
gcloud iam service-accounts create ${CMEK_GCP_SA_CUSTOMER_NAME} \
  --project "${CMEK_GCP_PROJECT}" \
  --display-name "Scalr CMEK test"
```

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

---

## 3 · Scalr → customer SA (impersonation)

**Staging / production** (Google service account member):

```bash
gcloud iam service-accounts add-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "serviceAccount:${CMEK_SCALR_GCP_SA}" \
  --role roles/iam.serviceAccountTokenCreator
```

Use `CMEK_SCALR_GCP_SA=vm-instance@main-scalr-dev.iam.gserviceaccount.com` or `vm-instance@scalr-iacp-saas.iam.gserviceaccount.com` per the table above.

**Preview-saas** (Workload Identity **principal** member; project number `205578254527`, pool `scalr-dev.svc.id.goog`, KSA `preview-saas`):

```bash
gcloud iam service-accounts add-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "principal://iam.googleapis.com/projects/205578254527/locations/global/workloadIdentityPools/scalr-dev.svc.id.goog/subject/ns/${CMEK_SCALR_PREVIEW_WI_SUBJECT_NAMESPACE}/sa/preview-saas" \
  --role roles/iam.serviceAccountTokenCreator
```

---

## 4 · Scalr

| JSON:API attribute | Value |
|--------------------|--------|
| `provider-type` | `google-cloud-kms` |
| `google-credentials-type` | `service-account-impersonation` |
| `google-kms-key-name` | `$CMEK_GCP_KMS_KEY_NAME` |
| `google-service-account-email` | `$CMEK_GCP_SA_CUSTOMER` |

---

## 5 · Encrypt / decrypt (smoke test, data-access audit logs)

After **§7**, both customer SAs have crypto on the first key; until then only **`${CMEK_GCP_SA_CUSTOMER}`** does. From your workstation either:

- **Impersonate** that SA (`--impersonate-service-account`), after your user has **`roles/iam.serviceAccountTokenCreator`** on `${CMEK_GCP_SA_CUSTOMER}`, or  
- Drop **`--impersonate-service-account`** if you granted **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** to your user on this key.

```bash
echo -n "cmek-audit-smoke" > /tmp/cmek-pt.txt

gcloud kms encrypt \
  --project="${CMEK_GCP_PROJECT}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --plaintext-file=/tmp/cmek-pt.txt \
  --ciphertext-file=/tmp/cmek-ct.bin \
  --impersonate-service-account="${CMEK_GCP_SA_CUSTOMER}"
```

```bash
gcloud kms decrypt \
  --project="${CMEK_GCP_PROJECT}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID}" \
  --ciphertext-file=/tmp/cmek-ct.bin \
  --plaintext-file=/tmp/cmek-pt-out.txt \
  --impersonate-service-account="${CMEK_GCP_SA_CUSTOMER}"
```

After Part B §7 you can use `--impersonate-service-account="${CMEK_GCP_SA_CUSTOMER_2}"` on this key as well.

Then query **`data_access`** logs for `cloudkms.googleapis.com` / `Encrypt` / `Decrypt`.

---

## Part B · Second key + second customer SA (both SAs on both keys)

Create a **second** CryptoKey in the **same** key ring. Add a **second** customer SA. Grant **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** on **each** CryptoKey to **both** `${CMEK_GCP_SA_CUSTOMER}` and `${CMEK_GCP_SA_CUSTOMER_2}` so either SA can call KMS on either key. Allow Scalr to impersonate the second SA the same way as the first (staging `serviceAccount:…` or preview `principal://…`).

## 6 · Second crypto key

Skip if the key already exists.

```bash
gcloud kms keys create "${CMEK_GCP_KEY_ID_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --purpose encryption \
  --protection-level software
```

```bash
echo "${CMEK_GCP_KMS_KEY_NAME_2}"
```

## 7 · Second customer SA + KMS (both SAs on both keys)

```bash
gcloud iam service-accounts create ${CMEK_GCP_SA_CUSTOMER_NAME_2} \
  --project "${CMEK_GCP_PROJECT}" \
  --display-name "Scalr CMEK test (second SA)"
```

Both customer SAs on the **first** key (SA1 is already on key 1 from §2; this adds SA2):

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

Both customer SAs on the **second** key:

```bash
gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter

gcloud kms keys add-iam-policy-binding "${CMEK_GCP_KEY_ID_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

## 8 · Scalr → second customer SA (impersonation)

**Staging / production:**

```bash
gcloud iam service-accounts add-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "serviceAccount:${CMEK_SCALR_GCP_SA}" \
  --role roles/iam.serviceAccountTokenCreator
```

**Preview-saas** (same principal as §3):

```bash
gcloud iam service-accounts add-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "principal://iam.googleapis.com/projects/205578254527/locations/global/workloadIdentityPools/scalr-dev.svc.id.goog/subject/ns/${CMEK_SCALR_PREVIEW_WI_SUBJECT_NAMESPACE}/sa/preview-saas" \
  --role roles/iam.serviceAccountTokenCreator
```

## 9 · Scalr (second CMEK profile)

Use a **second** customer-managed encryption key in Scalr (another account or another profile, per your test). Point it at the second key and second impersonation target:

| JSON:API attribute | Value |
|--------------------|--------|
| `provider-type` | `google-cloud-kms` |
| `google-credentials-type` | `service-account-impersonation` |
| `google-kms-key-name` | `$CMEK_GCP_KMS_KEY_NAME_2` |
| `google-service-account-email` | `$CMEK_GCP_SA_CUSTOMER_2` |

## 10 · Encrypt / decrypt (second key; smoke test)

Use `--impersonate-service-account="${CMEK_GCP_SA_CUSTOMER}"` or `--impersonate-service-account="${CMEK_GCP_SA_CUSTOMER_2}"`; after §7 both SAs have crypto on **both** keys. The commands below use key 2 and SA2.

```bash
echo -n "cmek-audit-smoke-b" > /tmp/cmek-pt-b.txt

gcloud kms encrypt \
  --project="${CMEK_GCP_PROJECT}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID_2}" \
  --plaintext-file=/tmp/cmek-pt-b.txt \
  --ciphertext-file=/tmp/cmek-ct-b.bin \
  --impersonate-service-account="${CMEK_GCP_SA_CUSTOMER_2}"

gcloud kms decrypt \
  --project="${CMEK_GCP_PROJECT}" \
  --location=global \
  --keyring="${CMEK_GCP_KEY_RING}" \
  --key="${CMEK_GCP_KEY_ID_2}" \
  --ciphertext-file=/tmp/cmek-ct-b.bin \
  --plaintext-file=/tmp/cmek-pt-b-out.txt \
  --impersonate-service-account="${CMEK_GCP_SA_CUSTOMER_2}"
```

---

## Cleanup · Part B (second key + second SA)

Order: remove Scalr impersonation on SA2, remove both SAs from key 2, remove SA2 from key 1 (before deleting SA2), destroy key 2 version, delete SA2.

Remove **one** Token Creator binding on SA2 (the same member you used in §8: staging **or** preview).

```bash
# Staging / prod
gcloud iam service-accounts remove-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "serviceAccount:${CMEK_SCALR_GCP_SA}" \
  --role roles/iam.serviceAccountTokenCreator
```

Preview-saas:

```bash
gcloud iam service-accounts remove-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "principal://iam.googleapis.com/projects/205578254527/locations/global/workloadIdentityPools/scalr-dev.svc.id.goog/subject/ns/${CMEK_SCALR_PREVIEW_WI_SUBJECT_NAMESPACE}/sa/preview-saas" \
  --role roles/iam.serviceAccountTokenCreator
```

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter

gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID_2}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

Remove SA2 from the **first** key before deleting the SA:

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER_2}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

```bash
gcloud kms keys versions destroy 1 \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --key "${CMEK_GCP_KEY_ID_2}"
```

```bash
gcloud iam service-accounts delete "${CMEK_GCP_SA_CUSTOMER_2}" \
  --project "${CMEK_GCP_PROJECT}" --quiet
```

---

## Cleanup · Part A (first key + first SA)

```bash
# Staging / prod: use the same serviceAccount: member you added in §3
gcloud iam service-accounts remove-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "serviceAccount:${CMEK_SCALR_GCP_SA}" \
  --role roles/iam.serviceAccountTokenCreator
```

Preview-saas teardown: repeat `remove-iam-policy-binding` with the same **`principal://…`** `--member` string used in §3.

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

```bash
gcloud kms keys versions destroy 1 \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --key "${CMEK_GCP_KEY_ID}"
```

```bash
gcloud iam service-accounts delete "${CMEK_GCP_SA_CUSTOMER}" \
  --project "${CMEK_GCP_PROJECT}" --quiet
```

**Key rings:** There is no `gcloud kms keyrings delete`. Cloud KMS **key rings are not deletable**; only **crypto keys** (and key versions) can be removed. The empty key ring stays in the project. See [Delete Cloud KMS resources](https://cloud.google.com/kms/docs/delete-kms-resources).

To **cancel** scheduled version destruction (**`versions restore`**) while the version is still pending, see **`cmek-edge-cases.md`** (GCP schedule and cancel version destruction).

After `versions destroy`, wait until the version is **`DESTROYED`**, then you can **delete the version** and **delete the crypto key** (optional tidy-up):

```bash
gcloud kms keys versions delete 1 \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --key "${CMEK_GCP_KEY_ID}"
```

If you used Part B, repeat for `${CMEK_GCP_KEY_ID_2}` after its version is destroyed.

```bash
gcloud kms keys delete "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --quiet
```

If you used Part B, also run `gcloud kms keys delete` for `${CMEK_GCP_KEY_ID_2}` once that key has no remaining versions.

If `gcloud` says **Invalid choice: 'delete'**, the Cloud SDK is too old. Upgrade (`gcloud components update`) or use the beta command (install with `gcloud components install beta` if needed):

```bash
gcloud beta kms keys delete "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --quiet
```

If you used **Part B**, run **Cleanup · Part B** first (so both SAs are unbound from key 2 and SA2 is unbound from key 1), then **Cleanup · Part A**, then the optional version/key deletes above when versions have reached `DESTROYED`.

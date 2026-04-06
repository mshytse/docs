# GCP CMEK impersonation (test setup)

Scalr calls KMS as your **customer service account** by impersonation. Scalr's GCP identity needs **`roles/iam.serviceAccountTokenCreator`** on that SA. The customer SA needs **`roles/cloudkms.cryptoKeyEncrypterDecrypter`** (or tighter) on the key.

KMS key resource name (no version suffix):

`projects/{PROJECT_ID}/locations/global/keyRings/{RING}/cryptoKeys/{KEY}`

Aligns with `cmek-aws-impersonation.md`: shared idea of `CMEK_*` env vars in the same shell if you like; GCP-specific names below.

| Variable | Meaning |
|----------|---------|
| `CMEK_GCP_PROJECT` | GCP project id for the KMS key |
| `CMEK_GCP_KEY_RING` | Key ring id (`global`) |
| `CMEK_GCP_KEY_ID` | CryptoKey id |
| `CMEK_GCP_SA_CUSTOMER` | Customer SA email (KMS + impersonation target) |
| `CMEK_SCALR_GCP_SA` | Scalr environment GCP service account email (from SRE / deployment) |

```bash
export CMEK_GCP_PROJECT="your-project-id"
export CMEK_GCP_KEY_RING="scalr-cmek-ring"
export CMEK_GCP_KEY_ID="scalr-cmek-key"
export CMEK_GCP_SA_CUSTOMER="cmek-sa@${CMEK_GCP_PROJECT}.iam.gserviceaccount.com"
export CMEK_SCALR_GCP_SA="scalr-saas@YOUR-SCALR-PROJECT.iam.gserviceaccount.com"
export CMEK_GCP_KMS_KEY_NAME="projects/${CMEK_GCP_PROJECT}/locations/global/keyRings/${CMEK_GCP_KEY_RING}/cryptoKeys/${CMEK_GCP_KEY_ID}"
```

---

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
gcloud iam service-accounts create cmek-sa \
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

```bash
gcloud iam service-accounts add-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "serviceAccount:${CMEK_SCALR_GCP_SA}" \
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

## Cleanup · Tear down

```bash
gcloud iam service-accounts remove-iam-policy-binding "${CMEK_GCP_SA_CUSTOMER}" \
  --project "${CMEK_GCP_PROJECT}" \
  --member "serviceAccount:${CMEK_SCALR_GCP_SA}" \
  --role roles/iam.serviceAccountTokenCreator
```

```bash
gcloud kms keys remove-iam-policy-binding "${CMEK_GCP_KEY_ID}" \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --member "serviceAccount:${CMEK_GCP_SA_CUSTOMER}" \
  --role roles/cloudkms.cryptoKeyEncrypterDecrypter
```

```bash
gcloud kms keys versions schedule-destroy 1 \
  --project "${CMEK_GCP_PROJECT}" \
  --location global \
  --keyring "${CMEK_GCP_KEY_RING}" \
  --key "${CMEK_GCP_KEY_ID}"
```

```bash
gcloud iam service-accounts delete "${CMEK_GCP_SA_CUSTOMER}" \
  --project "${CMEK_GCP_PROJECT}" --quiet
```

---

## Reference

- `taco/app/encryption/resources.py` (CMEK attributes)
- `taco/app/encryption/service/cmek_providers/google.py`
- `taco/app/encryption/service/oidc.py` (AWS OIDC; GCP OIDC uses WIF path in `taco/app/encryption/v1/factory.py`)

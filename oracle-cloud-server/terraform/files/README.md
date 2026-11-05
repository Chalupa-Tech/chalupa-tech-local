# Public keys referenced by the Terraform stack

- `openbao-unseal-api-key.pub` — RSA public key (PEM) registered as the API
  key of the `openbao-unseal` IAM user (`openbao-unseal.tf`). Generate the
  pair locally; the private half goes only into the Kubernetes secret
  `openbao-oci-kms` (see `docs/runbooks/openbao-seal-migration.md`):

  ```bash
  openssl genrsa -out openbao-unseal.pem 2048
  openssl rsa -in openbao-unseal.pem -pubout -out openbao-unseal-api-key.pub
  ```

  The API-key resource has `prevent_destroy`: rotate by replacing the file's
  content (then update the `openbao-oci-kms` secret and roll the pods one at
  a time); never delete the file.

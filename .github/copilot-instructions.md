# Copilot Instructions

- Do not assume `terraform` is installed on the host.
- Run Terraform validation for this repo via Docker from the workspace root.
- Use the official image `hashicorp/terraform:1.8.5` unless the repo updates its Terraform version requirements.
- For validation, mount the `infra` directory into the container and run:

```powershell
docker run --rm -v "${PWD}\infra:/workspace" -w /workspace hashicorp/terraform:1.8.5 init -backend=false
docker run --rm -v "${PWD}\infra:/workspace" -w /workspace hashicorp/terraform:1.8.5 validate
```

- Keep Terraform validation scoped to `infra/` unless the repo structure changes.
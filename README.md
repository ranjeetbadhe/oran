# oran - telco site applications

Deployed by Argo CD on the RHACM hub to the sites selected in the O-RAN portal ("Deploy applications").

- `charts/<app>/` Helm chart. A release = new `image.digest` in values.yaml + higher `version` in Chart.yaml.
- `clusters/<site>/<app>.yaml` optional per-site values.

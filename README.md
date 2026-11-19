# Telco site applications

Deployed by Argo CD on the RHACM hub to the telco sites selected in the O-RAN portal
("Deploy applications"). The portal only labels ManagedClusters `app.oran/<app>=enabled`.

```
charts/<app>/                 Helm chart (Chart.yaml version + values.yaml image.digest = the release)
clusters/<cluster>/<app>.yaml  optional per-site overrides (folder = ManagedCluster name, file = app name)
```

Release = commit a new `image.digest` (and bump `version` in Chart.yaml). Argo CD rolls it out to every
selected site. Never commit registry passwords or tokens: the pull secret comes from an RHACM policy.

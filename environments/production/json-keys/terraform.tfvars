images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.15.6@sha256:06457d216da6416e58262893731c6caf4382d74e89baa13aa79eaffd629c771c"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.15.6@sha256:77f614bd68216773066954d6909b9c34d2ae4180c0336eb90e710890e0c158b7"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.15.6@sha256:644aacfd320655d5304d6fc2b626201c0be856fdfffe02975c56dc3b542ce28c"
  rest       = "ghcr.io/a-novel/service-json-keys/rest:v2.15.6@sha256:74f6c06745bb3e5fe9d85a1403be296c61adba89e7529ac6eaec59493473defa"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.15.6@sha256:ffe6bcdd19c3342f3cdd1384b3cc7a20320e01e680b765f5fe0344c1452d8b6d"
}

secret_versions = {
  app-master-key = 2
}

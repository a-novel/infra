images = {
  database   = "ghcr.io/a-novel/service-json-keys/database:v2.12.1@sha256:f1072d3e67f7c333eb84c35b1be9bdad6bb3beae362a6d808b39f2f2ec073c11"
  grpc       = "ghcr.io/a-novel/service-json-keys/grpc:v2.12.1@sha256:ebc21a2cb1f3b79de4e6e7b27f387b269e01e129617fe901c2348fe1ba6fcfa6"
  migrations = "ghcr.io/a-novel/service-json-keys/jobs/migrations:v2.12.1@sha256:2f28b5584f5d1bcd5a5f88c2bc438b07437a4bfb567128535288c515ea5b1594"
  rotatekeys = "ghcr.io/a-novel/service-json-keys/jobs/rotatekeys:v2.12.1@sha256:0fa5b4d9345633bfd812b000d97b798bea0d9ebb69207427ea54f47c777e625b"
}

secret_versions = {
  app-password   = 1
  app-master-key = 2
}

backup_repository = {
  cos_image = "projects/cos-cloud/global/images/cos-129-19506-505-8"
  runtime = {
    client_name      = "agora-database.a-novel-production-prod"
    ca_version       = "1"
    identity_version = "2"
  }
}

alert_email = "geoffroy.vincent@agorastoryverse.com"

locals {
  backup_jobs = {
    stanza-create = "stanza-create"
    check         = "check"
    full          = "--type=full --archive-copy --repo1-bundle --no-expire-auto backup"
    diff          = "--type=diff --archive-copy --repo1-bundle --no-expire-auto backup"
    verify        = "--output=text --verbose --log-level-console=error verify"
  }
  backup_calendars = {
    full  = "Sun *-*-* 02:00:00 UTC"
    diff  = "Mon..Sat *-*-* 02:00:00 UTC"
    check = "*-*-* *:30:00 UTC"
  }
  files = concat([
    {
      path        = "/etc/agora-database/docker/config.json"
      permissions = "0600"
      content     = jsonencode({ credHelpers = { "${var.region}-docker.pkg.dev" = "gcr" } })
    },
    {
      path        = "/etc/agora-database/startup.sh"
      permissions = "0400"
      content     = file("${path.module}/../../assets/database-host/startup.sh")
    },
    {
      path        = "/etc/agora-database/pgbackrest.conf"
      permissions = "0444"
      content = templatefile("${path.module}/templates/database-pgbackrest.conf.tftpl", {
        server_name = var.repository.name
        service     = var.service
        database    = "agora_${replace(var.service, "-", "_")}"
      })
    },
    {
      path        = "/etc/systemd/system/agora-database.service"
      permissions = "0644"
      content = templatefile("${path.module}/templates/database.service.tftpl", merge(var.repository, {
        project           = var.project_id
        service           = var.service
        management_number = var.management_number
        server_name       = var.repository.name
        server_ip         = var.repository.ip
        identity_version  = var.identity_version
        wal_archiving     = var.wal_archiving
        zone_argument     = var.shared_private ? "--zone=private " : ""
        backup_containers = join(" ", [for name in keys(local.backup_jobs) : "agora-backup-${name}"])
      }))
    },
    ], [for name, command in local.backup_jobs : {
      path        = "/etc/systemd/system/agora-backup-${name}.service"
      permissions = "0644"
      content = templatefile("${path.module}/templates/database-backup.service.tftpl", {
        name        = name
        command     = command
        image       = var.repository.server_image
        server_name = var.repository.name
        service     = var.service
      })
      }], [for name, calendar in local.backup_calendars : {
      path        = "/etc/systemd/system/agora-backup-${name}.timer"
      permissions = "0644"
      content     = templatefile("${path.module}/templates/database-backup.timer.tftpl", { name = name, calendar = calendar })
      }], [{
      path        = "/etc/agora-database/check-backup.sh"
      permissions = "0444"
      content     = file("${path.module}/../../assets/database-host/check-backup.sh")
  }])
}

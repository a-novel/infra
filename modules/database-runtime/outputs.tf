output "cloud_config" {
  description = "COS preparation-only cloud-config; the protected owner starts the units."
  # COS serves persistent keys, not the /etc/ssh keys cloud-init reports.
  value = "#cloud-config\n${yamlencode({ ssh_deletekeys = false, write_files = local.files, runcmd = [["systemctl", "daemon-reload"]] })}"
}

output "startup_script" {
  description = "COS startup script for the existing stateful group; starts the database and its approved schedules."
  value       = templatefile("${path.module}/templates/startup.sh.tftpl", { files = local.files })
}

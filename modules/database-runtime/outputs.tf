output "cloud_config" {
  description = "The host's files and units as a cloud-config document, which starts nothing. The module's tests read it."
  # COS serves persistent keys, not the /etc/ssh keys cloud-init reports.
  value = "#cloud-config\n${yamlencode({ ssh_deletekeys = false, write_files = local.files, runcmd = [["systemctl", "daemon-reload"]] })}"
}

output "startup_script" {
  description = "The host's startup script. It writes the host's files and starts the database, which also starts the backup timers when schedules are enabled."
  value       = templatefile("${path.module}/templates/startup.sh.tftpl", { files = local.files })
}

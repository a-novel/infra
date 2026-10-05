output "cloud_config" {
  description = "COS preparation-only cloud-config; the protected owner starts the units."
  value       = "#cloud-config\n${yamlencode({ write_files = local.files, runcmd = [["systemctl", "daemon-reload"]] })}"
}

output "startup_script" {
  description = "COS startup script for the existing stateful group; starts the database but leaves backup timers stopped."
  value       = templatefile("${path.module}/templates/startup.sh.tftpl", { files = local.files })
}

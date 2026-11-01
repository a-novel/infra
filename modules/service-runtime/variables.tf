variable "service" {
  description = "Application name, such as json-keys."
  type        = string
}

variable "project_id" {
  description = "Workload project that holds the service's repositories."
  type        = string
}

variable "region" {
  description = "Region of the image repositories."
  type        = string
}

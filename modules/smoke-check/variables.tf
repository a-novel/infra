variable "service" {
  description = "Application name, such as json-keys."
  type        = string
}

variable "region" {
  description = "Region of the service and the job."
  type        = string
}

variable "target" {
  description = "The private gRPC service the job checks: its Cloud Run name and URL, and its status RPC."
  type = object({
    name       = string
    uri        = string
    status_rpc = string
  })
}

variable "image" {
  description = "Digest-pinned image the job runs, which ships sh and grpcurl: the service's own gRPC image."
  type        = string
}

variable "service_account" {
  description = "Email of the job's own identity, which may only invoke the service."
  type        = string
}

variable "network" {
  description = "VPC network, subnetwork and network tags the job reaches the service through."
  type = object({
    network    = string
    subnetwork = string
    tags       = list(string)
  })
}

variable "downtime_start" {
  description = "Start of a planned downtime that lists one of this service's components, from which the check is skipped. Empty without one."
  type        = string
  default     = ""
}

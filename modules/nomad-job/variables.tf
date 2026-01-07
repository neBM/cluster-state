variable "jobspec_path" {
  description = "Path to the Nomad jobspec file"
  type        = string
}

variable "use_hcl2" {
  description = "Whether to use HCL2 variable interpolation"
  type        = bool
  default     = false
}

variable "hcl2_vars" {
  description = "Variables to pass to HCL2 jobspec"
  type        = map(string)
  default     = {}
}

variable "purge_on_destroy" {
  description = "Whether to purge the job on destroy"
  type        = bool
  default     = true
}

variable "detach" {
  description = "Whether to detach from job monitoring"
  type        = bool
  default     = false
}

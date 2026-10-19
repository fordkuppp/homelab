variable "snapshot_tasks" {
  description = "Periodic snapshot tasks keyed by a stable name"
  type = map(object({
    dataset        = string
    recursive      = optional(bool, true)
    allow_empty    = optional(bool, true)
    enabled        = optional(bool, true)
    lifetime_value = number
    lifetime_unit  = string
    naming_schema  = string
    minute         = optional(string, "0")
    hour           = string
    dom            = optional(string, "*")
    month          = optional(string, "*")
    dow            = optional(string, "*")
  }))
}

variable "node_name" {
  type        = string
}

variable "content_type" {
  type        = string
  description = "vztmpl for LXC, iso for VM"
}

variable "url" {
  type        = string
}

variable "file_name" {
  type        = string
  default     = null
}

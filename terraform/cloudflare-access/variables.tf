variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the Zero Trust configuration."
  type        = string
}

variable "allowed_idp_ids" {
  description = "Cloudflare Access identity provider IDs allowed for protected apps. Put your Google IdP ID here."
  type        = list(string)

  validation {
    condition     = length(var.allowed_idp_ids) > 0
    error_message = "At least one identity provider ID is required. Add your Google IdP ID."
  }
}

variable "default_access_enabled" {
  description = "Protect apps by default unless app YAML sets access.enabled to false."
  type        = bool
  default     = true
}

variable "default_session_duration" {
  description = "Default Cloudflare Access session duration for generated apps."
  type        = string
  default     = "24h"
}

variable "auto_redirect_to_identity" {
  description = "Redirect directly to the configured IdP when possible."
  type        = bool
  default     = true
}

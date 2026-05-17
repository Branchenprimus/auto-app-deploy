variable "cloudflare_account_id" {
  description = "Cloudflare account ID that owns the Zero Trust configuration."
  type        = string
}

variable "allowed_idp_ids" {
  description = "Existing Cloudflare Access identity provider IDs allowed for protected apps. Leave empty when manage_google_identity_provider is true."
  type        = list(string)
  default     = []
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

variable "manage_google_identity_provider" {
  description = "Create and manage the Cloudflare Access Google identity provider with Terraform."
  type        = bool
  default     = false
}

variable "google_identity_provider_name" {
  description = "Display name for the managed Google identity provider."
  type        = string
  default     = "Google"
}

variable "google_identity_provider_type" {
  description = "Cloudflare Access Google provider type. Use google for consumer Google accounts or google-apps for Google Workspace."
  type        = string
  default     = "google"

  validation {
    condition     = contains(["google", "google-apps"], var.google_identity_provider_type)
    error_message = "google_identity_provider_type must be either google or google-apps."
  }
}

variable "google_oauth_client_id" {
  description = "Google OAuth Client ID used by the managed Cloudflare Access Google identity provider."
  type        = string
  default     = null
}

variable "google_oauth_client_secret" {
  description = "Google OAuth Client Secret used by the managed Cloudflare Access Google identity provider."
  type        = string
  default     = null
  sensitive   = true
}

variable "google_workspace_domain" {
  description = "Google Workspace domain for google-apps identity providers. Leave null for regular google providers."
  type        = string
  default     = null
}

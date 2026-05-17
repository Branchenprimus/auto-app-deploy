output "protected_access_applications" {
  description = "Cloudflare Access applications managed from apps/*.yaml."
  value = {
    for key, app in cloudflare_zero_trust_access_application.app :
    key => {
      id     = app.id
      name   = app.name
      domain = app.domain
      aud    = app.aud
    }
  }
}

output "managed_google_identity_provider_id" {
  description = "ID of the Terraform-managed Google identity provider, when enabled."
  value       = var.manage_google_identity_provider ? cloudflare_zero_trust_access_identity_provider.google[0].id : null
}

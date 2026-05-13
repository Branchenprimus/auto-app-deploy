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

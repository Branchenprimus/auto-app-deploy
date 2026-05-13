locals {
  app_files = fileset("${path.module}/apps", "*.yaml")

  apps = {
    for file_name in local.app_files :
    trimsuffix(file_name, ".yaml") => yamldecode(file("${path.module}/apps/${file_name}"))
  }

  protected_apps = {
    for key, app in local.apps :
    key => app
    if try(app.access.enabled, var.default_access_enabled)
  }

  app_domains = {
    for key, app in local.protected_apps :
    key => try(app.route.path, "/") == "/" ? app.route.host : "${app.route.host}${app.route.path}"
  }
}

resource "cloudflare_zero_trust_access_application" "app" {
  for_each = local.protected_apps

  account_id = var.cloudflare_account_id
  name       = try(each.value.access.name, each.value.name)
  domain     = local.app_domains[each.key]
  type       = "self_hosted"

  allowed_idps              = try(each.value.access.allowed_idp_ids, var.allowed_idp_ids)
  app_launcher_visible      = try(each.value.access.app_launcher_visible, false)
  auto_redirect_to_identity = try(each.value.access.auto_redirect_to_identity, var.auto_redirect_to_identity)
  session_duration          = try(each.value.access.session_duration, var.default_session_duration)

  policies = [{
    name       = try(each.value.access.policy_name, "${each.value.name} Google login")
    decision   = "allow"
    precedence = 1

    include = [{
      everyone = {}
    }]
  }]
}

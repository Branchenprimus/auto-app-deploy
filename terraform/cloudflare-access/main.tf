locals {
  app_dir          = "${path.module}/apps"
  platform_app_dir = "${path.module}/platform-apps"
  app_files        = fileset(local.app_dir, "*.yaml")
  platform_files   = fileset(local.platform_app_dir, "*.yaml")

  workload_apps = {
    for file_name in local.app_files :
    trimsuffix(file_name, ".yaml") => yamldecode(file("${local.app_dir}/${file_name}"))
  }

  platform_apps = {
    for file_name in local.platform_files :
    trimsuffix(file_name, ".yaml") => yamldecode(file("${local.platform_app_dir}/${file_name}"))
  }

  apps = merge(local.workload_apps, local.platform_apps)

  protected_apps = {
    for key, app in local.apps :
    key => app
    if try(app.access.enabled, var.default_access_enabled) && try(app.access.managed, true)
  }

  app_domains = {
    for key, app in local.protected_apps :
    key => try(app.route.path, "/") == "/" ? app.route.host : "${app.route.host}${app.route.path}"
  }

  effective_allowed_idp_ids = var.manage_google_identity_provider ? [
    cloudflare_zero_trust_access_identity_provider.google[0].id
  ] : var.allowed_idp_ids
}

resource "cloudflare_zero_trust_access_identity_provider" "google" {
  count = var.manage_google_identity_provider ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = var.google_identity_provider_name
  type       = var.google_identity_provider_type

  config = {
    client_id     = var.google_oauth_client_id
    client_secret = var.google_oauth_client_secret
    apps_domain   = var.google_workspace_domain
  }

  lifecycle {
    precondition {
      condition     = var.google_oauth_client_id != null && var.google_oauth_client_secret != null
      error_message = "Set google_oauth_client_id and google_oauth_client_secret when manage_google_identity_provider is true."
    }
  }
}

resource "cloudflare_zero_trust_access_application" "app" {
  for_each = local.protected_apps

  account_id = var.cloudflare_account_id
  name       = try(each.value.access.name, each.value.name)
  domain     = local.app_domains[each.key]
  type       = "self_hosted"

  allowed_idps              = try(each.value.access.allowed_idp_ids, local.effective_allowed_idp_ids)
  app_launcher_visible      = try(each.value.access.app_launcher_visible, false)
  auto_redirect_to_identity = try(each.value.access.auto_redirect_to_identity, var.auto_redirect_to_identity)
  session_duration          = try(each.value.access.session_duration, var.default_session_duration)

  policies = [{
    name       = try(each.value.access.policy_name, "${each.value.name} Google login")
    decision   = try(each.value.access.policy_decision, "allow")
    precedence = try(each.value.access.precedence, 1)

    include = [{
      everyone = {}
    }]
  }]

  lifecycle {
    precondition {
      condition     = length(try(each.value.access.allowed_idp_ids, local.effective_allowed_idp_ids)) > 0
      error_message = "No identity provider IDs configured. Set allowed_idp_ids or enable manage_google_identity_provider."
    }
  }
}

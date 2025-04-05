resource "null_resource" "always_run" {
  triggers = {
    timestamp = "${timestamp()}"
  }
}

locals {
  nix_options = jsonencode({
    options = { for k, v in var.nix_options : k => v }
  })
}

data "external" "nix-build" {
  lifecycle {
    replace_triggered_by = [
      null_resource.always_run
    ]
  }
  program = [ "${path.module}/nix-build.sh" ]
  query = {
    attribute = var.attribute
    file = var.file
    nix_options = local.nix_options
    special_args = jsonencode(var.special_args)
  }
}
output "result" {
  value = data.external.nix-build.result
}

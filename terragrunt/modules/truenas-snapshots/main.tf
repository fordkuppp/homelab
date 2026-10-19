resource "truenas_periodic_snapshot_task" "this" {
  for_each = var.snapshot_tasks

  dataset        = each.value.dataset
  recursive      = each.value.recursive
  allow_empty    = each.value.allow_empty
  enabled        = each.value.enabled
  lifetime_value = each.value.lifetime_value
  lifetime_unit  = each.value.lifetime_unit
  naming_schema  = each.value.naming_schema

  schedule = {
    minute = each.value.minute
    hour   = each.value.hour
    dom    = each.value.dom
    month  = each.value.month
    dow    = each.value.dow
  }
}

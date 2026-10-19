output "task_ids" {
  description = "Created snapshot task IDs keyed by name"
  value       = { for k, v in truenas_periodic_snapshot_task.this : k => v.id }
}

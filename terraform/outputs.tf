# What the lab platform surfaces, and what an instructor needs to verify a
# pre-warmed cluster before students arrive.

output "alloydb_cluster" {
  description = "Cluster ID."
  value       = google_alloydb_cluster.main.cluster_id
}

output "alloydb_instance" {
  description = "Primary instance ID. The notebook discovers this itself; here for troubleshooting."
  value       = google_alloydb_instance.primary.instance_id
}

output "alloydb_public_ip" {
  description = "Reached by the AlloyDB Python Connector with IAM auth — no password, no authorized networks."
  value       = google_alloydb_instance.primary.public_ip_address
}

output "student_db_user" {
  description = "IAM database user holding alloydbsuperuser. Needed for the BM25 index in Task 3."
  value       = google_alloydb_user.student.user_id
}

output "instructor_preflight" {
  description = "Run after Task 1's notebook. Expect 13439 players / 796 clubs / 832193 appearances."
  value       = "SELECT * FROM provisioning_status;"
}

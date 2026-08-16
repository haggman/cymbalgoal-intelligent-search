# Values the lab platform surfaces, plus what an instructor needs to verify a
# pre-warmed cluster before students arrive.

output "alloydb_cluster" {
  description = "Cluster ID."
  value       = google_alloydb_cluster.main.cluster_id
}

output "alloydb_private_ip" {
  description = "Primary instance private IP. Students use AlloyDB Studio; this is for the startup VM and for troubleshooting."
  value       = google_alloydb_instance.primary.ip_address
}

output "database_name" {
  description = "Database the startup VM creates and loads."
  value       = "cymbalgoal"
}

output "student_db_user" {
  description = "IAM database user granted alloydbsuperuser — needed for the BM25 index in Task 3."
  value       = google_alloydb_user.student.user_id
}

output "provisioning_check" {
  description = "Instructor pre-flight. Run this in AlloyDB Studio before students start; expect 13439 / 796 / 832193."
  value       = "SELECT * FROM provisioning_status;"
}

output "startup_vm_log" {
  description = "Where to look when provisioning did not finish."
  value       = "gcloud compute instances get-serial-port-output ${google_compute_instance.startup.name} --zone=${google_compute_instance.startup.zone}"
}

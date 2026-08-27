output "nfs_storage_class_name" {
  value = kubernetes_storage_class.nfs.metadata[0].name
}

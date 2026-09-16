# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

variable "project_id" {
  description = "Existing Google Cloud project with billing enabled."
  type        = string
}

variable "cluster_name" {
  description = "Name prefix for this isolated OSMO deployment."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.cluster_name))
    error_message = "Use 2-20 lowercase letters, digits or hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "region" {
  type    = string
  default = "asia-southeast1"
}

variable "zone" {
  description = "Single-zone development cluster; must belong to region."
  type        = string
  default     = "asia-southeast1-b"
  validation {
    condition     = startswith(var.zone, "${var.region}-")
    error_message = "zone must belong to region."
  }
}

variable "deletion_protection" {
  description = "Protect GKE and Cloud SQL from accidental Terraform deletion."
  type        = bool
  default     = true
}

variable "redis_transit_encryption_mode" {
  description = "Memorystore in-transit encryption. SERVER_AUTHENTICATION needs clients that trust the instance CA; DISABLED keeps Redis traffic unencrypted inside the private VPC."
  type        = string
  default     = "SERVER_AUTHENTICATION"
  validation {
    condition     = contains(["SERVER_AUTHENTICATION", "DISABLED"], var.redis_transit_encryption_mode)
    error_message = "redis_transit_encryption_mode must be SERVER_AUTHENTICATION or DISABLED."
  }
}

variable "bucket_force_destroy" {
  description = "Delete remaining objects when the bucket is destroyed. Only for disposable development environments."
  type        = bool
  default     = false
}

variable "gpu_node_pool_enabled" {
  description = "Create a GPU node pool that scales from zero."
  type        = bool
  default     = false
}

variable "gpu_machine_type" {
  description = "Machine type of the GPU node pool."
  type        = string
  default     = "g4-standard-48"
}

variable "gpu_accelerator_type" {
  description = "Accelerator attached to each GPU node."
  type        = string
  default     = "nvidia-rtx-pro-6000"
}

variable "gpu_accelerator_count" {
  description = "GPUs per node."
  type        = number
  default     = 1
}

variable "gpu_node_pool_max_size" {
  description = "Autoscaler ceiling for the GPU node pool. Shares regional GPU quota with other clusters in the project."
  type        = number
  default     = 2
}

variable "gpu_spot" {
  description = "Use Spot VMs for GPU nodes. Spot capacity is not guaranteed."
  type        = bool
  default     = true
}

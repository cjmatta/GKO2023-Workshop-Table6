terraform {
  required_providers {
    confluent = {
      source  = "confluentinc/confluent"
      version = "1.28.0"
    }
  }
}
provider "confluent" {
  cloud_api_key    = var.confluent_cloud_api_key
  cloud_api_secret = var.confluent_cloud_api_secret
}
resource "confluent_environment" "gko2023-table6-env" {
  display_name = "gko2023-table6"
}
# Stream Governance and Kafka clusters can be in different regions as well as different cloud providers,
# but you should to place both in the same cloud and region to restrict the fault isolation boundary.
data "confluent_schema_registry_region" "advanced" {
  cloud   = "AWS"
  region  = "eu-central-1"
  package = "ADVANCED"
}
resource "confluent_schema_registry_cluster" "advanced" {
  package = data.confluent_schema_registry_region.advanced.package
  environment {
    id = confluent_environment.staging.id
  }
  region {
    # See https://docs.confluent.io/cloud/current/stream-governance/packages.html#stream-governance-regions
    id = data.confluent_schema_registry_region.essentials.id
  }
}
# Update the config to use a cloud provider and region of your choice.
# https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_kafka_cluster
resource "confluent_kafka_cluster" "breaking-the-monolith" {
  display_name = "gko2023-table6"
  availability = "MULTI_ZONE"
  cloud        = "AWS"
  region       = "eu-central-1"
  standard {}
  environment {
    id = confluent_environment.staging.id
  }
}

# Topics
resource "confluent_kafka_topic" "orders" {
  kafka_cluster {
    id = confluent_kafka_cluster.breaking-the-monolith.id
  }
  topic_name         = "orders"
  rest_endpoint      = confluent_kafka_cluster.breaking-the-monolith.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_kafka_topic" "inventory" {
  kafka_cluster {
    id = confluent_kafka_cluster.breaking-the-monolith.id
  }
  topic_name         = "inventory"
  rest_endpoint      = confluent_kafka_cluster.breaking-the-monolith.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_kafka_topic" "fulfilled-orders" {
  kafka_cluster {
    id = confluent_kafka_cluster.breaking-the-monolith.id
  }
  topic_name         = "fulfilled-orders"
  rest_endpoint      = confluent_kafka_cluster.breaking-the-monolith.rest_endpoint
  credentials {
    key    = confluent_api_key.app-manager-kafka-api-key.id
    secret = confluent_api_key.app-manager-kafka-api-key.secret
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Service Accounts:
# - App Manager (CloudClusterAdmin)
# - MongoDB source (DeveloperWrite - topic)
# - MongodDB sink (DeveloperRead - topic)
# - StreamProcessing (DeveloperRead & DeveloperWrite)
# AppManager
resource "confluent_service_account" "app-manager" {
  display_name = "app-manager"
  description  = "Service account to manage 'gko2023-table6' Kafka cluster"
}

resource "confluent_role_binding" "app-manager-kafka-cluster-admin" {
  principal   = "User:${confluent_service_account.app-manager.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.breaking-the-monolith.rbac_crn
}

resource "confluent_api_key" "app-manager-kafka-api-key" {
  display_name = "app-manager-kafka-api-key"
  description  = "Kafka API Key that is owned by 'app-manager' service account"
  owner {
    id          = confluent_service_account.app-manager.id
    api_version = confluent_service_account.app-manager.api_version
    kind        = confluent_service_account.app-manager.kind
  }
  managed_resource {
    id          = confluent_kafka_cluster.breaking-the-monolith.id
    api_version = confluent_kafka_cluster.breaking-the-monolith.api_version
    kind        = confluent_kafka_cluster.breaking-the-monolith.kind
    environment {
      id = confluent_environment.staging.id
    }
  }
  # The goal is to ensure that confluent_role_binding.app-manager-kafka-cluster-admin is created before
  # confluent_api_key.app-manager-kafka-api-key is used to create instances of
  # confluent_kafka_topic, confluent_kafka_acl resources.
  # 'depends_on' meta-argument is specified in confluent_api_key.app-manager-kafka-api-key to avoid having
  # multiple copies of this definition in the configuration which would happen if we specify it in
  # confluent_kafka_topic, confluent_kafka_acl resources instead.
  depends_on = [
    confluent_role_binding.app-manager-kafka-cluster-admin
  ]
}

# MongoDB Sink
resource "confluent_service_account" "mongo-sink-service-account" {
  display_name = "mongo-sink-service-account"
  description  = "Service account for MongoDB Sink"
}

resource "confluent_role_binding" "mongo-sink-developer-read" {
  principal   = "User:${confluent_service_account.mongo-sink-service-account.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.breaking-the-monolith.rbac_crn}/kafka=${confluent_kafka_cluster.breaking-the-monolith.id}/topic=${confluent_kafka_topic.fulfilled-orders.fulfilled-orders}"
}

resource "confluent_role_binding" "mongo-sink-read-group" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.breaking-the-monolith.rbac_crn}/kafka=${confluent_kafka_cluster.standard.id}/group=connector_group*"
}


resource "confluent_api_key" "mongodb-sink-api-key" {
  display_name = "mongodb-sink-api-key"
  description  = "Kafka API Key that is owned by 'mongo-sink-service-account' service account"
  owner {
    id          = confluent_service_account.mongo-sink-service-account.id
    api_version = confluent_service_account.mongo-sink-service-account.api_version
    kind        = confluent_service_account.mongo-sink-service-account.kind
  }
  managed_resource {
    id          = confluent_kafka_cluster.breaking-the-monolith.id
    api_version = confluent_kafka_cluster.breaking-the-monolith.api_version
    kind        = confluent_kafka_cluster.breaking-the-monolith.kind
    environment {
      id = confluent_environment.staging.id
    }
  }

  # The goal is to ensure that confluent_role_binding.mongo-sink-developer-read is created before
  # confluent_api_key.app-manager-kafka-api-key is used to create instances of
  # confluent_kafka_topic, confluent_kafka_acl resources.
  # 'depends_on' meta-argument is specified in confluent_api_key.app-manager-kafka-api-key to avoid having
  # multiple copies of this definition in the configuration which would happen if we specify it in
  # confluent_kafka_topic, confluent_kafka_acl resources instead.
  depends_on = [
    confluent_role_binding.mongo-sink-developer-read
  ]
}

resource "confluent_service_account" "mongo-source-service-account" {
  display_name = "mongo-source-service-account"
  description  = "Service account for MongoDB Source"
}

resource "confluent_role_binding" "mongo-source-developer-read-orders" {
  principal   = "User:${confluent_service_account.mongo-source-service-account.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.breaking-the-monolith.rbac_crn}/kafka=${confluent_kafka_cluster.breaking-the-monolith.id}/topic=${confluent_kafka_topic.fulfilled-orders.orders}"
}

resource "confluent_role_binding" "mongo-source-developer-read-inventory" {
  principal   = "User:${confluent_service_account.mongo-source-service-account.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.breaking-the-monolith.rbac_crn}/kafka=${confluent_kafka_cluster.breaking-the-monolith.id}/topic=${confluent_kafka_topic.fulfilled-orders.inventory}"
}

resource "confluent_api_key" "mongodb-source-api-key" {
  display_name = "mongodb-sink-api-key"
  description  = "Kafka API Key that is owned by 'mongo-sink-service-account' service account"
  owner {
    id          = confluent_service_account.mongo-source-service-account.id
    api_version = confluent_service_account.mongo-source-service-account.api_version
    kind        = confluent_service_account.mongo-source-service-account.kind
  }
  managed_resource {
    id          = confluent_kafka_cluster.breaking-the-monolith.id
    api_version = confluent_kafka_cluster.breaking-the-monolith.api_version
    kind        = confluent_kafka_cluster.breaking-the-monolith.kind
    environment {
      id = confluent_environment.staging.id
    }
  }

  # The goal is to ensure that confluent_role_binding.mongo-sink-developer-read is created before
  # confluent_api_key.app-manager-kafka-api-key is used to create instances of
  # confluent_kafka_topic, confluent_kafka_acl resources.
  # 'depends_on' meta-argument is specified in confluent_api_key.app-manager-kafka-api-key to avoid having
  # multiple copies of this definition in the configuration which would happen if we specify it in
  # confluent_kafka_topic, confluent_kafka_acl resources instead.
  depends_on = [
    confluent_role_binding.mongo-source-developer-read-orders,
    confluent_role_binding.mongo-source-developer-read-inventory
  ]
}


resource "confluent_service_account" "app" {
  display_name = "app-consumer"
  description  = "Service account to consume from 'orders' & 'inventory' and write to 'fulfilled-orders'"
}

resource "confluent_role_binding" "app-developer-write-fulfilled-orders" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "DeveloperWrite"
  crn_pattern = "${confluent_kafka_cluster.breaking-the-monolith.rbac_crn}/kafka=${confluent_kafka_cluster.breaking-the-monolith.id}/topic=${confluent_kafka_topic.fulfilled-orders.fulfilled-orders}"
}

resource "confluent_role_binding" "app-developer-read-orders" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.breaking-the-monolith.rbac_crn}/kafka=${confluent_kafka_cluster.breaking-the-monolith.id}/topic=${confluent_kafka_topic.fulfilled-orders.fulfilled-orders}"
}

resource "confluent_role_binding" "app-developer-read-inventory" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.breaking-the-monolith.rbac_crn}/kafka=${confluent_kafka_cluster.breaking-the-monolith.id}/topic=${confluent_kafka_topic.fulfilled-orders.fulfilled-inventory}"
}

resource "confluent_role_binding" "app-developer-read-group" {
  principal   = "User:${confluent_service_account.app.id}"
  role_name   = "DeveloperRead"
  crn_pattern = "${confluent_kafka_cluster.breaking-the-monolith.rbac_crn}/kafka=${confluent_kafka_cluster.standard.id}/group=ksql_app_id*"
}


resource "confluent_api_key" "app-kafka-api-key" {
  display_name = "app-consumer-kafka-api-key"
  description  = "Kafka API Key that is owned by 'app-consumer' service account"
  owner {
    id          = confluent_service_account.app.id
    api_version = confluent_service_account.app.api_version
    kind        = confluent_service_account.app.kind
  }
  managed_resource {
    id          = confluent_kafka_cluster.breaking-the-monolith.id
    api_version = confluent_kafka_cluster.breaking-the-monolith.api_version
    kind        = confluent_kafka_cluster.breaking-the-monolith.kind
    environment {
      id = confluent_environment.staging.id
    }
  }
  depends_on = [
    confluent_api_key.app-developer-write-fulfilled-orders,
    confluent_role_binding.app-developer-read-orders,
    confluent_role_binding.app-developer-read-inventory,
    confluent_role_binding.app-developer-read-group
  ]

}
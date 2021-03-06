require "topological_inventory/orchestrator/openshift_object"

module TopologicalInventory
  module Orchestrator
    # Deployment config is maintained by config map
    # Paired by LABEL_UNIQUE label
    class DeploymentConfig < OpenshiftObject
      LABEL_COMMON = "tp-inventory/collector".freeze
      LABEL_DIGEST = "topological-inventory/collector_digest".freeze # single-source DCs
      LABEL_UNIQUE = "tp-inventory/config-uid".freeze

      attr_accessor :config_map

      def to_s
        uid
      end

      def create_in_openshift
        raise "Cannot create deployment config, no config map associated" if config_map.nil?

        # Gets image name (defined per source type => same for all sources in config_map)
        related_source = config_map.sources.detect { |source| source.from_sources_api }
        if related_source.nil?
          # This state can happen when someone deletes DC manually
          #   and all Sources in ConfigMap are marked for deletion
          logger.warn("Failed to create deployment config, no existing source associated")
          return
        end

        logger.info("Creating DeploymentConfig #{self}")
        object_manager.create_deployment_config(name, config_map.source_type["collector_image"]) do |dc|
          dc[:metadata][:labels][LABEL_UNIQUE] = uid
          dc[:metadata][:labels][LABEL_COMMON] = ::Settings.labels.version.to_s
          dc[:metadata][:labels][ConfigMap::LABEL_SOURCE_TYPE] = config_map.source_type['name'] if config_map.source_type.present?
          dc[:spec][:replicas] = 1

          volumes = dc[:spec][:template][:spec][:volumes]
          volumes << {
            :name      => 'sources-config',
            :configMap => {:name => config_map.name}
          }

          volumes << {
            :name   => 'sources-secrets',
            :secret => {
              :secretName => config_map.secret&.name
            }
          }

          container = dc[:spec][:template][:spec][:containers].first
          container[:volumeMounts] = []
          container[:volumeMounts] << {
            :name => 'sources-config',
            :mountPath => "/opt/#{config_map.source_type['name']}-collector/config"
          }

          container[:volumeMounts] << {
            :name => 'sources-secrets',
            :mountPath => "/opt/#{config_map.source_type['name']}-collector/secret"
          }
          # Environment variables
          container[:env] = container_env_values
        end
        logger.info("[OK] Created DeploymentConfig #{self}")
      end

      def delete_in_openshift
        logger.info("Deleting DeploymentConfig #{self}")

        object_manager.delete_deployment_config(name)

        logger.info("[OK] Deleted DeploymentConfig #{self}")
      end

      def update_image(new_image)
        logger.info("Updating DeploymentConfig Image #{self}")

        # This is ugly, but its a JSON patch we're sending.
        patch = {
          :spec => {
            :template => {
              :spec => {
                :containers => [
                  :name  => name,
                  :image => new_image
                ]
              }
            }
          }
        }

        object_manager.update_deployment_config(name, patch)
        openshift_object(:reload => true)

        logger.info("[OK] Updated DeploymentConfig Image #{self}")
      end

      # DC config-UID is relation to config-map's template
      def uid
        return @uid if @uid.present?

        @uid = if @openshift_object.present? # no openshift_object reloading here (cycle)
                 @openshift_object.metadata.labels[LABEL_UNIQUE]
               else
                 config_map&.uid
               end
      end

      def name
        source_type = config_map&.source_type
        type_name   = source_type.present? ? source_type['name'] : 'unknown'
        "collector-#{type_name}-#{uid}"
      end

      def image
        openshift_object.spec.template.spec.containers.first.image
      end

      private

      def container_env_values
        [
          {:name => "INGRESS_API", :value => "http://#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_HOST"]}:#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_PORT"]}"},
          {:name => "CONFIG", :value => 'custom'},
          {:name => "CLOUD_WATCH_LOG_GROUP", :value => ENV["CLOUD_WATCH_LOG_GROUP"]},
          {:name => "CW_AWS_ACCESS_KEY_ID", :valueFrom => {:secretKeyRef => {:name => 'cloudwatch', :key => 'aws_access_key_id'}}},
          {:name => "CW_AWS_SECRET_ACCESS_KEY", :valueFrom => {:secretKeyRef => {:name => 'cloudwatch', :key => 'aws_secret_access_key'}}},
          {:name => "QUEUE_HOST", :value => ENV["QUEUE_HOST"]},
          {:name => "QUEUE_PORT", :value => ENV["QUEUE_PORT"]},
          {:name => "RECEPTOR_CONTROLLER_HOST", :value => ENV["RECEPTOR_CONTROLLER_HOST"]},
          {:name => "RECEPTOR_CONTROLLER_SCHEME", :value => ENV["RECEPTOR_CONTROLLER_SCHEME"]},
          {:name => "RECEPTOR_CONTROLLER_PORT", :value => ENV["RECEPTOR_CONTROLLER_PORT"]},
          {:name => "RECEPTOR_CONTROLLER_PSK", :valueFrom => {:secretKeyRef => {:name => 'receptor', :key => 'RECEPTOR_CONTROLLER_PSK'}}},
        ]
      end

      def load_openshift_object
        object_manager.get_deployment_configs(LABEL_COMMON).detect { |s| s.metadata.labels[LABEL_UNIQUE] == uid }
      end
    end
  end
end

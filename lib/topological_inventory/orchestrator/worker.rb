require "base64"
require "json"
require "manageiq-loggers"
require "manageiq-password"
require "more_core_extensions/core_ext/hash"
require "rest-client"
require "yaml"

require "topological_inventory/orchestrator/object_manager"

module TopologicalInventory
  module Orchestrator
    class Worker
      TOPOLOGY_API_VERSION = "v0.1".freeze
      SOURCES_API_VERSION = "v1.0".freeze
      ORCHESTRATOR_TENANT = "system_orchestrator".freeze

      attr_reader :logger, :sources_url, :topology_url

      def initialize(sources_url:, topology_url:, collector_definitions_file: ENV["COLLECTOR_DEFINITIONS_FILE"])
        @collector_definitions_file = collector_definitions_file || TopologicalInventory::Orchestrator.root.join("config/collector_definitions.yaml")

        @logger       = ManageIQ::Loggers::Container.new
        @sources_url  = sources_url
        @topology_url = topology_url
      end

      def run
        loop do
          make_openshift_match_database

          sleep 10
        end
      end

      private

      def digest(object)
        require 'digest'
        Digest::SHA1.hexdigest(Marshal.dump(object))
      end

      def make_openshift_match_database
        collector_hash = collectors_from_sources_api

        expected_digests = collector_hash.keys
        current_digests  = collector_digests_from_openshift

        logger.info("Checking...")

        (current_digests - expected_digests).each { |i| remove_openshift_objects_for_source(i) }
        (expected_digests - current_digests).each { |i| create_openshift_objects_for_source(i, collector_hash[i]) }

        logger.info("Checking... complete.")
      end


      ### API STUFF
      def each_source
        source_types_by_id = {}
        each_resource(sources_api_url_for("source_types")) { |source_type| source_types_by_id[source_type["id"]] = source_type }

        each_tenant do |tenant|
          each_resource(topology_api_url_for("sources"), tenant) do |source_stub|
            source      = get_and_parse(sources_api_url_for("sources/#{source_stub["id"]}"), tenant)
            source_type = source_types_by_id[source["source_type_id"]]

            next unless collector_definition = collector_definitions[source_type["name"]]

            next unless endpoint       = get_and_parse(sources_api_url_for("sources/#{source["id"]}/endpoints"), tenant)["data"].first
            next unless authentication = get_and_parse(sources_api_url_for("endpoints/#{endpoint["id"]}/authentications"), tenant)["data"].first

            auth = authentication_with_password(authentication["id"], tenant)
            yield source, endpoint, auth, collector_definition
          end
        end
      end

      def collectors_from_sources_api
        hash = {}
        each_source do |source, endpoint, authentication, collector_definition|
          value = {
            "endpoint_host"   => endpoint["host"],
            "endpoint_path"   => endpoint["path"],
            "endpoint_port"   => endpoint["port"].to_s,
            "endpoint_scheme" => endpoint["scheme"],
            "image"           => collector_definition["image"],
            "image_namespace" => collector_definition["image_namespace"] || ENV["IMAGE_NAMESPACE"],
            "source_id"       => source["id"],
            "source_uid"      => source["uid"],
            "secret"          => {
              "password" => authentication["password"],
              "username" => authentication["username"],
            },
          }
          key = digest(value)
          hash[key] = value
        end
        hash
      end

      def sources_api_url_for(path)
        File.join(sources_url, ENV["PATH_PREFIX"].to_s, ENV["APP_NAME"].to_s, SOURCES_API_VERSION, path)
      end

      def sources_internal_url_for(path)
        File.join(sources_url, "internal", "v1.0", path)
      end

      def topology_api_url_for(path)
        File.join(topology_url, ENV["PATH_PREFIX"].to_s, ENV["APP_NAME"].to_s, TOPOLOGY_API_VERSION, path)
      end

      def topology_internal_url_for(path)
        File.join(topology_url, "internal", "v0.0", path)
      end

      def each_resource(url, tenant_account = ORCHESTRATOR_TENANT, &block)
        return if url.nil?
        response = get_and_parse(url, tenant_account)
        paging = response.is_a?(Hash)

        resources = paging ? response["data"] : response
        resources.each { |i| yield i }

        each_resource(response.fetch_path("links", "next"), tenant_account, &block) if paging
      end

      def get_and_parse(url, tenant_account = ORCHESTRATOR_TENANT)
        JSON.parse(
          RestClient.get(
            url,
            "x-rh-identity" => Base64.strict_encode64(
              {"identity" => {"account_number" => tenant_account}}.to_json
            )
          )
        )
      end

      def each_tenant
        each_resource(topology_internal_url_for("tenants")) { |tenant| yield tenant["external_tenant"] }
      end

      # HACK for Authentications
      def authentication_with_password(id, tenant_account)
        get_and_parse(sources_internal_url_for("/authentications/#{id}?expose_encrypted_attribute[]=password"), tenant_account)
      end


      ### Orchestrator Stuff
      def collector_definitions
        @collector_definitions ||= begin
          require 'yaml'
          YAML.load_file(@collector_definitions_file)
        end
      end

      def object_manager
        @object_manager ||= ObjectManager.new
      end


      ### Openshift stuff
      def collector_digests_from_openshift
        object_manager.get_deployment_configs("topological-inventory/collector=true").collect { |i| i.metadata.labels["topological-inventory/collector_digest"] }
      end

      def create_openshift_objects_for_source(digest, source)
        logger.info("Creating objects for source #{source["source_id"]} with digest #{digest}")
        object_manager.create_secret(collector_deployment_secret_name_for_source(source), source["secret"])
        object_manager.create_deployment_config(collector_deployment_name_for_source(source), source["image_namespace"], source["image"]) do |d|
          d[:metadata][:labels]["topological-inventory/collector_digest"] = digest
          d[:metadata][:labels]["topological-inventory/collector"] = "true"
          d[:spec][:replicas] = 1
          container = d[:spec][:template][:spec][:containers].first
          container[:env] = collector_container_environment(source)
        end
      end

      def remove_openshift_objects_for_source(digest)
        return unless digest
        deployment = object_manager.get_deployment_configs("topological-inventory/collector_digest=#{digest}").detect { |i| i.metadata.labels["topological-inventory/collector"] == "true" }
        return unless deployment
        logger.info("Removing objects for deployment #{deployment.metadata.name}")
        object_manager.delete_deployment_config(deployment.metadata.name)
        object_manager.delete_secret("#{deployment.metadata.name}-secrets")
      end

      def collector_deployment_name_for_source(source)
        "topological-inventory-collector-source-#{source["source_id"]}"
      end

      def collector_deployment_secret_name_for_source(source)
        "#{collector_deployment_name_for_source(source)}-secrets"
      end

      def collector_container_environment(source)
        secret_name = "#{collector_deployment_name_for_source(source)}-secrets"
        [
          {:name => "AUTH_PASSWORD", :valueFrom => {:secretKeyRef => {:name => secret_name, :key => "password"}}},
          {:name => "AUTH_USERNAME", :valueFrom => {:secretKeyRef => {:name => secret_name, :key => "username"}}},
          {:name => "ENDPOINT_HOST", :value => source["endpoint_host"]},
          {:name => "ENDPOINT_PATH", :value => source["endpoint_path"]},
          {:name => "ENDPOINT_PORT", :value => source["endpoint_port"]},
          {:name => "ENDPOINT_SCHEME", :value => source["endpoint_scheme"]},
          {:name => "INGRESS_API", :value => "http://#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_HOST"]}:#{ENV["TOPOLOGICAL_INVENTORY_INGRESS_API_SERVICE_PORT"]}"},
          {:name => "SOURCE_UID",  :value => source["source_uid"]},
        ]
      end
    end
  end
end

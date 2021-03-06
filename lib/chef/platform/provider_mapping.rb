#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/log'
require 'chef/exceptions'
require 'chef/mixin/params_validate'
require 'chef/version_constraint/platform'
require 'chef/provider'

class Chef
  class Platform

    class << self
      attr_writer :platforms

      def platforms
        @platforms ||= { default: {} }
      end

      include Chef::Mixin::ParamsValidate

      def find(name, version)
        provider_map = platforms[:default].clone

        name_sym = name
        if name.kind_of?(String)
          name = name.downcase
          name.gsub!(/\s/, "_")
          name_sym = name.to_sym
        end

        if platforms.has_key?(name_sym)
          platform_versions = platforms[name_sym].select {|k, v| k != :default }
          if platforms[name_sym].has_key?(:default)
            provider_map.merge!(platforms[name_sym][:default])
          end
          platform_versions.each do |platform_version, provider|
            begin
              version_constraint = Chef::VersionConstraint::Platform.new(platform_version)
              if version_constraint.include?(version)
                Chef::Log.debug("Platform #{name.to_s} version #{version} found")
                provider_map.merge!(provider)
              end
            rescue Chef::Exceptions::InvalidPlatformVersion
              Chef::Log.debug("Chef::Version::Comparable does not know how to parse the platform version: #{version}")
            end
          end
        end
        provider_map
      end

      def find_platform_and_version(node)
        platform = nil
        version = nil

        if node[:platform]
          platform = node[:platform]
        elsif node.attribute?("os")
          platform = node[:os]
        end

        raise ArgumentError, "Cannot find a platform for #{node}" unless platform

        if node[:platform_version]
          version = node[:platform_version]
        elsif node[:os_version]
          version = node[:os_version]
        elsif node[:os_release]
          version = node[:os_release]
        end

        raise ArgumentError, "Cannot find a version for #{node}" unless version

        return platform, version
      end

      def provider_for_resource(resource, action=:nothing)
        node = resource.run_context && resource.run_context.node
        raise ArgumentError, "Cannot find the provider for a resource with no run context set" unless node
        provider = find_provider_for_node(node, resource).new(resource, resource.run_context)
        provider.action = action
        provider
      end

      def provider_for_node(node, resource_type)
        raise NotImplementedError, "#{self.class.name} no longer supports #provider_for_node"
      end

      def find_provider_for_node(node, resource_type)
        platform, version = find_platform_and_version(node)
        find_provider(platform, version, resource_type)
      end

      def set(args)
        validate(
          args,
          {
            :platform => {
              :kind_of => Symbol,
              :required => false,
            },
            :version => {
              :kind_of => String,
              :required => false,
            },
            :resource => {
              :kind_of => Symbol,
            },
            :provider => {
              :kind_of => [ String, Symbol, Class ],
            }
          }
        )
        if args.has_key?(:platform)
          if args.has_key?(:version)
            if platforms.has_key?(args[:platform])
              if platforms[args[:platform]].has_key?(args[:version])
                platforms[args[:platform]][args[:version]][args[:resource].to_sym] = args[:provider]
              else
                platforms[args[:platform]][args[:version]] = {
                  args[:resource].to_sym => args[:provider]
                }
              end
            else
              platforms[args[:platform]] = {
                args[:version] => {
                  args[:resource].to_sym => args[:provider]
                }
              }
            end
          else
            if platforms.has_key?(args[:platform])
              if platforms[args[:platform]].has_key?(:default)
                platforms[args[:platform]][:default][args[:resource].to_sym] = args[:provider]
              elsif args[:platform] == :default
                platforms[:default][args[:resource].to_sym] = args[:provider]
              else
                platforms[args[:platform]] = { :default => { args[:resource].to_sym => args[:provider] } }
              end
            else
              platforms[args[:platform]] = {
                :default => {
                  args[:resource].to_sym => args[:provider]
                }
              }
            end
          end
        else
          if platforms.has_key?(:default)
            platforms[:default][args[:resource].to_sym] = args[:provider]
          else
            platforms[:default] = {
              args[:resource].to_sym => args[:provider]
            }
          end
        end
      end

      def find_provider(platform, version, resource_type)
        provider_klass = explicit_provider(platform, version, resource_type) ||
                         platform_provider(platform, version, resource_type) ||
                         resource_matching_provider(platform, version, resource_type)

        raise ArgumentError, "Cannot find a provider for #{resource_type} on #{platform} version #{version}" if provider_klass.nil?

        provider_klass
      end

      private

        def explicit_provider(platform, version, resource_type)
          resource_type.kind_of?(Chef::Resource) ? resource_type.provider : nil
        end

        def platform_provider(platform, version, resource_type)
          pmap = Chef::Platform.find(platform, version)
          rtkey = resource_type.kind_of?(Chef::Resource) ? resource_type.resource_name.to_sym : resource_type
          pmap.has_key?(rtkey) ? pmap[rtkey] : nil
        end

        include Chef::Mixin::ConvertToClassName

        def resource_matching_provider(platform, version, resource_type)
          if resource_type.kind_of?(Chef::Resource)
            class_name = resource_type.class.to_s.split('::').last

            begin
              result = Chef::Provider.const_get(class_name)
              Chef::Log.warn("Class Chef::Provider::#{class_name} does not declare 'resource_name #{convert_to_snake_case(class_name).to_sym.inspect}'.")
              Chef::Log.warn("This will no longer work in Chef 13: you must use 'resource_name' to provide DSL.")
            rescue NameError
            end
          end
          result
        end

    end
  end
end

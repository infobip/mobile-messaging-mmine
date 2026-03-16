#
#  notification_extension_integrator.rb
#  mobile-messaging-mmine
#
#  Copyright (c) 2016-2025 Infobip Limited
#  Licensed under the Apache License, Version 2.0
#

require 'xcodeproj'
require 'fileutils'
require 'pathname'
require 'nokogiri'
require 'logger'
require 'json'
require 'set'
require_relative 'version'

module Mmine
  def self.root
    File.expand_path '../..', File.dirname(__FILE__)
  end
end

class NotificationExtensionIntegrator
  def initialize(project_file_path, app_group, main_target_name, cordova = false, swift_ver, override_signing, spm)
    @project_file_path = project_file_path
    @app_group = app_group
    @main_target_name = main_target_name
    @logger = nil
    @cordova = cordova
    @swift_version = swift_ver
    @override_signing = override_signing
    @spm = spm

    @project_dir = Pathname.new(@project_file_path).parent.to_s
    @project = Xcodeproj::Project.open(@project_file_path)
    @project_name = @project.root_object.name
    @main_target = @project.native_targets.select { |target| target.name == @main_target_name }.first
    @main_build_configurations_debug = @main_target.build_configurations.select { |config| config.type == :debug }
    @main_build_configurations_release = @main_target.build_configurations.select { |config| config.type == :release }
    @main_build_settings_debug = @main_build_configurations_debug.map(&:build_settings)
    @main_build_settings_release = @main_build_configurations_release.map(&:build_settings)

  end

  def logger=(_logger)
    @logger = _logger
  end

  def logger
    @logger
  end

  def setup_notification_extension
    puts "🏎  Integration starting... ver. #{Mmine::VERSION}"
    @logger.debug("Integration with parameters: \n project_file_path: #{@project_file_path} \n app_group: #{@app_group} \n main_target_name: #{@main_target_name} \n cordova: #{@cordova} \n swift_ver: #{@swift_ver} \n override_signing: #{@override_signing} \n spm: #{@spm}")
    @logger.debug("\n@main_target_build_configurations_debug #{@main_build_configurations_debug}\n@main_target_build_configurations_release #{@main_build_configurations_release}")
    @logger.debug("\n@main_target_build_configurations_debug #{JSON.pretty_generate(@main_build_settings_debug)}\n@main_target_build_configurations_release #{JSON.pretty_generate(@main_build_settings_release)}")
    create_notification_extension_target
    create_notification_extension_dir
    add_notification_extension_source_code
    setup_extension_target_signing(@override_signing)
    if @override_signing == false
      setup_development_team
    end
    setup_deployment_target
    setup_notification_extension_info_plist
    setup_notification_extension_bundle_id

    setup_user_app_group_value
    setup_background_modes_plist_value

    setup_target_capabilities_for_extension_target
    setup_target_capabilities_for_main_target

    setup_embed_extension_action
    setup_main_target_dependency
    setup_swift_version
    setup_product_name
    setup_extension_build_number
    erease_bridging_header

    if @cordova
      setup_entitlements(nil,
                         nil,
                         @extension_target_name,
                         @extension_build_settings_debug,
                         @extension_build_settings_release)
    else
      setup_entitlements(@main_build_configurations_debug.map { |config| config.build_settings['CODE_SIGN_ENTITLEMENTS'] },
                         @main_build_configurations_release.map { |config| config.build_settings['CODE_SIGN_ENTITLEMENTS'] },
                         @main_target_name,
                         @main_build_settings_debug,
                         @main_build_settings_release)

      setup_entitlements(@extension_build_configurations_debug.map { |config| config.build_settings['CODE_SIGN_ENTITLEMENTS'] },
                         @extension_build_configurations_release.map { |config| config.build_settings['CODE_SIGN_ENTITLEMENTS'] },
                         @extension_target_name,
                         @extension_build_settings_debug,
                         @extension_build_settings_release)
    end

    if @spm
        setup_extension_spm_dependency('MobileMessagingNotificationExtension')
    elsif !@cordova
        setup_podfile_extension_target
    end

    @project.save
    puts "🏁 Integration has been finished successfully!"
  end

  def setup_extension_spm_dependency(name)
    @logger.info("Setting up SPM dependency '#{name}' for extension target")

    # Check if extension already has the dependency (in packageProductDependencies or frameworks build phase)
    if @extension_target.package_product_dependencies.any? { |ref| ref.product_name == name }
      @logger.info("Extension target already has SPM dependency '#{name}' in packageProductDependencies, skipping")
      return
    end
    if @extension_target.frameworks_build_phase.files.any? { |f| f.product_ref && f.product_ref.product_name == name }
      @logger.info("Extension target already has SPM dependency '#{name}' in frameworks build phase, skipping")
      return
    end

    # Find MobileMessaging dependency to get the package reference.
    # Strategy 1: check packageProductDependencies on main target (older Xcode format)
    mm_dep = @main_target.package_product_dependencies.find { |ref| ref.product_name == 'MobileMessaging' }
    if mm_dep
      @logger.info("Found MobileMessaging in main target packageProductDependencies")
    else
      # Strategy 2: scan frameworks build phase for PBXBuildFile with productRef (newer Xcode format)
      @logger.info("MobileMessaging not found in packageProductDependencies, scanning frameworks build phase")
      mm_build_file = @main_target.frameworks_build_phase.files.find { |f| f.product_ref && f.product_ref.product_name == 'MobileMessaging' }
      mm_dep = mm_build_file.product_ref if mm_build_file
      if mm_dep
        @logger.info("Found MobileMessaging in main target frameworks build phase")
      end
    end

    unless mm_dep
      raise "Could not find MobileMessaging SPM product dependency on main target. Make sure the SDK is added as an SPM dependency."
    end

    package_ref = mm_dep.package
    unless package_ref
      raise "MobileMessaging dependency has no package reference. Cannot add extension dependency."
    end

    # Create the new XCSwiftPackageProductDependency
    new_dep = @project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
    new_dep.product_name = name
    new_dep.package = package_ref

    # Add to packageProductDependencies on the extension target
    @extension_target.package_product_dependencies << new_dep
    @logger.info("Added SPM dependency '#{name}' to extension target packageProductDependencies")

    # Also add a PBXBuildFile with productRef to the extension's frameworks build phase
    build_file = @project.new(Xcodeproj::Project::Object::PBXBuildFile)
    build_file.product_ref = new_dep
    @extension_target.frameworks_build_phase.files << build_file
    @logger.info("Added SPM dependency '#{name}' to extension target frameworks build phase")
  end

  def setup_podfile_extension_target
    podfile_path = File.join(@project_dir, 'Podfile')
    unless File.exist?(podfile_path)
      @logger.info("No Podfile found at #{podfile_path}, skipping Podfile modification")
      return
    end

    podfile_content = File.read(podfile_path)
    extension_pod_name = 'MobileMessagingNotificationExtension'

    if podfile_content.include?("target '#{@extension_target_name}'")
      @logger.info("Podfile already contains target '#{@extension_target_name}', skipping")
      return
    end

    @logger.info("Adding extension target '#{@extension_target_name}' with pod '#{extension_pod_name}' to Podfile")
    podfile_entry = "\ntarget '#{@extension_target_name}' do\n  pod '#{extension_pod_name}'\nend\n"
    File.open(podfile_path, 'a') do |file|
      file.write(podfile_entry)
    end
  end

  def setup_extension_target_signing(override_signing)
    @logger.info("Overriding extension target signing: #{override_signing}")

    signing_settings = {
        'DEVELOPMENT_TEAM' => '$MM_EXTENSION_DEVELOPMENT_TEAM',
        'CODE_SIGN_IDENTITY' => '$MM_EXTENSION_CODE_SIGN_IDENTITY',
    }

    signing_settings.keys.each do |key|
      value = signing_settings[key]
      @logger.info("Checking extension signing for key: #{key} value: #{value}")
      if override_signing
        set_notification_extension_build_settings(key, value)
      else
        # Delete setting if it was previously overridden
        @extension_target.build_configurations.each do |config|
          if config.resolve_build_setting(key) == value
            @logger.info("Deletes extension setting for key: #{key} value: #{value}")
            config.build_settings[key] = ''
          end
        end
      end
    end
  end

  def create_notification_extension_target
    @extension_target_name = 'MobileMessagingNotificationServiceExtension'
    @extension_source_name_filepath = File.join(Mmine.root, 'resources', 'NotificationService.swift')
    @extension_dir_name = 'NotificationServiceExtension'
    @extension_destination_dir = File.join(@project_dir, @extension_dir_name)
    @extension_code_destination_filepath = File.join(@extension_destination_dir, 'NotificationService.swift')
    @extension_group_name = 'NotificationServiceExtensionGroup'
    @extension_plist_name = 'MobileMessagingNotificationServiceExtension.plist'
    @extension_plist_source_filepath = File.join(Mmine.root, 'resources', @extension_plist_name)
    @extension_info_plist_path = File.join(@project_dir, @extension_dir_name, @extension_plist_name)
    @extension_target = @project.native_targets.select { |target| target.name == @extension_target_name }.first
    if @extension_target == nil
      @logger.info("Creating notification extension target with name #{@extension_target_name}")
      @extension_target = @project.new_target(:app_extension, @extension_target_name, :ios)
    else
      @logger.info("Notification extension target already exists, reusing...")
    end

    @extension_build_configurations_debug = @extension_target.build_configurations.select { |config| config.type == :debug }
    @extension_build_configurations_release = @extension_target.build_configurations.select { |config| config.type == :release }
    @extension_build_settings_debug = @extension_build_configurations_debug.map(&:build_settings)
    @extension_build_settings_release = @extension_build_configurations_release.map(&:build_settings)

    unless @main_target.build_configurations.any? { |config| config.name == "Release"}
      @extension_target.build_configuration_list.build_configurations.delete_if { |config| config.name == "Release"}
    end
    unless @main_target.build_configurations.any? { |config| config.name == "Debug"}
      @extension_target.build_configuration_list.build_configurations.delete_if { |config| config.name == "Debug"}
    end

    @logger.info("Notification extension target debug build settings:\n#{JSON.pretty_generate(@extension_build_settings_debug)}")
    @logger.info("Notification extension target release build settings:\n#{JSON.pretty_generate(@extension_build_settings_release)}")
  end

  def create_notification_extension_dir
    if File.directory?(@extension_destination_dir)
      @logger.info("Notification extension directory already exists: #{@extension_destination_dir}")
    else
      @logger.info("Creating directory: #{@extension_destination_dir}")
      FileUtils.mkdir_p(@extension_destination_dir)
    end
  end

  def add_notification_extension_source_code
    if File.exist?(@extension_code_destination_filepath)
      @logger.info("Notification extension source code already exists on path: #{@extension_code_destination_filepath}")
    else
      @logger.info("Copying notification extension source code to path: #{@extension_code_destination_filepath}")
      FileUtils.cp(@extension_source_name_filepath, @extension_code_destination_filepath)
      filereference = get_notification_extension_group_reference.new_reference(@extension_code_destination_filepath)
      @extension_target.add_file_references([filereference])
    end
  end

  def setup_development_team
    align_notification_extension_build_settings('DEVELOPMENT_TEAM',
                                                @main_target.build_configurations)
    align_notification_extension_build_settings('CODE_SIGN_STYLE',
                                                @main_target.build_configurations)
    align_notification_extension_build_settings('CODE_SIGN_IDENTITY',
                                                @main_target.build_configurations)
  end

  def setup_deployment_target
    min_version = "15.0"
    @main_target.build_configurations.each do |config|
      main_target_version = config.resolve_build_setting('IPHONEOS_DEPLOYMENT_TARGET')
      if main_target_version && Gem::Version.new(main_target_version) > Gem::Version.new(min_version)
        min_version = main_target_version
      end
    end
    @logger.info("Setting extension deployment target to #{min_version} (floor: 15.0, main target aligned)")
    set_notification_extension_build_settings('IPHONEOS_DEPLOYMENT_TARGET', min_version)
  end

  def setup_notification_extension_info_plist
    if File.exist?(@extension_info_plist_path)
      @logger.info("Notification extension info plist already exists on path: #{@extension_info_plist_path}")
    else
      @logger.info("Copying extension plist file to path: #{@extension_info_plist_path}")

      FileUtils.cp(@extension_plist_source_filepath, @extension_info_plist_path)
      get_notification_extension_group_reference.new_reference(@extension_info_plist_path) #check if additional plist manipulations needed (target membership?)
    end
    set_notification_extension_build_settings('INFOPLIST_FILE', resolve_xcode_path(@extension_info_plist_path))
  end

  def setup_notification_extension_bundle_id #todo test it
    suffix = 'notification-extension'
    key = 'PRODUCT_BUNDLE_IDENTIFIER'
    (@main_build_configurations_release + @main_build_configurations_debug).each do |config|
      bundleId = resolve_recursive_build_setting(config, key)
      if bundleId == nil
        plist_path = resolve_absolute_paths([config.resolve_build_setting("INFOPLIST_FILE")]).first
        bundleId = get_xml_string_value(key, plist_path)
        @logger.info("Composing #{key} from main target info plist: #{bundleId}.")
      else
        @logger.info("Composing #{key} from main target config build setting: #{bundleId}.")
      end
      value = "#{bundleId}.#{suffix}"
      @logger.info("\tSetting extension build settings:\n\t\t#{config.name}:  \t#{key}\t#{value}")
      @extension_target.build_configuration_list[config.name].build_settings[key] = value
    end
  end

  # https://github.com/CocoaPods/Xcodeproj/issues/505#issuecomment-584699008
  # Augments config.resolve_build_setting from xcproject
  # to continue expanding build settings and evaluate modifiers
  def resolve_recursive_build_setting(config, setting)
    resolution = config.resolve_build_setting(setting)

    # finds values with one of
    # $VALUE
    # $(VALLUE)
    # $(VALUE:modifier)
    # ${VALUE}
    # ${VALUE:modifier}
    resolution.gsub(/\$[\(\{]?.+[\)\}]?/) do |raw_value|
      # strip $() characters
      unresolved = raw_value.gsub(/[\$\(\)\{\}]/, '')

      # Get the modifiers after the ':' characters
      name, *modifiers = unresolved.split(':')

      # Expand variable name
      subresolution = resolve_recursive_build_setting(config, name)

      # Apply modifiers
      # NOTE: not all cases accounted for
      #
      # See http://codeworkshop.net/posts/xcode-build-setting-transformations
      # for various modifier options
      modifiers.each do |modifier|
        case modifier
        when 'lower'
          subresolution.downcase!
        when 'upper'
          subresolution.upcase!
        else
          # Fastlane message
          @logger.info("Unknown modifier: `#{modifier}` in `#{raw_value}")
        end
      end

      subresolution
    end
  end

  def create_entitlements_file(_entitlements_name)
    entitlements_destination_filepath = File.join(@project_dir, _entitlements_name)
    entitlements_source_filepath = File.join(Mmine.root, 'resources', "MobileMessagingNotificationExtension.entitlements")
    if File.exist?(entitlements_destination_filepath)
      @logger.info("\tEntitlements file already exists on path: #{entitlements_destination_filepath}")
    else
      @logger.info("\tCopying entitlements file to path: #{entitlements_destination_filepath}")
      FileUtils.cp(entitlements_source_filepath, entitlements_destination_filepath)
      ref = @project.main_group.new_reference(entitlements_destination_filepath)
      ref.last_known_file_type = "text.xml"
    end
    return resolve_xcode_path(entitlements_destination_filepath)
  end

  def setup_entitlements(entitlements_debug_file_paths, entitlements_release_file_paths, target_name, _build_settings_debug, _build_settings_release)
    entitlements_debug_file_paths = entitlements_debug_file_paths ? entitlements_debug_file_paths.compact : nil
    entitlements_release_file_paths = entitlements_release_file_paths ? entitlements_release_file_paths.compact :  nil
    @logger.debug("setup_entitlements #{entitlements_debug_file_paths} #{entitlements_release_file_paths} #{target_name} #{_build_settings_debug} #{_build_settings_release}")
    code_sign_entitlements_key = 'CODE_SIGN_ENTITLEMENTS'
    aps_env_key = 'aps-environment'
    development = 'development'
    production = 'production'
    if (entitlements_debug_file_paths == nil or entitlements_debug_file_paths.empty?) and (entitlements_release_file_paths == nil or entitlements_release_file_paths.empty?) and target_name != nil
      @logger.info("\tEntitlements are not set for both release and debug schemes, setting up...")
      entitlements_destination_filepath = create_entitlements_file("#{target_name}.entitlements")

      @logger.info("\tSetting build settings:\n\t\tdebug:  \t#{code_sign_entitlements_key}\t#{entitlements_destination_filepath}\n\t\trelease:\t#{code_sign_entitlements_key}\t#{entitlements_destination_filepath}")

      _build_settings_debug.each do |setting|
        setting[code_sign_entitlements_key] = entitlements_destination_filepath
      end
      _build_settings_release.each do |setting|
        setting[code_sign_entitlements_key] = entitlements_destination_filepath
      end
      entitlements_debug_file_paths = [entitlements_destination_filepath]
      entitlements_release_file_paths = [entitlements_destination_filepath]
    end

    if entitlements_debug_file_paths.to_set == entitlements_release_file_paths.to_set
      @logger.info("\tEntitlements settings are equal for debug and release schemes.")

      put_key_array_element("com.apple.security.application-groups", @app_group, entitlements_debug_file_paths)

      #aps env should be set only for main target
      if (target_name != @extension_target_name)
        put_string_value_into_xml(aps_env_key, development, entitlements_debug_file_paths)
      end
    else
      if (entitlements_debug_file_paths == nil or entitlements_debug_file_paths.empty?) and target_name != nil
        @logger.error("\tEntitlements debug settings are not set, creating entitlements file")
        entitlements_destination_filepath = create_entitlements_file("#{target_name}_debug.entitlements")
        _build_settings_debug.each do |setting|
          setting[code_sign_entitlements_key] = entitlements_destination_filepath
        end
        entitlements_debug_file_paths = [entitlements_destination_filepath]
      end

      if (entitlements_release_file_paths == nil or entitlements_release_file_paths.empty?) and target_name != nil
        @logger.error("\tEntitlements release settings are not set, creating entitlements file")
        entitlements_destination_filepath = create_entitlements_file("#{target_name}_release.entitlements")
        _build_settings_release.each do |setting|
          setting[code_sign_entitlements_key] = entitlements_destination_filepath
        end
        entitlements_release_file_paths = [entitlements_destination_filepath]
      end

      put_key_array_element("com.apple.security.application-groups", @app_group, entitlements_debug_file_paths + entitlements_release_file_paths)

      #aps env should be set only for main target
      if (target_name != @extension_target_name)
        put_string_value_into_xml(aps_env_key, development, entitlements_debug_file_paths)
        put_string_value_into_xml(aps_env_key, production, entitlements_release_file_paths)
      end
    end
  end

  def setup_user_app_group_value
    plist_paths = (@main_build_configurations_debug + @main_build_configurations_release).map { |config| config.resolve_build_setting("INFOPLIST_FILE") }
    put_string_value_into_xml("com.mobilemessaging.app_group", @app_group, resolve_absolute_paths(plist_paths))
  end

  def setup_background_modes_plist_value
    plist_paths = (@main_build_configurations_debug + @main_build_configurations_release).map { |config| config.resolve_build_setting("INFOPLIST_FILE") }
    put_key_array_element("UIBackgroundModes", "remote-notification", resolve_absolute_paths(plist_paths))
  end

  def setup_embed_extension_action
    phase_name = 'Embed App Extensions'
    phase = @main_target.copy_files_build_phases.select { |p| p.name == phase_name }.first
    if phase == nil
      @logger.info("Creating copy files build phase: #{phase_name}")
      phase = @main_target.new_copy_files_build_phase(phase_name)
      phase.dst_subfolder_spec = '13'
    end
    already_embedded = phase.files.any? { |f| f.file_ref == @extension_target.product_reference }
    if already_embedded
      @logger.info("Extension product already embedded in '#{phase_name}', skipping")
    else
      @logger.info("Adding extension product to '#{phase_name}' phase")
      phase.add_file_reference(@extension_target.product_reference)
    end
  end

  def setup_main_target_dependency
    unless @main_target.dependency_for_target(@extension_target)
      @logger.info("Adding extension target dependency for main target")
      @main_target.add_dependency(@extension_target)
    end
  end

  def erease_bridging_header
    set_notification_extension_build_settings('SWIFT_OBJC_BRIDGING_HEADER', '')
  end

  def setup_swift_version
    set_notification_extension_build_settings('SWIFT_VERSION', @swift_version)
  end

  def setup_product_name
    set_notification_extension_build_settings('PRODUCT_NAME', @extension_target_name)
  end

  def setup_extension_build_number
    version_key = "CFBundleShortVersionString"
    build_key = "CFBundleVersion"
    put_string_value_into_xml(version_key, '1.0', [@extension_info_plist_path])
    put_string_value_into_xml(build_key, '1', [@extension_info_plist_path])
  end

  def setup_target_capabilities_for_extension_target
    mobile_messaging_capabilities = {"SystemCapabilities" =>
                                           {
                                               "com.apple.ApplicationGroups.iOS" => {"enabled" => 1},
                                           }
    }
    setup_target_capabilities(@extension_target.uuid, mobile_messaging_capabilities)
  end

  def setup_target_capabilities_for_main_target
    mobile_messaging_capabilities = {"SystemCapabilities" =>
                                         {
                                             "com.apple.ApplicationGroups.iOS" => {"enabled" => 1},
                                             "com.apple.Push" => {"enabled" => 1},
                                             "com.apple.BackgroundModes" => {"enabled" => 1}
                                         }
    }
    setup_target_capabilities(@main_target.uuid, mobile_messaging_capabilities)
  end

  def setup_target_capabilities(target_uuid, capabilities)
    unless @project.root_object.attributes["TargetAttributes"]
      @project.root_object.attributes["TargetAttributes"] = Hash.new
    end
    existing_capabilities = @project.root_object.attributes["TargetAttributes"][target_uuid]
    if existing_capabilities == nil
      @logger.info("\tSetting TargetAttributes #{capabilities} for target #{target_uuid}")
      @project.root_object.attributes["TargetAttributes"][target_uuid] = capabilities
    else
      @logger.info("\tMerging TargetAttributes #{capabilities} for target #{target_uuid}")
      @project.root_object.attributes["TargetAttributes"][target_uuid] = existing_capabilities.merge(capabilities)
    end
  end

  def resolve_xcode_path(path)
    return path.sub(@project_dir, '$(PROJECT_DIR)')
  end

  def set_notification_extension_build_settings(key, value)
    @logger.info("\tSetting extension build settings across all configurations :\n\t\t#{key}\t#{value}")
    @extension_target.build_configuration_list.set_setting(key, value)
  end

  def align_notification_extension_build_settings(key, main_configurations)
    main_configurations.each do |config|
      value = config.resolve_build_setting(key)
      if value.nil? || value.empty?
        @logger.info("\tSkipping extension build setting (not set on main target):\n\t\t#{config.name}:  \t#{key}")
      else
        @logger.info("\tSetting extension build settings:\n\t\t#{config.name}:  \t#{key}\t#{value}")
        @extension_target.build_configuration_list[config.name].build_settings[key] = value
      end
    end
  end

  def get_notification_extension_group_reference
    group_reference = @project.groups.select { |group| group.name == @extension_group_name }.first
    if group_reference == nil
      group_reference = @project.new_group(@extension_group_name, @extension_destination_dir)
    end
    return group_reference
  end

  def resolve_absolute_paths(paths)
    paths.map do |path|
      ret = path
      ["$(PROJECT_DIR)", "$PROJECT_DIR"].each do |proj_dir|
        ret = ret.sub(proj_dir, @project_dir)
      end

      ["$(PROJECT_NAME)", "$PROJECT_NAME"].each do |proj_name|
        ret = ret.sub(proj_name, @project_name)
      end

      if ret.include?("$")
        puts "Could not resolve absolute path for #{path}. Make sure you don't misuse Xcode paths variables, contact Infobip Mobile Messaging support via email Push.Support@infobip.com"
        exit
      end

      if ret == path && !ret.include?("$") # no aliases found/replaced, no aliases left in path
        if path.start_with? "/"
          ret = path # it's already an absolute path
        else
          ret = File.join(@project_dir, path) # it's a relative project path
        end
      end

      ret
    end
  end

  def get_xml_string_value(key, plist_path)
    plist_path = resolve_absolute_paths([plist_path]).first
    doc = Nokogiri::XML(IO.read(plist_path))
    key_node = doc.search("//dict//key[text() = '#{key}']").first
    if key_node == nil
      return nil
    else
      existing_string_value_node = key_node.xpath("following-sibling::*").first
      if existing_string_value_node.name == 'string'
        return existing_string_value_node.content
      else
        return nil
      end
    end
  end

  def put_string_value_into_xml(key, value, plist_paths)
    plist_paths.each do |plist_path|
      plist_path = resolve_absolute_paths([plist_path]).first
      @logger.info("\tConfiguring plist on path: #{plist_path}")
      doc = Nokogiri::XML(IO.read(plist_path))
      key_node = doc.search("//dict//key[text() = '#{key}']").first
      string_value_node = Nokogiri::XML::Node.new("string", doc)
      string_value_node.content = value
      if key_node == nil
        @logger.info("\tAdding 'key' node with content #{key}")
        key_node = Nokogiri::XML::Node.new("key", doc)
        key_node.content = key
        doc.xpath("//dict").first.add_child(key_node)
        @logger.info("\tAdding next string sibling with content #{string_value_node}")
        key_node.add_next_sibling(string_value_node)
      else
        @logger.info("\t'Key' node with content #{key} already exists.")
        existing_string_value_node = key_node.xpath("following-sibling::*").first
        if existing_string_value_node.name == 'string'
          @logger.info("\tUpdating following string sibling value with #{value}")
          existing_string_value_node.content = value
        else
          @logger.info("\tAdding next string sibling with content #{string_value_node}")
          key_node.add_next_sibling(string_value_node)
        end
      end

      File.open(plist_path, 'w') do |file|
        @logger.info("\tWriting changes to plist: #{plist_path}")
        file.puts Nokogiri::XML(doc.to_xml) { |x| x.noblanks }
      end
    end
  end

  def put_key_array_element(key, value, file_paths) # check if it appends to existing array
    @logger.debug("put_key_array_element #{key} #{value} #{file_paths}")
    file_paths.each do |file_path|
      file_path = resolve_absolute_paths([file_path]).first
      doc = Nokogiri::XML(IO.read(file_path))
      key_node = doc.search("//dict//key[text() = '#{key}']").first
      string_app_group_value = Nokogiri::XML::Node.new("string", doc)
      string_app_group_value.content = value
      if key_node == nil
        @logger.info("\tAdding 'key' node with content #{key}")
        key_node = Nokogiri::XML::Node.new("key", doc)
        key_node.content = key
        array_node = Nokogiri::XML::Node.new("array", doc)
        array_node.add_child(string_app_group_value)

        doc.xpath("//dict").first.add_child(key_node)
        key_node.add_next_sibling(array_node)
      else
        @logger.info("\t'Key' node with content #{key} already exists.")
        array_node = key_node.xpath("following-sibling::*").first
        if array_node.name == 'array'
          @logger.info("\tFollowing array sibling already exists")
          if array_node.xpath("//string[text() = '#{value}']").first
            @logger.info("\tArray string element with content #{value} already exists")
          else
            @logger.info("\tAdding child string element with content #{value}")
            array_node.add_child(string_app_group_value)
          end
        else
          @logger.info("\tFollowing array sibling is missing. Adding array node containing a string element.")
          array_node = Nokogiri::XML::Node.new("array", doc)
          array_node.add_child(string_app_group_value)
          key_node.add_next_sibling(array_node)
        end
      end

      File.open(file_path, 'w') do |file|
        @logger.info("\tWriting changes to entitlements: #{file_path}")
        file.puts Nokogiri::XML(doc.to_xml) { |x| x.noblanks }
      end
    end
  end
end

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
  def initialize(application_code, project_file_path, app_group, main_target_name, cordova = false, swift_ver)
    @project_file_path = project_file_path
    @app_group = app_group
    @main_target_name = main_target_name
    @logger = nil
    @cordova = cordova
    @swift_version = swift_ver
    @application_code = application_code

    @project_dir = Pathname.new(@project_file_path).parent.to_s
    @project = Xcodeproj::Project.open(@project_file_path)
    @project_name = @project.root_object.name
    @framework_file_name = "MobileMessaging.framework"

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
    @logger.debug("\n@main_target_build_configurations_debug #{@main_build_configurations_debug}\n@main_target_build_configurations_release #{@main_build_configurations_release}")
    @logger.debug("\n@main_target_build_configurations_debug #{JSON.pretty_generate(@main_build_settings_debug)}\n@main_target_build_configurations_release #{JSON.pretty_generate(@main_build_settings_release)}")
    create_notification_extension_target
    create_notification_extension_dir
    add_notification_extension_source_code
    setup_development_team
    setup_deployment_target
    setup_notification_extension_info_plist
    setup_notification_extension_bundle_id

    setup_user_app_group_value
    setup_background_modes_plist_value

    setup_target_capabilities(@extension_target.uuid)
    setup_target_capabilities(@main_target.uuid)

    setup_embed_extension_action
    setup_main_target_dependency
    setup_swift_version
    setup_product_name
    setup_extension_build_number

    if @cordova
      setup_entitlements(resolve_absolute_paths(["$(PROJECT_DIR)/$(PROJECT_NAME)/Entitlements-Debug.plist"]),
                         resolve_absolute_paths(["$(PROJECT_DIR)/$(PROJECT_NAME)/Entitlements-Release.plist"]),
                         nil,
                         @main_build_settings_debug,
                         @main_build_settings_release)
      setup_framework_search_paths
      setup_run_path_search_paths
      setup_extension_lib_cordova_link
      setup_copy_framework_script
    else
      setup_entitlements(@main_build_configurations_debug.map { |config| config.resolve_build_setting('CODE_SIGN_ENTITLEMENTS') },
                         @main_build_configurations_release.map { |config| config.resolve_build_setting('CODE_SIGN_ENTITLEMENTS') },
                         @main_target_name,
                         @main_build_settings_debug,
                         @main_build_settings_release)

      setup_entitlements(@extension_build_configurations_debug.map { |config| config.resolve_build_setting('CODE_SIGN_ENTITLEMENTS') },
                         @extension_build_configurations_release.map { |config| config.resolve_build_setting('CODE_SIGN_ENTITLEMENTS') },
                         @extension_target_name,
                         @extension_build_settings_debug,
                         @extension_build_settings_release)
    end

    @project.save
    puts "🏁 Integration has been finished successfully!"
  end

  def create_notification_extension_target
    @extension_target_name = 'MobileMessagingNotificationExtension'
    @extension_source_name_filepath = File.join(Mmine.root, 'resources', 'NotificationService.swift')
    @extension_dir_name = 'NotificationExtension'
    @extension_destination_dir = File.join(@project_dir, @extension_dir_name)
    @extension_code_destination_filepath = File.join(@extension_destination_dir, 'NotificationService.swift')
    @extension_group_name = 'NotificationExtensionGroup'
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

    @extension_target.frameworks_build_phase.files_references.each { |ref|
      @extension_target.frameworks_build_phase.remove_file_reference(ref)
    }

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
    put_application_code_in_source_code
  end

  def put_application_code_in_source_code
    source_code = File.read(@extension_code_destination_filepath)
    modified_source_code = source_code.gsub(/<# put your Application Code here #>/, "\"#{@application_code}\"")
    unless source_code == modified_source_code
      File.open(@extension_code_destination_filepath, "w") do |file|
        @logger.info("\tWriting application code to source code at #{@extension_code_destination_filepath}")
        file.puts modified_source_code
      end
    end
  end

  def setup_development_team
    align_notification_extension_build_settings('DEVELOPMENT_TEAM',
                                                @main_target.build_configurations)
  end

  def setup_deployment_target
    set_notification_extension_build_settings('IPHONEOS_DEPLOYMENT_TARGET', "10.0")
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
      bundleId = config.resolve_build_setting(key)
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
    entitlements_debug_file_paths = entitlements_debug_file_paths.compact
    entitlements_release_file_paths = entitlements_release_file_paths.compact
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
      put_string_value_into_xml(aps_env_key, development, entitlements_debug_file_paths)
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
      put_string_value_into_xml(aps_env_key, development, entitlements_debug_file_paths)
      put_string_value_into_xml(aps_env_key, production, entitlements_release_file_paths)
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
    unless @main_target.copy_files_build_phases.select { |phase| phase.name == phase_name }.first
      @logger.info("Adding copy files build phase: #{phase_name}")
      new_phase = @main_target.new_copy_files_build_phase(phase_name)
      new_phase.dst_subfolder_spec = '13'
      new_phase.add_file_reference(@extension_target.product_reference)
    end
  end

  def setup_main_target_dependency
    unless @main_target.dependency_for_target(@extension_target)
      @logger.info("Adding extension target dependency for main target")
      @main_target.add_dependency(@extension_target)
    end
  end

  def setup_framework_search_paths
    set_notification_extension_build_settings('FRAMEWORK_SEARCH_PATHS', '$SRCROOT/$PROJECT/Plugins/com-infobip-plugins-mobilemessaging')
  end

  def setup_run_path_search_paths
    set_notification_extension_build_settings('LD_RUNPATH_SEARCH_PATHS', '@executable_path/../../Frameworks')
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

  def setup_extension_lib_cordova_link
    lib_cordova_name = 'libCordova.a'
    if @extension_target.frameworks_build_phase.files_references.select { |ref| ref.path == lib_cordova_name }.first
      @logger.info("Notification Extension target already has libCordova.a linked.")
    else
      @logger.info("Adding libCordova.a to Notification Extension target...")
      ref = @main_target.frameworks_build_phase.files_references.select { |ref| ref.path == lib_cordova_name }.first
      if ref
        @extension_target.frameworks_build_phase.add_file_reference(ref)
      else
        @logger.error("Main target has no libCordova.a as a linked library. Unable to add libCordova.a to Notification Extension target!")
      end
    end
  end

  def setup_copy_framework_script
    phase_name = "Copy Frameworks"
    shell_script = "/usr/local/bin/carthage copy-frameworks"
    input_path = "$SRCROOT/$PROJECT/Plugins/com-infobip-plugins-mobilemessaging/#{@framework_file_name}"
    output_path = "$(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/#{@framework_file_name}"
    existing_phase = @main_target.shell_script_build_phases.select { |phase| phase.shell_script.include? shell_script }.first

    if existing_phase
      existing_phase.input_paths |= [input_path]
      existing_phase.output_paths |= [output_path]
      @logger.info("Main target already has #{phase_name} shell script set up")
    else
      @logger.info("Setting up #{phase_name} shell script for main target")
      new_phase = @main_target.new_shell_script_build_phase(phase_name)
      new_phase.shell_path = "/bin/sh"
      new_phase.shell_script = shell_script
      new_phase.input_paths << input_path
      new_phase.output_paths << output_path
    end

    remove_embed_framework_phase
  end

  def setup_target_capabilities(target_uuid)
    unless @project.root_object.attributes["TargetAttributes"]
      @project.root_object.attributes["TargetAttributes"] = Hash.new
    end
    existing_capabilities = @project.root_object.attributes["TargetAttributes"][target_uuid]
    mobile_messaging_capabilities = {"SystemCapabilities" =>
                                         {
                                             "com.apple.ApplicationGroups.iOS" => {"enabled" => 1},
                                             "com.apple.Push" => {"enabled" => 1},
                                             "com.apple.BackgroundModes" => {"enabled" => 1}
                                         }
    }
    if existing_capabilities == nil
      @logger.info("\tSetting TargetAttributes #{mobile_messaging_capabilities} for target #{target_uuid}")
      @project.root_object.attributes["TargetAttributes"][target_uuid] = mobile_messaging_capabilities
    else
      @logger.info("\tMerging TargetAttributes #{mobile_messaging_capabilities} for target #{target_uuid}")
      @project.root_object.attributes["TargetAttributes"][target_uuid] = existing_capabilities.merge(mobile_messaging_capabilities)
    end
  end

  def remove_embed_framework_phase
    @logger.info("Setting up embed framework script")
    @main_target.copy_files_build_phases
        .select { |phase|
          phase.dst_subfolder_spec == '10'
        }
        .each { |phase|
          phase.files.select { |file|
            file.display_name == @framework_file_name
          }.each { |file|
            @logger.info("\tRemoving embeddin #{@framework_file_name} from phase #{phase.display_name}")
            phase.remove_build_file(file)
          }
        }
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
      @logger.info("\tSetting extension build settings:\n\t\t#{config.name}:  \t#{key}\t#{value}")
      @extension_target.build_configuration_list[config.name].build_settings[key] = value
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

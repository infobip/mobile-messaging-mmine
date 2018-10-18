require 'xcodeproj'
require 'fileutils'
require 'pathname'
require 'nokogiri'
require 'logger'

module Mmine
  def self.root
    File.expand_path '../..', File.dirname(__FILE__)
  end
end

class NotificationExtensionIntegrator
	def initialize(application_code, project_file_path, app_group, main_target_name)
		@application_code = application_code
		@project_file_path = project_file_path
		@app_group = app_group
		@main_target_name = main_target_name
		@logger = nil
		
		@project_dir = Pathname.new(@project_file_path).parent.to_s
		@project = Xcodeproj::Project.open(@project_file_path)
		@ne_target_name = 'MobileMessagingNotificationExtension'
		@extension_source_name_filepath = File.join(Mmine.root, 'resources','NotificationService.swift')
		@extension_dir_name = 'NotificationExtension'
		@extension_destination_dir = File.join(@project_dir, @extension_dir_name)
		@extension_code_destination_filepath = File.join(@extension_destination_dir, 'NotificationService.swift')
		@extension_group_name = 'NotificationExtensionGroup'

		@plist_name = 'MobileMessagingNotificationServiceExtension.plist'
		@plist_source_filepath = File.join(Mmine.root, 'resources', @plist_name)
		@extension_info_plist_path = File.join(@project_dir, @extension_dir_name, @plist_name)

		@main_target = @project.native_targets().select { |target| target.name == @main_target_name }.first
		@main_target_build_settings_debug = @main_target.build_configurations.select { |config| config.type == :debug }.first.build_settings
		@main_target_build_settings_release = @main_target.build_configurations.select { |config| config.type == :release }.first.build_settings
		@main_target_debug_plist = resolveAbsolutePath(@main_target_build_settings_debug["INFOPLIST_FILE"])
		@main_target_release_plist = resolveAbsolutePath(@main_target_build_settings_release["INFOPLIST_FILE"])
	end

	def logger=(_logger)
    	@logger = _logger
	end
	def logger
    	return @logger
	end

	def setupNotificationExtension
	
		createNotificationExtensionTarget()
		createNotificationExtensionDir()
		addNotificationExtensionSourceCode()
		setupDevelopmentTeam()
		setupDeploymentTarget()
		setupNotificationExtensionInfoPlist()
		setupNotificationExtensionBundleId()
		setupNotificationExtensionEntitlements()
		setupMainTargetEntitlements()
		setupAppGroupPlistValue()
		setupApplicationCodePlistValue()

		@project.save()
	end

	def createNotificationExtensionTarget
		@ne_target = @project.native_targets().select { |target| target.name == @ne_target_name }.first
		if @ne_target == nil
			@logger.info("Creating notification extension target with name #{@ne_target_name}")
			@ne_target = @project.new_target(:app_extension, @ne_target_name, ':ios')
		else
			@logger.info("Notification extension target already exists, reusing...")
		end
		@extension_build_settings_debug = @ne_target.build_configurations.select { |config| config.type == :debug }.first.build_settings
		@extension_build_settings_release = @ne_target.build_configurations.select { |config| config.type == :release }.first.build_settings
		@logger.info("Notification extension target debug build settings: #{@extension_build_settings_debug}")
		@logger.info("Notification extension target release build settings: #{@extension_build_settings_release}")
	end

	def createNotificationExtensionDir
		unless File.directory?(@extension_destination_dir)
			@logger.info("Creating directory: #{@extension_destination_dir}")
			FileUtils.mkdir_p(@extension_destination_dir)
		else
			@logger.info("Notification extension directory already exists: #{@extension_destination_dir}")
		end
	end

	def addNotificationExtensionSourceCode
		unless File.exist?(@extension_code_destination_filepath)
			@logger.info("Copying notification extension source code to path: #{@extension_code_destination_filepath}")
			FileUtils.cp(@extension_source_name_filepath, @extension_code_destination_filepath)
			filereference = getNotificationExtensionGroupReference().new_reference(@extension_code_destination_filepath)
			@ne_target.add_file_references([filereference])
		else
			@logger.info("Notification extension source code already exists on path: #{@extension_code_destination_filepath}")
		end
	end

	def setupDevelopmentTeam
		setNotificationExtensionBuildSettings('DEVELOPMENT_TEAM', @main_target_build_settings_debug['DEVELOPMENT_TEAM'], @main_target_build_settings_release['DEVELOPMENT_TEAM'])
	end

	def setupDeploymentTarget
		setNotificationExtensionBuildSettings('IPHONEOS_DEPLOYMENT_TARGET', "10.0")
	end

	def setupNotificationExtensionInfoPlist
		unless File.exist?(@extension_info_plist_path)
			@logger.info("Copying extension plist file to path: #{@extension_info_plist_path}")
			FileUtils.cp(@plist_source_filepath, @extension_info_plist_path)
			getNotificationExtensionGroupReference().new_reference(@extension_info_plist_path) #check if additional plist manipulations needed (target membership?)
		else
			@logger.info("Notification extension info plist already exists on path: #{@extension_info_plist_path}")
		end	
		setNotificationExtensionBuildSettings('INFOPLIST_FILE', resolveXcodePath(@extension_info_plist_path))
	end

	def setupNotificationExtensionBundleId
		suffix = "notification-extension"
		debug_id = @main_target_build_settings_debug['PRODUCT_BUNDLE_IDENTIFIER']
		release_id = @main_target_build_settings_release['PRODUCT_BUNDLE_IDENTIFIER']
		setNotificationExtensionBuildSettings('PRODUCT_BUNDLE_IDENTIFIER', "#{debug_id}.#{suffix}", "#{release_id}.#{suffix}")
	end

	def setupMainTargetEntitlements
		@logger.info("Setting up main target entitlements...")
		setupEntitlements(@main_target_build_settings_debug, @main_target_build_settings_release, @main_target_name)
	end

	def setupNotificationExtensionEntitlements
		@logger.info("Setting up extension entitlements...")
		setupEntitlements(@extension_build_settings_debug, @extension_build_settings_release, @ne_target_name)
	end

	def setupApplicationCodePlistValue
		putStringValueIntoPlist("com.mobilemessaging.app_code", @application_code, @main_target_release_plist)
	end

	def setupAppGroupPlistValue
		putStringValueIntoPlist("com.mobilemessaging.app_group", @app_group, @main_target_release_plist)
	end

	# private ->
	def setupEntitlements(_build_settings_debug, _build_settings_release, target_name)
		entitlements_debug_filepath = _build_settings_debug['CODE_SIGN_ENTITLEMENTS'] != nil ? resolveAbsolutePath(_build_settings_debug['CODE_SIGN_ENTITLEMENTS']) : nil
		entitlements_release_filepath = _build_settings_release['CODE_SIGN_ENTITLEMENTS'] != nil ? resolveAbsolutePath(_build_settings_release['CODE_SIGN_ENTITLEMENTS']) : nil

		if entitlements_debug_filepath == nil and entitlements_release_filepath == nil
			@logger.info("  Entitlements are not set for both release and debug schemes, setting up...")
			entitlements_destination_filepath = createAppGroupEntitlements("#{target_name}.entitlements")
			setBuildSettings(_build_settings_debug, _build_settings_release, 'CODE_SIGN_ENTITLEMENTS', resolveXcodePath(entitlements_destination_filepath))
		else
			if entitlements_debug_filepath == entitlements_release_filepath
				@logger.info("  Entitlements settings are equal for debug and release schemes.")
				putAppGroupIdIntoEntitlements(entitlements_debug_filepath)
			else
				if entitlements_debug_filepath != nil
					@logger.info("  Entitlements debug settings already set, updating settings...")
					putAppGroupIdIntoEntitlements(entitlements_debug_filepath)
				else
					@logger.info("  Entitlements debug settings are not set, setting up...")
					entitlements_destination_filepath = createAppGroupEntitlements("#{target_name}_debug.entitlements")
					_build_settings_debug['CODE_SIGN_ENTITLEMENTS'] = resolveXcodePath(entitlements_destination_filepath)
				end

				if entitlements_release_filepath != nil
					@logger.info("  Entitlements release settings already set, updating settings...")
					putAppGroupIdIntoEntitlements(entitlements_release_filepath)
				else
					@logger.info("  Entitlements release settings are not set, setting up...")
					entitlements_destination_filepath = createAppGroupEntitlements("#{target_name}_release.entitlements")
					_build_settings_release['CODE_SIGN_ENTITLEMENTS'] = resolveXcodePath(entitlements_destination_filepath)
				end
			end
		end

		#TODO merge with existing
		@project.root_object.attributes["TargetAttributes"][@ne_target.uuid] = {"SystemCapabilities" => {"com.apple.ApplicationGroups.iOS" => {"enabled" => 1}}}
	end

	def resolveXcodePath(path)
		return path.sub(@project_dir, '$(PROJECT_DIR)')
	end

	def setBuildSettings(_build_settings_debug, _build_settings_release, key, debug_value, release_value=nil)
		release_value = release_value != nil ? release_value : debug_value
		@logger.info("  Setting build settings:\n      key: #{key}\n      debug value: #{debug_value}\n      release value: #{release_value}")
		_build_settings_debug[key] = debug_value
		_build_settings_release[key] = release_value
	end

	def setNotificationExtensionBuildSettings(key, debug_value, release_value=nil)
		release_value = release_value != nil ? release_value : debug_value
		@logger.info("  Setting extension build settings for key #{key}. Debug value: #{debug_value}. Release value: #{release_value}")
		@extension_build_settings_debug[key] = debug_value
		@extension_build_settings_release[key] = release_value
	end

	def getNotificationExtensionGroupReference
		group_reference = @project.groups().select { |group| group.name == @extension_group_name }.first
		if group_reference == nil
			group_reference = @project.new_group(@extension_group_name, @extension_destination_dir)
		end
		return group_reference
	end

	def createAppGroupEntitlements(_entitlements_name)
		entitlements_destination_filepath = File.join(@project_dir, _entitlements_name)
		entitlements_source_filepath = File.join(Mmine.root, 'resources', "MobileMessagingNotificationExtension.entitlements")
		unless File.exist?(entitlements_destination_filepath)
			@logger.info("  Copying entitlemenst file to path: #{entitlements_destination_filepath}")
			FileUtils.cp(entitlements_source_filepath, entitlements_destination_filepath)
			ref = @project.main_group.new_reference(entitlements_destination_filepath)
			ref.last_known_file_type = "text.xml"
		else
			@logger.info("  Entitlements file already exists on path: #{entitlements_destination_filepath}")
		end
		putAppGroupIdIntoEntitlements(entitlements_destination_filepath)
		return entitlements_destination_filepath
	end

	def resolveAbsolutePath(path)
		if path.include? "$(PROJECT_DIR)" #TODO check what to do with src root
			return path.sub('$(PROJECT_DIR)', @project_dir)
		else
			if path.start_with? "/"
				return path
			else
				return File.join(@project_dir, path)
			end
		end
	end

	def putStringValueIntoPlist(key, value, plist_path)
		@logger.info("    Configuring plist on path: #{plist_path}")
		doc = Nokogiri::XML(IO.read(plist_path))
		key_node = doc.search("//dict//key[text() = '#{key}']").first
		string_value_node = Nokogiri::XML::Node.new("string",doc)
		string_value_node.content = value
		if key_node == nil
			@logger.info("    Adding 'key' node with content #{key}")
			key_node = Nokogiri::XML::Node.new("key",doc)
			key_node.content = key
			doc.xpath("//dict").first.add_child(key_node)
			@logger.info("    Adding next string sibling with content #{string_value_node}")
			key_node.add_next_sibling(string_value_node)
		else
			@logger.info("    'Key' node with content #{key} already extists.")
			existing_string_value_node = key_node.xpath("following-sibling::*").first
			if existing_string_value_node.name == 'string'
				@logger.info("    Updating following string sibling value with #{value}")
				existing_string_value_node.content = value
			else
				@logger.info("    Adding next string sibling with content #{string_value_node}")
				key_node.add_next_sibling(string_value_node)
			end
		end

		file = File.open(plist_path,'w')
		@logger.info("    Writing changes to plist: #{plist_path}")
		file.puts Nokogiri::XML(doc.to_xml) { |x| x.noblanks }
		file.close
	end

	def putAppGroupIdIntoEntitlements(filepath)
		doc = Nokogiri::XML(IO.read(filepath))
		app_groups_key = "com.apple.security.application-groups"
		key_node = doc.search("//dict//key[text() = '#{app_groups_key}']").first
		string_app_group_value = Nokogiri::XML::Node.new("string",doc)
		string_app_group_value.content = @app_group
		if key_node == nil
			@logger.info("    Adding 'key' node with content #{app_groups_key}")
			key_node = Nokogiri::XML::Node.new("key",doc)
			key_node.content = app_groups_key
			array_node = Nokogiri::XML::Node.new("array",doc)
			array_node.add_child(string_app_group_value)

			doc.xpath("//dict").first.add_child(key_node)
			key_node.add_next_sibling(array_node)
		else
			@logger.info("    'Key' node with content #{app_groups_key} already extists.")
			array_node = key_node.xpath("following-sibling::*").first
			if array_node.name == 'array'
				@logger.info("    Following array sibling already exists")
				unless array_node.xpath("//string[text() = '#{@app_group}']").first
					@logger.info("    Adding child string element with content #{@app_group}")
					array_node.add_child(string_app_group_value)
				else
					@logger.info("    Array string element with content #{@app_group} already exists")
				end
			else
				@logger.info("    Following array sibling is missing. Adding array node containing a string element.")
				array_node = Nokogiri::XML::Node.new("array",doc)
				array_node.add_child(string_app_group_value)
				key_node.add_next_sibling(array_node)
			end
		end

		file = File.open(filepath,'w')
		@logger.info("    Writing changes to entitlements: #{filepath}")
		file.puts Nokogiri::XML(doc.to_xml) { |x| x.noblanks }
		file.close
	end
end

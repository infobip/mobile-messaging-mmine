require 'xcodeproj'
require 'fileutils'
require 'pathname'
require 'nokogiri'
require 'logger'
require 'json'
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
		@ne_target_name = 'MobileMessagingNotificationExtension'
		@framework_file_name = "MobileMessaging.framework"
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
		puts "🏎  Integration starting... ver. #{Mmine::VERSION}"
		puts "🏎  Integration starting... ver. #{Mmine::VERSION}"
		createNotificationExtensionTarget()
		createNotificationExtensionDir()
		addNotificationExtensionSourceCode()
		setupDevelopmentTeam()
		setupDeploymentTarget()
		setupNotificationExtensionInfoPlist()
		setupNotificationExtensionBundleId()
		
		setupUserAppGroupValue()
		setupBackgroundModesPlistValue()
	
		setupTargetCapabilities(@ne_target.uuid)
		setupTargetCapabilities(@main_target.uuid)

		setupEmbedExtensionAction()
		setupMainTargetDependency()
		setupSwiftVersion()
		setupProductName()
		setupBuildNumber()
		
		if @cordova
			setupEntitlements(resolveAbsolutePath("$(PROJECT_DIR)/$(PROJECT_NAME)/Entitlements-Debug.plist"),resolveAbsolutePath("$(PROJECT_DIR)/$(PROJECT_NAME)/Entitlements-Release.plist"), nil, @main_target_build_settings_debug, @main_target_build_settings_release)
			setupFrameworkSearchPaths()
			setupRunpathSearchPaths()
			setupLibCordovaLink()
			setupCopyFrameworkScript()
		else
			setupEntitlements(@main_target_build_settings_debug['CODE_SIGN_ENTITLEMENTS'], @main_target_build_settings_release['CODE_SIGN_ENTITLEMENTS'], @main_target_name, @main_target_build_settings_debug, @main_target_build_settings_release)
			setupEntitlements(@extension_build_settings_debug['CODE_SIGN_ENTITLEMENTS'], @extension_build_settings_release['CODE_SIGN_ENTITLEMENTS'], @ne_target_name, @extension_build_settings_debug, @extension_build_settings_release)
		end

		@project.save()
		puts "🏁 Integration has been finished successfully!"
	end

	def createNotificationExtensionTarget
		@ne_target = @project.native_targets().select { |target| target.name == @ne_target_name }.first
		if @ne_target == nil
			@logger.info("Creating notification extension target with name #{@ne_target_name}")
			@ne_target = @project.new_target(:app_extension, @ne_target_name, :ios)
		else
			@logger.info("Notification extension target already exists, reusing...")
		end

		@extension_build_settings_debug = @ne_target.build_configurations.select { |config| config.name == 'Debug' }.first.build_settings
		@extension_build_settings_release = @ne_target.build_configurations.select { |config| config.name == 'Release' }.first.build_settings

		@ne_target.frameworks_build_phase.files_references.each { |ref|
			@ne_target.frameworks_build_phase.remove_file_reference(ref)
		}
		
		@logger.info("Notification extension target debug build settings:\n#{JSON.pretty_generate(@extension_build_settings_debug)}")
		@logger.info("Notification extension target release build settings:\n#{JSON.pretty_generate(@extension_build_settings_release)}")
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
		putApplicationCodeInSourceCode()
	end

	def putApplicationCodeInSourceCode
		source_code = File.read(@extension_code_destination_filepath)
		modified_source_code = source_code.gsub(/<# put your Application Code here #>/, "\"#{@application_code}\"")
		unless source_code == modified_source_code
			File.open(@extension_code_destination_filepath, "w") do |file|
				@logger.info("\tWriting application code to source code at #{@extension_code_destination_filepath}")
				file.puts modified_source_code
			end
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
		if debug_id and release_id
			@logger.info("Composing extension bundle id from main target build settings: debug #{debug_id}, release #{release_id}")
			setNotificationExtensionBuildSettings('PRODUCT_BUNDLE_IDENTIFIER', "#{debug_id}.#{suffix}", "#{release_id}.#{suffix}")
		else	
			key = "CFBundleIdentifier"
			main_bundle_id = getXMLStringValue(key, @main_target_release_plist)
			extension_bundle_id = "#{main_bundle_id}.#{suffix}"
			@logger.info("Composing extension bundle id from main target info plist: #{main_bundle_id}.")
			setNotificationExtensionBuildSettings('PRODUCT_BUNDLE_IDENTIFIER', extension_bundle_id)
		end		
	end

	def createEntitlementsFile(_entitlements_name)
		entitlements_destination_filepath = File.join(@project_dir, _entitlements_name)
		entitlements_source_filepath = File.join(Mmine.root, 'resources', "MobileMessagingNotificationExtension.entitlements")
		unless File.exist?(entitlements_destination_filepath)
			@logger.info("\tCopying entitlemenst file to path: #{entitlements_destination_filepath}")
			FileUtils.cp(entitlements_source_filepath, entitlements_destination_filepath)
			ref = @project.main_group.new_reference(entitlements_destination_filepath)
			ref.last_known_file_type = "text.xml"
		else
			@logger.info("\tEntitlements file already exists on path: #{entitlements_destination_filepath}")
		end
		return resolveXcodePath(entitlements_destination_filepath)
	end

	def setupEntitlements(entitlements_debug_filepath, entitlements_release_filepath, target_name, _build_settings_debug, _build_settings_release)
		key = 'CODE_SIGN_ENTITLEMENTS'
		
		if entitlements_debug_filepath == nil and entitlements_release_filepath == nil and target_name != nil
			@logger.info("\tEntitlements are not set for both release and debug schemes, setting up...")
			entitlements_destination_filepath = createEntitlementsFile("#{target_name}.entitlements")

			@logger.info("\tSetting build settings:\n\t\tdebug:  \t#{key}\t#{entitlements_destination_filepath}\n\t\trelease:\t#{key}\t#{entitlements_destination_filepath}")

			_build_settings_debug[key] = entitlements_destination_filepath
			_build_settings_release[key] = entitlements_destination_filepath
			entitlements_debug_filepath = entitlements_destination_filepath
			entitlements_release_filepath = entitlements_destination_filepath
		end

		if entitlements_debug_filepath == entitlements_release_filepath
			@logger.info("\tEntitlements settings are equal for debug and release schemes.")
			
			putKeyArrayElement("com.apple.security.application-groups", @app_group, entitlements_debug_filepath)
			putStringValueIntoXML("aps-environment", "development", entitlements_debug_filepath)
		else
			if entitlements_debug_filepath == nil and target_name != nil
				@logger.error("\tEntitlements debug settings are not set, creating entitlements file")
				entitlements_debug_filepath = createEntitlementsFile("#{target_name}_debug.entitlements")
				_build_settings_debug[key] = entitlements_debug_filepath
			end

			if entitlements_release_filepath == nil and target_name != nil
				@logger.error("\tEntitlements release settings are not set, creating entitlements file")
				entitlements_release_filepath = createEntitlementsFile("#{target_name}_release.entitlements")
				_build_settings_release[key] = entitlements_release_filepath
			end
				
			putKeyArrayElement("com.apple.security.application-groups", @app_group, entitlements_debug_filepath)
			putStringValueIntoXML("aps-environment", "development", entitlements_debug_filepath)
			putKeyArrayElement("com.apple.security.application-groups", @app_group, entitlements_release_filepath)
			putStringValueIntoXML("aps-environment", "production", entitlements_release_filepath)
		end
	end

	def setupUserAppGroupValue
		putStringValueIntoXML("com.mobilemessaging.app_group", @app_group, @main_target_debug_plist)
		putStringValueIntoXML("com.mobilemessaging.app_group", @app_group, @main_target_release_plist)
	end

	def setupBackgroundModesPlistValue
		putKeyArrayElement("UIBackgroundModes", "remote-notification", @main_target_debug_plist)
		putKeyArrayElement("UIBackgroundModes", "remote-notification", @main_target_release_plist)
	end

	def setupEmbedExtensionAction
		phase_name = 'Embed App Extensions'
		unless @main_target.copy_files_build_phases.select { |phase| phase.name == phase_name }.first
			@logger.info("Adding copy files build phase: #{phase_name}")
			new_phase = @main_target.new_copy_files_build_phase(phase_name)
			new_phase.dst_subfolder_spec = '13'
			new_phase.add_file_reference(@ne_target.product_reference)
		end
	end

	def setupMainTargetDependency
		unless @main_target.dependency_for_target(@ne_target)
			@logger.info("Adding extension target dependency for main target")
			@main_target.add_dependency(@ne_target)
		end
	end

	def setupFrameworkSearchPaths
		setNotificationExtensionBuildSettings('FRAMEWORK_SEARCH_PATHS', '$SRCROOT/$PROJECT/Plugins/com-infobip-plugins-mobilemessaging') 
	end

	def setupRunpathSearchPaths
		setNotificationExtensionBuildSettings('LD_RUNPATH_SEARCH_PATHS', '@executable_path/../../Frameworks')
	end

	def setupSwiftVersion
		setNotificationExtensionBuildSettings('SWIFT_VERSION', @swift_version)
	end

	def setupProductName
		setNotificationExtensionBuildSettings('PRODUCT_NAME', @ne_target_name)
	end

	def setupBuildNumber
		version_key = "CFBundleShortVersionString"
		build_key = "CFBundleVersion"
		main_version = getXMLStringValue(version_key, @main_target_release_plist)
		main_build = getXMLStringValue(build_key, @main_target_release_plist)
		putStringValueIntoXML(version_key, main_version, @extension_info_plist_path)
		putStringValueIntoXML(build_key, main_build, @extension_info_plist_path)
	end

	def setupLibCordovaLink
		lib_cordova_name = 'libCordova.a'
		unless @ne_target.frameworks_build_phase.files_references.select { |ref| ref.path == lib_cordova_name }.first
			@logger.info("Adding libCordova.a to Notification Extension target...")
			ref = @main_target.frameworks_build_phase.files_references.select { |ref| ref.path == lib_cordova_name }.first
			if ref
				@ne_target.frameworks_build_phase.add_file_reference(ref)
			else
				@logger.error("Main target has no libCordova.a as a linked library. Unable to add libCordova.a to Notification Extension target!")
			end
		else
			@logger.info("Notification Extension target already has libCordova.a linked.")
		end
	end

	def setupCopyFrameworkScript
		phase_name = "Copy Frameworks"
		shell_script = "/usr/local/bin/carthage copy-frameworks"
		input_path = "$SRCROOT/$PROJECT/Plugins/com-infobip-plugins-mobilemessaging/#{@framework_file_name}"
		output_path = "$(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/#{@framework_file_name}"
		existing_phase = @main_target.shell_script_build_phases.select { |phase| phase.shell_script.include? shell_script }.first

		unless existing_phase
			@logger.info("Setting up #{phase_name} shell script for main target")
			new_phase = @main_target.new_shell_script_build_phase(phase_name)
			new_phase.shell_path = "/bin/sh"
			new_phase.shell_script = shell_script
			new_phase.input_paths << input_path
			new_phase.output_paths << output_path
		else
			existing_phase.input_paths |= [input_path]
			existing_phase.output_paths |= [output_path]

			@logger.info("Main target already has #{phase_name} shell script set up")
		end
		removeEmbedFrameworkPhase()
	end

	def setupTargetCapabilities(target_uuid)
		unless @project.root_object.attributes["TargetAttributes"]
			@project.root_object.attributes["TargetAttributes"] = Hash.new
		end
		exitsting_capabilities = @project.root_object.attributes["TargetAttributes"][target_uuid] 
		mobilemessaging_capabilities = { "SystemCapabilities" => 
			{
				"com.apple.ApplicationGroups.iOS" => { "enabled" => 1 },
				"com.apple.Push" => { "enabled" => 1 },
				"com.apple.BackgroundModes" => { "enabled" => 1 }
			}
		}
		if exitsting_capabilities == nil
			@logger.info("\tSetting TargetAttributes #{mobilemessaging_capabilities} for target #{target_uuid}")
			@project.root_object.attributes["TargetAttributes"][target_uuid] = mobilemessaging_capabilities
		else
			@logger.info("\tMerging TargetAttributes #{mobilemessaging_capabilities} for target #{target_uuid}")
			@project.root_object.attributes["TargetAttributes"][target_uuid] = exitsting_capabilities.merge(mobilemessaging_capabilities)
		end
	end

	def removeEmbedFrameworkPhase
		@logger.info("Setting up embed framework script")
		emb_fs = @main_target.copy_files_build_phases
		.select { |phase|
			phase.dst_subfolder_spec == '10' 
		}.each { |phase|
 			phase.files.select { |file|
 				file.display_name == @framework_file_name
 			}.each { |file|
 				@logger.info("\tRemoving embeddin #{@framework_file_name} from phase #{phase.display_name}")
				phase.remove_build_file(file)
 			}
		}
	end

	def resolveXcodePath(path)
		return path.sub(@project_dir, '$(PROJECT_DIR)')
	end

	def setNotificationExtensionBuildSettings(key, debug_value, release_value=nil)
		release_value = release_value != nil ? release_value : debug_value
		@logger.info("\tSetting extension build settings:\n\t\tdebug:  \t#{key}\t#{debug_value}\n\t\trelease:\t#{key}\t#{release_value}")
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

	def resolveAbsolutePath(path)
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
				return path # it's already an absolute path
			else
				return File.join(@project_dir, path) # it's a relative project path
			end
		end
		return ret
	end

	def getXMLStringValue(key, plist_path)
		plist_path = resolveAbsolutePath(plist_path)
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

	def putStringValueIntoXML(key, value, plist_path)
		plist_path = resolveAbsolutePath(plist_path)
		@logger.info("\tConfiguring plist on path: #{plist_path}")
		doc = Nokogiri::XML(IO.read(plist_path))
		key_node = doc.search("//dict//key[text() = '#{key}']").first
		string_value_node = Nokogiri::XML::Node.new("string",doc)
		string_value_node.content = value
		if key_node == nil
			@logger.info("\tAdding 'key' node with content #{key}")
			key_node = Nokogiri::XML::Node.new("key",doc)
			key_node.content = key
			doc.xpath("//dict").first.add_child(key_node)
			@logger.info("\tAdding next string sibling with content #{string_value_node}")
			key_node.add_next_sibling(string_value_node)
		else
			@logger.info("\t'Key' node with content #{key} already extists.")
			existing_string_value_node = key_node.xpath("following-sibling::*").first
			if existing_string_value_node.name == 'string'
				@logger.info("\tUpdating following string sibling value with #{value}")
				existing_string_value_node.content = value
			else
				@logger.info("\tAdding next string sibling with content #{string_value_node}")
				key_node.add_next_sibling(string_value_node)
			end
		end

		File.open(plist_path,'w') do |file|
			@logger.info("\tWriting changes to plist: #{plist_path}")
			file.puts Nokogiri::XML(doc.to_xml) { |x| x.noblanks }
		end
	end

	def putKeyArrayElement(key, value, filepath) # check if it appends to existing array
		filepath = resolveAbsolutePath(filepath)
		doc = Nokogiri::XML(IO.read(filepath))
		key_node = doc.search("//dict//key[text() = '#{key}']").first
		string_app_group_value = Nokogiri::XML::Node.new("string",doc)
		string_app_group_value.content = value
		if key_node == nil
			@logger.info("\tAdding 'key' node with content #{key}")
			key_node = Nokogiri::XML::Node.new("key",doc)
			key_node.content = key
			array_node = Nokogiri::XML::Node.new("array",doc)
			array_node.add_child(string_app_group_value)

			doc.xpath("//dict").first.add_child(key_node)
			key_node.add_next_sibling(array_node)
		else
			@logger.info("\t'Key' node with content #{key} already extists.")
			array_node = key_node.xpath("following-sibling::*").first
			if array_node.name == 'array'
				@logger.info("\tFollowing array sibling already exists")
				unless array_node.xpath("//string[text() = '#{value}']").first
					@logger.info("\tAdding child string element with content #{value}")
					array_node.add_child(string_app_group_value)
				else
					@logger.info("\tArray string element with content #{value} already exists")
				end
			else
				@logger.info("\tFollowing array sibling is missing. Adding array node containing a string element.")
				array_node = Nokogiri::XML::Node.new("array",doc)
				array_node.add_child(string_app_group_value)
				key_node.add_next_sibling(array_node)
			end
		end

		File.open(filepath,'w') do |file|
			@logger.info("\tWriting changes to entitlements: #{filepath}")
			file.puts Nokogiri::XML(doc.to_xml) { |x| x.noblanks }
		end
	end
end

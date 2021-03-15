$:.push File.expand_path("../lib", __FILE__)
require "mmine/version"

Gem::Specification.new do |s|
  s.required_ruby_version = '>= 2.3.8'
  s.executables = ['mmine']
  s.name        = 'mmine'
  s.version     = Mmine::VERSION
  s.date		= '2018-10-16'
  s.summary     = "Mobile Messaging iOS Notification Extension Integration Tool made at Infobip (https://www.infobip.com)!!!"
  s.description = "Use this tool to automatically integrate your Xcode project with Infobips (https://www.infobip.com) Notification Service Extension"
  s.authors     = ["Andrey Kadochnikov"]
  s.email       = 'andrey.kadochnikov@infobip.com'
  s.homepage    = 'https://github.com/infobip/mobile-messaging-mmine'
  s.metadata 	= {"source_code_url" => "https://github.com/infobip/mobile-messaging-mmine"}
  s.files 		= Dir['lib/*'] + Dir['lib/mmine/*'] + Dir['bin/*'] + Dir['resources/*']
  s.license		= 'MIT'
  s.add_runtime_dependency 'xcodeproj', '=1.10.0'
  s.add_runtime_dependency 'nokogiri', '=1.11.0'
end

# release command: gem bump -v patch --tag --release --push
# rebuild/run (native): sudo gem build mmine.gemspec;sudo gem install mmine;./bin/mmine integrate -p /Users/akadochnikov/nescript/nescript.xcodeproj -g group.com.mobile-messaging.notification-service-extension -t nescript -a 0-dasdasd-adasdasda-dasdad-1 -v
# rebuild/run (cordova): sudo gem build mmine.gemspec;sudo gem install mmine;./bin/mmine integrate -p /Users/akadochnikov/cordovane1/platforms/ios/HelloCordova.xcodeproj -g group.com.mobile-messaging.notification-service-extension -t HelloCordova -a 0-dasdasd-adasdasda-dasdad-1 -v -c
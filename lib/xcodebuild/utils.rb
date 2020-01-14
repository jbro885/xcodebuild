require 'shellwords'
require 'fileutils'
require 'date'
require 'xcodebuild/run'
require 'xcodebuild/package'

module XcodeBuild

  PID = $$

  # @return [String] the value of the environment variable DEVELOPER_DIR if set, otherwise the path returned by
  # xcode-select -p.
  def self.xcode_path
    ENV.fetch('DEVELOPER_DIR', `xcode-select -p`.chomp)
  end

  def self.transporter_path
    search_root = self.xcode_path
    # This is where iTMSTransporter is located in Xcode 11, so we'll try this first; otherwise, we'll search for it
    path = File.join(search_root, 'usr/bin/iTMSTransporter')
    if File.exist?(path)
      return path
    else
      matches = Dir.glob("#{search_root}/**/bin/iTMSTransporter")
      if matches.length == 0
        raise "iTMSTransporter not found."
      else
        return matches[0]
      end
    end
  end

  def self.is_ci_build
    # CI is set by Circle CI
    # TRAVIS is set by Travis CI
    # TF_BUILD is set by Azure Pipelines ("TF" is "Team Foundation")
    # XCS is set by Xcode Server
    # GITHUB_ACTIONS is set by GitHub Actions
    ENV['CI'] == 'true' || ENV['TRAVIS'] == 'true' || ENV['TF_BUILD'] == 'True' || ENV['XCS'].to_i == 1 || ENV['GITHUB_ACTIONS'] == 'true'
  end

  def self.is_dev_build
    !is_ci_build
  end

  def self.install_certificate(certificate)
    build_keychain = "Build-#{PID}.keychain"

    # Get original list of keychains so we can restore these when we're done building
    original_keychains = %x{security list-keychains -d user}.shellsplit
    certificate_password = ENV.fetch('CERTIFICATE_PASSWORD', '')

    run('security', 'create-keychain', '-p', '', build_keychain)
    run('security', 'unlock-keychain', '-p', '', build_keychain)
    run('security', 'default-keychain', '-d', 'user', '-s', build_keychain)
    run('security', 'list-keychains', '-s', build_keychain, '/Library/Keychains/System.keychain')

    at_exit do
      run('security', 'delete-keychain', build_keychain)
      run(*%w(security list-keychains -s).concat(original_keychains))
      run(*%w(security default-keychain -s login.keychain))
    end

    #run('security', 'import', certificate, '-k', build_keychain, '-t', 'cert', '-f', 'pkcs12',
    #    '-P', certificate_password, '-A')

    run('security', 'import', certificate, '-k', build_keychain, '-t', 'cert', '-f', 'pkcs12',
        '-T', '/usr/bin/codesign', '-T', '/usr/bin/xcodebuild', '-P', certificate_password)
    run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', '', build_keychain)
    run('security', 'set-keychain-settings', '-lut', '3600', build_keychain)

  end

  def self.install_provisioning_profile(profile)
    profiles_dir = File.expand_path '~/Library/MobileDevice/Provisioning Profiles'
    unless File.exists?(profiles_dir)
      puts "Creating #{profiles_dir}."
      FileUtils::makedirs(profiles_dir)
    end
    puts "Copying #{profile} to #{profiles_dir}"
    profile_copy = File.join(profiles_dir, File.basename(profile))
    FileUtils::copy_file(profile, profile_copy)

    at_exit do
      puts "Removing provisioning profile #{profile_copy}"
      FileUtils.remove(profile_copy)
    end
  end

  def self.default_build_number
    date = Date.today
    "#{date.year}.#{date.yday}.0"
  end

  def self.build_number
    ENV.fetch('BUILD_NUMBER', default_build_number)
  end

  # Runs xcodebuild.
  def self.xcodebuild(scheme, configuration, args, action, project, build_settings)
    env = {'DEVELOPER_DIR' => self.xcode_path}

    xcode_args = Array.new
    xcode_args << 'xcodebuild'
    if project.project
      xcode_args << '-project' << project.project
    else
      xcode_args << '-workspace' << project.workspace
    end

    xcode_args << '-scheme' << scheme

    if configuration
      xcode_args << '-configuration' << configuration
    end

    xcode_args.concat(args)
    xcode_args << action

    xcode_args << "OBJROOT=#{project.build_dir}/Intermediates"
    xcode_args << "SHARED_PRECOMPS_DIR=#{project.build_dir}/PrecompiledHeaders"
    xcode_args << "CURRENT_PROJECT_VERSION=#{build_number}"
    xcode_args.concat(build_settings)

    if action == 'test'
      test_log = "#{project.build_dir}/#{scheme}-test.log"
      run(env, *xcode_args, :out => test_log)
      process_test_log(test_log, scheme, project.build_dir)
    else
      run(env, *xcode_args)
    end
  end

  # Runs xcodebuild archive with a Build object.
  def self.archive(build)
    args = Array.new
    args << '-archivePath' << build.archive_path.to_s
    args << '-sdk' << build.sdk

    build_settings = Array.new
    if build.certificate && !is_dev_build
      build_keychain = "Build-#{PID}.keychain"
      build_settings << "OTHER_CODE_SIGN_FLAGS=--keychain #{build_keychain}"
    end

    if build.code_sign_style
      build_settings << "CODE_SIGN_STYLE=#{build.code_sign_style}"
    end
    if build.code_signing_identity
      build_settings << "CODE_SIGN_IDENTITY=#{build.code_signing_identity}"
    end
    if build.provisioning_profile
      build_settings << "PROVISIONING_PROFILE_SPECIFIER=#{build.provisioning_profile}"
    end

    xcodebuild(build.scheme, build.configuration, args, 'archive', build.project, build_settings)
  end

  # Runs xcodebuild test with a Test object.
  def self.test(test)
    args = Array.new
    args << '-sdk' << test.sdk
    args << '-destination' << test.destinations.join(',')
    args << '-sdk' << test.sdk

    xcodebuild(test.scheme, test.configuration, args, 'test', test.project, [])
  end

  def self.export_archive(build)
    env = {'DEVELOPER_DIR' => self.xcode_path}

    xcode_args = Array.new
    xcode_args << 'xcodebuild' << '-exportArchive'
    xcode_args << '-exportOptionsPlist' << build.export_options_plist
    xcode_args << '-archivePath' << build.archive_path.to_s
    xcode_args << '-exportPath' << build.export_path.to_s

    run(env, *xcode_args)
  end

  def self.make_deploy_script(project)
    deploy_ruby_file = File.join(File.dirname(__FILE__), '_deploy.rb')
    FileUtils.copy(deploy_ruby_file, project.packages_path / 'deploy.rb')
  end

  def self.export_packages(project)
    project.builds.each do |build|
      platform = case build.sdk
                 when 'iphoneos'
                   'ios'
                 when 'appletvos'
                   'appletvos'
                 when 'macosx'
                   'osx'
                 end
      package = XcodeBuild::Package.new(build.ipa_path, build.app_id, platform)
      package.make_itmsp(build.package_path)
    end
  end

  def self.upload_build_to_test_flight(build, username, password)
    XcodeBuild.run(XcodeBuild.transporter_path, '-m', 'upload', '-f', build.package_path.to_s, '-u', username, '-p', password, '-v', 'detailed')
  end

  def self.fix_test_output(test_log)
    content = File.read(test_log)
    content.sub!("** TEST SUCCEEDED **\n\n", '')
    File.open(test_log, 'w') {|file| file.puts content}
  end

  def self.process_test_log(test_log, scheme, build_dir)
    fix_test_output(test_log)
    args = %w(xcpretty --report junit --output)
    args << "#{build_dir}/#{scheme}-junit.xml"
    run(*args, :in => test_log)
  end

end